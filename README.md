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

**controller 通用配置**：推荐把 `LINK_SERVER` / `LINK_TOKEN` 写到 `~/.link-projects/controller.env`，Node 版与 mac 版共用一处，无需各项目单独配置（优先级：环境变量 > 项目 `.env` > 全局文件 > mac 版回落 UserDefaults）。

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

cd controller && npm install && npm run dev  # 终端3，token 读全局 ~/.link-projects/controller.env
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
# 配置写入 .env（或 ~/.link-projects/client.env）后：
npm start          # 后台运行（node dist/index.js 不带命令时等同 start）

# 3. 本地
cd controller && npm run dev          # .env 里 LINK_TOKEN = 服务端 CONTROLLER_TOKEN
```

## client 命令

client 默认**后台运行**（同机单实例），pid 记录在 `~/.link-projects/client.pid`，日志写入 `~/.link-projects/client.log`（带时间戳，status 可直接看最近日志）。

```
node dist/index.js [命令] [选项]     # 不带命令时默认 start

start     后台启动；已在运行则提示（不重复拉起）
stop      停止后台进程（先 SIGTERM 优雅退出，5s 未退则 SIGKILL；执行中的命令一并终止）
status    查看运行状态、当前配置与最近 10 行日志（npm 下需 npm run status）
restart   重启（修改配置后生效）
run       前台运行，调试排查用（Ctrl+C 退出）

选项：--server <ws://...> --id <clientId> --token <token>（透传给后台进程，也可用环境变量/.env 配置）
```

对应 npm 脚本：`npm start` / `npm stop` / `npm restart` / `npm run status`（`status` 与 npm 内置命令重名，需带 `run`）。开发调试：`npm run dev`（前台 tsx 直跑）；dev 模式的后台启停用 `npm run dev:start` / `npm run dev:stop`。

## controller 使用

```
/list                查看在线客户端（* 标记当前目标）
/use <id>            选择要控制的客户端（仅一台在线时自动选择；提示符显示当前目标）
/read <路径>          读取远程文件
/write <路径> <内容>   写入远程文件（自动创建目录）
/exit                退出
其他任意输入          作为 shell 命令在客户端执行，stdout 正常显示、stderr 红色、非零退出码提示
```

## controller-mac（macOS 图形版）

`controller-mac/` 是功能等价的 macOS 原生控制台（SwiftUI，Xcode 打开 `controller-mac.xcodeproj` 运行）：

- 左侧在线客户端列表（点击即切换目标，等价 `/use`），右侧终端输出 + 命令输入，交互命令与上面一致（另含 `/clear` 清屏，无 `/exit`）
- 配置默认读 `~/.link-projects/controller.env`（与 Node 版共用；文件存在时界面里改配置会写回该文件，不存在时存 UserDefaults），下次启动自动连接；也支持环境变量 `LINK_SERVER` / `LINK_TOKEN` 临时覆盖
- 命令行运行：`./run.sh`（杀掉旧进程 → xcodebuild 构建 → 后台启动，日志 `/tmp/controller-mac.log`）
- 自动剥除 ANSI 颜色码，stderr 红色显示，输出超过 5000 行自动截断

## 运维备忘

- **更新 server 代码**：本地 `server/` 下 `npm run build`，rsync 同步 `dist/` + `package.json` 后重启进程。
- **更新 client 代码**：云电脑上 `npm run build && npm restart`。
- **安全**：分角色 token + 每台 client 独立 token（白名单实时重读）；当前传输为明文 ws，如需公网加密可前置 nginx TLS 或改 wss。
- **本地代理环境注意**：若本机开启 TUN 模式代理，需将服务器 IP 加入直连规则，否则 WebSocket 连接会被代理干扰。
