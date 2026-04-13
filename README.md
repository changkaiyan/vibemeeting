# 智能会议（Django + LiveKit）

基于 Django + DRF 的在线会议系统，支持会议管理、权限控制、聊天与 LiveKit 入会能力。

## 代码与产物目录

- `conference/`
  - 后端核心业务代码
- `docs/`
  - 设计与架构文档
- `smart_meeting/`
  - Django 项目配置与入口
- `app/templates/`
  - Django 模板
- `app/static/`
  - 手写静态资源
- `flutter_app/`
  - Flutter Web 前端源码
- `artifacts/flutter_app_web/`
  - Flutter Web 构建产物，供 Django 作为静态文件挂载
  - 不应手工编辑，应由 Flutter Web 构建结果同步过来
- `tools/`
  - 本地运行依赖和第三方工具，不纳入源码提交流程

## 页面入口

- 首页：`/`
- 登录：`/accounts/login`
- 注册：`/accounts/register`
- 科技云 OAuth 发起：`/auth/techcloud/login`
- 科技云 OAuth 回调：`/callback`
- 会议控制台：`/dashboard`
- Django 管理后台：`/admin`

## 文档索引

文档入口：

- [文档总览](./docs/README.md)

开发与联调：

- [本地开发指南](./docs/run/development.md)
- [HTTPS 启动](./docs/run/https-testing.md)
- [部署说明](./docs/run/deployment.md)
- [Git 工作流](./docs/run/git-workflow.md)

架构与方案：

- [AI 双工作流总览](./docs/design/ai-workflows-overview.md)
- [工作区近实时 STT 设计](./docs/design/near-realtime-stt-design.md)
- [流式 STT worker 设计](./docs/design/streaming-stt-worker-design.md)
- [火山云端 STT 设计](./docs/design/volcengine-cloud-stt-design.md)
- [会议工作区与实时语音助手边界](./docs/design/meeting-workspace-boundaries.md)
- [会议上下文驱动 AI 架构方案](./docs/design/meeting-context-agent-architecture.md)
- [会议上下文 MVP 实施计划](./docs/design/meeting-context-mvp-implementation-plan.md)
- [虚拟 Agent 参会设计方案](./docs/design/virtual-agent-meeting-design.md)
- [虚拟 Agent 参会当前实现状态](./docs/status/virtual-agent-meeting-current-status.md)

运行组件：

- [LiveKit SSL 启动](./docs/run/livekit-ssl-startup.md)
- [LiveKit Egress 配置](./docs/run/livekit-egress-setup.md)
- [STT Worker 说明](./docs/run/stt-worker.md)
- [Flutter App 说明](./docs/run/flutter-app.md)
- [构建产物说明](./docs/run/artifacts.md)

历史参考：

- [Kaiyan / Zhaoyilun 集成方案](./docs/history/kaiyan-zhaoyilun-integration-plan.md)
- [火山实时语音测试](./docs/history/volcengine-realtime-voice-testing.md)

## 功能概览

- 用户注册/登录（Django 认证体系）
- 登录失败风控（失败次数锁定）
- 会议创建、加入、编辑、删除
- 角色模型（主持人 / 联席主持人 / 参会者）
- 成员管理（邀请、改角色、移除、静音）
- 会议聊天消息
- 审计日志
- 组织维度隔离
- LiveKit 房间与参会 Token 签发
- 超级管理员可配置登录策略（科技云 OAuth、本地注册、本地用户名密码登录）
- 超级管理员可导出用户信息与用量报表（CSV）

## 本地开发快速启动（uv）

推荐使用 `uv` 管理本地 Python 环境，当前已验证可用的 Python 版本为 `3.10.19`。

```bash
uv venv --python 3.10.19 .venv
uv pip install --python .venv/bin/python -r requirements.txt
uv pip install --python .venv/bin/python -r services/stt_worker/requirements.txt
cp .env.example .env
uv run --python .venv/bin/python manage.py migrate
uv run --python .venv/bin/python -m uvicorn smart_meeting.asgi:application --host 127.0.0.1 --port 8000
```

启动后访问 `http://127.0.0.1:8000`，或检查 `http://127.0.0.1:8000/healthz`。

完整的本地开发部署说明见 [docs/run/development.md](./docs/run/development.md)。

如果你要从同一内网的另一台机器访问，尤其要测试：

- 浏览器麦克风权限
- Flutter 会议页里的实时字幕
- LiveKit 实时音视频

请优先使用 `HTTPS + WSS` 拓扑，而不是 `http://内网IP:8000`。原因是多数浏览器不会把 `http://内网IP` 视为安全上下文，麦克风与部分 WebSocket 能力会被拦截。

如果需要刷新 Flutter Web 静态产物：

```bash
cd flutter_app
flutter pub get
flutter build web
```

然后将 `flutter_app/build/web/` 的内容同步到 `artifacts/flutter_app_web/`。

## 环境变量

以 `.env.example` 为模板创建 `.env`：

```bash
cp .env.example .env
```

关键配置：

- `SECRET_KEY`：Django 密钥
- `DEBUG`：开发建议 `1`，生产设为 `0`
- `ALLOWED_HOSTS`：允许访问域名/IP 列表
- `DATABASE_URL`：数据库连接（默认 SQLite）
- `LIVEKIT_URL`：服务端连接 LiveKit 的地址
- `LIVEKIT_PUBLIC_URL`：前端可访问的 LiveKit 地址（HTTPS 页面需 `wss://`）
- `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET`：LiveKit 服务端鉴权
- `LIVEKIT_MEET_URL`：打开 LiveKit Meet 的地址（默认官方托管）
- `MEETING_STT_PROVIDER`：上传音频转写模式；当前本地默认对齐 `faster_whisper`
- `MEETING_REALTIME_STT_WORKER_URL`：主应用连接实时 STT worker 的 WebSocket 地址
- `STT_WORKER_PROVIDER`：独立 STT worker 的 provider，当前支持 `faster_whisper` 与 `volcengine_realtime`
- `STT_WORKER_VOLCENGINE_APP_ID`：火山流式语音识别大模型 appid
- `STT_WORKER_VOLCENGINE_ACCESS_TOKEN`：火山流式语音识别大模型 access token
- `STT_WORKER_VOLCENGINE_RESOURCE_ID`：火山资源 ID，当前默认 `volc.bigasr.sauc.duration`
- `STT_WORKER_VOLCENGINE_WS_URL`：火山 WebSocket 地址，当前默认 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`
- `MEETING_AGENT_BRIDGE_MODE`：Agent bridge 模式；当前本地默认对齐 `http`
- `MEETING_AGENT_BRIDGE_URL`：HTTP 模式下的 Agent bridge 地址
- `TECHCLOUD_OAUTH_CLIENT_ID`：中国科技云通行证应用 `client_id`
- `TECHCLOUD_OAUTH_CLIENT_SECRET`：中国科技云通行证应用 `client_secret`
- `TECHCLOUD_OAUTH_REDIRECT_URI`：OAuth 回调地址（建议与应用平台登记一致）
- `TECHCLOUD_OAUTH_AUTHORIZE_URL`：授权地址（默认 `https://passport.escience.cn/oauth2/authorize`）
- `TECHCLOUD_OAUTH_TOKEN_URL`：换取 Token 地址（默认 `https://passport.escience.cn/oauth2/token`）
- `TECHCLOUD_OAUTH_THEME`：登录页风格（默认 `full`，可选 `simple` / `embed`）
- `TECHCLOUD_OAUTH_SCOPE`：可选，按通行证平台要求填写
- `TECHCLOUD_OAUTH_LOGOUT_URL`：通行证退出地址（默认 `https://passport.escience.cn/logout`）
- `TECHCLOUD_OAUTH_LOGOUT_REDIRECT_PARAM`：退出回跳参数名（默认 `WebServerURL`）

说明：

- `.env` 已被 `.gitignore` 忽略，不应提交到仓库。
- 仅提交 `.env.example` 作为变量模板。

## 科技云 OAuth 登录说明

项目已支持中国科技云通行证 OAuth 2.0 授权码模式：

1. 用户在 `/accounts/login` 点击“使用中国科技云通行证登录”。
2. 系统跳转到 `https://passport.escience.cn/oauth2/authorize`。
3. 通行证登录成功后回调到应用 `TECHCLOUD_OAUTH_REDIRECT_URI`（例如 `https://meeting.chipgpt.chat/callback`）。
4. 后端使用 `code` 调用 `https://passport.escience.cn/oauth2/token` 换取 token 与 `userInfo`。
5. 系统自动创建或更新本地用户并完成登录。

注意事项：

- `TECHCLOUD_OAUTH_REDIRECT_URI` 必须与通行证应用管理后台登记值完全一致，否则会出现 `redirect_uri_mismatch`。
- 生产环境请务必配置 `TECHCLOUD_OAUTH_CLIENT_ID` 与 `TECHCLOUD_OAUTH_CLIENT_SECRET`，未配置时登录页不会显示科技云登录按钮。

## 超级管理员登录策略与导出

- 超级管理员可在计费管理界面（`/billing`）配置：
  - 是否允许科技云 OAuth 登录
  - 是否允许本地注册（`/accounts/register`、`/api/auth/register`）
  - 是否允许本地用户名密码登录（`/accounts/login`、`/api/auth/login`）
- 超级管理员可在计费管理界面导出用户信息 CSV（包含邮箱、套餐、用量和限制信息）。

## 主要 API

- `POST /api/auth/register`
- `POST /api/auth/login`
- `GET|PATCH /api/system/auth-options`
- `GET|POST /api/meetings`
- `GET|PATCH|DELETE /api/meetings/{meeting_id}`
- `POST /api/meetings/join`
- `POST /api/meetings/{meeting_id}/join-token`
- `GET|POST /api/meetings/{meeting_id}/members`
- `PATCH /api/meetings/{meeting_id}/members/{target_user_id}/role`
- `PATCH /api/meetings/{meeting_id}/members/{target_user_id}/mute`
- `DELETE /api/meetings/{meeting_id}/members/{target_user_id}`
- `GET|POST /api/meetings/{meeting_id}/messages`
- `GET /api/orgs/my`
- `GET|POST /api/orgs/{org_id}/members`
- `GET /api/audit/logs`
- `GET /api/billing/users/export`
