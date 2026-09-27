# Link Projects —— 云电脑远程控制系统

多台云电脑（无公网 IP）+ 一台公网服务器中继 + 本地控制台，实现对云电脑的远程命令执行（实时输出）和文件读写。

## 架构

```
┌────────────┐      ┌──────────────────┐      ┌────────────┐
│ controller │◄────►│  server (公网)    │◄────►│   client   │
│  (本地电脑) │ ws   │  <服务器IP>:9600  │  ws  │ (云电脑*N) │
└────────────┘      └──────────────────┘      └────────────┘
```

- **server/**：部署在公网服务器，WebSocket 中继。维护 client 在线列表，把 controller 的指令路由给目标 client，把 client 的响应广播回 controller；另支持 controller 直接管理 client 白名单（`clients.json`，原子写回）。
- **client/**：部署在每台云电脑。主动连接 server（出站连接，无需公网 IP），接收指令：执行 shell 命令（stdout/stderr 流式回传）、读写文件。断线自动重连。
- **controller/**：本地运行的交互式终端，下发指令、实时查看输出。

三端通过 token 认证（**分角色、每台 client 独立 token**），消息为 JSON，详见各端 `src/protocol.ts`（三份相同拷贝）。

## 认证模型

- **controller** → 使用服务端 `.env` 里的 `CONTROLLER_TOKEN`
- **client** → 每台机器一个专属 token，登记在服务端 `clients.json`（`{ "clientId": "token" }`），注册时 ID+token 必须匹配
- `clients.json` 每次注册时实时重读，**新增/删除云电脑只需改文件，无需重启服务**；也可用 mac 控制端的「客户端管理」直接增删改（见下），无需登录服务器
- 泄露影响面：controller token 泄露 = 可下发命令 + 可改白名单；单台 client token 泄露 = 只影响那一台（无法控制其他机器）

## 配置

所有配置通过环境变量或各目录下的 `.env` 文件提供（复制 `.env.example` 为 `.env` 后填写；`.env` 与 `clients.json` 已被 gitignore，不会提交）。

**controller 通用配置**：推荐把 `LINK_SERVER` / `LINK_TOKEN` 写到 `~/.link-projects/controller.env`，Node 版每次启动读取（优先级：环境变量 > 项目 `.env` > 全局文件）；mac 版已改为应用内管理多个服务端，首次启动时自动把该文件（或环境变量/旧 UserDefaults）里的单服务端配置迁移为列表第一项，之后不再依赖它。

| 变量 | 用于 | 说明 | 默认 |
|------|------|------|------|
| `CONTROLLER_TOKEN` | server | controller 专用 token，生成：`openssl rand -hex 16` | 无，必填 |
| `PORT` | server | ws:// 明文监听端口（云服务器安全组需放行） | 9600 |
| `CLIENTS_FILE` | server | client 白名单文件路径 | `<项目根>/clients.json` |
| `ALLOW_SERVER_FILES` | server | 是否允许 controller 浏览服务器本机文件（`@server` 目标），设 `0` 禁用 | `1`（允许） |
| `ALLOW_SERVER_EXEC` | server | 是否允许 controller 在服务器本机执行命令（`@server` 目标），设 `0` 禁用 | `1`（允许） |
| `PUBLIC_DIR` | server | 免鉴权 public 目录，配置后 `PORT` 端口同时提供 http 文件服务（浏览器访问 `http://<IP>:<PORT>/` 即可浏览下载，无鉴权；支持 `~` 与相对路径，目录自动创建） | 无（不启用） |
| `TLS_PORT` | server | wss:// 加密监听端口，配置 `TLS_CERT`+`TLS_KEY` 后启用，与 ws 并存（安全组需放行） | 9601 |
| `TLS_CERT` | server | TLS 证书路径（含完整链），与 `TLS_KEY` 同时配置才生效 | 无 |
| `TLS_KEY` | server | TLS 私钥路径 | 无 |
| `LINK_SERVER` | client / controller | server 的 ws/wss 地址 | `ws://127.0.0.1:9600` |
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
# 1. 公网服务器：从 GitHub 拉取代码部署，systemd 托管（.env / clients.json 只存在于服务器，不进 git）
ssh <服务器> 'git clone https://github.com/cjhgit/link-projects.git /root/projects/link-projects'
ssh <服务器> 'cd /root/projects/link-projects/server && npm install && npm run build'
# 配置 server/.env（CONTROLLER_TOKEN，可选 PORT）与 clients.json（也可之后用 mac 控制端直接管理）
cat > /etc/systemd/system/link-server.service <<EOF
[Unit]
Description=link-projects server (WebSocket relay)
After=network-online.target

[Service]
WorkingDirectory=/root/projects/link-projects/server
ExecStart=<node 绝对路径> dist/index.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now link-server
# 安全组放行入方向 TCP 9600

# 2. 云电脑：克隆仓库后只需 client 目录
git clone https://github.com/cjhgit/link-projects.git && cd link-projects/client
npm install && npm run build
# 先在服务端登记客户端：mac 控制端点 + 添加（或直接改服务端 clients.json）
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

- 支持同时管理多个服务端：左侧服务器列表（+ 添加，右键/`…` 连接、断开、编辑、删除，状态点绿=已连接、黄=连接中），每个服务端一条独立连接，启动时自动连接所有已配置 token 的服务端
- **客户端列表 = 白名单全体**：中间列显示当前选中服务端的全部登记客户端（在线只是状态：绿点=在线、灰点=离线，点击即设为目标、等价 `/use`），右侧终端输出/输入随之切换，各服务端的目标选择独立记忆；未连接时保留显示上次同步的白名单
- **客户端管理就地完成**，无需登录服务器：标题栏 `+` 登记新客户端（token 支持随机生成），右键行可编辑、删除（在线连接立即断开，之后无法再注册）、拷贝 ID / Token / 接入配置（.env 三行）；变更经 server 原子写回 `clients.json` 并广播给所有控制端，多端列表自动同步
- **可直接操作服务器本机**：客户端列表固定首行「服务器主机」（`@server` 保留目标，`~` 为 server 家目录），选中后终端即可在 server 上执行命令（实时输出），「文件」页签可浏览/查看/编辑/新建/删除 server 上的文件（如直接改 `clients.json`、看日志）；命令与文件浏览分别由 server 的 `ALLOW_SERVER_EXEC` / `ALLOW_SERVER_FILES` 控制
- 服务端列表存于 UserDefaults；首次启动自动从旧的单服务端配置（`~/.link-projects/controller.env` / 环境变量 / 旧 UserDefaults）迁移
- 交互命令与上面一致（另含 `/clear` 清屏，无 `/exit`）
- **Agent 页签**与「终端 / 文件」并列：仅针对在线云电脑，调用该机已安装并登录的 `claude`（Claude Code CLI）。可新建会话、选取历史会话继续对话，并通过刷新查看「执行中 / 已完成 / 失败」及最终输出；不依赖实时流式传输。
- Agent 的会话清单、对话记录和状态只保存到云电脑 `~/.link-projects/claude-sessions.json`，中继 server 与控制端不保存；控制端网络中断后重新连接、选择同一云电脑并刷新即可恢复查看。若云电脑 client 自身重启，之前显示为执行中的任务会标为状态未知，避免误报仍在运行。
- 命令行运行：`./run.sh`（杀掉旧进程 → xcodebuild 构建 → 后台启动，日志 `/tmp/controller-mac.log`）
- 自动剥除 ANSI 颜色码，stderr 红色显示，输出超过 5000 行自动截断

## link-ios（iOS 手机版）

`link-ios/` 是功能等价的 iPhone/iPad 控制台（SwiftUI，Xcode 打开 `link-ios.xcodeproj`，连真机运行），方便在手机上随时操作云电脑：

- 功能与 controller-mac 一致：多服务端管理（连接/断开/编辑/删除，启动自动连接）、客户端白名单管理（增删改、token 随机生成、拷贝 ID/Token/接入配置）、终端（`/list` `/use` `/read` `/write` `/clear` `/help` + 任意 shell 命令，输出按客户端分流）、远程文件浏览（客户端与服务器本机 `@server`，目录导航/路径跳转/隐藏文件/新建/删除/查看编辑保存，二进制与超大文件只读）
- 服务端列表存于 UserDefaults（iPhone 沙盒内，不与 mac 版共享）
- 移动端适配：三栏改为「服务器 → 客户端 → 工作区」push 导航；右键菜单改为长按菜单 + 左滑操作；文件查看器为全屏模态，有未保存修改时禁止下滑关闭；键盘上方提供清屏/收起键盘工具条
- 工作区提供「Agent」页签，可创建/续聊云电脑本机的 Claude Code 会话，并手动刷新任务状态与结果
- 回到前台自动重连被系统断开的连接（锁屏/切后台后 ws 易被断开）；手动断开或注册被拒则不打扰
- 部署目标 iOS 26；`Info.plist` 已放开 ATS（自建 ws:// 明文直连；条件允许时建议服务端配 TLS 用 wss:// 接入）

## 运维备忘

- **更新 server 代码**：服务器上 `cd /root/projects/link-projects && git pull && cd server && npm install && npm run build && systemctl restart link-server`。部署改为从 GitHub 拉取（systemd 托管：开机自启、崩溃自动拉起）；客户端管理（白名单增删改）与服务器本机文件浏览（`@server`）需要 server 为新版，旧版 server 会把这些消息当普通转发而报「客户端不在线」。
- **更新 client 代码**：云电脑上 `npm run build && npm restart`。
- **安全**：分角色 token + 每台 client 独立 token（白名单实时重读）；server 只放行 client 的指令响应类消息（exec-output / exec-exit / file-content / done），client 无法伪造 `clients` / `whitelist` 等服务端消息；当前传输为明文 ws，如需公网加密可前置 nginx TLS 或改 wss。
- **public 文件服务**：server 配置 `PUBLIC_DIR` 后，`PORT` 端口在 ws 之外同时提供**免鉴权** http 文件服务（目录浏览 + 下载，配了 TLS 则 `TLS_PORT` 同样提供 https 版），任何人可读——只应放置可公开分享的文件；已做 `..` 路径穿越防护，服务范围严格限定在该目录内。
- **本地代理环境注意**：若本机开启 TUN 模式代理，需将服务器 IP 加入直连规则，否则 WebSocket 连接会被代理干扰。
