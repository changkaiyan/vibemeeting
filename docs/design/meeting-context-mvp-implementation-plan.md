# Meeting Context MVP 实施计划

## 目标

当前仓库只有 `meeting_context workspace MVP`，还没有真实的 STT，也没有真实的本地 agent bridge。

接下来的开发顺序按下面三层推进，并严格采用 TDD：

1. 真实 agent bridge
2. 音频上传式 STT
3. 上下文引擎与 UI 闭环

原则：

- 先把假能力改成真能力
- 默认失败优于默认伪装成功
- mock 只能显式开启，不能作为默认行为
- 每一层都先写失败测试，再补最小实现

## Phase 1: Meeting Agent Bridge

### 目标

把当前“假连接 + 默认 mock reply”改成真实语义：

- 未配置 bridge 时，connect / action 必须失败
- 只有显式 `mock` 模式才允许本地假返回
- 配置了真实 bridge URL 时，必须先 health check
- action 失败时不能静默冒充成功

### 模块拆分

新增独立目录：

- `conference/meeting_agent_bridge/`
  - `__init__.py`
  - `client.py`
  - `exceptions.py`

### 配置约定

- `MEETING_AGENT_BRIDGE_MODE`
  - `disabled` 默认
  - `mock`
  - `http`
- `MEETING_AGENT_BRIDGE_URL`
  - 当 mode=`http` 时必填

### TDD Checklist

#### 测试先行

- `POST /api/meetings/{id}/agents`
  - mode 未配置时返回失败
  - mode=`mock` 时成功
  - mode=`http` 且 health 成功时成功
  - mode=`http` 且 health 失败时失败

- `POST /api/meetings/{id}/agent-actions`
  - mode 未配置时返回失败
  - mode=`mock` 时成功并生成 artifact
  - mode=`http` 且 action 成功时成功
  - mode=`http` 且 action 超时/异常时失败且不生成 artifact

#### 实现后置条件

- `bridge_online` 只有真实 health 成功后才为 `true`
- `presence_status` 出错时应落到错误态，而不是 `idle`
- 不再默认 `_mock_reply`

## Phase 2: Speech To Text

### 目标

先实现“浏览器录音片段上传 -> 服务端 STT -> transcript 入库”，不直接上复杂实时流。

### 模块拆分

新增独立目录：

- `conference/speech_to_text/`
  - `__init__.py`
  - `providers/`
  - `services/ingest.py`
  - `services/transcribe.py`
  - `views.py`
  - `serializers.py`

### TDD Checklist

- 音频上传接口成功
- 非法文件失败
- provider 返回文本后写入 `MeetingTranscriptChunk`
- `source=stt_upload`
- sequence 连续

## Phase 3: Context + UI 闭环

### 目标

让 transcript 真正进入 current context，并可被 Alice/Bob 直接消费。

### 模块重构

拆分当前：

- `conference/meeting_context/services.py`

为：

- `conference/meeting_context/services/context_builder.py`
- `conference/meeting_context/services/snapshot_service.py`
- `conference/meeting_context/services/artifact_service.py`
- `conference/meeting_context/services/agent_dispatcher.py`

### TDD Checklist

- 多 chunk 场景下 context snapshot 正确选窗
- 选中 chunk ids 时 action 使用指定上下文
- 未选中时使用当前 snapshot 源 chunk
- artifact 与 session 状态正确更新

## 验收口径

第一阶段完成后，才允许说“支持连接本地 agent”。

第二阶段完成后，才允许说“支持 speech to text”。

第三阶段完成后，才允许说“会议上下文可以真实 offload 给 agent”。
