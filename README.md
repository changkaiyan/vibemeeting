# 智能会议（Django + LiveKit）

基于 Django + DRF 的在线会议系统，支持会议管理、权限控制、聊天与 LiveKit 入会能力。

## 代码与产物目录

- `conference/`
  - 后端核心业务代码
- `smart_meeting/`
  - Django 项目配置与入口
- `app/templates/`
  - Django 模板
- `app/static/`
  - 手写静态资源
- `flutter_dashboard/`
  - Flutter Dashboard 源码
- `artifacts/flutter_dashboard_web/`
  - Flutter Web 构建产物，供 Django 作为静态文件挂载
  - 不应手工编辑，使用 `./scripts/build_flutter_dashboard.sh` 生成
- `tools/`
  - 本地运行依赖和第三方工具，不纳入源码提交流程

## 页面入口

- 首页：`/`
- 登录：`/accounts/login`
- 注册：`/accounts/register`
- 会议控制台：`/dashboard`
- Django 管理后台：`/admin`

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

## 快速启动（Windows PowerShell）

```powershell
py -3.10 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver 0.0.0.0:8000
```

启动后访问 `http://127.0.0.1:8000`。

如果需要刷新 Flutter Dashboard 静态产物：

```bash
./scripts/build_flutter_dashboard.sh
```

## 环境变量

以 `.env.example` 为模板创建 `.env`：

```powershell
Copy-Item .env.example .env
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

说明：

- `.env` 已被 `.gitignore` 忽略，不应提交到仓库。
- 仅提交 `.env.example` 作为变量模板。

## HTTPS 本地联调

参考 [HTTPS_TESTING.md](./HTTPS_TESTING.md) 与 [LIVEKIT_SSL_STARTUP.md](./LIVEKIT_SSL_STARTUP.md)。

## 主要 API

- `POST /api/auth/register`
- `POST /api/auth/login`
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
