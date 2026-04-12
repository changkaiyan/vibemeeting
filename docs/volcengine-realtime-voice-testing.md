# VolcEngine Realtime Voice Testing

本文档记录本项目接入火山引擎豆包端到端实时语音大模型时，已经验证可用的控制台选择、参数映射、配置方式、测试步骤和常见报错。

## 1. 适用范围

本项目当前的实时语音 AI 成员使用的是豆包语音 WebSocket 对话接口：

- `wss://openspeech.bytedance.com/api/v3/realtime/dialogue`

它对应的是：

- `豆包端到端实时语音大模型`

不是以下服务：

- `流式语音识别大模型`
- `录音文件识别`
- 纯 `语音合成`
- 其他纯 ASR / 纯 TTS 服务

## 2. 控制台应选择的服务

在火山引擎控制台中，应进入：

- `豆包语音`
- `豆包端到端实时语音大模型`

控制台里的服务接口认证信息页可看到：

- `APP ID`
- `Access Token`
- `Secret Key`

当前项目测试已确认：

- 项目中真正需要填写的是 `APP ID` 和 `Access Token`
- `Secret Key` 当前这条 WebSocket 接法不直接使用

## 3. 项目字段与火山参数映射

在会议页 `AI管控 -> 火山引擎` 中，字段应这样填写：

- `Volcengine WebSocket URL`
  - `wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- `Volcengine App ID`
  - 控制台中的 `APP ID`
- `Volcengine Access Key`
  - 控制台中的 `Access Token`
- `Volcengine Resource ID`
  - `volc.speech.dialog`
- `Volcengine App Key`
  - `PlgvMymc7f3tQnJ6`
- `Volcengine UID`
  - 任意可定位日志的值，例如 `test-user-1`

说明：

- 当前项目代码采用火山引擎该接口的旧式 header 方案：
  - `X-Api-App-ID`
  - `X-Api-App-Key`
  - `X-Api-Access-Key`
  - `X-Api-Resource-Id`
- 结合保存于 `origin/kaiyan` 分支的官方文档快照，`X-Api-App-Key` 对当前接口是固定值：
  - `PlgvMymc7f3tQnJ6`

## 4. 模型与音色选择

当前项目支持的火山模型值：

- `1.2.1.1`
  - 对应 `O2.0`
- `2.2.0.0`
  - 对应 `SC2.0`

推荐优先使用：

- `Volcengine Model = 2.2.0.0`

### 4.1 SC2.0 可用 speaker

当模型为 `2.2.0.0` 时，`Volcengine Voice` 不能填 OpenAI voice，例如：

- `marin`

这会导致火山服务端返回：

- `ClientError:InvalidSpeaker`

当前仓库内置了一组 SC2.0 可用 speaker，示例包括：

- `saturn_zh_female_nuanxinxuejie_tob`
- `saturn_zh_female_keainvsheng_tob`
- `saturn_zh_female_wenrouwenya_tob`
- `saturn_zh_male_yangguangqingnian_tob`
- `saturn_zh_male_wenrouxuezhang_tob`

建议第一次联调直接使用：

- `saturn_zh_female_nuanxinxuejie_tob`

### 4.2 O2.0 可用 speaker

如果模型改为 `1.2.1.1`，建议使用 `jupiter` 系列 speaker，例如：

- `zh_female_vv_jupiter_bigtts`

## 5. 一套已验证可用的最小配置

以下是一套已在本仓库内验证过可进入有效会话的配置模板：

- `Volcengine WebSocket URL`
  - `wss://openspeech.bytedance.com/api/v3/realtime/dialogue`
- `Volcengine Model`
  - `2.2.0.0`
- `Volcengine Voice`
  - `saturn_zh_female_nuanxinxuejie_tob`
- `Volcengine App ID`
  - 填控制台 `APP ID`
- `Volcengine App Key`
  - `PlgvMymc7f3tQnJ6`
- `Volcengine Access Key`
  - 填控制台 `Access Token`
- `Volcengine Resource ID`
  - `volc.speech.dialog`
- `Volcengine UID`
  - `test-user-1`

## 6. 测试步骤

### 6.1 前端连通性测试

1. 进入会议页。
2. 打开 `AI管控`。
3. 选择 `火山引擎`。
4. 按本文档第 5 节填写参数。
5. 先点击 `保存`。
6. 再点击 `测试连通性`。

如果返回：

- `连通性测试成功`

则说明：

- WebSocket 已握手成功
- 会话已成功创建
- 文本 query 已获得模型回复

### 6.2 服务端调试日志

火山 WebSocket 事件调试开关在 `.env` 中：

- `REALTIME_BOT_VOLC_DEBUG_EVENTS=1`

打开后，重启 Django 进程，再执行连通性测试，可用于定位：

- `ConnectionStarted`
- `SessionStarted`
- 错误帧
- 文本 query 后的返回事件

## 7. 已确认的常见问题

### 7.1 误选服务

现象：

- 已配置 `APP ID / Access Token`
- 连通性测试仍无文本输出

常见原因：

- 使用了 `流式语音识别大模型` 或其他 ASR/TTS 服务的认证信息

正确做法：

- 必须使用 `豆包端到端实时语音大模型` 的认证信息

### 7.2 `speaker is empty`

现象：

- 火山返回错误：
  - `speaker is empty`

原因：

- 当前接口和当前项目实现下，TTS speaker 不能为空

处理：

- 为所选模型填写合法 speaker

### 7.3 `ClientError:InvalidSpeaker`

现象：

- 火山返回错误：
  - `ClientError:InvalidSpeaker`

原因：

- `Volcengine Voice` 填了非法 speaker
- 例如把 OpenAI voice `marin` 填入火山配置

处理：

- 对 `2.2.0.0` 使用 `saturn_*`
- 对 `1.2.1.1` 使用 `jupiter_*`

### 7.4 只看到 `APP ID / Access Token / Secret Key`

说明：

- 这是正常的控制台展示
- 当前项目对这条 WebSocket 接口只直接使用：
  - `APP ID`
  - `Access Token`
- `App Key` 对这条接口是固定值：
  - `PlgvMymc7f3tQnJ6`

## 8. 相关代码位置

- 火山默认配置：
  - `/home/zhaoyilun/vibemeeting/.env.example`
- 运行时配置读取：
  - `/home/zhaoyilun/vibemeeting/smart_meeting/settings.py`
- 火山 WebSocket header 组装：
  - `/home/zhaoyilun/vibemeeting/conference/views.py`
- 火山连通性测试接口：
  - `/home/zhaoyilun/vibemeeting/conference/views.py`
- 前端 AI 管控弹窗：
  - `/home/zhaoyilun/vibemeeting/flutter_app/lib/meeting_room/page.dart`

## 9. 手工验证记录

本次联调已确认：

- `APP ID + Access Token + 固定 App Key + resource_id` 的接法是正确方向
- 之前失败的直接原因不是认证，而是 `Volcengine Voice` 填成了 OpenAI voice：
  - `marin`
- 该错误会导致火山返回：
  - `ClientError:InvalidSpeaker`

因此，后续再次配置火山实时语音时，应先确认：

1. 服务选的是 `豆包端到端实时语音大模型`
2. `Model` 与 `Voice` 是同一体系
3. `Voice` 不要复用 OpenAI voice 名称
