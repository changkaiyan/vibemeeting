# Git 协作工作流（适用于 vibemeeting 小团队）

本文档定义 `vibemeeting` 仓库的日常 Git 协作规范，目标不是“消灭冲突”，而是把冲突控制在更早、更小、更容易处理的范围内。

适用范围：

- 3 到 5 人小团队
- 单仓协作
- Django 后端 + Flutter Web 前端 + STT worker + meeting agent bridge

## 1. 仓库特点与协作重点

当前仓库不是单一应用，而是多层协作的单仓：

- Django 主应用：`conference/`、`smart_meeting/`
- Django 模板与静态资源：`app/`
- Flutter Web 前端源码：`flutter_app/`
- STT worker：`services/stt_worker/`
- Agent bridge：`services/meeting_agent_bridge/`
- 数据库迁移：`conference/migrations/`

当前协作里最容易发生冲突的区域：

- `conference/models.py`
- `conference/serializers.py`
- `conference/views.py`
- `conference/migrations/`
- `smart_meeting/settings.py`
- `flutter_app/lib/meeting_room/`

当前仓库还有几个必须记住的事实：

- 真实会议页来自 Flutter Web，而不是传统 Django 模板页
- Django 当前挂载的是构建产物目录 `artifacts/flutter_app_web/`
- `artifacts/flutter_app_web/`、`flutter_app/build/`、`.env`、`smart_meeting.db` 已被忽略，不属于日常代码提交流程

因此，本仓库的 Git 工作流必须重点管住下面几类问题：

- Django model 与 migration 并行修改
- Flutter 源码与构建产物混提
- 后端、worker、bridge 的协议字段不一致
- 长分支导致的跨层逻辑冲突

## 2. 分支策略

只保留一个长期分支：

- `main`：唯一长期分支，始终保持可运行、可迁移、可联调

所有开发都从 `main` 拉短命分支，命名按改动面区分：

- `feat/backend-*`
- `feat/flutter-*`
- `feat/stt-*`
- `feat/bridge-*`
- `fix/backend-*`
- `fix/flutter-*`
- `fix/stt-*`
- `chore/devx-*`
- `docs/*`

示例：

- `feat/backend-billing-export`
- `feat/flutter-meeting-toolbar`
- `fix/stt-reconnect`
- `chore/devx-local-startup`

规则：

- 禁止直接向 `main` push
- 一个分支只做一件事
- 一个分支尽量只覆盖一个改动面
- 分支尽量在 1 到 2 天内合并

不建议使用长期功能分支、多人共享功能分支或 Git Flow 式多长期环境分支。

## 3. 日常开发流程

### 3.1 开工前

每天开始开发前先同步 `main`：

```bash
git checkout main
git pull origin main
git checkout -b feat/backend-xxx
```

### 3.2 开发中

开发过程中至少每天同步一次主干：

```bash
git fetch origin
git rebase origin/main
```

如果团队不想用 `rebase`，也可以统一用：

```bash
git fetch origin
git merge origin/main
```

关键点不是一定要用哪一种，而是团队必须统一，不要混用。

### 3.3 开发完成后

改完就尽快开 PR，优先走 Draft PR，让其他人尽早知道你在碰哪里。

合并前要求：

- 必要检查通过
- 至少 1 人 review
- 如有 migration，必须验证迁移可执行
- 如涉及跨层协议，必须完成最小联调

## 4. PR 拆分原则

这个仓库最重要的实践是：按改动面拆 PR，而不是按“需求描述”硬塞成一个大 PR。

推荐的 PR 类型：

- 纯 Django 业务/API PR
- 纯 Flutter UI/交互 PR
- 纯 STT worker PR
- 纯 bridge PR
- 纯脚本/文档/配置 PR

优先这样拆：

1. 先铺底层兼容能力
2. 再改调用方或界面
3. 最后清理旧逻辑

例如一个“会议实时字幕协议升级”需求，建议拆成：

1. 后端兼容新旧字段的 PR
2. STT worker 输出新字段的 PR
3. Flutter 页面消费新字段的 PR
4. 删除旧字段支持的 PR

不要在一个 PR 里同时做下面这些事：

- 改 Django model
- 改 migration
- 改 Flutter 页面
- 改 WebSocket schema
- 顺手重构目录结构

这样的 PR 即使文本冲突不多，逻辑冲突也会很重。

## 5. Django 后端协作规则

适用目录：

- `conference/`
- `smart_meeting/`
- `app/`

规则：

- 改 `conference/models.py` 前，先在群里同步
- 改 `smart_meeting/settings.py` 时，只提交必要配置变更，不夹带业务修改
- 改接口时，同步确认 Flutter、worker、bridge 是否依赖该字段
- 对高频公共文件，尽量把改动限制在局部，不做无关格式化或大面积重排

建议：

- 视图、序列化、服务逻辑分层提交
- 重构和功能变更分 PR
- API 字段改名先做兼容，再移除旧字段

## 6. Migration 规则

`conference/migrations/` 是本仓库冲突最高发区域之一，必须单独管理。

强制规则：

- 只要改了 Django model，对应 PR 必须包含 migration
- migration 尽量在 PR 收尾时生成，避免反复冲突
- 已合并到 `main` 的历史 migration 不随意改写
- 如果两个分支各自产生了新 migration，后合并的人负责基于最新 `main` 重新整理
- 必要时新增 merge migration，但不要为了省事手工篡改依赖关系

建议合并前运行：

```bash
uv run --python .venv/bin/python manage.py makemigrations --check
uv run --python .venv/bin/python manage.py migrate
uv run --python .venv/bin/python manage.py check
```

如果 PR 改了 model 但没有 migration，默认不能合并。

如果 PR 含 migration，PR 标题建议显式标注：

- `[migration] add billing fields`
- `[migration] split realtime bot provider config`

## 7. Flutter Web 协作规则

适用目录：

- `flutter_app/`

本仓库里的 Flutter 开发有一个特殊点：

- 实际页面由 Flutter Web 构建产物提供
- Django 本地联调读取的是 `artifacts/flutter_app_web/`

但日常协作中，代码 review 以源码为准，而不是构建产物。

强制规则：

- 只提交 `flutter_app/` 源码和测试
- 不提交 `flutter_app/build/`
- 不提交 `artifacts/flutter_app_web/` 本地产物

建议：

- 修改 `flutter_app/lib/meeting_room/page.dart` 前，先确认是否有人正在改同一区域
- UI 调整尽量拆成 widget 级 PR，不要几个人同时改同一个大页面
- 组件结构调整和视觉样式调整尽量分开

建议检查：

```bash
cd flutter_app
flutter test
flutter build web
```

说明：

- `flutter build web` 主要用于验证构建是否正常
- 默认不把 build 输出提交到仓库

## 8. STT Worker 与 Agent Bridge 协作规则

适用目录：

- `services/stt_worker/`
- `services/meeting_agent_bridge/`
- `conference/speech_to_text/`
- `conference/meeting_agent_bridge/`

这部分最容易出现的不是文本冲突，而是协议冲突。

强制规则：

- 涉及 WebSocket 消息体、schema、URL、环境变量名的改动，PR 描述里必须写清楚
- 改协议时要写明是否向后兼容
- 不允许只改发送方不改接收方就直接合并，除非发送方已经做兼容输出

PR 描述中至少写清这几项：

- 哪个服务先发布
- 哪些字段变了
- 是否兼容旧字段
- 本地联调怎么验证

建议检查：

- Python tests
- 至少一次后端 + worker 的本地联调
- 如果影响会议主流程，补一次从进入会议到看到转录结果的人工验证

## 9. 生成文件与本地文件规则

以下内容不进入日常协作：

- `.env`
- `.env.*`
- `.venv/`
- `smart_meeting.db`
- `flutter_app/build/`
- `artifacts/flutter_app_web/`
- `staticfiles/`
- 各类日志、缓存与本机证书

规则：

- 不提交本地数据库
- 不提交本地环境变量
- 不提交 Flutter build 产物
- 不在功能 PR 里混入缓存、日志和 IDE 文件

如果某次发布流程确实需要携带构建产物，单独建立“发布 PR”或部署流程，不和功能开发 PR 混在一起。

## 10. 提交规范

不强制复杂的 commit convention，但提交信息必须可读。

推荐格式：

```text
feat: add meeting transcript source field
fix: handle empty livekit url in meeting join
refactor: split room session logic from page state
docs: add git workflow for small team
```

提交建议：

- 一个小功能点一个 commit
- 不把“顺手修复”和主改动混在同一个 commit
- 不提交纯格式化噪音，除非该 PR 就是格式化或重排

## 11. PR 模板建议

建议团队统一使用下面这版 PR 模板：

```md
## 背景
解决什么问题

## 改动范围
- Django / API
- Flutter Web
- STT worker
- Agent bridge
- Docs / Script

## 关键文件
列出主要目录或文件

## 数据库影响
- 无
- 有 migration
- 有数据兼容风险

## 协议/配置影响
- 无
- 有：列出 env、接口、WebSocket 字段变化

## 验证
- manage.py check
- migrate
- flutter test
- python test
- 本地联调路径
```

要求：

- PR 描述必须写验证方式
- 跨层 PR 必须写联调路径
- 含 migration 的 PR 必须写数据库影响

## 12. 合并策略

默认使用：

- `Squash and merge`

原因：

- 小团队更容易保持主干历史干净
- 一个 PR 对应一个合并提交，便于回滚
- 减少分支内零碎提交带来的历史噪音

如无特殊原因，不使用多人共享分支后反复 merge 的方式堆历史。

## 13. 最小检查清单

按改动面执行，不要求所有 PR 都跑全量检查。

后端 PR：

- `uv run --python .venv/bin/python manage.py check`
- `uv run --python .venv/bin/python manage.py migrate`
- 相关 Django tests

含 model 或 migration 的 PR：

- `uv run --python .venv/bin/python manage.py makemigrations --check`
- `uv run --python .venv/bin/python manage.py migrate`

Flutter PR：

- `cd flutter_app && flutter test`
- 必要时 `cd flutter_app && flutter build web`

STT worker / bridge PR：

- 相关 Python tests
- 至少一次本地联调

跨层 PR：

- Django 主应用启动成功
- 进入会议页成功
- 相关功能主路径至少手工走一遍

## 14. 冲突处理 SOP

发生冲突时，按下面顺序处理：

1. 先同步最新 `main`
2. 理解双方改动目的，不要只机械解决标记
3. 手动处理文本冲突
4. 重新跑最小检查
5. 如果涉及协议、migration 或公共页面，找相关同学快速复核
6. 确认逻辑无误后再推送

特别提醒：

- Git 只会提示文本冲突，不会提示逻辑冲突
- 这个仓库里最危险的是“看起来已经合并成功，但 Django、Flutter、worker 三边语义不一致”

## 15. 团队默认约定

如果只保留最核心的规则，团队默认执行下面 10 条：

1. `main` 是唯一长期分支，禁止直接 push。
2. 所有人从最新 `main` 拉短命分支开发。
3. 分支按改动面命名。
4. 一个 PR 只做一件事，尽量只碰一层。
5. 改 Django model 必须带 migration。
6. 含 migration 的 PR 优先合并，不长期挂起。
7. Flutter 只提源码和测试，不提 build 产物。
8. 改 STT 或 bridge 协议时，PR 描述必须写清字段变化和联调步骤。
9. 每天至少同步一次 `main`。
10. 默认使用 `Squash and merge`。

这套规则的目标不是增加流程负担，而是让这个多层单仓在小团队协作下保持稳定节奏。
