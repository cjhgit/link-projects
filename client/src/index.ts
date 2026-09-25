import './env';
import { WebSocket } from 'ws';
import { spawn } from 'node:child_process';
import { hostname as osHostname } from 'node:os';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import type {
  AnyMsg,
  ExecMsg,
  FileReadMsg,
  FileWriteMsg,
} from './protocol';

// 配置：环境变量优先，其次命令行参数 --server / --id / --token
const args = process.argv.slice(2);
function argOf(name: string): string | undefined {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

const SERVER = argOf('server') || process.env.LINK_SERVER || 'ws://127.0.0.1:9600';
const CLIENT_ID = argOf('id') || process.env.LINK_CLIENT_ID || osHostname();
const TOKEN = argOf('token') || process.env.LINK_TOKEN || '';

if (!TOKEN) {
  console.error('缺少 token（--token 或环境变量 LINK_TOKEN）');
  process.exit(1);
}

const RECONNECT_DELAY = 3000;
let ws: WebSocket;

function reply(msg: AnyMsg) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function connect() {
  ws = new WebSocket(SERVER);

  ws.on('open', () => {
    ws.send(JSON.stringify({
      type: 'register',
      role: 'client',
      clientId: CLIENT_ID,
      token: TOKEN,
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
          process.exit(1);
        }
        console.log('[client] 注册成功，等待指令');
        break;
      case 'exec':
        return handleExec(msg as ExecMsg);
      case 'file-read':
        return handleFileRead(msg as FileReadMsg);
      case 'file-write':
        return handleFileWrite(msg as FileWriteMsg);
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

console.log(`[client] 启动：server=${SERVER} id=${CLIENT_ID}`);
connect();
