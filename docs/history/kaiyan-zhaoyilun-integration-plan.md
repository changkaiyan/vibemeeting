# Kaiyan 与 Zhaoyilun-Dev 功能整合方案

## 1. 目标

本方案的目标不是简单合并两个分支，而是在一个新的集成分支上同时保留以下能力：

1. 保留 `kaiyan` 分支上的实时语音 AI 能力，尤其是：
   - OpenAI / Volcengine 两套 realtime bot 配置字段拆分
   - 与 realtime 语音 AI 相关的 WebSocket consumer / routing / ASGI 接入
   - 实时语音链路上的 provider-specific 逻辑
2. 保留 `zhaoyilun-dev` 分支上的整体前端重构和增强能力，尤其是：
   - `flutter_app` 新结构
   - 主题系统与运行时主题切换
   - `meeting_room` 的模块拆分
   - 已新增的 Flutter 单测
3. 保留 `zhaoyilun-dev` 分支上的 STT / agent / workspace 能力，尤其是：
   - `conference/meeting_context/*`
   - `conference/speech_to_text/*`
   - `services/stt_worker/*`
   - `conference/meeting_agent_bridge/*`
   - `services/meeting_agent_bridge/*`

结论先行：

- 集成时必须以 `zhaoyilun-dev` 为底。
- `kaiyan` 不能整分支直接 merge 进来。
- 需要按“后端模型与 API -> 迁移 -> 前端配置面板 -> 前端实时音频链路”的顺序逐层整合。

## 2. 当前分支差异概览

### 2.1 `kaiyan` 分支的独特价值

`kaiyan` 的 feature 核心集中在 `8e8ee8f` 这一条功能提交，重点是：

1. Realtime bot 的 provider 配置拆分
   - `realtime_bot_openai_model`
   - `realtime_bot_openai_voice`
   - `realtime_bot_volc_model`
   - `realtime_bot_volc_voice`
   - `realtime_bot_volc_ws_url`
   - `realtime_bot_volc_app_id`
   - `realtime_bot_volc_app_key`
   - `realtime_bot_volc_access_key`
   - `realtime_bot_volc_resource_id`
   - `realtime_bot_volc_uid`
2. Realtime 语音 AI 的 WebSocket 入口与 consumer 接入
3. 旧版 Flutter 会议页中与 provider 切换、音频 ingress、debug 面板相关的前端逻辑增强

### 2.2 `zhaoyilun-dev` 分支的独特价值

`zhaoyilun-dev` 已经向更完整的平台化结构演进，核心价值包括：

1. Flutter 前端重构：
   - `flutter_dashboard` 重构为 `flutter_app`
   - `app / core / features / meeting_room` 分层
   - 主题系统与运行时 theme 切换
   - `meeting_room` 中菜单构建器、模型、逻辑、部件逐步拆分
2. 后端能力扩展：
   - `meeting_context`
   - `speech_to_text`
   - `meeting_agent_bridge`
   - `services/stt_worker`
3. 测试和文档补强：
   - Flutter 单测
   - 开发 / 部署文档

### 2.3 为什么不能直接 merge

直接 merge `kaiyan` 会引入三类高风险问题：

1. 前端结构回退风险
   - `kaiyan` 仍然基于 `flutter_dashboard/lib/meeting_room_page.dart`
   - 直接 merge 会把已经拆开的 `flutter_app` 结构重新搅乱
2. Django migration 编号冲突
   - 双方的 `0019 / 0020` 已经分叉
   - 直接 merge 很容易把迁移历史合坏
3. 生成物与源码混杂
   - `kaiyan` 包含构建产物与快照文件
   - 这些不应作为 feature 合并依据

## 3. 总体整合策略

## 3.1 基线选择

以 `origin/zhaoyilun-dev` 作为整合分支基线。

原因：

1. `zhaoyilun-dev` 已经拥有更先进的前端结构。
2. `zhaoyilun-dev` 已经拥有 STT worker / meeting context / agent bridge 等更大的功能集合。
3. `kaiyan` 的真正独特 feature 更适合被“摘取并吸收”，而不是整分支覆盖。

## 3.2 集成分支

使用专门的集成分支：

- `integration/kaiyan-voice`

所有整合工作都在该分支完成，不直接污染 `zhaoyilun-dev`。

## 3.3 整合原则

1. 保留 `zhaoyilun-dev` 的目录结构。
2. 吸收 `kaiyan` 的语音 AI feature，不回退到旧前端结构。
3. 优先人工映射和手工整合，不做粗暴 cherry-pick 整条旧分支。
4. 构建产物、快照文件、`.dart_tool`、`build/web` 不进入整合范围。

## 4. 后端整合方案

后端整合优先级最高，因为前端表单与音频链路都依赖后端字段和接口。

### 4.1 需要吸收的 `kaiyan` 后端能力

主要参考 `kaiyan` 的这些文件：

- `conference/models.py`
- `conference/views.py`
- `conference/serializers.py`
- `conference/consumers.py`
- `conference/routing.py`
- `smart_meeting/asgi.py`
- `smart_meeting/settings.py`

整合目标是把以下能力并入当前代码：

1. 拆分 provider-specific realtime bot 字段
2. provider-specific 配置校验逻辑
3. realtime audio ingress 相关 WebSocket / consumer 链路

### 4.2 模型层整合原则

在当前 `zhaoyilun-dev` 的 meeting 模型基础上，补入 `kaiyan` 中有价值的字段：

1. 保留已有兼容字段：
   - `realtime_bot_model`
   - `realtime_bot_voice`
2. 新增并切主用字段：
   - `realtime_bot_openai_model`
   - `realtime_bot_openai_voice`
   - `realtime_bot_volc_model`
   - `realtime_bot_volc_voice`
   - `realtime_bot_volc_ws_url`
   - `realtime_bot_volc_app_id`
   - `realtime_bot_volc_app_key`
   - `realtime_bot_volc_access_key`
   - `realtime_bot_volc_resource_id`
   - `realtime_bot_volc_uid`
3. 兼容策略：
   - 保留 legacy 字段作为 fallback
   - 所有读逻辑优先读 provider-specific 字段
   - 仅在 provider-specific 字段为空时回退到 legacy 字段

### 4.3 视图与序列化层整合原则

不要直接用 `kaiyan` 的 `conference/views.py` 覆盖当前文件，应将其拆成功能块并迁入现有架构：

1. Provider 归一化方法
2. OpenAI / Volcengine 各自的默认值与校验
3. PATCH AI 控制接口中的 provider-specific 更新逻辑
4. 测试接口中的 provider-specific payload 组装逻辑
5. 会议 realtime bot ready 判定逻辑

当前分支中与会议上下文、STT、agent bridge 相关的逻辑必须保留，不允许被旧逻辑覆盖。

### 4.4 WebSocket 与 ASGI 整合原则

`kaiyan` 的 consumer/routing 能力需要吸收，但必须纳入当前整体路由结构。

整合方法：

1. 将 `conference/consumers.py` 中与 realtime audio ingress 或 bot 相关的 consumer 提炼出来。
2. 将 `conference/routing.py` 的路由定义接入当前项目 ASGI 路由树。
3. 检查 `smart_meeting/asgi.py` 当前是否已支持 websocket 路由汇总。
4. 如有必要，将 websocket 路由逻辑放入：
   - `conference/routing.py`
   - 或新的 `conference/ws_routes.py`

目标是：

- `meeting_context`
- `speech_to_text`
- `realtime bot`

三类 websocket/实时能力能同时存在，而不是互相覆盖。

## 5. Migration 整合方案

这是整个整合过程中最敏感的一步。

### 5.1 问题

双方分支已经各自生成了不同的：

- `0019`
- `0020`

迁移文件。

### 5.2 原则

不要试图保留两边各自的分叉迁移链并继续往前追加。

应该采用：

1. 在整合分支完成最终模型收敛后
2. 重新生成新的 merge migration
3. 使数据库模式反映“最终模型状态”，而不是忠实保留两边分叉编号结构

### 5.3 实施建议

1. 先保留历史迁移文件不删
2. 完成 models.py 整合
3. 跑 `makemigrations`
4. 如 Django 自动生成冲突，手工整理出一个新的 merge migration
5. 确保迁移后的数据库字段同时支持：
   - `kaiyan` 的 realtime provider 拆分
   - `zhaoyilun-dev` 的 meeting context / artifact / agent session 能力

## 6. 前端整合方案

前端绝不能“整文件回退合并”，必须做能力映射。

## 6.1 前端整合的核心原则

保留：

- `flutter_app`
- 当前的模块化结构

不保留：

- `flutter_dashboard` 作为主前端入口
- `kaiyan` 的整块 `meeting_room_page.dart` 作为新主页面

要做的是：

- 从 `kaiyan` 的旧页面中提取 feature 逻辑
- 将其映射到当前 `flutter_app` 的模块化结构中

## 6.2 前端能力拆分方法

`kaiyan` 旧前端的价值可以拆成三类。

### A. 配置状态与字段映射

这类能力可以直接吸收到当前 `flutter_app` 的状态层：

1. provider 切换
   - `openai`
   - `volcengine`
2. OpenAI 专属字段
   - model
   - voice
   - base_url
3. Volc 专属字段
   - model
   - voice
   - ws_url
   - app_id
   - resource_id
   - uid
   - key_set 状态

实施位置建议：

- `flutter_app/lib/meeting_room/page.dart`
- 或继续抽到新的 `meeting_room/realtime_bot/` 子目录

### B. 配置面板表单逻辑

旧前端有一套完整的表单交互：

1. provider 条件渲染
2. 不同 provider 的字段展示与校验
3. 配置回填
4. test payload 组装

这套逻辑不能照搬旧 widget 树，但可以迁移成新模块：

建议新建：

- `flutter_app/lib/meeting_room/realtime_bot/realtime_bot_settings_panel.dart`
- `flutter_app/lib/meeting_room/realtime_bot/realtime_bot_form_state.dart`
- `flutter_app/lib/meeting_room/realtime_bot/realtime_bot_payloads.dart`

由当前 `meeting_room/page.dart` 负责装配，而不是把旧页面整块拼回来。

### C. 实时音频 ingress 与 debug 逻辑

这是 `kaiyan` 前端最有价值的 feature 部分之一。

旧页面里包含：

1. 麦克风 PCM 采集
2. VAD 阈值、preroll、speech start/end
3. websocket ingress 连接与 chunk 发送
4. timeout / ack / error / ws close 处理
5. debug panel
6. provider-specific 音频上传行为

这部分建议：

1. 保留当前 `meeting_room` 的拆分结构
2. 不把旧逻辑塞回单一 page 文件
3. 优先新建独立逻辑模块，例如：
   - `flutter_app/lib/meeting_room/logic/realtime_bot_logic.dart`
   - `flutter_app/lib/meeting_room/realtime_bot/realtime_bot_debug_panel.dart`

## 6.3 前端整合执行顺序

正确顺序是：

1. 先整后端字段与接口
2. 再整前端配置表单
3. 最后整实时音频 ingress 与 debug 面板

原因：

- 前端配置表单依赖后端真实字段
- ingress 逻辑依赖后端 websocket 与 payload 协议稳定

## 7. STT / Agent / Workspace 能力保留策略

这是 `zhaoyilun-dev` 的核心资产，必须明确保护。

必须保留的目录：

- `conference/meeting_context/*`
- `conference/speech_to_text/*`
- `conference/meeting_agent_bridge/*`
- `services/stt_worker/*`
- `services/meeting_agent_bridge/*`

整合原则：

1. `kaiyan` 的 realtime bot 增强只作为“新增能力层”
2. 不允许删除或回退上述目录
3. 如功能重叠，以当前模块化实现为主，吸收 `kaiyan` 的 provider-specific 补强逻辑

## 8. 分阶段实施计划

### 阶段 1：后端字段与 API 收敛

目标：

- 让当前后端同时支持 OpenAI / Volcengine 拆分配置

动作：

1. 合并 models 字段
2. 合并 serializers / views 校验与默认值
3. 保留 legacy fallback
4. 补充 Django tests

完成标志：

- meeting 配置接口可稳定读写 provider-specific 字段

### 阶段 2：WebSocket / consumer / ASGI 收敛

目标：

- 让 realtime audio ingress 链路接入当前项目

动作：

1. 吸收 `kaiyan` 中 consumer / routing 的实现
2. 接到当前 ASGI 路由
3. 确保不破坏已有 STT / workspace 路由

完成标志：

- websocket 路由可连接
- 本地日志能观察到 ingress 请求和响应

### 阶段 3：迁移收口

目标：

- 建立统一迁移链

动作：

1. 完成最终 models 收敛
2. 生成 merge migration
3. 跑迁移验证

完成标志：

- 干净数据库上可完整 migrate

### 阶段 4：前端配置面板整合

目标：

- 当前 `flutter_app` 可完整配置 OpenAI / Volcengine 两套实时语音 AI 参数

动作：

1. 新增 `realtime_bot` 子模块
2. 将旧表单能力迁入当前 UI 结构
3. 补 widget / unit tests

完成标志：

- 会议页里可切 provider 并正确展示不同字段

### 阶段 5：前端实时音频 ingress 细节整合

目标：

- 当前前端能通过 websocket 将语音发送给 AI，并接收回复

动作：

1. 接 ingress payload 协议
2. 合并 VAD / chunk / timeout / debug 面板
3. 补协议与状态机测试

完成标志：

- 实时语音 AI 链路端到端可工作

### 阶段 6：联调与回归

目标：

- 保证三条能力线同时存在：
  - realtime AI
  - STT worker
  - meeting context / agent bridge

动作：

1. Django tests
2. Flutter tests
3. `flutter build web`
4. 手工联调 checklist

完成标志：

- 功能可同时工作
- 主干无明显回归

## 9. 测试与验证策略

## 9.1 后端

必须增加或更新自动化测试：

1. 模型字段与默认值测试
2. serializers 输入输出测试
3. PATCH AI 控制接口测试
4. provider-specific 校验测试
5. websocket / consumer 基本协议测试

## 9.2 前端

必须增加或更新自动化测试：

1. provider 切换的 widget 测试
2. 配置表单字段显示/隐藏测试
3. payload 组装单测
4. debug 状态映射单测
5. `flutter build web`

## 9.3 集成验证

手工联调至少覆盖：

1. OpenAI provider 配置保存与测试
2. Volcengine provider 配置保存与测试
3. 会议中实时语音输入
4. AI 回复文本与音频回放
5. STT worker 仍然可用
6. meeting context / agent workspace 仍然可用

## 10. 风险与规避

### 风险 1：前端结构倒退

触发条件：

- 直接恢复 `flutter_dashboard` 为主前端

规避：

- 明确只保留 `flutter_app`
- 旧前端只做 feature 提取

### 风险 2：迁移链冲突

触发条件：

- 继续沿双方旧编号硬接下去

规避：

- 在集成分支上生成统一 merge migration

### 风险 3：实时链路覆盖 STT / workspace

触发条件：

- consumer / routing / asgi 直接覆盖现有配置

规避：

- 先梳理当前实时路由，再增量接入 `kaiyan` 的 websocket 能力

### 风险 4：旧前端逻辑整块搬迁导致 god file 回潮

触发条件：

- 把 `kaiyan` 的大页面片段直接粘进当前 `meeting_room/page.dart`

规避：

- 新建 `realtime_bot/` 子模块
- 保持 page 只做装配

## 11. 建议的首批实施任务

建议按如下顺序执行：

1. 对 `kaiyan@8e8ee8f` 生成文件级映射清单
2. 先整合后端 realtime bot provider-specific 字段
3. 再整合 websocket consumer / routing / asgi
4. 解决迁移冲突
5. 再把前端 AI 配置面板迁入 `flutter_app`
6. 最后整合前端实时音频 ingress 细节

## 12. 结论

这次整合的正确姿势不是“把两个分支 merge 在一起”，而是：

1. 以 `zhaoyilun-dev` 为平台基线
2. 抽取 `kaiyan` 中真正有价值的实时语音 AI feature
3. 将这些 feature 重建到当前模块化结构里

只有这样，才能同时保住：

1. `kaiyan` 的语音 AI 功能
2. `zhaoyilun-dev` 的前端重构成果
3. `zhaoyilun-dev` 的 STT / agent / workspace 能力

否则最终结果只会是：

- 旧前端回潮
- migration 冲突
- 实时链路和工作区链路互相踩踏

本方案的执行目标就是避免这三件事。
