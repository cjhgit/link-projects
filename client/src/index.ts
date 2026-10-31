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
  AgentKind,
  ProjectListMsg,
  ProjectSaveMsg,
  ProjectDeleteMsg,
  Project,
  TerminalCommandListMsg,
  TerminalCommandSaveMsg,
  TerminalCommandDeleteMsg,
  TerminalCommand,
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
// Agent（Claude Code / Codex CLI）的会话摘要与对话记录属于云电脑，不经过 controller / server 存储。
// 文件名沿用 claude-sessions.json（历史遗留），claude 与 codex 会话混存于同一个文件。
const AGENT_SESSIONS_FILE = join(RUNTIME_DIR, 'claude-sessions.json');
const DEFAULT_AGENT_CWD = join(RUNTIME_DIR, 'workspace');
const agentProcesses = new Map<string, ChildProcess>();
let agentSessions: StoredAgentSession[] = [];
// 项目（常用目录）同样属于云电脑，保存在本机。
const PROJECTS_FILE = join(RUNTIME_DIR, 'projects.json');
let projects: Project[] = [];
const TERMINAL_COMMANDS_FILE = join(RUNTIME_DIR, 'terminal-commands.json');
let terminalCommands: TerminalCommand[] = [];

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
      case 'terminal-command-list':
        return handleTerminalCommandList(msg as TerminalCommandListMsg);
      case 'terminal-command-save':
        return handleTerminalCommandSave(msg as TerminalCommandSaveMsg);
      case 'terminal-command-delete':
        return handleTerminalCommandDelete(msg as TerminalCommandDeleteMsg);
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

// ---------- Agent 会话（Claude Code / Codex CLI） ----------

// Claude Code 官方数据目录：会话本体在 projects/<编码cwd>/<sessionId>.jsonl，
// 输入历史在 history.jsonl（每行含 sessionId 与 project 原文，是发现外部会话的线索）。
const CLAUDE_DIR = join(homedir(), '.claude');
const CLAUDE_HISTORY_FILE = join(CLAUDE_DIR, 'history.jsonl');
const CLAUDE_PROJECTS_DIR = join(CLAUDE_DIR, 'projects');
// Codex 官方会话目录：按 年/月/日 分层，文件名 rollout-<时间戳>-<threadId>.jsonl
const CODEX_SESSIONS_DIR = join(homedir(), '.codex', 'sessions');
// Cursor Agent（CLI）官方会话目录：<chatId>/<实例uuid>/{store.db, meta.json}（消息在 SQLite blobs 表里）
const CURSOR_CHATS_DIR = join(homedir(), '.cursor', 'chats');
// Cursor IDE 官方数据库：composerHeaders 表为全部会话头，cursorDiskKV 表存逐条消息
// （bubbleId:<composerId>:<bubbleId>[/s:N]）；jsonlPath 指向 .vscdb 即 IDE 会话
const CURSOR_IDE_DB = join(homedir(), 'Library', 'Application Support', 'Cursor', 'User', 'globalStorage', 'state.vscdb');
// pi 官方会话目录：<编码cwd>/<时间戳>_<sessionId>.jsonl（首行 session 事件带 cwd 原文）
const PI_SESSIONS_DIR = join(homedir(), '.pi', 'agent', 'sessions');
// 历史列表每个 tab 最多展示的条数（按最近活动排序），避免历史会话过多拖垮列表与请求耗时
const MAX_EXTERNAL_SESSIONS = 300;
// 支持的底层 CLI（加载旧记录时把未知值规范化为 claude）
const AGENT_KINDS: ReadonlySet<string> = new Set(['claude', 'codex', 'cursor', 'pi']);

// 持久化到 claude-sessions.json 的记录：claude / codex 会话均不维护 messages（复用官方会话文件，
// 实时解析）。旧版 codex 记录自带的 messages 保留作兜底（官方 rollout 已被清理时仍有内容可看）。
// 协议快照中的 messages 是组装出来的视图。
type StoredAgentSession = Omit<AgentSession, 'messages' | 'streaming'> & {
  messages?: AgentSession['messages'];
  origin?: AgentSession['origin'];
  jsonlPath?: string;
};

// cwd -> 官方 projects 子目录名：Claude Code 把路径中所有非字母数字字符替换为 '-'
function claudeProjectDirName(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, '-');
}

// claude 会话对应的官方 jsonl 路径（是否存在由调用方 stat 判断）
function claudeJsonlPath(cwd: string | undefined, sessionId: string): string | undefined {
  return cwd ? join(CLAUDE_PROJECTS_DIR, claudeProjectDirName(cwd), `${sessionId}.jsonl`) : undefined;
}

// 解析官方会话 jsonl 为消息视图：只保留主链路的用户输入与文本回复，
// 跳过 thinking / tool_use / tool_result / 系统注入（如 token 上限续写提示）等非对话内容，
// 相邻同角色的文本合并为一条，避免 UI 出现大量碎气泡。
function parseClaudeJsonl(content: string): AgentSession['messages'] {
  const messages: AgentSession['messages'] = [];
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let event: any;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event?.isSidechain) continue;
    // isMeta = CLI 自己注入的行（如 token 上限续写提示）；新版真实用户输入都带 origin.kind = human
    if (event?.isMeta) continue;
    const timestamp = typeof event?.timestamp === 'string' ? Date.parse(event.timestamp) : NaN;
    const createdAt = Number.isFinite(timestamp) ? timestamp : 0;
    const message = event?.message;
    let role: 'user' | 'assistant' | undefined;
    let text = '';
    if (event?.type === 'user' && message) {
      // 用户真实输入：content 为字符串，或数组中的 text 项；tool_result 与系统注入行跳过
      if (typeof message.content === 'string') {
        if (event?.origin && event.origin?.kind !== 'human') continue;
        role = 'user';
        text = message.content;
      } else if (Array.isArray(message.content)) {
        if (message.content.some((item: any) => item?.type === 'tool_result')) continue;
        text = message.content
          .filter((item: any) => item?.type === 'text' && typeof item?.text === 'string')
          .map((item: any) => item.text)
          .join('\n\n');
        if (text) role = 'user';
      }
    } else if (event?.type === 'assistant' && message && Array.isArray(message.content)) {
      text = message.content
        .filter((item: any) => item?.type === 'text' && typeof item?.text === 'string')
        .map((item: any) => item.text)
        .join('\n\n');
      if (text) role = 'assistant';
    }
    if (!role || !text.trim()) continue;
    pushOrMerge(messages, role, text, createdAt);
  }
  return messages;
}

// 读取官方 jsonl 并解析消息；文件缺失 / 损坏时返回 undefined（调用方决定回退方式）
async function readClaudeMessages(jsonlPath: string): Promise<AgentSession['messages'] | undefined> {
  try {
    return parseClaudeJsonl(await readFile(jsonlPath, 'utf8'));
  } catch {
    return undefined;
  }
}

// ---------- Codex 官方会话（~/.codex/sessions/年/月/日/rollout-<ts>-<threadId>.jsonl） ----------

// Codex rollout 里 CLI 注入的非用户输入内容（环境上下文 / 权限说明等），解析时跳过
const CODEX_INJECTED_PREFIXES = ['<environment_context>', '<permissions', '<user_instructions>', '<app-context>', '<app-instructions>', '<turn_context>', '<user_shell>', '<IDE>', '# AGENTS.md'];

// 解析 Codex rollout jsonl 为消息视图：只保留真实用户输入（input_text）与回复（output_text），
// 跳过 developer 注入、reasoning、工具调用等；相邻同角色合并（与 Claude 解析口径一致）。
function parseCodexJsonl(content: string): AgentSession['messages'] {
  const messages: AgentSession['messages'] = [];
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let event: any;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event?.type !== 'response_item') continue;
    const payload = event?.payload;
    if (payload?.type !== 'message' || !Array.isArray(payload?.content)) continue;
    const timestamp = typeof event?.timestamp === 'string' ? Date.parse(event.timestamp) : NaN;
    const createdAt = Number.isFinite(timestamp) ? timestamp : 0;
    const text = payload.content
      .filter((item: any) => typeof item?.text === 'string' && item.text
        && (item?.type === 'input_text' || item?.type === 'output_text'))
      .map((item: any) => item.text)
      .join('\n\n');
    if (!text.trim()) continue;
    if (payload.role === 'user') {
      const trimmed = text.trimStart();
      if (CODEX_INJECTED_PREFIXES.some((prefix) => trimmed.startsWith(prefix))) continue;
      pushOrMerge(messages, 'user', text, createdAt);
    } else if (payload.role === 'assistant') {
      pushOrMerge(messages, 'assistant', text, createdAt);
    }
  }
  return messages;
}

// 相邻同角色的文本合并为一条，避免 UI 出现大量碎气泡（两个解析器共用）
function pushOrMerge(messages: AgentSession['messages'], role: 'user' | 'assistant', text: string, createdAt: number): void {
  const last = messages[messages.length - 1];
  if (last && last.role === role) last.content = `${last.content}\n\n${text}`;
  else messages.push({ role, content: text, createdAt });
}

async function readCodexMessages(jsonlPath: string): Promise<AgentSession['messages'] | undefined> {
  try {
    return parseCodexJsonl(await readFile(jsonlPath, 'utf8'));
  } catch {
    return undefined;
  }
}

// 从 rollout 头部提取 cwd：session_meta / turn_context 的 payload.cwd。
// session_meta 行含完整 instructions 可能很长，头部截断导致 JSON 解析失败时用正则兜底。
function codexCwdFromHead(head: string): string | undefined {
  for (const line of head.split('\n')) {
    try {
      const event = JSON.parse(line);
      const cwd = event?.payload?.cwd ?? event?.cwd;
      if (typeof cwd === 'string' && cwd) return cwd;
    } catch { /* 截断行落到正则兜底 */ }
  }
  const m = head.match(/"cwd"\s*:\s*"([^"]+)"/);
  return m ? m[1] : undefined;
}

// rollout 文件名：rollout-<时间戳>-<threadId>.jsonl 或 rollout-<时间戳>-<threadId>_<分支id>.jsonl。
// 同一 thread 经 resume 会产生多个分片文件，各分片只记录自己那段对话（不包含被 resume 的历史），
// 完整对话需按时间顺序合并全部分片；threadId 为文件名里下划线前的标准 UUID。
const CODEX_ROLLOUT_RE = /^rollout-.*-([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:_[0-9a-fA-F-]+)?\.jsonl$/;

interface CodexThreadFiles {
  threadId: string;
  oldest: string; // 最老分片（首条用户输入在这里，用于标题）
  newest: string; // 最新分片（jsonlPath 指向它，活动时间取其 mtime）
  mtimeMs: number;
}

// Codex 会话目录按 年/月/日 分层且目录名即日期：倒序遍历（最新在前），
// 收集 rollout 文件并按 thread 聚合，凑够 limit 个 thread 即停（磁盘上可能有数万个文件）。
async function listCodexThreadFiles(limit: number): Promise<CodexThreadFiles[]> {
  // 一个 thread 常有 1-3 个分片，多收一些文件再分组
  const rawFiles: { threadId: string; path: string; name: string; mtimeMs: number }[] = [];
  const wantFiles = limit * 3;
  const years = (await readdirSafe(CODEX_SESSIONS_DIR)).sort().reverse();
  for (const year of years) {
    const months = (await readdirSafe(join(CODEX_SESSIONS_DIR, year))).sort().reverse();
    for (const month of months) {
      const days = (await readdirSafe(join(CODEX_SESSIONS_DIR, year, month))).sort().reverse();
      for (const day of days) {
        const dir = join(CODEX_SESSIONS_DIR, year, month, day);
        let names: string[];
        try {
          names = (await readdir(dir, { withFileTypes: true })).filter((d) => d.isFile()).map((d) => d.name);
        } catch { continue; }
        for (const name of names) {
          const m = CODEX_ROLLOUT_RE.exec(name);
          if (!m) continue;
          const path = join(dir, name);
          try {
            const st = await stat(path);
            if (st.isFile()) rawFiles.push({ threadId: m[1], path, name, mtimeMs: st.mtimeMs });
          } catch { /* 忽略失效文件 */ }
          if (rawFiles.length >= wantFiles) break;
        }
        if (rawFiles.length >= wantFiles) break;
      }
      if (rawFiles.length >= wantFiles) break;
    }
    if (rawFiles.length >= wantFiles) break;
  }
  // 按 thread 聚合：文件名含时间戳，字符串排序即时间序
  const byThread = new Map<string, typeof rawFiles>();
  for (const file of rawFiles) {
    const list = byThread.get(file.threadId) ?? [];
    list.push(file);
    byThread.set(file.threadId, list);
  }
  const threads: CodexThreadFiles[] = [];
  for (const [threadId, files] of byThread) {
    files.sort((a, b) => a.name.localeCompare(b.name));
    threads.push({
      threadId,
      oldest: files[0].path,
      newest: files[files.length - 1].path,
      mtimeMs: Math.max(...files.map((f) => f.mtimeMs)),
    });
  }
  threads.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return threads.slice(0, limit);
}

async function readdirSafe(dir: string): Promise<string[]> {
  try {
    return (await readdir(dir, { withFileTypes: true })).filter((d) => d.isDirectory()).map((d) => d.name);
  } catch {
    return [];
  }
}

// threadId -> 全部分片路径（合并完整对话用）。全目录扫描一次后缓存，
// 后续详情读取直接命中（readdir 文件名匹配为主，不逐文件 stat）。
const codexThreadPathsCache = new Map<string, string[]>();

async function findCodexAllRollouts(threadId: string): Promise<string[]> {
  if (!/^[0-9a-fA-F-]{8,64}$/.test(threadId)) return [];
  const cached = codexThreadPathsCache.get(threadId);
  if (cached) return cached;
  const paths: string[] = [];
  const walk = async (dir: string, depth: number): Promise<void> => {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (depth < 3) await walk(join(dir, entry.name), depth + 1);
      } else if (entry.isFile()) {
        const m = CODEX_ROLLOUT_RE.exec(entry.name);
        if (m && m[1] === threadId) paths.push(join(dir, entry.name));
      }
    }
  };
  await walk(CODEX_SESSIONS_DIR, 0);
  paths.sort((a, b) => a.localeCompare(b)); // 文件名含时间戳，排序即对话顺序
  codexThreadPathsCache.set(threadId, paths);
  return paths;
}

// 读取一个 thread 的完整对话：按时间顺序合并全部分片后解析
async function readCodexThreadMessages(threadId: string): Promise<AgentSession['messages'] | undefined> {
  const paths = await findCodexAllRollouts(threadId);
  if (paths.length === 0) return undefined;
  const messages: AgentSession['messages'] = [];
  for (const path of paths) {
    const part = await readCodexMessages(path);
    if (!part) continue;
    for (const item of part) pushOrMerge(messages, item.role, item.content, item.createdAt);
  }
  return messages;
}

interface ClaudeHistoryEntry {
  display: string; // 该会话的第一句输入，作为标题
  project: string; // 会话的工作目录原文（jsonl 目录名由它编码而来）
  timestamp: number; // 该会话第一次输入的时间
}

// 解析 ~/.claude/history.jsonl：sessionId -> 会话线索（首句输入 + project 原文）。
// 旧格式行没有 sessionId，无法恢复会话，直接跳过。
async function loadClaudeHistoryIndex(): Promise<Map<string, ClaudeHistoryEntry>> {
  const index = new Map<string, ClaudeHistoryEntry>();
  let content: string;
  try {
    content = await readFile(CLAUDE_HISTORY_FILE, 'utf8');
  } catch {
    return index;
  }
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    try {
      const item = JSON.parse(line);
      if (typeof item?.sessionId !== 'string' || !item.sessionId) continue;
      if (typeof item?.project !== 'string' || !item.project) continue;
      // 同一会话多行输入只保留第一句做标题
      if (index.has(item.sessionId)) continue;
      index.set(item.sessionId, {
        display: typeof item.display === 'string' ? item.display : '',
        project: item.project,
        timestamp: typeof item.timestamp === 'number' ? item.timestamp : 0,
      });
    } catch { /* 忽略坏行 */ }
  }
  return index;
}

async function loadAgentSessions(): Promise<void> {
  try {
    const parsed = JSON.parse(await readFile(AGENT_SESSIONS_FILE, 'utf8'));
    agentSessions = Array.isArray(parsed) ? parsed : [];
    // 旧记录没有 agent 字段，统一规范化为 claude，后续逻辑不必再判空
    for (const session of agentSessions) {
      if (!AGENT_KINDS.has(session.agent ?? '')) session.agent = 'claude';
      // 迁移：claude 会话不再维护 messages（复用官方 jsonl），丢弃旧副本并补记 jsonl 路径
      if (session.agent === 'claude') {
        delete session.messages;
        if (!session.jsonlPath) session.jsonlPath = claudeJsonlPath(session.cwd, session.sessionId);
        // 自愈：旧版把无害的 CLI stderr 噪音（stdin 提示、代理模型名告警）误判为失败，对话实际已成功
        if (session.state === 'failed' && session.error
          && /no stdin data received|unrecognized_model/i.test(session.error)) {
          session.state = 'completed';
          session.error = undefined;
        }
      }
      if (session.origin !== 'external') session.origin = 'link';
    }
    // codex 旧记录改由官方 rollout 解析消息：按 externalId（thread id）回填最新分片路径。
    // 旧 messages 副本保留作兜底（rollout 已被官方清理时详情仍有内容可看），不再更新。
    for (const session of agentSessions) {
      if (session.agent === 'codex' && !session.jsonlPath && session.externalId
        && session.state !== 'running') {
        const paths = await findCodexAllRollouts(session.externalId);
        if (paths.length > 0) session.jsonlPath = paths[paths.length - 1];
      }
    }
    // client 重启意味着旧 CLI 子进程不可能仍由本实例托管，避免永久显示“运行中”。
    for (const session of agentSessions) {
      if (session.state === 'running') {
        session.state = 'failed';
        session.error = '云电脑客户端已重启，之前的任务状态未知，请继续对话或重新发起任务';
        session.updatedAt = Date.now();
      }
    }
    // 启动仅一次：上面的字段迁移（丢弃旧 messages / 补 jsonlPath）随之落盘
    await persistAgentSessions();
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

function agentSnapshot(session: StoredAgentSession): AgentSession {
  // JSON 往返同时避免调用方意外改写内存中的会话记录。
  return JSON.parse(JSON.stringify(session)) as AgentSession;
}

// 列表摘要快照：不带消息（消息体量大，选中会话后由 agent-status 拉取详情）
function summarySnapshot(session: StoredAgentSession): AgentSession {
  return { ...agentSnapshot(session), messages: [] };
}

// 运行中的任务视图（claude / codex 通用）：启动时的消息基线 + 本轮输入 + 实时增量文本。
// 只存在于内存（不落盘），任务结束后以官方会话文件的解析结果为准。
const activeRuns = new Map<string, { baseMessages: AgentSession['messages']; prompt: string; streamedText: string }>();

// 运行中快照：基线消息 + 本轮输入（官方文件写入前的兜底显示）+ streaming 增量
function runningSnapshot(session: StoredAgentSession): AgentSession {
  const run = activeRuns.get(session.sessionId);
  const messages: AgentSession['messages'] = run
    ? JSON.parse(JSON.stringify(run.baseMessages))
    : [];
  if (run) {
    const last = messages[messages.length - 1];
    if (!(last?.role === 'user' && last.content === run.prompt)) {
      messages.push({ role: 'user', content: run.prompt, createdAt: session.updatedAt });
    }
  }
  const snapshot = { ...agentSnapshot(session), messages };
  if (run?.streamedText) snapshot.streaming = run.streamedText;
  else delete snapshot.streaming;
  return snapshot;
}

// 详情快照：优先实时解析官方会话文件（claude jsonl / codex 全分片合并的 rollout）；
// codex 旧记录 rollout 已清理时回退本软件曾维护的 messages 副本。
async function detailSnapshot(session: StoredAgentSession): Promise<AgentSession> {
  if (session.state === 'running') return runningSnapshot(session);
  const messages = await readAgentMessages(session);
  if (messages !== undefined) return { ...agentSnapshot(session), messages };
  return { ...agentSnapshot(session), messages: session.messages ?? [] };
}

// 会话标题：清洗斜杠命令 / 环境注入的 XML 标签等噪音，空则回退短 id
function agentSessionTitle(text: string, sessionId: string): string {
  const cleaned = text
    .replace(/<command-[a-z-]+>[\s\S]*?<\/command-[a-z-]+>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return (cleaned || `会话 ${sessionId.slice(0, 8)}`).slice(0, 48);
}

// 由 history 线索 + 官方 jsonl 的 mtime 组装一条外部会话记录
function externalSessionFromHistory(sessionId: string, entry: ClaudeHistoryEntry, mtimeMs: number): StoredAgentSession {
  return {
    sessionId,
    agent: 'claude',
    origin: 'external',
    title: agentSessionTitle(entry.display, sessionId),
    cwd: entry.project,
    state: 'completed',
    createdAt: entry.timestamp || mtimeMs,
    updatedAt: mtimeMs,
    jsonlPath: claudeJsonlPath(entry.project, sessionId),
  };
}

// 从 jsonl 头部文本中取第一个带 cwd 的事件行（官方会话几乎每个事件行都带 cwd）
function firstCwdFromHead(head: string): string | undefined {
  for (const line of head.split('\n')) {
    try {
      const event = JSON.parse(line);
      if (typeof event?.cwd === 'string' && event.cwd) return event.cwd;
    } catch { /* 坏行跳过 */ }
  }
  return undefined;
}

// 发现 Claude 历史会话：以磁盘上的官方 jsonl 为准（~/.claude/projects/*/<sessionId>.jsonl），
// 含 -p 模式发起、history.jsonl 未收录的会话；history.jsonl 仅用于补标题（会话第一句输入）。
// 只在请求列表时动态生成，不写入 claude-sessions.json；回复不改变此列表
// （回复后 jsonl 更新，仅排序随之变化），跟踪运行状态的内部记录归「会话」页。
async function discoverExternalClaudeSessions(): Promise<StoredAgentSession[]> {
  let dirs;
  try {
    dirs = await readdir(CLAUDE_PROJECTS_DIR, { withFileTypes: true });
  } catch {
    return [];
  }
  // 完全由磁盘上的官方 jsonl 决定（含本软件发起的）；与「会话」页可能重复出现是预期
  // 先收集全部候选文件按 mtime 排序，只对最近的一批读头部解析，不为老会话做文件 IO
  const candidates: { sessionId: string; path: string; mtimeMs: number }[] = [];
  await Promise.all(dirs.map(async (dir) => {
    if (!dir.isDirectory()) return;
    let files;
    try {
      files = await readdir(join(CLAUDE_PROJECTS_DIR, dir.name));
    } catch { return; }
    await Promise.all(files.map(async (name) => {
      if (!name.endsWith('.jsonl')) return;
      const sessionId = name.slice(0, -'.jsonl'.length);
      const path = join(CLAUDE_PROJECTS_DIR, dir.name, name);
      try {
        const st = await stat(path);
        if (st.isFile()) candidates.push({ sessionId, path, mtimeMs: st.mtimeMs });
      } catch { /* 忽略失效文件 */ }
    }));
  }));
  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
  const history = await loadClaudeHistoryIndex(); // 标题线索：display 为会话第一句输入
  const found = await Promise.all(candidates.slice(0, MAX_EXTERNAL_SESSIONS).map(async (item) => {
    const head = readFileHead(item.path, 64 * 1024);
    const cwd = firstCwdFromHead(head);
    if (!cwd) return undefined; // 恢复对话依赖 cwd 定位官方会话文件
    const entry = history.get(item.sessionId);
    const title = entry?.display
      ? agentSessionTitle(entry.display, item.sessionId)
      : agentSessionTitle(parseClaudeJsonl(head).find((m) => m.role === 'user')?.content ?? '', item.sessionId);
    return {
      sessionId: item.sessionId,
      agent: 'claude',
      origin: 'external',
      title,
      cwd,
      state: 'completed',
      createdAt: entry?.timestamp || item.mtimeMs,
      updatedAt: item.mtimeMs,
      jsonlPath: item.path,
    } as StoredAgentSession;
  }));
  return found.filter((item): item is StoredAgentSession => item !== undefined);
}

// 读取文件头部若干字节（找 cwd / 首条用户输入用，避免为定位元信息读完整大文件）
function readFileHead(path: string, bytes: number): string {
  const fd = openSync(path, 'r');
  try {
    const buf = Buffer.alloc(bytes);
    const n = readSync(fd, buf, 0, bytes, 0);
    return buf.subarray(0, n).toString('utf8');
  } finally {
    closeSync(fd);
  }
}

// history.jsonl 里没有时的兜底：按 sessionId 直接扫描官方 projects 目录（文件名即 sessionId），
// 从文件头部定位 cwd 并取首条用户输入做标题。供「按 Session ID 继续」恢复任意仍存在的会话。
async function findClaudeSessionOnDisk(sessionId: string): Promise<StoredAgentSession | undefined> {
  // sessionId 用于拼接路径，只放行 UUID 形态字符，杜绝目录穿越
  if (!/^[0-9a-fA-F-]{8,64}$/.test(sessionId)) return undefined;
  let dirs;
  try {
    dirs = await readdir(CLAUDE_PROJECTS_DIR, { withFileTypes: true });
  } catch {
    return undefined;
  }
  for (const dir of dirs) {
    if (!dir.isDirectory()) continue;
    const jsonlPath = join(CLAUDE_PROJECTS_DIR, dir.name, `${sessionId}.jsonl`);
    try {
      const st = await stat(jsonlPath);
      if (!st.isFile()) continue;
      const head = readFileHead(jsonlPath, 64 * 1024);
      const cwd = firstCwdFromHead(head);
      if (!cwd) continue;
      const firstUser = parseClaudeJsonl(head).find((item) => item.role === 'user');
      return {
        sessionId,
        agent: 'claude',
        origin: 'external',
        title: agentSessionTitle(firstUser?.content ?? '', sessionId),
        cwd,
        state: 'completed',
        createdAt: st.mtimeMs,
        updatedAt: st.mtimeMs,
        jsonlPath,
      };
    } catch { /* 该项目目录下无此会话，继续找 */ }
  }
  return undefined;
}

// 查单个外部 Claude 会话（agent-status / agent-run 复用）；已是内部记录的返回 undefined。
// history 线索优先（有首句输入做标题），找不到再按 sessionId 扫描磁盘。
async function findExternalClaudeSession(sessionId: string): Promise<StoredAgentSession | undefined> {
  if (agentSessions.some((item) => item.sessionId === sessionId)) return undefined;
  const entry = (await loadClaudeHistoryIndex()).get(sessionId);
  if (entry) {
    const jsonlPath = claudeJsonlPath(entry.project, sessionId);
    if (jsonlPath) {
      try {
        const st = await stat(jsonlPath);
        if (st.isFile()) return externalSessionFromHistory(sessionId, entry, st.mtimeMs);
      } catch { /* 落到磁盘扫描兜底 */ }
    }
  }
  return findClaudeSessionOnDisk(sessionId);
}

// ---------- Cursor Agent 官方会话（~/.cursor/chats/<chatId>/<实例uuid>/{store.db, meta.json}） ----------

// 读取 Cursor 实例的 store.db（SQLite）：消息以 JSON blob 存在 blobs 表、无时间戳字段，
// rowid（写入序）即对话顺序；工具数据等 protobuf 行 JSON.parse 失败自然跳过。
// node:sqlite 不可用（Node < 22.5）时返回 undefined，消息查看降级。
function parseCursorStore(storePath: string): AgentSession['messages'] | undefined {
  let DatabaseSync: any;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    return undefined;
  }
  let db: any;
  try {
    db = new DatabaseSync(storePath, { readOnly: true });
    const messages: AgentSession['messages'] = [];
    const rows = db.prepare('SELECT data FROM blobs ORDER BY rowid').all() as { data: Uint8Array }[];
    for (const { data } of rows) {
      let event: any;
      try {
        event = JSON.parse(Buffer.from(data).toString('utf8'));
      } catch {
        continue;
      }
      if (event?.role !== 'user' && event?.role !== 'assistant') continue;
      const content = event.content;
      if (typeof content === 'string') {
        // string 形态的 user 内容是 IDE/CLI 注入（user_info 等），非真实输入
        continue;
      }
      if (!Array.isArray(content)) continue;
      const text = content
        .filter((item: any) => item?.type === 'text' && typeof item?.text === 'string')
        .map((item: any) => item.text)
        .join('\n\n');
      if (!text.trim()) continue;
      if (event.role === 'user') {
        // 真实输入包裹在 <user_query> 标签里（外层还带 <timestamp> 等注入）；无此标签的整条视为注入跳过
        const q = /<user_query>\s*([\s\S]*?)\s*<\/user_query>/.exec(text);
        if (q && q[1].trim()) pushOrMerge(messages, 'user', q[1], 0);
      } else {
        pushOrMerge(messages, 'assistant', text, 0);
      }
    }
    return messages;
  } catch {
    return undefined;
  } finally {
    try { db?.close(); } catch { /* 忽略 */ }
  }
}

// 读取 Cursor IDE 的会话消息（state.vscdb 的 cursorDiskKV）：
// 每条消息为 bubbleId:<composerId>:<bubbleId>，assistant 回复按 /s:N 分片存放（独立增量，拼接即全文），
// /t:call-* 为工具数据跳过；bubble 间按 createdAt 排序。
function parseCursorIdeMessages(dbPath: string, composerId: string): AgentSession['messages'] | undefined {
  let DatabaseSync: any;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    return undefined;
  }
  let db: any;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true });
    // 字典序 range 查询（LIKE 'prefix%' 在此表上不走索引、会全表扫描 14GB 库）；
    // LIMIT 兜底防极端会话（正常会话远小于此）
    // 上界取 prefix 前缀自增（最后的 ':' 换成 ';'），覆盖 bubbleId:<cid>: 开头的全部 key
    const rows = db.prepare('SELECT key, value FROM cursorDiskKV WHERE key >= ? AND key < ? LIMIT 5000')
      .all(`bubbleId:${composerId}:`, `bubbleId:${composerId};`);
    // 一个 bubbleId = 一轮对话：type 1 是 user 提问（带 text），
    // type 2 的 /s:N 分片是对这轮的 assistant 回复（独立增量，按序号拼接即全文）
    const users = new Map<string, { createdAt: number; text: string }>();
    const replies = new Map<string, { createdAt: number; parts: { seq: number; text: string }[] }>();
    for (const { key, value } of rows as { key: string; value: Uint8Array }[]) {
      if (!/^bubbleId:[0-9a-fA-F-]+:[0-9a-fA-F-]+(?:\/s:\d+)?$/.test(key)) continue; // /t:call-* 等工具数据
      let event: any;
      try {
        event = JSON.parse(Buffer.from(value).toString('utf8'));
      } catch {
        continue;
      }
      const text = typeof event?.text === 'string' ? event.text : '';
      if (!text.trim()) continue;
      if (event?.type === 1) {
        const trimmed = text.trimStart();
        if (trimmed.startsWith('<user_info>') || trimmed.startsWith('<timestamp>')) continue; // IDE 注入防御
      }
      const ts = typeof event?.createdAt === 'string' ? Date.parse(event.createdAt) : NaN;
      const createdAt = Number.isFinite(ts) ? ts : 0;
      const bubbleId = key.split(':')[2];
      const seq = Number(/^.*\/s:(\d+)$/.exec(key)?.[1] ?? -1);
      if (event?.type === 1) {
        users.set(bubbleId, { createdAt: createdAt || users.get(bubbleId)?.createdAt || 0, text });
      } else if (event?.type === 2) {
        const reply = replies.get(bubbleId) ?? { createdAt: 0, parts: [] };
        if (createdAt) reply.createdAt = Math.max(reply.createdAt, createdAt);
        reply.parts.push({ seq, text });
        replies.set(bubbleId, reply);
      }
    }
    // 两种消息一起按时间排序输出
    const timed: { createdAt: number; role: 'user' | 'assistant'; text: string }[] = [];
    for (const [bid, item] of users) timed.push({ createdAt: item.createdAt, role: 'user', text: item.text });
    for (const [bid, item] of replies) {
      item.parts.sort((a, b) => a.seq - b.seq);
      const text = item.parts.map((part) => part.text).join('\n\n');
      if (text.trim()) timed.push({ createdAt: item.createdAt || users.get(bid)?.createdAt || 0, role: 'assistant', text });
    }
    timed.sort((a, b) => a.createdAt - b.createdAt);
    const messages: AgentSession['messages'] = [];
    for (const item of timed) pushOrMerge(messages, item.role, item.text, item.createdAt);
    return messages;
  } catch {
    return undefined;
  } finally {
    try { db?.close(); } catch { /* 忽略 */ }
  }
}

// ---------- pi 官方会话（~/.pi/agent/sessions/<编码cwd>/<ts>_<sessionId>.jsonl） ----------

// pi 的会话文件与 --mode json 输出流同构：message 事件带完整 role + content 数组
function parsePiJsonl(content: string): AgentSession['messages'] {
  const messages: AgentSession['messages'] = [];
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let event: any;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event?.type !== 'message') continue;
    const message = event?.message;
    if (!message || (message.role !== 'user' && message.role !== 'assistant')) continue;
    const ts = typeof event?.timestamp === 'string' ? Date.parse(event.timestamp) : NaN;
    const createdAt = Number.isFinite(ts) ? ts : 0;
    let text = '';
    if (typeof message.content === 'string') text = message.content;
    else if (Array.isArray(message.content)) {
      text = message.content
        .filter((item: any) => item?.type === 'text' && typeof item?.text === 'string')
        .map((item: any) => item.text)
        .join('\n\n');
    }
    if (!text.trim()) continue;
    pushOrMerge(messages, message.role, text, createdAt);
  }
  return messages;
}

async function readFileSafe(path: string): Promise<string> {
  try {
    return await readFile(path, 'utf8');
  } catch {
    return '';
  }
}

// 统一消息读取：按 agent 类型分派到对应官方文件解析器。
// cursor 的 jsonlPath 约定为实例目录（消息在其 store.db 里）。
async function readAgentMessages(session: StoredAgentSession): Promise<AgentSession['messages'] | undefined> {
  switch (session.agent) {
    case 'codex':
      return readCodexThreadMessages(session.externalId ?? session.sessionId);
    case 'cursor':
      if (!session.jsonlPath) return undefined;
      return session.jsonlPath.endsWith('.vscdb')
        ? parseCursorIdeMessages(session.jsonlPath, session.sessionId)
        : parseCursorStore(join(session.jsonlPath, 'store.db'));
    case 'pi':
      return session.jsonlPath ? parsePiJsonl(await readFileSafe(session.jsonlPath)) : undefined;
    default:
      return session.jsonlPath ? readClaudeMessages(session.jsonlPath) : undefined;
  }
}

// 由 Cursor 实例目录组装会话记录（meta.json 提供官方标题 / cwd / 时间）
async function cursorSessionFromInstance(instanceDir: string, sessionId: string, mtimeMs: number): Promise<StoredAgentSession | undefined> {
  let meta: any;
  try {
    meta = JSON.parse(await readFile(join(instanceDir, 'meta.json'), 'utf8'));
  } catch {
    meta = undefined;
  }
  const cwd = typeof meta?.cwd === 'string' && meta.cwd ? meta.cwd : undefined;
  if (!cwd) return undefined;
  return {
    sessionId,
    agent: 'cursor',
    origin: 'external',
    externalId: sessionId, // --resume 用实例 uuid
    title: agentSessionTitle(typeof meta?.title === 'string' ? meta.title : '', sessionId),
    cwd,
    state: 'completed',
    createdAt: typeof meta?.createdAtMs === 'number' ? meta.createdAtMs : mtimeMs,
    updatedAt: typeof meta?.updatedAtMs === 'number' ? meta.updatedAtMs : mtimeMs,
    jsonlPath: instanceDir,
  };
}

// 发现 Cursor 历史会话：IDE（state.vscdb 的 composerHeaders，通常数千条）与
// CLI（~/.cursor/chats）两来源合并，按最近活动取最新一批。与其他历史同理：
// 只在请求列表时动态生成、完全由官方文件决定。jsonlPath 指向 .vscdb 即 IDE 会话、
// 指向实例目录即 CLI 会话；两者都可被 cursor-agent --resume（按 uuid）。
async function discoverExternalCursorSessions(): Promise<StoredAgentSession[]> {
  const found: StoredAgentSession[] = await discoverCursorIdeSessions();
  found.push(...await discoverCursorCliSessions());
  found.sort((a, b) => b.updatedAt - a.updatedAt);
  return found.slice(0, MAX_EXTERNAL_SESSIONS);
}

// IDE 会话：composerHeaders（排除子 agent 与归档），标题用官方 name
async function discoverCursorIdeSessions(): Promise<StoredAgentSession[]> {
  let DatabaseSync: any;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    return [];
  }
  let db: any;
  try {
    db = new DatabaseSync(CURSOR_IDE_DB, { readOnly: true });
    const rows = db.prepare(
      'SELECT composerId, createdAt, lastUpdatedAt, value FROM composerHeaders '
      + 'WHERE isSubagent = 0 AND isArchived = 0 ORDER BY lastUpdatedAt DESC LIMIT ?',
    ).all(MAX_EXTERNAL_SESSIONS) as { composerId: string; createdAt: number; lastUpdatedAt: number; value: Uint8Array }[];
    const found: StoredAgentSession[] = [];
    for (const row of rows) {
      let name = '';
      try {
        const header = JSON.parse(Buffer.from(row.value).toString('utf8'));
        if (typeof header?.name === 'string') name = header.name;
      } catch { /* header 解析失败用短 id 兜底 */ }
      found.push({
        sessionId: row.composerId,
        agent: 'cursor',
        origin: 'external',
        externalId: row.composerId,
        title: agentSessionTitle(name, row.composerId),
        cwd: undefined, // IDE 会话头不带工作目录；resume 不依赖 cwd（云端会话）
        state: 'completed',
        createdAt: row.createdAt || row.lastUpdatedAt,
        updatedAt: row.lastUpdatedAt,
        jsonlPath: CURSOR_IDE_DB,
      });
    }
    return found;
  } catch {
    return []; // IDE 未安装 / 数据库不可读
  } finally {
    try { db?.close(); } catch { /* 忽略 */ }
  }
}

// CLI 会话：每个 chatId 目录取 mtime 最新的实例作为当前会话状态
async function discoverCursorCliSessions(): Promise<StoredAgentSession[]> {
  let chatDirs;
  try {
    chatDirs = await readdir(CURSOR_CHATS_DIR, { withFileTypes: true });
  } catch {
    return [];
  }
  const found: StoredAgentSession[] = [];
  await Promise.all(chatDirs.filter((d) => d.isDirectory()).map(async (chatDir) => {
    const chatPath = join(CURSOR_CHATS_DIR, chatDir.name);
    let instances;
    try {
      instances = (await readdir(chatPath, { withFileTypes: true })).filter((d) => d.isDirectory());
    } catch {
      return;
    }
    let latest: { name: string; mtimeMs: number } | undefined;
    for (const inst of instances) {
      try {
        const st = await stat(join(chatPath, inst.name));
        if (st.isDirectory() && (!latest || st.mtimeMs > latest.mtimeMs)) latest = { name: inst.name, mtimeMs: st.mtimeMs };
      } catch { /* 忽略 */ }
    }
    if (!latest) return;
    const session = await cursorSessionFromInstance(join(chatPath, latest.name), latest.name, latest.mtimeMs);
    if (session) found.push(session);
  }));
  return found;
}

// 由 pi 会话文件组装记录（首行 session 事件带 cwd 原文与时间）
async function piSessionFromFile(path: string, sessionId: string, mtimeMs: number): Promise<StoredAgentSession | undefined> {
  const firstLine = readFileHead(path, 4096).split('\n')[0] ?? '';
  let sessionEvent: any;
  try {
    sessionEvent = JSON.parse(firstLine);
  } catch {
    return undefined;
  }
  if (sessionEvent?.type !== 'session') return undefined;
  const cwd = typeof sessionEvent.cwd === 'string' && sessionEvent.cwd ? sessionEvent.cwd : undefined;
  if (!cwd) return undefined;
  const ts = typeof sessionEvent.timestamp === 'string' ? Date.parse(sessionEvent.timestamp) : NaN;
  const firstUser = parsePiJsonl(readFileHead(path, 256 * 1024)).find((m) => m.role === 'user');
  return {
    sessionId,
    agent: 'pi',
    origin: 'external',
    externalId: sessionId, // --session 用会话 uuid
    title: agentSessionTitle(firstUser?.content ?? '', sessionId),
    cwd,
    state: 'completed',
    createdAt: Number.isFinite(ts) ? ts : mtimeMs,
    updatedAt: mtimeMs,
    jsonlPath: path,
  };
}

// 发现 pi 历史会话：扫 <编码cwd>/<ts>_<sessionId>.jsonl，按 mtime 取最新一批
async function discoverExternalPiSessions(): Promise<StoredAgentSession[]> {
  let dirs;
  try {
    dirs = await readdir(PI_SESSIONS_DIR, { withFileTypes: true });
  } catch {
    return [];
  }
  const found: StoredAgentSession[] = [];
  await Promise.all(dirs.filter((d) => d.isDirectory()).map(async (dir) => {
    let files;
    try {
      files = await readdir(join(PI_SESSIONS_DIR, dir.name));
    } catch {
      return;
    }
    await Promise.all(files.map(async (name) => {
      const m = /^\d{4}-\d{2}-\d{2}T[0-9.\-]+Z_([0-9a-fA-F-]{8,64})\.jsonl$/.exec(name);
      if (!m) return;
      const path = join(PI_SESSIONS_DIR, dir.name, name);
      try {
        const st = await stat(path);
        if (!st.isFile()) return;
        const session = await piSessionFromFile(path, m[1], st.mtimeMs);
        if (session) found.push(session);
      } catch { /* 忽略 */ }
    }));
  }));
  found.sort((a, b) => b.updatedAt - a.updatedAt);
  return found.slice(0, MAX_EXTERNAL_SESSIONS);
}

// 定位 Cursor 实例目录（chats/*/<uuid>/）；不校验内部记录，close 回填路径复用
async function locateCursorInstanceDir(sessionId: string): Promise<string | undefined> {
  if (!/^[0-9a-fA-F-]{8,64}$/.test(sessionId)) return undefined;
  let chatDirs;
  try {
    chatDirs = await readdir(CURSOR_CHATS_DIR, { withFileTypes: true });
  } catch {
    return undefined;
  }
  for (const d of chatDirs) {
    if (!d.isDirectory()) continue;
    const instanceDir = join(CURSOR_CHATS_DIR, d.name, sessionId);
    try {
      const st = await stat(instanceDir);
      if (st.isDirectory()) return instanceDir;
    } catch { /* 该 chat 下无此实例，继续 */ }
  }
  return undefined;
}

// 查单个外部 Cursor 会话：先 IDE（composerHeaders 按 composerId 点查）再 CLI（chats/<uuid>/）
async function findExternalCursorSession(sessionId: string): Promise<StoredAgentSession | undefined> {
  if (agentSessions.some((item) => item.sessionId === sessionId || item.externalId === sessionId)) return undefined;
  const ide = await findCursorIdeSession(sessionId);
  if (ide) return ide;
  const instanceDir = await locateCursorInstanceDir(sessionId);
  if (!instanceDir) return undefined;
  const st = await stat(instanceDir);
  return cursorSessionFromInstance(instanceDir, sessionId, st.mtimeMs);
}

// IDE 会话单查（按 ID 恢复 / 拉详情用）
async function findCursorIdeSession(sessionId: string): Promise<StoredAgentSession | undefined> {
  let DatabaseSync: any;
  try {
    ({ DatabaseSync } = require('node:sqlite'));
  } catch {
    return undefined;
  }
  let db: any;
  try {
    db = new DatabaseSync(CURSOR_IDE_DB, { readOnly: true });
    const row = db.prepare(
      'SELECT composerId, createdAt, lastUpdatedAt, value FROM composerHeaders '
      + 'WHERE composerId = ? AND isSubagent = 0 AND isArchived = 0',
    ).get(sessionId) as { composerId: string; createdAt: number; lastUpdatedAt: number; value: Uint8Array } | undefined;
    if (!row) return undefined;
    let name = '';
    try {
      const header = JSON.parse(Buffer.from(row.value).toString('utf8'));
      if (typeof header?.name === 'string') name = header.name;
    } catch { /* 短 id 兜底 */ }
    return {
      sessionId: row.composerId,
      agent: 'cursor',
      origin: 'external',
      externalId: row.composerId,
      title: agentSessionTitle(name, row.composerId),
      cwd: undefined,
      state: 'completed',
      createdAt: row.createdAt || row.lastUpdatedAt,
      updatedAt: row.lastUpdatedAt,
      jsonlPath: CURSOR_IDE_DB,
    };
  } catch {
    return undefined;
  } finally {
    try { db?.close(); } catch { /* 忽略 */ }
  }
}

// 定位 pi 会话文件（sessions/*/*_<uuid>.jsonl）；不校验内部记录，close 回填路径复用
async function locatePiSessionFile(sessionId: string): Promise<string | undefined> {
  if (!/^[0-9a-fA-F-]{8,64}$/.test(sessionId)) return undefined;
  let dirs;
  try {
    dirs = await readdir(PI_SESSIONS_DIR, { withFileTypes: true });
  } catch {
    return undefined;
  }
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    try {
      const names = await readdir(join(PI_SESSIONS_DIR, d.name));
      const hit = names.find((name) => name.endsWith(`_${sessionId}.jsonl`));
      if (hit) return join(PI_SESSIONS_DIR, d.name, hit);
    } catch { /* 目录不可读，继续 */ }
  }
  return undefined;
}

// 查单个外部 pi 会话：按会话 uuid 定位（sessions/*/*_<uuid>.jsonl）
async function findExternalPiSession(sessionId: string): Promise<StoredAgentSession | undefined> {
  if (agentSessions.some((item) => item.sessionId === sessionId || item.externalId === sessionId)) return undefined;
  const path = await locatePiSessionFile(sessionId);
  if (!path) return undefined;
  const st = await stat(path);
  if (!st.isFile()) return undefined;
  return piSessionFromFile(path, sessionId, st.mtimeMs);
}

// 发现 Codex 历史会话：以磁盘上的官方 rollout 为准，按 thread 聚合、mtime 取最新一批。
// 与 Claude 历史同理：只在请求列表时动态生成、不写入 claude-sessions.json、回复不改变此列表。
async function discoverExternalCodexSessions(): Promise<StoredAgentSession[]> {
  // 完全由磁盘上的官方 rollout 决定（含本软件发起、以及继续过对话的），
  // 与「会话」页可能重复出现是预期：历史只看官方文件，不管会话由谁发起
  const threads = await listCodexThreadFiles(MAX_EXTERNAL_SESSIONS);
  const found = await Promise.all(threads.map(async (item) => {
    // cwd / 标题线索读最老分片（首条用户输入在那里），jsonlPath 指向最新分片
    const head = readFileHead(item.oldest, 256 * 1024);
    const cwd = codexCwdFromHead(head);
    if (!cwd) return undefined; // 恢复对话依赖 cwd 定位工作目录
    let firstUser = parseCodexJsonl(head).find((m) => m.role === 'user');
    if (!firstUser && item.newest !== item.oldest) {
      // 最老分片头部只有长篇注入指令（如 AGENTS.md）时，取最新分片的首条输入做标题
      firstUser = parseCodexJsonl(readFileHead(item.newest, 256 * 1024)).find((m) => m.role === 'user');
    }
    return {
      sessionId: item.threadId,
      agent: 'codex',
      origin: 'external',
      // threadId 即 codex resume 所需的 id
      externalId: item.threadId,
      title: agentSessionTitle(firstUser?.content ?? '', item.threadId),
      cwd,
      state: 'completed',
      createdAt: item.mtimeMs,
      updatedAt: item.mtimeMs,
      jsonlPath: item.newest,
    } as StoredAgentSession;
  }));
  return found.filter((item): item is StoredAgentSession => item !== undefined);
}

// 查单个外部 Codex 会话：按 threadId 定位全部分片后组装记录
async function findExternalCodexSession(threadId: string): Promise<StoredAgentSession | undefined> {
  if (agentSessions.some((item) => item.sessionId === threadId || item.externalId === threadId)) return undefined;
  const paths = await findCodexAllRollouts(threadId);
  if (paths.length === 0) return undefined;
  try {
    const head = readFileHead(paths[0], 256 * 1024);
    const cwd = codexCwdFromHead(head);
    if (!cwd) return undefined;
    const firstUser = parseCodexJsonl(head).find((m) => m.role === 'user');
    const newest = paths[paths.length - 1];
    const st = await stat(newest);
    return {
      sessionId: threadId,
      agent: 'codex',
      origin: 'external',
      externalId: threadId,
      title: agentSessionTitle(firstUser?.content ?? '', threadId),
      cwd,
      state: 'completed',
      createdAt: st.mtimeMs,
      updatedAt: st.mtimeMs,
      jsonlPath: newest,
    };
  } catch {
    return undefined;
  }
}

// 按会话 ID 查外部会话（各 CLI 的 id 均为 uuid/hex 形态、无法从形态区分，顺序查找）
async function findExternalAgentSession(sessionId: string): Promise<StoredAgentSession | undefined> {
  return (await findExternalClaudeSession(sessionId))
    ?? (await findExternalCodexSession(sessionId))
    ?? (await findExternalCursorSession(sessionId))
    ?? (await findExternalPiSession(sessionId));
}

function replyAgent(reqId: string, targetId: string, sessions: AgentSession[]) {
  reply({ type: 'agent-sessions', reqId, targetId, sessions });
}

function handleAgentList(msg: AgentListMsg) {
  // 最近更新的排在前面；列表不依赖 controller 保留任何状态。
  void (async () => {
    // 历史 tab：完全由官方会话文件决定；默认 tab：本软件的会话记录（含从历史导入并继续过的）
    let list: StoredAgentSession[];
    if (msg.scope === 'claudeHistory') list = await discoverExternalClaudeSessions();
    else if (msg.scope === 'codexHistory') list = await discoverExternalCodexSessions();
    else if (msg.scope === 'cursorHistory') list = await discoverExternalCursorSessions();
    else if (msg.scope === 'piHistory') list = await discoverExternalPiSessions();
    else list = [...agentSessions].sort((a, b) => b.updatedAt - a.updatedAt);
    replyAgent(msg.reqId, msg.targetId, list.map(summarySnapshot));
  })();
}

function handleAgentStatus(msg: AgentStatusMsg) {
  void (async () => {
    const session = agentSessions.find((item) => item.sessionId === msg.sessionId)
      ?? (await findExternalAgentSession(msg.sessionId));
    replyAgent(msg.reqId, msg.targetId, session ? [await detailSnapshot(session)] : []);
  })();
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

async function handleAgentRun(msg: AgentRunMsg) {
  const prompt = msg.prompt.trim();
  if (!prompt) return replyAgent(msg.reqId, msg.targetId, []);

  let session: StoredAgentSession | undefined;
  if (msg.sessionId) session = agentSessions.find((item) => item.sessionId === msg.sessionId);
  // 内部记录没有但官方文件里有：外部会话（Claude 历史 / Codex 历史）首次继续对话，转为内部记录
  if (msg.sessionId && !session) {
    session = await findExternalAgentSession(msg.sessionId);
    if (session) {
      agentSessions.push(session);
      console.log(`[agent] 导入外部${session.agent === 'codex' ? ' Codex' : session.agent === 'cursor' ? ' Cursor' : session.agent === 'pi' ? ' Pi' : ' Claude Code'} 会话 ${session.sessionId} (cwd: ${session.cwd})`);
    }
  }
  if (msg.sessionId && !session) {
    return reply({ type: 'error', reqId: msg.reqId, message: '找不到该会话（它可能已在云电脑上被删除）' });
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
    // 默认工作区以及用户明确指定的不存在目录都会创建，避免 CLI 因 cwd 不存在直接启动失败。
    try { mkdirSync(cwd, { recursive: true }); } catch (err: any) {
      return reply({ type: 'error', reqId: msg.reqId, message: `无法创建 Agent 工作目录 ${cwd}: ${err.message}` });
    }
    session = {
      sessionId: randomUUID(),
      // 新建时才采用 msg.agent（缺省 claude）；继续会话时类型以记录为准
      agent: msg.agent === 'codex' ? 'codex' : 'claude',
      origin: 'link',
      title: prompt.replace(/\s+/g, ' ').slice(0, 48),
      cwd,
      state: 'running',
      createdAt: now,
      updatedAt: now,
    };
    agentSessions.push(session);
  } else {
    session.state = 'running';
    session.error = undefined;
    session.updatedAt = now;
    // 外部会话的 cwd 固定为原会话目录：--resume 依赖它定位 Claude Code 的官方会话文件
    if (msg.cwd?.trim() && session.origin !== 'external') session.cwd = msg.cwd.trim();
  }
  // 云电脑 Agent 没有可供用户确认的本地交互界面；显式跳过 CLI 的逐次权限询问，
  // 使其能按用户在控制端发起的任务读取和修改工作目录中的文件。
  const kind: AgentKind = session.agent ?? 'claude';
  // 消息一律以官方会话文件为准、本软件不维护。claude 按 cwd 推导路径；
  // codex 的 rollout 路径无法预知（文件名含时间戳），close 时按 thread id 回填。
  if (kind !== 'codex' && !session.jsonlPath) {
    session.jsonlPath = claudeJsonlPath(session.cwd, session.sessionId);
  }
  // 运行期间的内存视图基线：官方文件已解析的内容（旧记录无官方文件时用曾维护的副本兜底）
  const base = (await readAgentMessages(session)) ?? session.messages;
  activeRuns.set(session.sessionId, { baseMessages: JSON.parse(JSON.stringify(base ?? [])), prompt, streamedText: '' });
  persistAgentSessions().catch((err) => console.error(`[agent] 保存会话失败: ${err.message}`));
  // 立即回 running 快照；网络中断时控制端可稍后用 agent-status / agent-list 拉取最终结果。
  replyAgent(msg.reqId, msg.targetId, [runningSnapshot(session)]);

  let file: string;
  let args: string[];
  if (kind === 'codex') {
    // codex exec --json 输出 JSONL 事件；thread id 由 codex 自行生成（无法预指定），
    // 继续会话靠 exec resume <externalId>。stdin 必须给 /dev/null：管道会让 codex 追加读取 stdin 而挂起。
    file = 'codex';
    args = ['exec', '--json', '--skip-git-repo-check', '--dangerously-bypass-approvals-and-sandbox'];
    if (msg.sessionId && session.externalId) args.push('resume', session.externalId);
    args.push(prompt);
  } else if (kind === 'cursor') {
    // cursor-agent 的 stream-json 与 claude 同构；-f 跳过逐次权限确认（无人交互界面）。
    // 会话 id（--resume 用）无法预指定，从 init 事件的 session_id 获取。
    file = 'cursor-agent';
    args = ['-p', prompt, '--output-format', 'stream-json', '--stream-partial-output', '-f'];
    if (msg.sessionId && session.externalId) args.push('--resume', session.externalId);
  } else if (kind === 'pi') {
    // pi -p --mode json 输出 JSONL 事件；会话 id 从首行 session 事件获取，继续会话用 --session。
    file = 'pi';
    args = ['-p', prompt, '--mode', 'json'];
    if (msg.sessionId && session.externalId) args.push('--session', session.externalId);
  } else {
    // include-partial-messages 才会在 stream-json 中输出 token 级 text_delta；否则通常只会收到结束结果。
    file = 'claude';
    args = ['-p', prompt, '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--dangerously-skip-permissions'];
    if (msg.sessionId) args.push('--resume', session.sessionId);
    else args.push('--session-id', session.sessionId);
  }
  console.log(`[agent] ${msg.sessionId ? '继续' : '新建'}${kind === 'codex' ? ' Codex' : kind === 'cursor' ? ' Cursor' : kind === 'pi' ? ' Pi' : ' Claude Code'} 会话 ${session.sessionId}${session.cwd ? ` (cwd: ${session.cwd})` : ''}`);
  const child = spawn(file, args, { cwd: session.cwd || undefined, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
  agentProcesses.set(session.sessionId, child);
  let stdout = '';
  let stderr = '';
  let streamBuffer = '';
  let streamedText = '';
  let turnCompleted = false; // codex：收到过 turn.completed 则视为执行成功（stderr 可能有无害杂音）
  const publishStream = () => {
    session!.updatedAt = Date.now();
    // 增量只存在于内存视图（claude / codex 一致），断线恢复以官方会话文件的解析结果为准
    replyAgent(msg.reqId, msg.targetId, [runningSnapshot(session!)]);
  };
  const consumeStreamLine = (line: string) => {
    if (!line.trim()) return;
    try {
      const event = JSON.parse(line);
      if (kind === 'cursor') {
        if (event?.type === 'system' && event?.subtype === 'init' && typeof event?.session_id === 'string') {
          // 与 codex 的 thread.started 同理：尽早记录会话 id（--resume 用）
          if (session!.externalId !== event.session_id) {
            session!.externalId = event.session_id;
            session!.updatedAt = Date.now();
            persistAgentSessions().catch((err) => console.error(`[agent] 保存会话失败: ${err.message}`));
          }
        } else if (event?.type === 'assistant' && Array.isArray(event?.message?.content)) {
          // 带 timestamp_ms 的是增量 delta，不带的是整条完整消息（取 text 部分拼接）
          const text = event.message.content
            .filter((item: any) => item?.type === 'text' && typeof item?.text === 'string')
            .map((item: any) => item.text)
            .join('\n\n');
          if (!text) return;
          if (typeof event?.timestamp_ms === 'number') {
            const run = activeRuns.get(session!.sessionId);
            if (run) run.streamedText += text;
            streamedText += text;
            publishStream();
          } else if (!streamedText) {
            // 无增量时（未开 partial 的整条输出）一次成条
            const run = activeRuns.get(session!.sessionId);
            if (run) run.streamedText += text;
            streamedText += text;
            publishStream();
          }
        }
        return;
      }
      if (kind === 'pi') {
        if (event?.type === 'session' && typeof event?.id === 'string') {
          if (session!.externalId !== event.id) {
            session!.externalId = event.id;
            session!.updatedAt = Date.now();
            persistAgentSessions().catch((err) => console.error(`[agent] 保存会话失败: ${err.message}`));
          }
        } else if (event?.type === 'message_end' && event?.message?.role === 'assistant' && Array.isArray(event?.message?.content)) {
          // message_end 携带整条消息（无 token 级增量），一次成条
          const text = event.message.content
            .filter((item: any) => item?.type === 'text' && typeof item?.text === 'string')
            .map((item: any) => item.text)
            .join('\n\n');
          if (text) {
            const run = activeRuns.get(session!.sessionId);
            if (run) run.streamedText += text;
            streamedText += text;
            publishStream();
          }
        } else if (event?.type === 'agent_settled' && !event?.aborted) {
          turnCompleted = true;
        }
        return;
      }
      if (kind === 'codex') {
        if (event?.type === 'thread.started' && typeof event.thread_id === 'string') {
          // resume 与新建都会下发 thread.started；尽早落盘，client 中途被杀后仍可恢复
          if (session!.externalId !== event.thread_id) {
            session!.externalId = event.thread_id;
            session!.updatedAt = Date.now();
            persistAgentSessions().catch((err) => console.error(`[agent] 保存会话失败: ${err.message}`));
          }
        } else if (event?.type === 'item.completed' && event?.item?.type === 'agent_message') {
          const text = typeof event?.item?.text === 'string' ? event.item.text : '';
          if (text) {
            // codex 的 item.completed 携带整条消息（无 token 级增量），一次成条进内存视图
            const run = activeRuns.get(session!.sessionId);
            if (run) run.streamedText += text;
            streamedText += text;
            publishStream();
          }
        } else if (event?.type === 'turn.completed') {
          turnCompleted = true;
        }
        return;
      }
      const delta = event?.event?.delta;
      const text = delta?.type === 'text_delta' ? delta.text : undefined;
      if (typeof text === 'string' && text) {
        // claude 增量只进内存运行视图，最终以官方 jsonl 的完整消息为准
        const run = activeRuns.get(session!.sessionId);
        if (run) run.streamedText += text;
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
    if (err.message.includes('ENOENT')) {
      stderr += kind === 'codex'
        ? '未找到 codex 命令，请确认云电脑已安装 Codex CLI 且已登录。'
        : kind === 'cursor'
          ? '未找到 cursor-agent 命令，请确认云电脑已安装 Cursor Agent 且已登录。'
          : kind === 'pi'
            ? '未找到 pi 命令，请确认云电脑已安装 pi 且已登录。'
            : '未找到 claude 命令，请确认云电脑已安装 Claude Code CLI 且已登录。';
    }
  });
  child.on('close', async (code) => {
    agentProcesses.delete(session!.sessionId);
    const finished = Date.now();
    if (streamBuffer) consumeStreamLine(streamBuffer);
    let result = '';
    // claude / cursor 的 stream-json 最终 result 事件带完整结果；仅在未收到文本增量时作为回退，避免重复展示。
    let resultReported = false; // 是否收到 stream-json 的最终 result 事件（CLI 正常走完输出阶段）
    let resultIsError = false; // result 事件自身标记的错误
    if (kind === 'claude' || kind === 'cursor') {
      for (const line of stdout.split(/\r?\n/)) {
        try {
          const event = JSON.parse(line);
          if (event.type === 'result') {
            resultReported = true;
            if (event.is_error) {
              resultIsError = true;
              stderr ||= typeof event.result === 'string' ? event.result : 'Claude Code 执行失败';
            }
            if (typeof event.result === 'string') result = event.result;
          }
        } catch { /* 忽略非 JSON 行 */ }
      }
    }
    session!.updatedAt = finished;
    // codex / pi 的 stderr 可能带无害运行提示，以收到结束事件（turn.completed / agent_settled）为准；
    // claude / cursor 的 stderr 同样常有无害噪音（stdin 提示、代理模型名告警），收到 result 事件时以它为准，
    // 仅在 CLI 未走到输出阶段（无 result）时才用 stderr / 退出码兜底判失败。
    const hasResultEvent = kind === 'claude' || kind === 'cursor';
    const ok = code === 0 && (hasResultEvent
      ? resultReported ? !resultIsError : !stderr
      : turnCompleted || !stderr);
    if (ok) {
      session!.state = 'completed';
    } else {
      session!.state = 'failed';
      session!.error = stderr.trim() || `${kind === 'codex' ? 'Codex' : kind === 'cursor' ? 'Cursor' : kind === 'pi' ? 'Pi' : 'Claude Code'} 退出码 ${code ?? '未知'}`;
    }
    // 最终消息以官方会话文件为准；各 CLI 的会话文件路径此刻才可定位
    // （codex 文件名含时间戳、cursor 的实例目录与 pi 的会话文件均按会话 id 反查），逐一回填。
    // 若文件缺失或尚未包含本轮输入（CLI 启动失败 / 落盘延迟），
    // 回退用本轮运行视图组装，保证控制端不丢本次对话。
    if (session!.externalId) {
      if (kind === 'codex') {
        const paths = await findCodexAllRollouts(session!.externalId);
        if (paths.length > 0) session!.jsonlPath = paths[paths.length - 1];
      } else if (kind === 'cursor' && !session!.jsonlPath) {
        session!.jsonlPath = await locateCursorInstanceDir(session!.externalId);
      } else if (kind === 'pi' && !session!.jsonlPath) {
        session!.jsonlPath = await locatePiSessionFile(session!.externalId);
      }
    }
    let finalMessages: AgentSession['messages'] | undefined = await readAgentMessages(session!);
    const run = activeRuns.get(session!.sessionId);
    if (run && (finalMessages === undefined || !finalMessages.some((item) => item.role === 'user' && item.content === run.prompt))) {
      const replyText = run.streamedText || result;
      finalMessages = [
        ...run.baseMessages,
        { role: 'user', content: run.prompt, createdAt: now },
        ...(replyText ? [{ role: 'assistant' as const, content: replyText, createdAt: finished }] : []),
      ];
    }
    activeRuns.delete(session!.sessionId);
    try { await persistAgentSessions(); } catch (err: any) { console.error(`[agent] 保存会话失败: ${err.message}`); }
    // 流式阶段已推送 running；退出时必须再推送最终 completed / failed，控制端才能关闭 loading。
    replyAgent(msg.reqId, msg.targetId, [{ ...agentSnapshot(session!), messages: finalMessages ?? [] }]);
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

// ---------- 终端常用命令（本机持久化） ----------

async function loadTerminalCommands(): Promise<void> {
  try {
    const parsed = JSON.parse(await readFile(TERMINAL_COMMANDS_FILE, 'utf8'));
    terminalCommands = Array.isArray(parsed) ? parsed : [];
  } catch (err: any) {
    if (err?.code !== 'ENOENT') console.error(`[terminal-command] 读取失败: ${err.message}`);
    terminalCommands = [];
  }
}

async function persistTerminalCommands(): Promise<void> {
  await mkdir(RUNTIME_DIR, { recursive: true });
  const tmp = `${TERMINAL_COMMANDS_FILE}.tmp`;
  await writeFile(tmp, JSON.stringify(terminalCommands, null, 2), 'utf8');
  await rename(tmp, TERMINAL_COMMANDS_FILE);
}

function replyTerminalCommands(reqId: string, targetId: string) {
  reply({ type: 'terminal-commands', reqId, targetId, commands: [...terminalCommands].sort((a, b) => a.createdAt - b.createdAt) });
}

function handleTerminalCommandList(msg: TerminalCommandListMsg) { replyTerminalCommands(msg.reqId, msg.targetId); }

async function handleTerminalCommandSave(msg: TerminalCommandSaveMsg) {
  const command = msg.command.trim();
  if (!command) return reply({ type: 'error', reqId: msg.reqId, message: '命令内容不能为空' });
  const name = msg.name.trim() || command.split(/\s+/)[0];
  const now = Date.now();
  const existing = msg.commandId ? terminalCommands.find((item) => item.commandId === msg.commandId) : undefined;
  if (msg.commandId && !existing) return reply({ type: 'error', reqId: msg.reqId, message: '找不到该常用命令' });
  if (existing) {
    existing.name = name;
    existing.command = command;
    existing.updatedAt = now;
  } else {
    terminalCommands.push({ commandId: randomUUID(), name, command, createdAt: now, updatedAt: now });
  }
  try {
    await persistTerminalCommands();
    replyTerminalCommands(msg.reqId, msg.targetId);
  } catch (err: any) { reply({ type: 'error', reqId: msg.reqId, message: `保存常用命令失败: ${err.message}` }); }
}

async function handleTerminalCommandDelete(msg: TerminalCommandDeleteMsg) {
  const index = terminalCommands.findIndex((item) => item.commandId === msg.commandId);
  if (index < 0) return reply({ type: 'error', reqId: msg.reqId, message: '找不到该常用命令' });
  terminalCommands.splice(index, 1);
  try {
    await persistTerminalCommands();
    replyTerminalCommands(msg.reqId, msg.targetId);
  } catch (err: any) { reply({ type: 'error', reqId: msg.reqId, message: `删除常用命令失败: ${err.message}` }); }
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
  await loadTerminalCommands();
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
