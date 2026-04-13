# Docs Guide

`docs/` 当前按文档性质分为四层：

- `docs/run/`
  - 开发、联调、部署、运行组件相关文档
- `docs/design/`
  - 当前有效的架构设计、边界定义、子系统设计
- `docs/status/`
  - 当前实现状态、已完成 / 未完成能力盘点
- `docs/history/`
  - 阶段性方案、专项验证记录、历史集成文档
- `docs/diagrams/`
  - Mermaid 源文件和导出的 PNG 图

推荐阅读顺序：

1. `README.md`
2. `docs/run/development.md`
3. `docs/design/ai-workflows-overview.md`
4. `docs/run/stt-worker.md`
5. `docs/status/virtual-agent-meeting-current-status.md`

如果你只想快速启动本地环境，优先看：

- `docs/run/development.md`
- `docs/run/https-testing.md`

如果你在理解 AI / STT / agent 方向，优先看：

- `docs/design/ai-workflows-overview.md`
- `docs/design/meeting-workspace-boundaries.md`
- `docs/design/volcengine-cloud-stt-design.md`

`docs/history/` 下的文档默认不作为当前实现的主依据，只作为背景参考。
