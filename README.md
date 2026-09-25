# Link Projects —— 云电脑远程控制系统

多台云电脑（无公网 IP）+ 一台公网服务器中继 + 本地控制台，实现对云电脑的远程命令执行（实时输出）和文件读写。

## 架构

```
┌────────────┐      ┌──────────────────┐      ┌────────────┐
│ controller │◄────►│  server (公网)    │◄────►│   client   │
│  (本地电脑) │ ws   │  <服务器IP>:9600  │  ws  │ (云电脑*N) │
└────────────┘      └──────────────────┘      └────────────┘
```

- **server/**：部署在公网服务器，WebSocket 中继。维护 client 在线列表，把 controller 的指令路由给目标 client，把 client 的响应广播回 controller。不落任何数据。
- **client/**：部署在每台云电脑。主动连接 server（出站连接，无需公网 IP），接收指令：执行 shell 命令（stdout/stderr 流式回传）、读写文件。断线自动重连。
- **controller/**：本地运行的交互式终端，下发指令、实时查看输出。

三端通过 token 认证（**分角色、每台 client 独立 token**），消息为 JSON，详见各端 `src/protocol.ts`（三份相同拷贝）。

## 认证模型

- **controller** → 使用服务端 `.env` 里的 `CONTROLLER_TOKEN`
- **client** → 每台机器一个专属 token，登记在服务端 `clients.json`（`{ "clientId": "token" }`），注册时 ID+token 必须匹配
- `clients.json` 每次注册时实时重读，**新增/删除云电脑只需改文件，无需重启服务**
- 泄露影响面：controller token 泄露 = 可下发命令；单台 client token 泄露 = 只影响那一台（无法控制其他机器）

## 配置

所有配置通过环境变量或各目录下的 `.env` 文件提供（复制 `.env.example` 为 `.env` 后填写；`.env` 与 `clients.json` 已被 gitignore，不会提交）。

| 变量 | 用于 | 说明 | 默认 |
|------|------|------|------|
| `CONTROLLER_TOKEN` | server | controller 专用 token，生成：`openssl rand -hex 16` | 无，必填 |
| `PORT` | server | 监听端口（云服务器安全组需放行） | 9600 |
| `CLIENTS_FILE` | server | client 白名单文件路径 | `<项目根>/clients.json` |
| `LINK_SERVER` | client / controller | server 的 ws 地址 | `ws://127.0.0.1:9600` |
| `LINK_TOKEN` | client | 本机专属 token（服务端 clients.json 分配） | 无，必填 |
| `LINK_TOKEN` | controller | 即服务端的 `CONTROLLER_TOKEN` | 无，必填 |
| `LINK_CLIENT_ID` | client | 本机唯一标识（clients.json 的 key） | 主机名 |

也支持命令行参数：`--server ws://... --token xxx --id xxx`。

## 快速开始

### 本地开发（三端都在本机）

```bash
cd server && cp .env.example .env     # 填 TOKEN
npm install && npm run dev            # 终端1

cd client && cp .env.example .env     # 填 LINK_TOKEN
npm install && npm run dev            # 终端2

cd controller && cp .env.example .env # 填 LINK_TOKEN
npm install && npm run dev            # 终端3
```

### 线上部署

```bash
# 1. 公网服务器：本地编译后同步（rsync 排除 .env / clients.json，服务器上单独配置）
cd server && npm install && npm run build
rsync -az --delete server/dist server/package.json server/package-lock.json <服务器>:/opt/link-server/
scp server/.env server/clients.json <服务器>:/opt/link-server/
ssh <服务器> 'cd /opt/link-server && npm install --omit=dev && nohup node dist/index.js > server.log 2>&1 &'
# 安全组放行入方向 TCP 9600

# 2. 云电脑：拷贝 client 目录
cd client && npm install && npm run build
# 先在服务端 clients.json 登记："云电脑名字": "专属token"
LINK_SERVER=ws://<服务器IP>:9600 LINK_CLIENT_ID=<云电脑名字> \
  LINK_TOKEN=<该机器专属token> node dist/index.js

# 3. 本地
cd controller && npm run dev          # .env 里 LINK_TOKEN = 服务端 CONTROLLER_TOKEN
```

## controller 使用

```
/list                查看在线客户端（* 标记当前目标）
/use <id>            选择要控制的客户端（仅一台在线时自动选择；提示符显示当前目标）
/read <路径>          读取远程文件
/write <路径> <内容>   写入远程文件（自动创建目录）
/exit                退出
其他任意输入          作为 shell 命令在客户端执行，stdout 正常显示、stderr 红色、非零退出码提示
```

## 运维备忘

- **更新 server 代码**：本地 `server/` 下 `npm run build`，rsync 同步 `dist/` + `package.json` 后重启进程。
- **安全**：分角色 token + 每台 client 独立 token（白名单实时重读）；当前传输为明文 ws，如需公网加密可前置 nginx TLS 或改 wss。
- **本地代理环境注意**：若本机开启 TUN 模式代理，需将服务器 IP 加入直连规则，否则 WebSocket 连接会被代理干扰。
