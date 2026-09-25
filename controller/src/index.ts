import './env';
import { WebSocket } from 'ws';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import type {
  AnyMsg,
  ClientsMsg,
} from './protocol';

const args = process.argv.slice(2);
function argOf(name: string): string | undefined {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

const SERVER = argOf('server') || process.env.LINK_SERVER || 'ws://127.0.0.1:9600';
const TOKEN = argOf('token') || process.env.LINK_TOKEN || '';

if (!TOKEN) {
  console.error('缺少 token（--token 或环境变量 LINK_TOKEN）');
  process.exit(1);
}

let currentTarget = ''; // 当前控制的 client id
let onlineClients: { clientId: string }[] = [];
let registered = false;
let ready = false; // 注册完成且拿到客户端列表后才开始处理输入
const pendingLines: string[] = [];
let listRequested = false; // 用户主动 /list，收到响应时打印详细列表

const rl = createInterface({
  input: process.stdin,
  output: process.stdout,
  prompt: '',
});

const ws = new WebSocket(SERVER);

function newReqId(): string {
  return randomUUID().slice(0, 8);
}

// 注册完成且拿到客户端列表（或已有选择）后，重放缓存的输入
function maybeFlush() {
  if (ready || !registered) return;
  if (!currentTarget && onlineClients.length === 0) return;
  ready = true;
  for (const l of pendingLines.splice(0)) handleLine(l);
}

function send(msg: AnyMsg) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function setPrompt() {
  rl.setPrompt(currentTarget ? `${currentTarget}> ` : '(未选择)> ');
}

// 实时输出：先清掉当前行（提示符+未输入完的内容），打印后重画提示符
function printChunk(text: string, isErr = false) {
  process.stdout.write('\r\x1b[K');
  if (isErr) process.stdout.write('\x1b[31m'); // stderr 红色
  process.stdout.write(text);
  if (isErr) process.stdout.write('\x1b[0m');
  rl.prompt(true);
}

ws.on('open', () => {
  ws.send(JSON.stringify({
    type: 'register',
    role: 'controller',
    clientId: randomUUID().slice(0, 8),
    token: TOKEN,
  }));
});

ws.on('close', () => {
  console.log('\n[与服务器断开连接，退出]');
  process.exit(1);
});

ws.on('error', (err) => {
  console.error(`[连接错误] ${err.message}`);
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
        console.error(`[注册被拒绝] ${msg.error}`);
        process.exit(1);
      }
      registered = true;
      console.log(`[已连接服务器 ${SERVER}]`);
      send({ type: 'list-clients' });
      maybeFlush();
      rl.prompt();
      break;

    case 'clients': {
      const m = msg as ClientsMsg;
      const before = onlineClients.map((c) => c.clientId).join(',');
      onlineClients = m.clients;
      const after = m.clients.map((c) => c.clientId).join(',');
      // 当前目标掉线、或还没选且只有一台在线时，自动选择
      if (!m.clients.some((c) => c.clientId === currentTarget)) {
        currentTarget = '';
        if (m.clients.length === 1) currentTarget = m.clients[0].clientId;
        setPrompt();
        rl.prompt(true);
      } else if (!currentTarget && m.clients.length === 1) {
        currentTarget = m.clients[0].clientId;
        setPrompt();
        rl.prompt(true);
      }
      // 主动 /list 时打印详细列表（* 标记当前目标）；线路变化时只打印摘要
      if (listRequested) {
        listRequested = false;
        if (m.clients.length === 0) {
          printChunk('[无在线客户端]\n', true);
        } else {
          const lines = m.clients.map((c) => {
            const cur = c.clientId === currentTarget;
            return `  ${cur ? '*' : ' '} ${c.clientId}${cur ? '  <- 当前' : ''}`;
          });
          printChunk(`在线客户端：\n${lines.join('\n')}\n`);
        }
      } else if (registered && before !== after) {
        printChunk(`[在线客户端: ${after || '无'}]\n`);
      }
      maybeFlush();
      break;
    }

    case 'exec-output':
      printChunk(msg.data, msg.stream === 'stderr');
      break;

    case 'exec-exit':
      if (msg.code !== 0) {
        printChunk(`[退出码 ${msg.code}]\n`);
      }
      break;

    case 'file-content':
      if (msg.error) printChunk(`[读取失败] ${msg.error}\n`, true);
      else printChunk(msg.content!.endsWith('\n') ? msg.content! : msg.content! + '\n');
      break;

    case 'done':
      if (msg.ok) printChunk('[写入成功]\n');
      else printChunk(`[写入失败] ${msg.error}\n`, true);
      break;

    case 'error':
      printChunk(`[错误] ${msg.message}\n`, true);
      break;
  }
});

function requireTarget(): boolean {
  if (currentTarget) return true;
  printChunk('[请先用 /use <clientId> 选择客户端，/list 查看在线列表]\n', true);
  return false;
}

function handleLine(line: string) {
  const input = line.trim();
  if (!input) {
    rl.prompt();
    return;
  }

  // 本地命令以 / 开头
  if (input.startsWith('/')) {
    const [cmd, ...rest] = input.slice(1).split(/\s+/);
    switch (cmd) {
      case 'list':
        listRequested = true;
        send({ type: 'list-clients' });
        break;
      case 'use': {
        const id = rest.join(' ');
        if (!id) {
          printChunk('用法: /use <clientId>\n', true);
          break;
        }
        if (!onlineClients.some((c) => c.clientId === id)) {
          printChunk(`[注意] ${id} 不在当前在线列表中，仍会尝试发送\n`);
        }
        currentTarget = id;
        setPrompt();
        printChunk(`[已选择 ${id}]\n`);
        break;
      }
      case 'read': {
        if (!requireTarget()) break;
        const path = rest.join(' ');
        if (!path) {
          printChunk('用法: /read <远程路径>\n', true);
          break;
        }
        send({ type: 'file-read', reqId: newReqId(), targetId: currentTarget, path });
        break;
      }
      case 'write': {
        if (!requireTarget()) break;
        const path = rest[0] ?? '';
        const content = path ? input.slice(input.indexOf(path) + path.length).trimStart() : '';
        if (!path || content === '') {
          printChunk('用法: /write <远程路径> <内容>\n', true);
          break;
        }
        send({ type: 'file-write', reqId: newReqId(), targetId: currentTarget, path, content });
        break;
      }
      case 'help':
        printChunk(
          '命令：\n' +
          '  /list              查看在线客户端\n' +
          '  /use <id>          选择要控制的客户端\n' +
          '  /read <路径>        读取远程文件\n' +
          '  /write <路径> <内容> 写入远程文件\n' +
          '  /exit              退出\n' +
          '  其他任意输入        作为 shell 命令在客户端执行（实时输出）\n'
        );
        break;
      case 'exit':
        ws.close();
        process.exit(0);
      default:
        printChunk(`未知命令 ${cmd}，/help 查看帮助\n`, true);
    }
    rl.prompt();
    return;
  }

  // 其余输入作为 shell 命令下发
  if (!requireTarget()) {
    rl.prompt();
    return;
  }
  send({ type: 'exec', reqId: newReqId(), targetId: currentTarget, command: input });
  rl.prompt();
}

rl.on('line', (line) => {
  if (!ready) {
    pendingLines.push(line);
    return;
  }
  handleLine(line);
});

rl.on('close', () => {
  ws.close();
  process.exit(0);
});
