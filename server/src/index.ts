import './env';
import { WebSocketServer, WebSocket } from 'ws';
import http from 'node:http';
import https from 'node:https';
import { spawn, type ChildProcess } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, renameSync, createReadStream } from 'node:fs';
import type { Stats } from 'node:fs';
import { readFile, writeFile, rm, mkdir, readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, dirname, resolve, basename, extname, sep } from 'node:path';
import type {
  AnyMsg,
  RegisterMsg,
  FileEntry,
} from './protocol';

const PORT = Number(process.env.PORT || 9600);
// wss（TLS）配置：证书与私钥同时配置时额外监听一个加密端口，与 ws 明文端口并存
const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
const TLS_PORT = Number(process.env.TLS_PORT || 9601);
// controller 连接专用 token
const CONTROLLER_TOKEN = process.env.CONTROLLER_TOKEN || '';
// client 白名单文件（clientId -> 专属 token），默认放在项目根目录
const CLIENTS_FILE = process.env.CLIENTS_FILE || join(__dirname, '..', 'clients.json');
// 免鉴权 public 目录（配置后启用 http 文件服务，空则不启用）
const PUBLIC_DIR_RAW = process.env.PUBLIC_DIR || '';
// 支持 ~ 展开与相对路径（相对 server 项目根目录，与 CLIENTS_FILE 的基准一致）
const PUBLIC_DIR = !PUBLIC_DIR_RAW ? '' : resolve(
  __dirname, '..',
  PUBLIC_DIR_RAW === '~' || PUBLIC_DIR_RAW.startsWith('~/')
    ? join(homedir(), PUBLIC_DIR_RAW.slice(1))
    : PUBLIC_DIR_RAW,
);
// 自身版本（package.json 的 version，dev 与 dist 两种运行方式下 package.json 都在上级目录）
const VERSION: string = JSON.parse(readFileSync(join(__dirname, '..', 'package.json'), 'utf8')).version;

if (!CONTROLLER_TOKEN) {
  console.error('缺少 CONTROLLER_TOKEN 环境变量，退出');
  process.exit(1);
}
if (!existsSync(CLIENTS_FILE)) {
  console.error(`缺少 client 白名单文件 ${CLIENTS_FILE}，退出`);
  process.exit(1);
}

// 白名单读取：文件缺失/格式错误时返回 null（区别于空名单），管理类写入据此拒绝，避免把损坏文件覆盖成空名单
function readWhitelist(): Record<string, string> | null {
  try {
    return JSON.parse(readFileSync(CLIENTS_FILE, 'utf8'));
  } catch (err) {
    console.error(`[auth] 白名单文件解析失败: ${(err as Error).message}`);
    return null;
  }
}

// 每次注册时重读白名单，增删 client 无需重启服务
function loadClientTokens(): Record<string, string> {
  return readWhitelist() ?? {};
}

// 白名单写回：临时文件 + rename 原子替换，保持 2 空格缩进便于人工查看
function saveWhitelist(map: Record<string, string>): boolean {
  try {
    const tmp = `${CLIENTS_FILE}.tmp`;
    writeFileSync(tmp, `${JSON.stringify(map, null, 2)}\n`, 'utf8');
    renameSync(tmp, CLIENTS_FILE);
    return true;
  } catch (err) {
    console.error(`[whitelist] 白名单文件写入失败: ${(err as Error).message}`);
    return false;
  }
}

// clientId -> client 连接
const clients = new Map<string, WebSocket>();
// 所有已注册的 controller 连接
const controllers = new Set<WebSocket>();

// ---------- 服务器本机操作：执行命令 + 文件浏览（targetId = @server 保留目标） ----------

// 保留 targetId：controller 的 exec / 文件类消息带此目标时不转发，由 server 就地处理（操作服务器本机）
const SERVER_TARGET = '@server';
// 是否允许浏览服务器本机文件（默认允许；设 0 可禁止，防止 controller token 泄露时波及服务器自身文件）
const ALLOW_SERVER_FILES = process.env.ALLOW_SERVER_FILES !== '0';
// 是否允许在服务器本机执行命令（默认允许；设 0 可禁止，比文件浏览风险更高，可单独关闭）
const ALLOW_SERVER_EXEC = process.env.ALLOW_SERVER_EXEC !== '0';

// @server 目标执行中的命令子进程；进程退出时统一清理，避免遗留孤儿进程
const serverChildren = new Set<ChildProcess>();
function killServerChildren() {
  for (const child of serverChildren) {
    try { child.kill(); } catch { /* 忽略 */ }
  }
}
process.on('SIGTERM', () => { killServerChildren(); process.exit(0); });
process.on('SIGINT', () => { killServerChildren(); process.exit(0); });

// 服务器本机文件操作响应（结构对齐 client 的同名响应，targetId 固定为 @server）
function serverReply(ws: WebSocket, msg: any, payload: Record<string, unknown>) {
  send(ws, { reqId: msg.reqId ?? '', targetId: SERVER_TARGET, ...payload } as AnyMsg);
}

// 在服务器本机执行 shell 命令，stdout/stderr 流式回传（对齐 client 的 handleExec）
function serverExec(ws: WebSocket, msg: any) {
  console.log(`[exec] @server ${msg.command}${msg.cwd ? ` (cwd: ${msg.cwd})` : ''}`);
  const child = spawn('/bin/bash', ['-c', msg.command], { cwd: msg.cwd || undefined });
  serverChildren.add(child);
  child.on('exit', () => serverChildren.delete(child));

  const output = (stream: 'stdout' | 'stderr') => (d: Buffer) => {
    send(ws, { reqId: msg.reqId, targetId: SERVER_TARGET, type: 'exec-output', stream, data: d.toString() } as AnyMsg);
  };
  child.stdout.on('data', output('stdout'));
  child.stderr.on('data', output('stderr'));
  child.on('error', (err) => {
    send(ws, { reqId: msg.reqId, targetId: SERVER_TARGET, type: 'exec-output', stream: 'stderr', data: `启动失败: ${err.message}\n` } as AnyMsg);
    send(ws, { reqId: msg.reqId, targetId: SERVER_TARGET, type: 'exec-exit', code: 127 } as AnyMsg);
  });
  child.on('exit', (code) => {
    send(ws, { reqId: msg.reqId, targetId: SERVER_TARGET, type: 'exec-exit', code } as AnyMsg);
  });
}

// 以下五个处理函数与 client/src/index.ts 的同名逻辑保持一致（~ 展开、stat 容错、wx 防覆盖等），
// 区别仅在于操作的是 server 本机文件系统、响应只回发起的 controller

async function serverFileList(ws: WebSocket, msg: any) {
  const raw = (msg.path || '').trim() || '~';
  const target = raw === '~' || raw.startsWith('~/')
    ? join(homedir(), raw.slice(1))
    : raw;
  console.log(`[file-list] @server ${raw} -> ${target}`);
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
    serverReply(ws, msg, { type: 'file-listing', path: target, entries });
  } catch (err: any) {
    serverReply(ws, msg, { type: 'file-listing', path: target, error: err.message });
  }
}

async function serverFileRead(ws: WebSocket, msg: any) {
  console.log(`[file-read] @server ${msg.path}`);
  try {
    const content = await readFile(msg.path, 'utf8');
    serverReply(ws, msg, { type: 'file-content', path: msg.path, content });
  } catch (err: any) {
    serverReply(ws, msg, { type: 'file-content', path: msg.path, error: err.message });
  }
}

async function serverFileWrite(ws: WebSocket, msg: any) {
  console.log(`[file-write] @server ${msg.path} (${String(msg.content ?? '').length} 字符)`);
  try {
    // 目标目录不存在时自动创建
    await mkdir(dirname(msg.path), { recursive: true });
    await writeFile(msg.path, msg.content, 'utf8');
    serverReply(ws, msg, { type: 'done', ok: true });
  } catch (err: any) {
    serverReply(ws, msg, { type: 'done', ok: false, error: err.message });
  }
}

// 新建空文本文件：wx 标志保证仅在不存在时创建，绝不动已有内容
async function serverFileCreate(ws: WebSocket, msg: any) {
  console.log(`[file-create] @server ${msg.path}`);
  try {
    await writeFile(msg.path, '', { flag: 'wx' });
    serverReply(ws, msg, { type: 'done', ok: true });
  } catch (err: any) {
    serverReply(ws, msg, { type: 'done', ok: false, error: err.message });
  }
}

// 删除文件或目录（目录递归删除）
async function serverFileDelete(ws: WebSocket, msg: any) {
  console.log(`[file-delete] @server ${msg.path}`);
  try {
    await rm(msg.path, { recursive: true });
    serverReply(ws, msg, { type: 'done', ok: true });
  } catch (err: any) {
    serverReply(ws, msg, { type: 'done', ok: false, error: err.message });
  }
}

// ---------- 免鉴权 public 目录 HTTP 文件服务（配置 PUBLIC_DIR 后启用） ----------
// 浏览器直接访问 http://<服务器IP>:<PORT>/ 浏览/下载该目录，无任何鉴权，只应放置可公开的文件。
// 与 ws 共用监听端口（HTTP 请求与 WebSocket 升级可同端口并存）；配置 TLS 时 https 端口同样提供服务。

// 常见扩展名 -> Content-Type；未命中的按 attachment 下发，避免未知类型被浏览器当文本渲染
const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8', '.md': 'text/markdown; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.ico': 'image/x-icon',
  '.pdf': 'application/pdf',
  '.mp4': 'video/mp4', '.webm': 'video/webm',
  '.mp3': 'audio/mpeg', '.wav': 'audio/wav',
  '.zip': 'application/zip', '.gz': 'application/gzip', '.tar': 'application/x-tar',
};

function humanSize(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = -1;
  do { v /= 1024; i++; } while (v >= 1024 && i < units.length - 1);
  return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

// 目录浏览页（目录在前、名称自然排序，与 @server 文件列表的排序规则一致）
async function renderDirIndex(absDir: string, urlPath: string): Promise<string> {
  const dirents = await readdir(absDir, { withFileTypes: true });
  const rows = await Promise.all(dirents.map(async (d) => {
    let isDir = d.isDirectory();
    let size = '-';
    let mtime = '-';
    try {
      const st = await stat(join(absDir, d.name));
      isDir = st.isDirectory();
      if (!isDir) size = humanSize(st.size);
      mtime = new Date(st.mtimeMs).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
    } catch { /* 删除竞态等，保留粗略信息 */ }
    return { name: d.name, isDir, size, mtime };
  }));
  rows.sort((a, b) =>
    Number(b.isDir) - Number(a.isDir) ||
    a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' })
  );
  const esc = (s: string) =>
    s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const up = urlPath !== '/' ? '<tr><td><a href="../">../</a></td><td>-</td><td>-</td></tr>' : '';
  const items = rows.map((r) => {
    // 相对链接（当前目录 URL 已带尾斜杠），中文/空格等经 encodeURIComponent 编码
    const href = encodeURIComponent(r.name) + (r.isDir ? '/' : '');
    return `<tr><td><a href="${href}">${esc(r.name)}${r.isDir ? '/' : ''}</a></td><td>${r.size}</td><td>${r.mtime}</td></tr>`;
  }).join('\n');
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(urlPath)}</title>
<style>
  body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 2rem 1rem; }
  main { max-width: 48rem; margin: 0 auto; }
  h1 { font-size: 1.1rem; word-break: break-all; }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  td { padding: 0.35rem 0.6rem; border-bottom: 1px solid #eee; white-space: nowrap; }
  td:first-child { white-space: normal; word-break: break-all; }
  td:nth-child(2), td:nth-child(3) { color: #888; text-align: right; font-variant-numeric: tabular-nums; }
  a { color: #0366d6; text-decoration: none; } a:hover { text-decoration: underline; }
</style>
</head>
<body>
<main>
<h1>/${esc(urlPath.replace(/^\//, ''))}</h1>
<table>
${up}
${items}
</table>
</main>
</body>
</html>`;
}

// 文件响应：流式发送；未知扩展名带 Content-Disposition 按下载处理（RFC 5987 编码中文文件名）
function sendFile(abs: string, st: Stats, req: http.IncomingMessage, res: http.ServerResponse) {
  const type = MIME[extname(abs).toLowerCase()] || 'application/octet-stream';
  const headers: Record<string, string | number> = {
    'Content-Type': type,
    'Content-Length': st.size,
    'Last-Modified': st.mtime.toUTCString(),
    'X-Content-Type-Options': 'nosniff',
  };
  if (type === 'application/octet-stream') {
    headers['Content-Disposition'] = `attachment; filename*=UTF-8''${encodeURIComponent(basename(abs))}`;
  }
  res.writeHead(200, headers);
  if (req.method === 'HEAD') return res.end();
  const stream = createReadStream(abs);
  stream.on('error', () => res.destroy());
  stream.pipe(res);
}

// HTTP 请求统一入口：未配置 PUBLIC_DIR 一律 404；配置后提供目录浏览 + 文件下载
function publicHttpHandler(req: http.IncomingMessage, res: http.ServerResponse) {
  const done = (status: number, body: string, headers: Record<string, string> = {}) => {
    res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', ...headers });
    res.end(req.method === 'HEAD' ? undefined : body);
  };
  if (!PUBLIC_DIR) return done(404, 'public 文件服务未启用（未配置 PUBLIC_DIR）\n');
  if (req.method !== 'GET' && req.method !== 'HEAD') return done(405, '只支持 GET\n', { Allow: 'GET, HEAD' });

  let rel: string;
  try {
    rel = decodeURIComponent((req.url || '/').split('?')[0]);
  } catch {
    return done(400, 'URL 编码非法\n');
  }
  // resolve 规范化 .. 等路径段后必须仍位于 PUBLIC_DIR 内，防目录穿越
  const abs = resolve(PUBLIC_DIR, `.${rel}`);
  if (abs !== PUBLIC_DIR && !abs.startsWith(PUBLIC_DIR + sep)) return done(403, '禁止访问目录外路径\n');

  stat(abs).then(async (st) => {
    if (st.isDirectory()) {
      const reqPath = (req.url || '/').split('?')[0];
      // 目录无尾斜杠先 301 补上，保证页内相对链接不错位
      if (!reqPath.endsWith('/')) {
        res.writeHead(301, { Location: reqPath + '/' });
        return res.end();
      }
      // 存在 index.html 时直接作为目录首页（可用来放静态网页）
      const indexFile = join(abs, 'index.html');
      try {
        const ist = await stat(indexFile);
        if (ist.isFile()) return sendFile(indexFile, ist, req, res);
      } catch { /* 无 index.html，列目录 */ }
      const html = await renderDirIndex(abs, rel);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'X-Content-Type-Options': 'nosniff' });
      res.end(req.method === 'HEAD' ? undefined : html);
      return;
    }
    if (!st.isFile()) return done(404, '不是文件或目录\n');
    sendFile(abs, st, req, res);
  }).catch(() => done(404, '文件不存在\n'));
}

function send(ws: WebSocket, msg: AnyMsg) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

// 把在线客户端列表推给所有 controller
function broadcastClientList() {
  const list = {
    type: 'clients' as const,
    clients: [...clients.entries()].map(([clientId, ws]) => ({
      clientId,
      connectedAt: (ws as any).__connectedAt ?? 0,
      version: (ws as any).__version || undefined,
    })),
  };
  for (const c of controllers) send(c, list);
}

// 白名单全量列表（online 按当前在线连接实时计算）
function whitelistMsg() {
  const map = loadClientTokens();
  return {
    type: 'whitelist' as const,
    clients: Object.entries(map).map(([clientId, token]) => ({
      clientId,
      token,
      online: clients.has(clientId),
    })),
  };
}

function sendWhitelist(ws: WebSocket, reqId?: string) {
  send(ws, { ...whitelistMsg(), reqId });
}

// 白名单变更后推给所有 controller，各端列表保持同步
function broadcastWhitelist() {
  const list = whitelistMsg();
  for (const c of controllers) send(c, list);
}

// 连接处理：注册鉴权、消息路由，ws 与 wss 两个监听共用
function onConnection(ws: WebSocket) {
  let role: 'client' | 'controller' | null = null;
  let clientId = '';

  ws.on('message', (raw) => {
    let msg: AnyMsg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return send(ws, { type: 'error', message: '非法 JSON' });
    }

    // 未注册前只接受 register
    if (!role) {
      if (msg.type !== 'register') {
        return send(ws, { type: 'error', message: '请先发送 register' });
      }
      const reg = msg as RegisterMsg;
      if (reg.role === 'client') {
        // client：ID + 专属 token 必须匹配白名单
        const expect = loadClientTokens()[reg.clientId];
        if (!expect || expect !== reg.token) {
          console.log(`[auth] client ${reg.clientId} 白名单校验失败，拒绝`);
          return send(ws, { type: 'registered', ok: false, error: 'ID 或 token 不在服务端白名单' });
        }
      } else if (reg.token !== CONTROLLER_TOKEN) {
        // controller：专用 token
        console.log('[auth] controller token 校验失败，拒绝');
        return send(ws, { type: 'registered', ok: false, error: 'token 错误' });
      }
      role = reg.role;
      if (role === 'client') {
        clientId = reg.clientId;
        // 同名旧连接顶掉
        const old = clients.get(clientId);
        if (old && old !== ws) old.close();
        clients.set(clientId, ws);
        (ws as any).__connectedAt = Date.now();
        (ws as any).__version = reg.version || '';
        console.log(`[client] ${clientId} 上线（共 ${clients.size} 台）${reg.version ? `，版本 ${reg.version}` : ''}`);
        broadcastClientList();
      } else {
        controllers.add(ws);
        console.log('[controller] 上线');
      }
      send(ws, { type: 'registered', ok: true, serverVersion: VERSION });
      // controller 注册后顺带推送白名单，管理界面打开即有数据
      if (role === 'controller') sendWhitelist(ws);
      return;
    }

    // controller 查询在线列表
    if (msg.type === 'list-clients') {
      return send(ws, {
        type: 'clients',
        clients: [...clients.entries()].map(([id, c]) => ({
          clientId: id,
          connectedAt: (c as any).__connectedAt ?? 0,
          version: (c as any).__version || undefined,
        })),
      });
    }

    // controller 查询白名单
    if (role === 'controller' && msg.type === 'list-whitelist') {
      return sendWhitelist(ws, (msg as any).reqId);
    }

    // controller 增删改白名单（server 直接处理并回执，不经 client 转发）
    if (role === 'controller' && ['client-add', 'client-update', 'client-remove'].includes(msg.type)) {
      const m = msg as any;
      const reply = (ok: boolean, error?: string) =>
        send(ws, { type: 'done', reqId: m.reqId ?? '', targetId: '', ok, error });
      const clientId = String(m.clientId ?? '').trim();
      const token = String(m.token ?? '').trim();
      if (!clientId) return reply(false, 'clientId 不能为空');

      const map = readWhitelist();
      if (!map) return reply(false, '白名单文件读取失败，请先在服务器上检查 clients.json 格式');
      if (msg.type === 'client-add') {
        if (!token) return reply(false, 'token 不能为空');
        if (clientId === SERVER_TARGET) return reply(false, `客户端 ID ${SERVER_TARGET} 为服务端保留字`);
        if (map[clientId] !== undefined) return reply(false, `客户端 ${clientId} 已存在`);
        map[clientId] = token;
      } else if (msg.type === 'client-update') {
        if (map[clientId] === undefined) return reply(false, `客户端 ${clientId} 不存在`);
        if (!token) return reply(false, 'token 不能为空');
        map[clientId] = token;
      } else {
        if (map[clientId] === undefined) return reply(false, `客户端 ${clientId} 不存在`);
        delete map[clientId];
      }
      if (!saveWhitelist(map)) return reply(false, '白名单文件写入失败（检查服务器磁盘/权限）');

      console.log(`[whitelist] ${msg.type === 'client-add' ? '新增' : msg.type === 'client-update' ? '更新' : '删除'} ${clientId}`);
      reply(true);
      broadcastWhitelist();
      // 删除时同步断开在线连接，立即生效（client 重连注册会因白名单缺失被拒）；
      // 更新 token 不断开，旧连接保持，重连后用新 token
      if (msg.type === 'client-remove') clients.get(clientId)?.close(4001, 'removed from whitelist');
      return;
    }

    // controller -> client：按 targetId 转发
    if (role === 'controller' && msg.type !== 'register') {
      const m = msg as any;
      // 保留目标 @server：exec 与文件类消息由 server 就地处理（操作服务器本机）
      if (m.targetId === SERVER_TARGET) {
        if (msg.type === 'exec') {
          if (!ALLOW_SERVER_EXEC) {
            return send(ws, { type: 'error', reqId: m.reqId, message: '服务端已禁用本机命令执行（ALLOW_SERVER_EXEC=0）' });
          }
          return serverExec(ws, m);
        }
        if (!ALLOW_SERVER_FILES) {
          return send(ws, { type: 'error', reqId: m.reqId, message: '服务端已禁用本机文件浏览（ALLOW_SERVER_FILES=0）' });
        }
        switch (msg.type) {
          case 'file-list': return serverFileList(ws, m);
          case 'file-read': return serverFileRead(ws, m);
          case 'file-write': return serverFileWrite(ws, m);
          case 'file-create': return serverFileCreate(ws, m);
          case 'file-delete': return serverFileDelete(ws, m);
          default:
            return send(ws, { type: 'error', reqId: m.reqId, message: `服务器主机不支持 ${msg.type} 类型消息` });
        }
      }
      const target = m.targetId ? clients.get(m.targetId) : undefined;
      if (!target) {
        return send(ws, {
          type: 'error',
          reqId: m.reqId,
          message: `客户端 ${m.targetId} 不在线`,
        });
      }
      return send(target, msg);
    }

    // client -> controller：响应广播给所有 controller，各自按 reqId 过滤。
    // 只放行指令响应类消息，防止 client 伪造 clients / whitelist 等服务端消息
    const CLIENT_RESPONSE_TYPES = new Set(['exec-output', 'exec-exit', 'file-content', 'file-listing', 'done', 'error', 'agent-sessions', 'projects']);
    if (role === 'client' && msg.type !== 'register') {
      if (!CLIENT_RESPONSE_TYPES.has(msg.type)) return;
      for (const c of controllers) send(c, msg);
    }
  });

  ws.on('close', () => {
    if (role === 'client' && clientId) {
      if (clients.get(clientId) === ws) clients.delete(clientId);
      console.log(`[client] ${clientId} 下线（剩余 ${clients.size} 台）`);
      broadcastClientList();
    }
    if (role === 'controller') {
      controllers.delete(ws);
      console.log('[controller] 下线');
    }
  });

  ws.on('error', (err) => {
    console.error(`[ws] 连接错误: ${err.message}`);
  });
}

// ws 与 public 文件服务共用同一 HTTP 端口：普通请求走文件服务，WebSocket 升级走 ws
const httpServer = http.createServer(publicHttpHandler);
const wss = new WebSocketServer({ server: httpServer });
httpServer.listen(PORT, () => {
  console.log(`[server] 监听端口 ${PORT}（ws://${PUBLIC_DIR ? ' + http 文件服务' : ''}）`);
});
wss.on('connection', onConnection);

// PUBLIC_DIR 启用提示（目录不存在时自动创建）
if (PUBLIC_DIR) {
  mkdir(PUBLIC_DIR, { recursive: true }).then(
    () => console.log(`[public] 免鉴权文件服务: ${PUBLIC_DIR} -> http://<服务器IP>:${PORT}/`),
    (err) => console.error(`[public] 目录创建失败，文件服务不可用: ${(err as Error).message}`),
  );
}

// wss://（TLS 加密）：client/controller 把地址换成 wss://<证书域名>:<TLS_PORT> 即用；https 端口同样提供文件服务
if (TLS_CERT && TLS_KEY) {
  try {
    const httpsServer = https.createServer({
      cert: readFileSync(TLS_CERT),
      key: readFileSync(TLS_KEY),
    }, publicHttpHandler);
    httpsServer.on('error', (err) => {
      console.error(`[server] wss 监听失败: ${(err as Error).message}`);
      process.exit(1);
    });
    const wssSecure = new WebSocketServer({ server: httpsServer });
    wssSecure.on('connection', onConnection);
    httpsServer.listen(TLS_PORT, () => {
      console.log(`[server] 监听端口 ${TLS_PORT}（wss://，证书 ${TLS_CERT}）`);
    });
  } catch (err) {
    console.error(`[server] wss 启用失败（证书/私钥读取）: ${(err as Error).message}`);
    process.exit(1);
  }
} else if (TLS_CERT || TLS_KEY) {
  console.warn('[server] TLS_CERT 与 TLS_KEY 需同时配置，未启用 wss');
}
