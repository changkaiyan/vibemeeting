# Deployment Guide

本文档概述当前项目在非本机开发场景下需要关注的部署主题，并给出仓库内现有专题文档入口。

## 1. 适用范围

部署场景通常包括：

- 通过域名对外提供访问
- 使用 `https://` 和 `wss://`
- 配置反向代理
- 将 Django、LiveKit、STT worker、agent bridge 作为长期运行服务托管
- 提供局域网或公网可访问地址

如果你的目标只是本机开发和功能联调，请使用 `docs/development.md`。

## 2. 组件清单

一个完整的可访问部署通常至少包含以下组件：

- Django 主应用
  - 页面、API、数据库访问、鉴权、业务逻辑
- Flutter Web 静态产物
  - 由 `flutter_app/` 构建并发布到静态资源目录
- LiveKit
  - 实时音视频房间和 join token 对接
- STT worker
  - 会议字幕转写服务
- Meeting agent bridge
  - 本地或远程 agent 调用入口

## 3. 部署时需要明确的事项

### 3.1 地址与协议

需要明确以下地址配置：

- Django 对外访问地址
- LiveKit 对外访问地址
- 是否使用 `https://`
- 页面中的 LiveKit 地址是否需要使用 `wss://`

### 3.2 进程管理

需要明确以下运行方式：

- Django 如何托管
- LiveKit 如何托管
- STT worker 如何托管
- agent bridge 如何托管
- 日志如何收集
- 进程退出后如何自动拉起

### 3.3 静态资源发布

当前真实会议页来自 Flutter Web 构建产物，因此部署时需要明确：

- `flutter_app/` 的构建流程
- `artifacts/flutter_app_web/` 或等价静态目录的发布方式
- Django 最终读取哪个静态产物目录

### 3.4 外部依赖

部署前还需要确认：

- 数据库类型和连接方式
- 录制或 egress 输出目录
- STT 模型下载或缓存策略
- `codex` CLI 或其他 agent runner 的可用性

## 4. 当前仓库的相关专题文档

- HTTPS 本地联调：`HTTPS_TESTING.md`
- LiveKit SSL：`LIVEKIT_SSL_STARTUP.md`
- STT worker 运行时说明：`services/stt_worker/README.md`
- 开发与本机联调：`docs/development.md`

## 5. 后续建议

如果后面补完整部署手册，建议至少单独补齐以下章节：

- 环境变量矩阵
- 单机部署步骤
- 反向代理配置示例
- HTTPS / WSS 配置
- 进程托管方式
- Flutter 静态产物发布流程
- LiveKit 对外地址配置
- STT worker 和 agent bridge 的部署方式
