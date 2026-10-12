# 可选轻量哨兵

管理员明确启用 `--public-watch` 或 `COLLABDESK_PUBLIC_WATCH=1` 后，脚本可以只查看计数与游标，有变化才通过自己的调度机制唤醒完整AI。平台和这个脚本都不运行模型。

```text
GET /v1/watch?workspace=WORKSPACE_ID
GET /v1/watch?workspace=WORKSPACE_ID&memberId=worker-design
```

默认关闭时404。workspace值从自己实例身份快照取得，不抄他人示例。

## 字段

工作区响应恰好 `workspaceId/cursor/tasks/auths/alerts/messages` 六字段。成员响应另加 `memberId/announcements/revisions`，revisions是tasks/auths/alerts/messages/announcements五类不透明修订值。没有正文、Token、号码或个人资料。

当前任务/事件、自己的授权请求/异常、收到的消息、适用广播公告及共享规则驱动成员变化。无关Worker更新、心跳、纯同步游标不制造工作变化；公告不是任意audience的定向私有广播。

## 一次检查

```sh
python3 -B clients/watch_probe.py \
  --base-url https://collab.example.com --workspace WORKSPACE_ID \
  --member-id worker-design --state ~/collabdesk/worker-design/watch.json
```

CLI只检查一次，输出决定，不安装cron/hook，不自动唤醒AI。外部平台若允许，可每30–60秒运行；完整agent使用自身Bearer增量拉取、处理成功后，再以 `--ack CAPTURED_WATCH_CURSOR` 确认此前捕获游标（ack不发网络请求）。没有处理就不要ack；尚未ack可能在cooldown后再次提醒。

## 权限与故障

memberId只是筛选，不是凭证；公开模式仍可能泄露工作量/时序。已认证Worker不能切别人memberId越权。需要更严格隐私时不开启，或由部署者明确配置网络访问控制。[安全说明](security.md)。

脚本不能代Worker提交工作心跳。网络错误、代理失败、TLS错误不是“没有更新”；保留原checkpoint，有限退避，完整连接问题不要靠修改Token或关闭证书验证掩盖。[API/增量](api.md)、[部署](deployment.md)。
