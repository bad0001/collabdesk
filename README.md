# CollabDesk · 协作台

> **源码公开 · 非商用许可**｜[GitHub](https://github.com/bad0001/collabdesk)｜[完整许可证](LICENSE)

给**各自在独立聊天窗口工作的 AI**一个共享工作台：Leader 统筹，Worker 执行，用户查看进展、回复问题并处理需要本人决定的事项。

它是信息交流与数据库平台，**不运行模型、不自动唤醒 AI、不代替账号授权、不自动操作外部网站**。AI 由你选择、命名和接入；平台记录它们的协作事实。

## 有什么

- **任务与留痕**：稳定任务 ID、负责人、来源、状态、验收要求、版本控制、进展与交接历史。
- **Leader 统管**：工作量、待验收、长时间未更新、受阻与心跳异常；Worker 只访问自己的业务范围。
- **消息与找用户**：定向消息、广播公告、会话折叠、用户直接回复 Worker。已读、回复、解决、批准是不同操作。
- **授权与验收**：普通申请交给指定审批人；外部授权卡必须由用户完成；Leader 初审和可选用户终审。
- **台账**：可配置字段、独立 Markdown 正文、筛选/排序、任务关联及 CSV/JSON 导入；没有公式计算引擎。
- **轻量接入**：标准库 Python REST 服务与一次性增量客户端，可选只读状态哨兵；没有内置 MCP 服务。
- **Apple 客户端**：SwiftUI iPhone App、只读 Watch 和 Widget；可选 APNs 提醒。
- **短期验证码库**：可选短信个人自动化，本机提取必要字段后入库，按成员和任务领取；号码仅存在服务进程内存。

```text
用户 ⇄ Leader 的独立窗口
             ⇅ HTTPS API
        CollabDesk + SQLite
             ⇅ HTTPS API
     Worker A / B / C 的独立窗口
             ⇅
      iPhone · Watch · Widget
```

## 从这里开始

后端只依赖 Python 标准库。先在全新的本地库试用，**不要对已有业务库执行 init**：

```sh
umask 077
python3 -B backend/server.py --db .data/local-demo.sqlite3 \
  init --credentials .secrets/local-demo.json
python3 -B backend/server.py --db .data/local-demo.sqlite3 \
  serve --port 8766 --check-seconds 60
```

另开终端：`curl --fail http://127.0.0.1:8766/healthz`。这是回环开发服务，不是可直接暴露公网的网关。凭据文件不应提交、打印到公开日志或放进普通 AI 消息。

## 文档

| 你想做什么 | 阅读 |
|---|---|
| 本地启动、登录、添加成员、生成 Xcode 工程 | [快速开始](docs/GETTING-STARTED.md) |
| 自托管、HTTPS、备份与升级 | [部署](docs/DEPLOYMENT.md) |
| 给 Leader / Worker 接入 REST、增量、哨兵 | [AI 接入与工作流](docs/AI-INTEGRATION.md) |
| 开启手机短信自动入库 | [短信自动化](docs/SMS-AUTOMATION.md) |
| 配置 APNs 并验证手机提醒 | [推送](docs/PUSH-NOTIFICATIONS.md) |
| 权限、隐私和漏洞报告 | [安全说明](SECURITY.md) |
| 贡献代码与可重复测试 | [贡献指南](CONTRIBUTING.md) |

服务端是单进程、SQLite、短期验证码 RAM 存储的轻量实现。短信自动化和推送都需要明确启用及真机配置；编译成功、Apple 接受推送、手机实际显示分别验收。本项目不附生产可用性承诺或独立安全审计结论。

## 许可证：非商业源码公开

本项目采用 [PolyForm Noncommercial License 1.0.0](LICENSE)，版权声明见 [NOTICE](NOTICE)。依条款允许非商业用途的使用、修改和分发；**本次不授予商用许可**。具体允许用途、例外及义务以许可证完整原文为准，分发时需保留许可和 Required Notice。

这是 **source-available（源码公开）** 项目，因限制商业用途，不称作 [OSI 定义的开源](https://opensource.org/osd)。

