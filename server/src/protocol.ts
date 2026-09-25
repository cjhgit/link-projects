// 三个端共享的消息协议定义（client / controller 目录各有一份相同拷贝）
// 路由规则：controller 发出的消息带 targetId（目标 client），由 server 转发；
// client 发出的响应消息原样广播给所有 controller，各自按 reqId 过滤。

export interface RegisterMsg {
  type: 'register';
  role: 'client' | 'controller';
  clientId: string; // client 的唯一标识；controller 传随机 id
  token: string;
}

export interface RegisteredMsg {
  type: 'registered';
  ok: boolean;
  error?: string;
}

// controller -> server 查询在线客户端
export interface ListClientsMsg {
  type: 'list-clients';
}

// server -> controller 在线列表
export interface ClientsMsg {
  type: 'clients';
  clients: { clientId: string; connectedAt: number }[];
}

// ===== 执行命令（流式回传） =====
export interface ExecMsg {
  type: 'exec';
  reqId: string;
  targetId: string;
  command: string;
  cwd?: string;
}

export interface ExecOutputMsg {
  type: 'exec-output';
  reqId: string;
  targetId: string;
  stream: 'stdout' | 'stderr';
  data: string;
}

export interface ExecExitMsg {
  type: 'exec-exit';
  reqId: string;
  targetId: string;
  code: number | null; // null = 被信号杀死
}

// ===== 文件读写 =====
export interface FileReadMsg {
  type: 'file-read';
  reqId: string;
  targetId: string;
  path: string;
}

export interface FileContentMsg {
  type: 'file-content';
  reqId: string;
  targetId: string;
  path: string;
  content?: string;
  error?: string;
}

export interface FileWriteMsg {
  type: 'file-write';
  reqId: string;
  targetId: string;
  path: string;
  content: string;
}

export interface DoneMsg {
  type: 'done';
  reqId: string;
  targetId: string;
  ok: boolean;
  error?: string;
}

export interface ErrorMsg {
  type: 'error';
  reqId?: string;
  message: string;
}

export type ClientToServerMsg = RegisterMsg | ExecOutputMsg | ExecExitMsg | FileContentMsg | DoneMsg;
export type ServerMsg =
  | RegisteredMsg
  | ClientsMsg
  | ExecMsg
  | FileReadMsg
  | FileWriteMsg
  | ErrorMsg;
export type AnyMsg = ClientToServerMsg | ServerMsg | ListClientsMsg;
