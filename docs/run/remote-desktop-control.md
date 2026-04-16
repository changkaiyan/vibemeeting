# Remote Desktop Control (Web + Native)

本文档说明会议中的远程桌面控制能力，以及当前实现边界。

## 支持范围

- 控制端：Web 会议页、Windows native 会议页
- 被控端：Windows native 会议页

当前不支持“Web 被控”。

## 可见性优先（避免盲控）

远控同意前，目标端必须先具备可见画面：

1. 控制端从成员菜单发起 `请求远程控制`
2. 被控端弹出同意/拒绝对话框
3. 被控端点“允许”后，必须先完成屏幕共享源选择
4. 屏幕共享开启成功，才会返回“同意远控”
5. 控制端自动聚焦目标画面，并优先显示目标屏幕流

如果目标端取消共享源选择、系统权限不足或共享源失效，请求会被拒绝（`target_screen_share_unavailable`）。

## 会话控制

- 控制端可在画面覆盖层点击 `结束控制`
- 被控端可在顶部按钮点击 `结束被控`
- 任一方结束后，双方会话状态都会清理

## 常见拒绝原因

- `target_busy`：目标端已经在另一个远控会话里
- `target_rejected`：目标端手动拒绝
- `target_screen_share_unavailable`：目标端无法开启或未完成屏幕共享
- `web_target_unsupported`：目标是 Web 客户端（当前不支持）

## 构建与运行

Windows native 入口和构建命令见：

- `docs/run/flutter-windows-launcher.md`
