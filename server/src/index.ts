import './env';
import { WebSocketServer, WebSocket } from 'ws';
import { existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import type {
  AnyMsg,
  RegisterMsg,
} from './protocol';

const PORT = Number(process.env.PORT || 9600);
// controller 连接专用 token
const CONTROLLER_TOKEN = process.env.CONTROLLER_TOKEN || '';
// client 白名单文件（clientId -> 专属 token），默认放在项目根目录
const CLIENTS_FILE = process.env.CLIENTS_FILE || join(__dirname, '..', 'clients.json');

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

const wss = new WebSocketServer({ port: PORT });
console.log(`[server] 监听端口 ${PORT}`);

wss.on('connection', (ws) => {
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
        console.log(`[client] ${clientId} 上线（共 ${clients.size} 台）`);
        broadcastClientList();
      } else {
        controllers.add(ws);
        console.log('[controller] 上线');
      }
      send(ws, { type: 'registered', ok: true });
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
    const CLIENT_RESPONSE_TYPES = new Set(['exec-output', 'exec-exit', 'file-content', 'done']);
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
});
