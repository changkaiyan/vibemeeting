# 中文开源发布准备验证

本记录针对当前源码发布准备，不代表已推送远端或创建正式 Release。

## 文档与许可

- README 按项目动机、Demo、功能、一键安装、流程测试、隐私、开发文档与许可组织。
- 参考 1Panel 中文 README 与 Langchain-Chatchat 的信息结构，内容按实际项目能力编写。
- 根目录 `LICENSE` 使用 Apache 官方原文；商业与多人使用无需另行授权。
- 作者明确同意公开的联系邮箱已加入联系入口，其他个人邮箱不在允许范围。

## 自动化验证

实际执行以下命令，34 项脚本测试通过，其中包含 11 项发布审计测试：

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s scripts/tests -p "test_*.py"
```

为泛化旧测试名称后验证行为，执行以下两个后端回归，均通过：

```powershell
.\.venv\Scripts\python.exe manage.py test conference.tests.MeetingRealtimeAudioWebSocketTests.test_stream_bridge_start_uses_expected_session_audio_params conference.tests.MeetingRealtimeAudioWebSocketTests.test_decode_audio_chunk_applies_streaming_auto_gain_path --verbosity 0
```

发布审计与源码导出命令：

```powershell
.\.venv\Scripts\python.exe scripts/release_audit.py
.\.venv\Scripts\python.exe scripts/release_audit.py --output artifacts/releases/vibemeeting-source.zip
git -c safe.directory="<PROJECT_ROOT>" diff --check
```

Git 命令在项目根目录执行；上面的 `<PROJECT_ROOT>` 在实际执行时替换为本机项目根目录，发布记录不保存开发者的实际绝对路径。

## 发布边界

当前可提交源码与文档已经脱敏并通过扫描，图标元数据已清除。源码包不携带旧 Git 历史、数据库、用户数据、凭据、录像、日志和本地运行环境。

原 Git 历史仍有作者 / 提交者邮箱和旧文档，没有被重写。正式公开源码应使用本次导出的源码包建立干净仓库；直接公开原仓库全部历史不在本次通过扫描的范围内。

扫描器的规则、公开例外和人工复核边界见 [发布与隐私说明](../run/release-privacy.md)。
