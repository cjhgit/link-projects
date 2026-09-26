// 三个端共享的消息协议定义（client / controller 目录各有一份相同拷贝）
// 路由规则：controller 发出的消息带 targetId（目标 client），由 server 转发；
// client 发出的响应消息原样广播给所有 controller，各自按 reqId 过滤；
// 白名单管理类消息（*-whitelist / client-*）由 server 直接处理，不转发给 client。
// 保留目标 @server：文件类消息（file-list/read/write/create/delete）带此 targetId 时同样由 server
// 就地处理（浏览服务器本机文件，路径即 server 上的路径），响应直接回给发起的 controller。

export interface RegisterMsg {
  type: 'register';
  role: 'client' | 'controller';
  clientId: string; // client 的唯一标识；controller 传随机 id
  token: string;
  version?: string; // client 上报的自身版本（package.json），服务端原样透出
}

export interface RegisteredMsg {
  type: 'registered';
  ok: boolean;
  error?: string;
  serverVersion?: string; // server 自身版本（package.json），旧版 server 不下发
}

// controller -> server 查询在线客户端
export interface ListClientsMsg {
  type: 'list-clients';
}

// server -> controller 在线列表
export interface ClientsMsg {
  type: 'clients';
  clients: { clientId: string; connectedAt: number; version?: string }[]; // version 为该 client 注册时上报的版本
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
  targetId: string; // 白名单管理类操作由 server 响应时为空字符串（不经 client 转发）
  ok: boolean;
  error?: string;
}

// ===== 新建文本文件 / 删除 =====
export interface FileCreateMsg {
  type: 'file-create';
  reqId: string;
  targetId: string;
  path: string; // 完整路径；已存在（含同名目录）则失败，不覆盖已有内容
}

export interface FileDeleteMsg {
  type: 'file-delete';
  reqId: string;
  targetId: string;
  path: string; // 文件或目录，目录递归删除
}

// ===== 目录浏览 =====
export interface FileEntry {
  name: string;
  kind: 'dir' | 'file' | 'other'; // other：失效符号链接、设备文件等
  size: number; // 仅 file 有意义，字节
  mtime: number; // 修改时间（毫秒），取不到为 0
}

export interface FileListMsg {
  type: 'file-list';
  reqId: string;
  targetId: string;
  path: string; // 空或 ~ 表示 client 家目录，开头的 ~ 会展开
}

export interface FileListingMsg {
  type: 'file-listing';
  reqId: string;
  targetId: string;
  path: string; // 实际路径（~ 展开后），控制端据此继续导航
  entries?: FileEntry[]; // 目录在前、同级按名称自然排序
  error?: string;
}

export interface ErrorMsg {
  type: 'error';
  reqId?: string;
  message: string;
}

// ===== 客户端白名单管理（controller -> server 直接处理，响应也由 server 回给 controller） =====

// 查询服务端 clients.json 全量白名单
export interface ListWhitelistMsg {
  type: 'list-whitelist';
  reqId?: string;
}

// server -> controller 白名单全量列表（controller 注册后 / 白名单变更后推送，或作为 list-whitelist 响应）
export interface WhitelistMsg {
  type: 'whitelist';
  reqId?: string; // 仅作为 list-whitelist 响应时回传
  clients: { clientId: string; token: string; online: boolean }[];
}

// 新增客户端（clientId 已存在则失败）
export interface ClientAddMsg {
  type: 'client-add';
  reqId: string;
  clientId: string;
  token: string;
}

// 更新客户端 token（clientId 不存在则失败；不影响已建立的连接，重连后生效）
export interface ClientUpdateMsg {
  type: 'client-update';
  reqId: string;
  clientId: string;
  token: string;
}

// 删除客户端（同时断开其在线连接，立即生效）
export interface ClientRemoveMsg {
  type: 'client-remove';
  reqId: string;
  clientId: string;
}

export type ClientToServerMsg = RegisterMsg | ExecOutputMsg | ExecExitMsg | FileContentMsg | FileListingMsg | DoneMsg;
export type ServerMsg =
  | RegisteredMsg
  | ClientsMsg
  | ExecMsg
  | FileReadMsg
  | FileWriteMsg
  | FileCreateMsg
  | FileDeleteMsg
  | FileListMsg
  | DoneMsg
  | WhitelistMsg
  | ErrorMsg;
export type AnyMsg =
  | ClientToServerMsg
  | ServerMsg
  | ListClientsMsg
  | ListWhitelistMsg
  | ClientAddMsg
  | ClientUpdateMsg
  | ClientRemoveMsg;
