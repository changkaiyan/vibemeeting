# 会议上下文驱动 AI 架构方案

## 当前实现状态

截至当前 Git 主线代码，这个项目**已经落地**的只有一个很轻量的 `meeting_context` MVP，而不是完整的“语音入会 + 实时 STT + 本地 Agent 双向桥接”系统。

当前已存在的能力：

- 会议页里有一个 meeting workspace 面板
- 支持通过 API 手动写入 transcript chunk
- 支持基于 transcript 生成当前 context snapshot
- 支持为当前用户创建 `codex` / `claude` 两类 agent session
- 支持触发 `summarize` / `extract_todos` / `draft_api` 等 action
- 支持把 action 结果保存为 artifact
- 当前前端可以浏览 transcript / context / artifact，并把选中的 transcript 发送给 agent action API

当前**没有落地**的能力：

- 没有 Git 跟踪的 `conference/speech_to_text/` 实现
- 没有实时音频转写链路
- 没有真正把会议音频自动写入 transcript
- 没有 Git 跟踪的 `conference/speech_agent/` bridge 实现
- 没有真正连到本地 Codex / Claude Code 的稳定执行链路
- 没有“Agent 像真实参会者一样通过语音实时交流”的已实现能力

所以，这份文档下面的内容应理解为：**目标架构 / 后续演进方向**，不是当前已交付能力说明。

## 背景

当前主线会议页的 AI 交互如果继续沿用“输入框/聊天框 -> agent”的模式，本质上和在飞书里通过机器人对话区别不大：

- 上下文来源仍然是单条消息
- AI 只能看到用户显式输入的内容
- 会议过程中的发言、争议、结论、待办没有持续进入 AI 上下文
- 产品难以形成区别于 IM 机器人的独特价值

因此，新的方向不是“把聊天框换成语音框”，而是把会议本身变成 AI 的实时上下文源。

## 目标

把 AI 从“聊天对象”改成“会议协作层”。

MVP 目标：

1. 持续获取会议转写结果
2. 把转写结果组织成可引用的会议上下文
3. 基于上下文片段调用本地 Codex / Claude
4. 自动沉淀会议摘要、决策和待办

非目标：

- 不做完整 IM 替代品
- 不做会外私聊入口替代
- 不把“录音发给 agent”作为主交互

## 产品定位

### 飞书 / cc-connect 适合的场景

- 会外异步提问
- 单人和 agent 私聊
- 临时问一句、要一个简短回复

### VibeMeeting 适合的场景

- 会议进行中多人共享上下文
- 对某一段讨论做总结、分析、转化
- 生成决策记录和待办
- 让 Codex/Claude 基于会议实时内容协同工作

一句话区分：

- 飞书机器人：`我和 AI 对话`
- VibeMeeting：`AI 参与这场会`

## 核心设计原则

1. 上下文优先于输入框
2. 片段引用优先于自由聊天
3. 结构化产出优先于长对话历史
4. 本地 agent bridge 复用，但 prompt 来源改为会议上下文包
5. 语音是会议数据源，不是主交互入口

## 目标总体架构

```text
LiveKit 音视频
   |
   v
Transcript Ingestion
   |
   v
Meeting Context Engine
   |                \
   |                 \-> Summary / Decision / Todo materializer
   v
Agent Orchestrator
   |          \
   |           \-> Claude bridge
   \-> Codex bridge
                |
                v
Meeting UI (timeline / actions / outputs)
```

## 目标模块拆分

建议后续新增独立模块，避免和当前轻量 workspace 逻辑耦合：

- `conference/meeting_context/`
  - 会议上下文核心模块
- `conference/meeting_context/models.py`
  - 转写片段、上下文快照、输出产物
- `conference/meeting_context/services/ingest.py`
  - 接收转写片段
- `conference/meeting_context/services/context.py`
  - 构建滚动上下文窗口
- `conference/meeting_context/services/materialize.py`
  - 生成 summary / decisions / todos
- `conference/meeting_context/services/orchestrator.py`
  - 统一调 Codex / Claude
- `conference/meeting_context/serializers.py`
  - API 出入参
- `conference/meeting_context/views.py`
  - REST 接口

已有模块的复用方式：

- `conference/speech_to_text/`
  - 目标模块，负责音频 -> 文本
  - 当前 Git 代码中并不存在有效实现
- `conference/speech_agent/services/bridge.py`
  - 目标模块，负责调用本地 agent
  - 当前 Git 代码中并不存在有效实现
- `app/templates/meeting_room.html`
  - 当前已经承载轻量 workspace UI
- `app/static/meeting-room.js`
  - 当前已经有 transcript + actions + outputs 驱动的基础版

## 数据模型

### 1. MeetingTranscriptChunk

表示会议时间线中的最小转写片段。

建议字段：

- `meeting`
- `speaker_identity`
- `speaker_name`
- `source`
  - `live_stream`
  - `manual_upload`
  - `mock`
- `text`
- `start_ms`
- `end_ms`
- `is_final`
- `confidence`
- `sequence_no`
- `created_at`

用途：

- 作为会议时间线展示源
- 作为上下文引用对象
- 作为 agent prompt 的原始材料

### 2. MeetingContextSnapshot

表示某个时间点的滚动上下文视图。

建议字段：

- `meeting`
- `window_start_ms`
- `window_end_ms`
- `topic_label`
- `summary_text`
- `open_questions_json`
- `decisions_json`
- `todos_json`
- `source_chunk_ids_json`
- `version`
- `created_at`

用途：

- 给 UI 展示“当前讨论主题”
- 给 agent 提供压缩后的上下文

### 3. MeetingAgentTask

表示一次基于会议上下文的 AI 任务。

建议字段：

- `meeting`
- `agent_type`
  - `codex`
  - `claude`
- `task_type`
  - `summarize`
  - `risk_analysis`
  - `implementation_plan`
  - `todo_extract`
  - `decision_refine`
- `trigger_mode`
  - `manual`
  - `auto`
- `context_snapshot`
- `selected_chunk_ids_json`
- `prompt_body`
- `response_body`
- `status`
- `latency_ms`
- `created_by`
- `created_at`

用途：

- 保留会议内 AI 行为审计
- 为后续效果评估提供数据

### 4. MeetingArtifact

表示会议沉淀产物。

建议字段：

- `meeting`
- `artifact_type`
  - `summary`
  - `decision_log`
  - `todo_list`
  - `code_task`
- `content`
- `source_snapshot`
- `created_by_agent_type`
- `version`
- `created_at`
- `updated_at`

## 增量处理链路

### 第一步：转写片段入库

转写服务输出新的文本片段后：

1. 写入 `MeetingTranscriptChunk`
2. 生成可供 UI 订阅/轮询的数据
3. 标记该会议的上下文缓存失效

要求：

- 支持 partial/final
- 只以 final chunk 进入稳定上下文
- partial 仅用于 UI 实时展示

### 第二步：构建滚动上下文窗口

上下文引擎以最近 N 分钟或最近 N 个 final chunks 为窗口。

建议 MVP 窗口：

- 时间窗口：最近 5 分钟
- 数量兜底：最近 30 个 final chunks

输出：

- 当前主题
- 3 到 5 行摘要
- 当前未解决问题
- 候选决策点
- 候选待办

这是会议页右侧“当前上下文”区域的核心数据源。

### 第三步：结构化产物物化

两种触发方式：

- 自动触发
  - 每隔 2 到 3 分钟
  - 或累计新增 5 个 final chunks
- 手动触发
  - 用户点击“更新摘要”“提取待办”

输出写入 `MeetingArtifact`。

### 第四步：agent 调用

agent 不再直接接收“用户自由输入”，而接收：

- 用户选中的 transcript 片段
- 当前 `MeetingContextSnapshot`
- 用户选择的任务类型

调用输入示例：

```json
{
  "agent_type": "codex",
  "task_type": "implementation_plan",
  "meeting_id": 123,
  "selected_chunk_ids": [101, 102, 108],
  "context": {
    "topic_label": "OAuth 登录重构",
    "summary_text": "团队确认需要保留本地登录，新增统一鉴权层。",
    "decisions": [
      "先不拆用户模型",
      "优先保持 API 向后兼容"
    ],
    "open_questions": [
      "session 刷新策略",
      "多端登录冲突处理"
    ]
  }
}
```

## Agent 编排策略

### Claude 的角色

适合：

- 会议内容总结
- 风险分析
- 分歧解释
- 待办提取
- 决策归纳

### Codex 的角色

适合：

- 实现方案拆分
- 模块/API 草案
- 代码任务清单
- 重构步骤建议

### 调用原则

1. Claude 偏“理解和整理”
2. Codex 偏“实现和落地”
3. 两者都通过统一 orchestrator 调用
4. 不让前端直接拼 prompt

## UI 改造

当前会议页是“视频 + 参与者 + 状态 + 聊天框”。

建议改为以下结构。

### 左侧：Transcript Timeline

- 实时转写时间线
- 按 speaker / 时间分组
- 每段都有快捷动作：
  - `引用`
  - `问 Claude`
  - `交给 Codex`
  - `加入摘要`

### 中间：Current Context

- 当前讨论主题
- 最近 3 到 5 行摘要
- 当前 open questions
- 当前 decisions

### 右侧：Actions + Outputs

上半区是动作面板：

- `总结刚才 5 分钟`
- `提取待办`
- `请 Claude 分析风险`
- `请 Codex 生成实现草案`

下半区是输出面板：

- `Summary`
- `Decision Log`
- `Todos`
- `Code Tasks`

### 聊天框处理建议

MVP 不建议保留普通聊天框作为主交互。

选项：

- 直接移除普通 `Chat`
- 或降级为成员文字沟通辅助，不再承载 AI 主入口

结论：

AI 主入口不再是输入框，而是“对会议片段执行动作”。

## API 设计

### Transcript

- `GET /api/meetings/{meeting_id}/transcripts`
  - 获取转写时间线
- `POST /api/meetings/{meeting_id}/transcripts`
  - 新增转写片段

### Context

- `GET /api/meetings/{meeting_id}/context/current`
  - 获取当前上下文快照
- `POST /api/meetings/{meeting_id}/context/rebuild`
  - 手动重建上下文

### Agent Actions

- `POST /api/meetings/{meeting_id}/agent-actions`
  - 基于 selected chunks + task_type 调 Claude/Codex

请求体建议：

```json
{
  "agent_type": "claude",
  "task_type": "risk_analysis",
  "selected_chunk_ids": [101, 102, 108]
}
```

### Artifacts

- `GET /api/meetings/{meeting_id}/artifacts`
  - 获取会议产物
- `POST /api/meetings/{meeting_id}/artifacts/materialize`
  - 触发产物生成

## 与现有本地 bridge 的关系

之前对接本地 Codex/Claude 的方法论可以直接复用：

- 本地 bridge 继续负责“把请求发给本地 agent，再取回文本结果”
- 不需要重新设计底层通信

需要变化的只有两点：

1. 调用入口从“用户聊天消息”改成“会议上下文任务”
2. prompt 构造从“单条文本”改成“结构化上下文包”

因此，bridge 层保留，orchestrator 层重写。

## MVP 实施顺序

### Phase 1：只做会议上下文，不接真实 STT

目标：

- 先验证交互和数据结构

实现：

- 新建 `meeting_context` 模块
- 支持手动写入 transcript chunks
- 完成 context snapshot / artifact / agent action 接口
- 会议页改造成 transcript + actions + outputs
- agent 调用先走 mock transcript 或文本模拟

### Phase 2：接真实 STT

目标：

- 让会议音频持续产生 transcript

实现：

- 复用 `speech_to_text`
- 把 final transcript 写入 `MeetingTranscriptChunk`
- partial transcript 用于前端实时显示

### Phase 3：自动化物化

目标：

- 自动生成 summary / todos / decisions

实现：

- 加入定时或增量触发机制
- 评估 Claude / Codex 在不同任务上的效果

## 风险与取舍

### 风险 1：实时 STT 不稳定

应对：

- MVP 先解耦 STT，先把上下文和 agent 调用链跑通

### 风险 2：上下文膨胀

应对：

- 只保留最近窗口 + 结构化摘要
- 不把整场会议全文直接塞给 agent

### 风险 3：产品又回到聊天模式

应对：

- UI 主入口改为 transcript actions
- 弱化自由输入框

### 风险 4：前后端耦合 prompt 逻辑

应对：

- prompt 在后端 orchestrator 构造
- 前端只传 task_type 和 selected_chunk_ids

## 最终建议

下一步不要先恢复“语音发给 agent”的旧实现，而应该优先做：

1. `meeting_context` 模块
2. transcript 时间线 UI
3. 基于片段的 Claude/Codex actions
4. summary / decision / todo 三类会议产物

这条路线能让 VibeMeeting 和飞书机器人形成清晰边界，也能最大化复用已有本地 bridge 能力。
