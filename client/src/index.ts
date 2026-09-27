import './env';
import { WebSocket } from 'ws';
import { spawn, type ChildProcess } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { hostname as osHostname, homedir } from 'node:os';
import { readFile, writeFile, rm, mkdir, readdir, stat, rename } from 'node:fs/promises';
import {
  mkdirSync,
  readFileSync,
  writeFileSync,
  unlinkSync,
  openSync,
  closeSync,
  writeSync,
  readSync,
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
  FileUploadStartMsg,
  FileUploadChunkMsg,
  FileUploadFinishMsg,
  FileDownloadMsg,
  AgentListMsg,
  AgentRunMsg,
  AgentStatusMsg,
  AgentDeleteMsg,
  AgentSession,
  ProjectListMsg,
  ProjectSaveMsg,
  ProjectDeleteMsg,
  Project,
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
// Claude Code 的会话摘要与对话记录属于云电脑，不经过 controller / server 存储。
const AGENT_SESSIONS_FILE = join(RUNTIME_DIR, 'claude-sessions.json');
const DEFAULT_AGENT_CWD = join(RUNTIME_DIR, 'workspace');
const agentProcesses = new Map<string, ChildProcess>();
let agentSessions: AgentSession[] = [];
// 项目（常用目录）同样属于云电脑，保存在本机。
const PROJECTS_FILE = join(RUNTIME_DIR, 'projects.json');
let projects: Project[] = [];

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
// 进行中的上传：reqId -> 临时文件句柄（断线时统一清理，避免残留半截文件）
const uploadTemp = new Map<string, { fd: number; tmpPath: string; finalPath: string; size: number; error?: string }>();
// 上传 / 下载分块大小（base64 后约 700KB，兼顾消息体积与条数）
const TRANSFER_CHUNK = 512 * 1024;
const MAX_DOWNLOAD_SIZE = 1024 * 1024 * 1024; // 超过 1GB 拒绝下载

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
  cleanupUploads();
  // stop / 重启时不让 Claude 子进程脱离 client 继续运行；同步落盘使下次刷新能看见原因。
  if (agentProcesses.size > 0) {
    const now = Date.now();
    for (const [sessionId, child] of agentProcesses) {
      try { child.kill(); } catch { /* 忽略 */ }
      const session = agentSessions.find((item) => item.sessionId === sessionId);
      if (session) {
        session.state = 'failed';
        session.error = '云电脑客户端已停止，任务已终止';
        session.updatedAt = now;
      }
    }
    try {
      mkdirSync(RUNTIME_DIR, { recursive: true });
      writeFileSync(AGENT_SESSIONS_FILE, JSON.stringify(agentSessions, null, 2), 'utf8');
    } catch (err: any) {
      console.error(`[agent] 停止时保存会话失败: ${err.message}`);
    }
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
      case 'file-upload-start':
        return handleFileUploadStart(msg as FileUploadStartMsg);
      case 'file-upload-chunk':
        return handleFileUploadChunk(msg as FileUploadChunkMsg);
      case 'file-upload-finish':
        return handleFileUploadFinish(msg as FileUploadFinishMsg);
      case 'file-download':
        return handleFileDownload(msg as FileDownloadMsg);
      case 'agent-list':
        return handleAgentList(msg as AgentListMsg);
      case 'agent-run':
        return handleAgentRun(msg as AgentRunMsg);
      case 'agent-status':
        return handleAgentStatus(msg as AgentStatusMsg);
      case 'agent-delete':
        return handleAgentDelete(msg as AgentDeleteMsg);
      case 'project-list':
        return handleProjectList(msg as ProjectListMsg);
      case 'project-save':
        return handleProjectSave(msg as ProjectSaveMsg);
      case 'project-delete':
        return handleProjectDelete(msg as ProjectDeleteMsg);
    }
  });

  ws.on('close', () => {
    console.log(`[client] 连接断开，${RECONNECT_DELAY / 1000}s 后重连`);
    // 断线时进行中的上传必然残缺，清掉临时文件（控制端等不到回执也会放弃）
    cleanupUploads();
    setTimeout(connect, RECONNECT_DELAY);
  });

  ws.on('error', (err) => {
    console.error(`[client] 连接错误: ${err.message}`);
  });
}

// ---------- Claude Code 会话 ----------

async function loadAgentSessions(): Promise<void> {
  try {
    const parsed = JSON.parse(await readFile(AGENT_SESSIONS_FILE, 'utf8'));
    agentSessions = Array.isArray(parsed) ? parsed : [];
    // client 重启意味着旧 CLI 子进程不可能仍由本实例托管，避免永久显示“运行中”。
    let changed = false;
    for (const session of agentSessions) {
      if (session.state === 'running') {
        session.state = 'failed';
        session.error = '云电脑客户端已重启，之前的任务状态未知，请继续对话或重新发起任务';
        session.updatedAt = Date.now();
        changed = true;
      }
    }
    if (changed) await persistAgentSessions();
  } catch (err: any) {
    if (err?.code !== 'ENOENT') console.error(`[agent] 读取会话失败: ${err.message}`);
    agentSessions = [];
  }
}

async function persistAgentSessions(): Promise<void> {
  await mkdir(RUNTIME_DIR, { recursive: true });
  const tmp = `${AGENT_SESSIONS_FILE}.tmp`;
  await writeFile(tmp, JSON.stringify(agentSessions, null, 2), 'utf8');
  await rename(tmp, AGENT_SESSIONS_FILE);
}

function agentSnapshot(session: AgentSession): AgentSession {
  // JSON 往返同时避免调用方意外改写内存中的会话记录。
  return JSON.parse(JSON.stringify(session)) as AgentSession;
}

function replyAgent(reqId: string, targetId: string, sessions: AgentSession[]) {
  reply({ type: 'agent-sessions', reqId, targetId, sessions: sessions.map(agentSnapshot) });
}

function handleAgentList(msg: AgentListMsg) {
  // 最近更新的排在前面，列表不依赖 controller 保留任何状态。
  replyAgent(msg.reqId, msg.targetId, [...agentSessions].sort((a, b) => b.updatedAt - a.updatedAt));
}

function handleAgentStatus(msg: AgentStatusMsg) {
  const session = agentSessions.find((item) => item.sessionId === msg.sessionId);
  replyAgent(msg.reqId, msg.targetId, session ? [session] : []);
}

async function handleAgentDelete(msg: AgentDeleteMsg) {
  const index = agentSessions.findIndex((item) => item.sessionId === msg.sessionId);
  if (index < 0) return reply({ type: 'error', reqId: msg.reqId, message: '找不到该 Link 会话记录' });
  if (agentSessions[index].state === 'running') {
    return reply({ type: 'error', reqId: msg.reqId, message: '会话仍在执行中，完成后才能删除' });
  }
  // 仅移除 ~/.link-projects/claude-sessions.json 中的条目；绝不触碰 Claude Code 原生会话。
  agentSessions.splice(index, 1);
  try {
    await persistAgentSessions();
    replyAgent(msg.reqId, msg.targetId, []);
  } catch (err: any) {
    reply({ type: 'error', reqId: msg.reqId, message: `删除 Link 会话记录失败: ${err.message}` });
  }
}

function handleAgentRun(msg: AgentRunMsg) {
  const prompt = msg.prompt.trim();
  if (!prompt) return replyAgent(msg.reqId, msg.targetId, []);

  let session: AgentSession | undefined;
  if (msg.sessionId) session = agentSessions.find((item) => item.sessionId === msg.sessionId);
  if (msg.sessionId && !session) {
    return reply({ type: 'error', reqId: msg.reqId, message: '找不到该 Claude 会话（它可能已在云电脑上被删除）' });
  }
  if (session && session.state === 'running') {
    return reply({ type: 'error', reqId: msg.reqId, message: '该会话仍在执行中，请稍后刷新状态' });
  }

  const now = Date.now();
  if (!session) {
    const requestedCwd = msg.cwd?.trim();
    const cwd = requestedCwd
      ? (requestedCwd === '~' || requestedCwd.startsWith('~/') ? join(homedir(), requestedCwd.slice(1)) : requestedCwd)
      : DEFAULT_AGENT_CWD;
    // 默认工作区以及用户明确指定的不存在目录都会创建，避免 Claude 因 cwd 不存在直接启动失败。
    try { mkdirSync(cwd, { recursive: true }); } catch (err: any) {
      return reply({ type: 'error', reqId: msg.reqId, message: `无法创建 Agent 工作目录 ${cwd}: ${err.message}` });
    }
    session = {
      sessionId: randomUUID(),
      title: prompt.replace(/\s+/g, ' ').slice(0, 48),
      cwd,
      state: 'running',
      createdAt: now,
      updatedAt: now,
      messages: [],
    };
    agentSessions.push(session);
  } else {
    session.state = 'running';
    session.error = undefined;
    session.updatedAt = now;
    if (msg.cwd?.trim()) session.cwd = msg.cwd.trim();
  }
  session.messages.push({ role: 'user', content: prompt, createdAt: now });
  persistAgentSessions().catch((err) => console.error(`[agent] 保存会话失败: ${err.message}`));
  // 立即回 running 快照；网络中断时控制端可稍后用 agent-status / agent-list 拉取最终结果。
  replyAgent(msg.reqId, msg.targetId, [session]);

  // 云电脑 Agent 没有可供用户确认的本地交互界面；显式跳过 Claude Code 的逐次权限询问，
  // 使其能按用户在控制端发起的任务读取和修改工作目录中的文件。
  // include-partial-messages 才会在 stream-json 中输出 token 级 text_delta；否则通常只会收到结束结果。
  const args = ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--dangerously-skip-permissions'];
  if (msg.sessionId) args.push('--resume', session.sessionId);
  else args.push('--session-id', session.sessionId);
  console.log(`[agent] ${msg.sessionId ? '继续' : '新建'}会话 ${session.sessionId}${session.cwd ? ` (cwd: ${session.cwd})` : ''}`);
  const child = spawn('claude', args, { cwd: session.cwd || undefined, env: process.env });
  agentProcesses.set(session.sessionId, child);
  let stdout = '';
  let stderr = '';
  let streamBuffer = '';
  let streamedText = '';
  let assistantMessage: AgentSession['messages'][number] | undefined;
  const publishStream = () => {
    session!.updatedAt = Date.now();
    // 每个增量既主动推送给在线控制端，也写入云电脑；断线时刷新仍可恢复。
    persistAgentSessions().catch((err) => console.error(`[agent] 保存流式输出失败: ${err.message}`));
    replyAgent(msg.reqId, msg.targetId, [session!]);
  };
  const consumeStreamLine = (line: string) => {
    if (!line.trim()) return;
    try {
      const event = JSON.parse(line);
      const delta = event?.event?.delta;
      const text = delta?.type === 'text_delta' ? delta.text : undefined;
      if (typeof text === 'string' && text) {
        if (!assistantMessage) {
          assistantMessage = { role: 'assistant', content: '', createdAt: Date.now() };
          session!.messages.push(assistantMessage);
        }
        assistantMessage.content += text;
        streamedText += text;
        publishStream();
      }
    } catch { /* 非 JSON 行留到 close 时作为异常诊断 */ }
  };
  child.stdout.on('data', (data) => {
    const chunk = data.toString();
    stdout += chunk;
    streamBuffer += chunk;
    const lines = streamBuffer.split(/\r?\n/);
    streamBuffer = lines.pop() ?? '';
    for (const line of lines) consumeStreamLine(line);
  });
  child.stderr.on('data', (data) => { stderr += data.toString(); });
  child.on('error', async (err) => {
    if (err.message.includes('ENOENT')) stderr += '未找到 claude 命令，请确认云电脑已安装 Claude Code CLI 且已登录。';
  });
  child.on('close', async (code) => {
    agentProcesses.delete(session!.sessionId);
    const finished = Date.now();
    if (streamBuffer) consumeStreamLine(streamBuffer);
    let result = '';
    // stream-json 的最终 result 事件带完整结果；仅在未收到文本增量时作为回退，避免重复展示。
    for (const line of stdout.split(/\r?\n/)) {
      try {
        const event = JSON.parse(line);
        if (event.type === 'result') {
          if (event.is_error) stderr ||= typeof event.result === 'string' ? event.result : 'Claude Code 执行失败';
          if (typeof event.result === 'string') result = event.result;
        }
      } catch { /* 忽略非 JSON 行 */ }
    }
    if (!streamedText && result) session!.messages.push({ role: 'assistant', content: result, createdAt: finished });
    session!.updatedAt = finished;
    if (code === 0 && !stderr) {
      session!.state = 'completed';
    } else {
      session!.state = 'failed';
      session!.error = stderr.trim() || `Claude Code 退出码 ${code ?? '未知'}`;
    }
    try { await persistAgentSessions(); } catch (err: any) { console.error(`[agent] 保存会话失败: ${err.message}`); }
    // 流式阶段已推送 running；退出时必须再推送最终 completed / failed，控制端才能关闭 loading。
    replyAgent(msg.reqId, msg.targetId, [session!]);
    console.log(`[agent] 会话 ${session!.sessionId} ${session!.state}`);
  });
}

// ---------- 项目（常用目录，本机持久化） ----------

async function loadProjects(): Promise<void> {
  try {
    const parsed = JSON.parse(await readFile(PROJECTS_FILE, 'utf8'));
    projects = Array.isArray(parsed) ? parsed : [];
  } catch (err: any) {
    if (err?.code !== 'ENOENT') console.error(`[project] 读取项目失败: ${err.message}`);
    projects = [];
  }
}

async function persistProjects(): Promise<void> {
  await mkdir(RUNTIME_DIR, { recursive: true });
  const tmp = `${PROJECTS_FILE}.tmp`;
  await writeFile(tmp, JSON.stringify(projects, null, 2), 'utf8');
  await rename(tmp, PROJECTS_FILE);
}

function replyProjects(reqId: string, targetId: string) {
  // 按创建顺序返回（即添加顺序），列表不依赖 controller 保留任何状态。
  reply({ type: 'projects', reqId, targetId, projects: [...projects].sort((a, b) => a.createdAt - b.createdAt) });
}

function handleProjectList(msg: ProjectListMsg) {
  replyProjects(msg.reqId, msg.targetId);
}

async function handleProjectSave(msg: ProjectSaveMsg) {
  const rawPath = msg.path.trim();
  if (!rawPath) return reply({ type: 'error', reqId: msg.reqId, message: '项目目录不能为空' });
  // ~ 开头展开为家目录，其余按绝对路径保存
  const path = rawPath === '~' || rawPath.startsWith('~/') ? join(homedir(), rawPath.slice(1)) : rawPath;
  const name = msg.name.trim() || (path.split('/').filter(Boolean).pop() ?? path);
  const now = Date.now();
  const existing = msg.projectId ? projects.find((item) => item.projectId === msg.projectId) : undefined;
  if (msg.projectId && !existing) {
    return reply({ type: 'error', reqId: msg.reqId, message: '找不到该项目（它可能已在云电脑上被删除）' });
  }
  if (existing) {
    existing.name = name;
    existing.path = path;
    existing.updatedAt = now;
  } else {
    projects.push({ projectId: randomUUID(), name, path, createdAt: now, updatedAt: now });
  }
  console.log(`[project] ${existing ? '更新' : '新增'} ${name} (${path})`);
  try {
    await persistProjects();
    replyProjects(msg.reqId, msg.targetId);
  } catch (err: any) {
    reply({ type: 'error', reqId: msg.reqId, message: `保存项目失败: ${err.message}` });
  }
}

async function handleProjectDelete(msg: ProjectDeleteMsg) {
  const index = projects.findIndex((item) => item.projectId === msg.projectId);
  if (index < 0) return reply({ type: 'error', reqId: msg.reqId, message: '找不到该项目' });
  // 仅删除 ~/.link-projects/projects.json 中的条目，不触碰项目目录本身。
  const [removed] = projects.splice(index, 1);
  console.log(`[project] 删除 ${removed.name} (${removed.path})`);
  try {
    await persistProjects();
    replyProjects(msg.reqId, msg.targetId);
  } catch (err: any) {
    reply({ type: 'error', reqId: msg.reqId, message: `删除项目失败: ${err.message}` });
  }
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

// ---------- 文件上传 / 下载（分块 base64；上传先写临时文件，收完原子替换） ----------

// 清理进行中的上传（断线 / 退出时调用）：关句柄、删半截临时文件
function cleanupUploads(): void {
  for (const entry of uploadTemp.values()) {
    try { closeSync(entry.fd); } catch { /* 已关闭 */ }
    try { unlinkSync(entry.tmpPath); } catch { /* 忽略 */ }
  }
  uploadTemp.clear();
}

// 展开路径开头的 ~（上传 / 下载共用）
function expandPath(raw: string): string {
  return raw === '~' || raw.startsWith('~/') ? join(homedir(), raw.slice(1)) : raw;
}

function handleFileUploadStart(msg: FileUploadStartMsg) {
  console.log(`[file-upload] ${msg.path} (${msg.size} 字节)`);
  const finalPath = expandPath(msg.path);
  const tmpPath = `${finalPath}.link-upload-${msg.reqId}.tmp`;
  try {
    // 必须同步完成注册：紧随其后的 chunk / finish（空文件时 finish 直接到达）
    // 依赖本条消息处理完时 uploadTemp 已有条目，不能让出事件循环。
    // 目标目录不存在时创建（与 file-write 行为一致）；临时文件放同目录，rename 原子生效
    mkdirSync(dirname(finalPath), { recursive: true });
    const fd = openSync(tmpPath, 'w');
    uploadTemp.set(msg.reqId, { fd, tmpPath, finalPath, size: msg.size });
  } catch (err: any) {
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: false, error: `创建上传临时文件失败: ${err.message}` });
  }
}

function handleFileUploadChunk(msg: FileUploadChunkMsg) {
  const entry = uploadTemp.get(msg.reqId);
  if (!entry) return; // start 失败后的迟到数据块，直接忽略（finish 会回执失败）
  if (entry.error) return; // 已失败，等 finish 回执
  try {
    const buf = Buffer.from(msg.data, 'base64');
    writeSync(entry.fd, buf, 0, buf.length, msg.offset);
  } catch (err: any) {
    entry.error = `写入上传数据失败: ${err.message}`;
  }
}

async function handleFileUploadFinish(msg: FileUploadFinishMsg) {
  const entry = uploadTemp.get(msg.reqId);
  if (!entry) {
    return reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: false, error: '上传已中断（未开始或连接已重置）' });
  }
  uploadTemp.delete(msg.reqId);
  try { closeSync(entry.fd); } catch { /* 忽略 */ }
  try {
    // 大小校验：防止控制端中途丢块产生截断文件
    const actual = (await stat(entry.tmpPath)).size;
    if (actual !== entry.size) {
      throw new Error(`大小不匹配（收到 ${actual} / 声明 ${entry.size} 字节）`);
    }
    if (entry.error) throw new Error(entry.error);
    await rename(entry.tmpPath, entry.finalPath);
    console.log(`[file-upload] 完成 ${entry.finalPath}`);
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: true });
  } catch (err: any) {
    try { await rm(entry.tmpPath, { force: true }); } catch { /* 忽略 */ }
    reply({ type: 'done', reqId: msg.reqId, targetId: msg.targetId, ok: false, error: `上传失败: ${err.message}` });
  }
}

async function handleFileDownload(msg: FileDownloadMsg) {
  const target = expandPath(msg.path);
  let fd: number | undefined;
  try {
    const st = await stat(target);
    if (!st.isFile()) throw new Error('不是普通文件（目录 / 设备等），无法下载');
    if (st.size > MAX_DOWNLOAD_SIZE) throw new Error(`文件超过 1GB（${st.size} 字节），暂不支持下载`);
    console.log(`[file-download] ${msg.path} -> ${target} (${st.size} 字节)`);
    fd = openSync(target, 'r');
    const buf = Buffer.alloc(TRANSFER_CHUNK);
    let offset = 0;
    for (;;) {
      const n = st.size === 0 ? 0 : readSync(fd, buf, 0, TRANSFER_CHUNK, offset);
      const done = offset + n >= st.size;
      const payload = JSON.stringify({
        type: 'file-download-data', reqId: msg.reqId, targetId: msg.targetId,
        offset, data: buf.subarray(0, n).toString('base64'), done, size: st.size,
      });
      // 逐块等发送完成再读下一块，避免大文件整体堆在发送缓冲里
      await new Promise<void>((resolve) => ws.send(payload, () => resolve()));
      if (done) break;
      offset += n;
    }
    console.log(`[file-download] 完成 ${target}`);
  } catch (err: any) {
    reply({ type: 'error', reqId: msg.reqId, message: `下载失败: ${err.message}` });
  } finally {
    if (fd !== undefined) { try { closeSync(fd); } catch { /* 忽略 */ } }
  }
}

async function runForeground(): Promise<void> {
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
  await loadAgentSessions();
  await loadProjects();
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
