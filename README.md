# 智能会议（Django 版）

项目后端已全量切换为 Django + DRF，并采用分离的认证页面流程：

- 首页：`/`
- 登录：`/accounts/login`
- 注册：`/accounts/register`
- 会议控制台：`/dashboard`
- Django Admin：`/admin`

## 核心能力

- 用户注册/登录（Django 原生认证）
- 登录失败风控（失败次数锁定）
- 会议创建、加入、编辑、删除
- 会议角色模型（主持人 / 联席主持人 / 参会者）
- 成员管理（加人、改角色、移除、静音）
- 会议文本聊天
- 审计日志
- 组织与多租户基础隔离
- LiveKit 房间创建与参会 Token

## 会议可编辑属性

- 标题、描述
- 开始时间、时长
- 会议密码
- 等候室开关
- 入会默认禁言
- 最大参会人数
- 允许录制
- 允许屏幕共享
- 允许聊天

## 快速启动

```powershell
py -3.10 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
python manage.py makemigrations
python manage.py migrate
python manage.py createsuperuser
python manage.py runserver 0.0.0.0:8000
```

HTTPS测试手册详见HTTPS_TESTING.md

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
