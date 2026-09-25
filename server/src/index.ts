import './env';
import { WebSocketServer, WebSocket } from 'ws';
import { existsSync, readFileSync } from 'node:fs';
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

// 每次注册时重读白名单，增删 client 无需重启服务
function loadClientTokens(): Record<string, string> {
  try {
    return JSON.parse(readFileSync(CLIENTS_FILE, 'utf8'));
  } catch (err) {
    console.error(`[auth] 白名单文件解析失败: ${(err as Error).message}`);
    return {};
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
      return send(ws, { type: 'registered', ok: true });
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

    // client -> controller：响应广播给所有 controller，各自按 reqId 过滤
    if (role === 'client' && msg.type !== 'register') {
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
