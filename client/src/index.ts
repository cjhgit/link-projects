import './env';
import { WebSocket } from 'ws';
import { spawn, type ChildProcess } from 'node:child_process';
import { hostname as osHostname, homedir } from 'node:os';
import { readFile, writeFile, rm, mkdir, readdir, stat } from 'node:fs/promises';
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
  openSync,
  closeSync,
  writeSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import type {
  AnyMsg,
  ExecMsg,
  FileEntry,
  FileCreateMsg,
  FileDeleteMsg,
  FileListMsg,
  FileReadMsg,
  FileWriteMsg,
} from './protocol';

// ---------- 命令行解析：start（默认，后台运行）/ stop / status / restart / run（前台调试） ----------

const COMMANDS = ['start', 'stop', 'status', 'restart', 'run'] as const;
type Command = (typeof COMMANDS)[number];

const argv = process.argv.slice(2);
const first = argv[0] && !argv[0].startsWith('-') ? argv[0] : undefined;
if (first && !(COMMANDS as readonly string[]).includes(first)) {
  console.error(`[client] 未知命令：${first}\n`);
  usage();
  process.exit(1);
}
const command = (first ?? 'start') as Command;
const args = first ? argv.slice(1) : argv;

// 配置：环境变量优先，其次命令行参数 --server / --id / --token
function argOf(name: string): string | undefined {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

const SERVER = argOf('server') || process.env.LINK_SERVER || 'ws://127.0.0.1:9600';
const CLIENT_ID = argOf('id') || process.env.LINK_CLIENT_ID || osHostname();
const TOKEN = argOf('token') || process.env.LINK_TOKEN || '';

// 自身版本（package.json 的 version，dev 与 dist 两种运行方式下 package.json 都在上级目录）
const VERSION: string = JSON.parse(readFileSync(join(__dirname, '..', 'package.json'), 'utf8')).version;

// ---------- 运行时文件：pid 与日志都在 ~/.link-projects/ ----------

const RUNTIME_DIR = join(homedir(), '.link-projects');
const PID_FILE = join(RUNTIME_DIR, 'client.pid');
const LOG_FILE = join(RUNTIME_DIR, 'client.log');

// ---------- 日志加时间戳（后台写文件后便于排查） ----------

function timestamp(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
const rawLog = console.log.bind(console);
const rawError = console.error.bind(console);
console.log = (...a: unknown[]) => rawLog(`[${timestamp()}]`, ...a);
console.error = (...a: unknown[]) => rawError(`[${timestamp()}]`, ...a);

function usage(): void {
  console.log(`用法：node dist/index.js [命令] [选项]

命令：
  start     后台启动（默认，不带命令时等同 start）
  stop      停止后台进程
  status    查看运行状态与最近日志
  restart   重启（配置修改后生效用）
  run       前台运行（调试用，Ctrl+C 退出）

选项：--server <ws://...> --id <clientId> --token <token>
配置也可通过环境变量 / .env 提供，详见 .env.example`);
}

// ---------- pid 文件辅助 ----------

function readPid(): number | undefined {
  try {
    const n = parseInt(readFileSync(PID_FILE, 'utf8').trim(), 10);
    return Number.isFinite(n) && n > 0 ? n : undefined;
  } catch {
    return undefined;
  }
}

function writePid(pid: number): void {
  mkdirSync(RUNTIME_DIR, { recursive: true });
  writeFileSync(PID_FILE, `${pid}\n`);
}

// 只清理属于当前进程的 pid 文件，避免误删其他实例的
function cleanupPid(): void {
  if (readPid() === process.pid) {
    try { unlinkSync(PID_FILE); } catch { /* 忽略 */ }
  }
}

// 进程是否存在（signal 0 探测；EPERM 说明进程存在但无权限）
function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: any) {
    return err.code === 'EPERM';
  }
}

function tailLog(lines: number): string {
  try {
    const all = readFileSync(LOG_FILE, 'utf8').split('\n').filter((l) => l.trim() !== '');
    return all.slice(-lines).join('\n');
  } catch {
    return '（暂无日志）';
  }
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ---------- 命令实现 ----------

async function startDaemon(): Promise<void> {
  mkdirSync(RUNTIME_DIR, { recursive: true });

  const existing = readPid();
  if (existing && isAlive(existing)) {
    console.log(`[client] 已在运行（pid ${existing}），如需重启请用 restart`);
    process.exit(0);
  }

  // 后台子进程：node <本脚本> run <透传选项>；dev 模式（tsx 直跑 .ts）则用 tsx 拉起
  const scriptArgs = [__filename, 'run', ...args];
  if (__filename.endsWith('.ts')) {
    scriptArgs.unshift(require.resolve('tsx/cli'));
  }

  const logFd = openSync(LOG_FILE, 'a');
  writeSync(logFd, `\n===== ${timestamp()} 后台启动 server=${SERVER} id=${CLIENT_ID} =====\n`);
  const child = spawn(process.execPath, scriptArgs, {
    detached: true,
    stdio: ['ignore', logFd, logFd],
  });
  closeSync(logFd);
  child.unref();

  // 等待子进程写入 pid 文件确认启动成功
  for (let i = 0; i < 25; i++) {
    await sleep(200);
    const pid = readPid();
    // dev 模式（tsx）下写 pid 的是 tsx 内部再拉起的 node 进程，pid 不同于 child.pid，
    // 因此只要 pid 文件新写入且该进程存活即认为启动成功（开头已清理过残留 pid）
    if (pid !== undefined && isAlive(pid)) {
      // 再等一小会，把“启动即退出”（如 token 配错被拒）拦在这里
      await sleep(600);
      if (!isAlive(pid)) {
        console.error('[client] 进程启动后立即退出，最近日志：');
        console.error(tailLog(20));
        process.exit(1);
      }
      console.log(`[client] 已后台启动（pid ${child.pid}）`);
      console.log(`[client] server=${SERVER} id=${CLIENT_ID}，日志：${LOG_FILE}`);
      return;
    }
    if (child.exitCode !== null || child.signalCode) {
      console.error('[client] 启动失败，最近日志：');
      console.error(tailLog(20));
      process.exit(1);
    }
  }
  console.error('[client] 启动超时：未检测到 pid 文件，最近日志：');
  console.error(tailLog(20));
  process.exit(1);
}

async function stopDaemon(): Promise<boolean> {
  const pid = readPid();
  if (!pid) {
    console.log('[client] 未在运行');
    return false;
  }
  if (!isAlive(pid)) {
    cleanupStalePid(pid);
    console.log('[client] 未在运行（进程已退出，已清理残留 pid 文件）');
    return false;
  }

  process.kill(pid, 'SIGTERM');
  for (let i = 0; i < 20 && isAlive(pid); i++) {
    await sleep(250);
  }
  if (isAlive(pid)) {
    console.log('[client] 未响应 SIGTERM，强制结束');
    process.kill(pid, 'SIGKILL');
  }
  cleanupStalePid(pid);
  console.log(`[client] 已停止（pid ${pid}）`);
  return true;
}

function cleanupStalePid(pid: number): void {
  if (readPid() === pid) {
    try { unlinkSync(PID_FILE); } catch { /* 忽略 */ }
  }
}

async function showStatus(): Promise<void> {
  const pid = readPid();
  if (pid && isAlive(pid)) {
    console.log(`[client] 运行中（pid ${pid}）`);
    console.log(`[client] server=${SERVER} id=${CLIENT_ID}`);
    console.log(`[client] 日志 ${LOG_FILE}，最近 10 行：`);
    console.log(tailLog(10));
  } else {
    console.log('[client] 未在运行');
    if (pid) {
      cleanupStalePid(pid);
      console.log('[client] 已清理残留 pid 文件');
    }
  }
}

async function restartDaemon(): Promise<void> {
  await stopDaemon();
  await sleep(300);
  await startDaemon();
}

// ---------- 前台运行（原客户端逻辑） ----------

const RECONNECT_DELAY = 3000;
let ws: WebSocket;
const runningChildren = new Set<ChildProcess>();

function reply(msg: AnyMsg) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function shutdown(code: number): void {
  try { ws?.close(); } catch { /* 忽略 */ }
  for (const child of runningChildren) {
    try { child.kill(); } catch { /* 忽略 */ }
  }
  cleanupPid();
  process.exit(code);
}

function connect() {
  ws = new WebSocket(SERVER);

  ws.on('open', () => {
    ws.send(JSON.stringify({
      type: 'register',
      role: 'client',
      clientId: CLIENT_ID,
      token: TOKEN,
      version: VERSION,
    }));
    console.log(`[client] 已连接 ${SERVER}，以 ${CLIENT_ID} 注册`);
  });

  ws.on('message', (raw) => {
    let msg: AnyMsg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }

    switch (msg.type) {
      case 'registered':
        if (!msg.ok) {
          console.error(`[client] 注册被拒绝：${msg.error}，退出`);
          shutdown(1);
        }
        console.log('[client] 注册成功，等待指令');
        break;
      case 'exec':
        return handleExec(msg as ExecMsg);
      case 'file-read':
        return handleFileRead(msg as FileReadMsg);
      case 'file-write':
        return handleFileWrite(msg as FileWriteMsg);
      case 'file-create':
        return handleFileCreate(msg as FileCreateMsg);
      case 'file-delete':
        return handleFileDelete(msg as FileDeleteMsg);
      case 'file-list':
        return handleFileList(msg as FileListMsg);
    }
  });

  ws.on('close', () => {
    console.log(`[client] 连接断开，${RECONNECT_DELAY / 1000}s 后重连`);
    setTimeout(connect, RECONNECT_DELAY);
  });

  ws.on('error', (err) => {
    console.error(`[client] 连接错误: ${err.message}`);
  });
}

function handleExec(msg: ExecMsg) {
  console.log(`[exec] ${msg.command}${msg.cwd ? ` (cwd: ${msg.cwd})` : ''}`);
  const child = spawn('/bin/bash', ['-c', msg.command], {
    cwd: msg.cwd || undefined,
  });
  runningChildren.add(child);
  child.on('exit', () => runningChildren.delete(child));

  child.stdout.on('data', (d) => {
    reply({ type: 'exec-output', reqId: msg.reqId, targetId: msg.targetId, stream: 'stdout', data: d.toString() });
  });
  child.stderr.on('data', (d) => {
    reply({ type: 'exec-output', reqId: msg.reqId, targetId: msg.targetId, stream: 'stderr', data: d.toString() });
  });
  child.on('error', (err) => {
    reply({ type: 'exec-output', reqId: msg.reqId, targetId: msg.targetId, stream: 'stderr', data: `启动失败: ${err.message}\n` });
    reply({ type: 'exec-exit', reqId: msg.reqId, targetId: msg.targetId, code: 127 });
  });
  child.on('exit', (code) => {
    reply({ type: 'exec-exit', reqId: msg.reqId, targetId: msg.targetId, code });
  });
}

async function handleFileRead(msg: FileReadMsg) {
  console.log(`[file-read] ${msg.path}`);
  try {
    const content = await readFile(msg.path, 'utf8');
    reply({ type: 'file-content', reqId: msg.reqId, targetId: msg.targetId, path: msg.path, content });
  } catch (err: any) {
    reply({ type: 'file-content', reqId: msg.reqId, targetId: msg.targetId, path: msg.path, error: err.message });
  }
}

async function handleFileWrite(msg: FileWriteMsg) {
  console.log(`[file-write] ${msg.path} (${msg.content.length} 字符)`);
  try {
    // 目标目录不存在时自动创建
    await mkdir(dirname(msg.path), { recursive: true });
    await writeFile(msg.path, msg.content, 'utf8');
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: true });
  } catch (err: any) {
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: false, error: err.message });
  }
}

// 新建空文本文件：wx 标志保证仅在不存在时创建（已存在报 EEXIST，绝不动已有内容）
async function handleFileCreate(msg: FileCreateMsg) {
  console.log(`[file-create] ${msg.path}`);
  try {
    await writeFile(msg.path, '', { flag: 'wx' });
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: true });
  } catch (err: any) {
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: false, error: err.message });
  }
}

// 删除文件或目录（目录递归删除；force 默认 false，路径不存在时报错）
async function handleFileDelete(msg: FileDeleteMsg) {
  console.log(`[file-delete] ${msg.path}`);
  try {
    await rm(msg.path, { recursive: true });
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: true });
  } catch (err: any) {
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: false, error: err.message });
  }
}

// 目录列举：~ / 空路径展开为家目录；符号链接跟随目标（指向目录的链接可继续进入），
// 单项 stat 失败（失效链接等）不拖垮整个列表，标记为 other
async function handleFileList(msg: FileListMsg) {
  const raw = (msg.path || '').trim() || '~';
  const target = raw === '~' || raw.startsWith('~/')
    ? join(homedir(), raw.slice(1))
    : raw;
  console.log(`[file-list] ${raw} -> ${target}`);
  try {
    const dirents = await readdir(target, { withFileTypes: true });
    const entries: FileEntry[] = await Promise.all(dirents.map(async (d): Promise<FileEntry> => {
      let kind: FileEntry['kind'] = 'other';
      let size = 0;
      let mtime = 0;
      try {
        const st = await stat(join(target, d.name));
        if (st.isDirectory()) kind = 'dir';
        else if (st.isFile()) { kind = 'file'; size = st.size; }
        mtime = st.mtimeMs;
      } catch { /* 保留 other */ }
      return { name: d.name, kind, size, mtime };
    }));
    const order: Record<FileEntry['kind'], number> = { dir: 0, file: 1, other: 2 };
    entries.sort((a, b) =>
      order[a.kind] - order[b.kind] ||
      a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })
    );
    reply({ type: 'file-listing', reqId: msg.reqId, targetId: msg.targetId, path: target, entries });
  } catch (err: any) {
    reply({ type: 'file-listing', reqId: msg.reqId, targetId: msg.targetId, path: target, error: err.message });
  }
}

function runForeground(): void {
  if (!TOKEN) {
    console.error('缺少 token（--token 或环境变量 LINK_TOKEN）');
    process.exit(1);
  }
  const existing = readPid();
  if (existing && isAlive(existing)) {
    console.error(`[client] 已有一个实例在运行（pid ${existing}），同机仅支持单实例，请先 stop 或用 restart`);
    process.exit(1);
  }
  console.log(`[client] 前台运行：server=${SERVER} id=${CLIENT_ID}（Ctrl+C 退出）`);
  writePid(process.pid);
  process.on('SIGINT', () => shutdown(0));
  process.on('SIGTERM', () => shutdown(0));
  connect();
}

// ---------- 入口 ----------

async function main(): Promise<void> {
  switch (command) {
    case 'start':
      if (!TOKEN) {
        console.error('缺少 token（--token 或环境变量 LINK_TOKEN）');
        process.exit(1);
      }
      return startDaemon();
    case 'stop':
      await stopDaemon();
      return;
    case 'status':
      return showStatus();
    case 'restart':
      return restartDaemon();
    case 'run':
      return runForeground();
  }
}

main();
