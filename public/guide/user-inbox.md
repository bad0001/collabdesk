# 找用户、回复与短期验证码

只有用户掌握的资料、事实范围或外部账号操作，可以在平台直接找用户；普通跨Worker协调先Leader。用户App首页聚合需要本人处理的事项，消息按成员折叠；平台提供通道，不自动保证外部AI窗口已经醒来。

## 求助与回复

`POST /v1/user-requests` 使用成员Bearer/幂等键：taskId（可省略）、kind、subject、body。kind支持question/material/external_action；验证码必须用 `/v1/code-requests`，不在正文传数字。

用户用 `/v1/user-requests/ID/reply`，正文含最新version/body及可选resolve；回复生成回给请求人的定向消息。`/resolve`或`/cancel`需最新version。任务绑定求助在转派/提交待验收/完成/取消后终止，一般taskId为空的请求不因无关任务结束而消失。

直接聊天 `POST /v1/messages` 使用recipientId/body；Worker可找Leader/admin，用户可直接回复Worker。收件人 `/v1/messages/ID/read` 标已读。Leader/admin能统管普通业务消息，这不是用户与某Worker的秘密保险箱。

**已读、回复、解决请求、批准授权、通过验收分别记录。** 不要靠一句“好的”绕过正式审批；普通回复也不会把任务自动完成。

## 授权与验收

normal授权由当前指定reviewer处理，card由用户外部操作后confirmed_external。Leader可转交普通申请给用户，但不能批准card。成果默认Leader验收，forward_user后用户终审。用原对象和最新version留痕，而非删重建历史。

## 短期码分派

用户可手动确认导入，或明确启用 [手机新短信自动入库](sms-code-import.md)，不再逐条填字段。自动来源标签为短信自述，账号/不明用途保持未知。

Worker先登记当前任务的code-request，再看适配元数据。claim按当前成员/任务/正式授权/码version原子检查；多个任务争用409交Leader/admin assign。仅用户和当前获分派Worker读临时数字，Leader只看元数据/分派。

码只在单进程RAM；数据库仅保存不含码的状态和历史。消费、到期、替换、任务转派/结束、重启失效。数字不放普通聊天、授权正文、日志、缓存、通知、Watch或Widget。

## 提醒

完成 [APNs](push-setup.md) 后，找用户、未读定向消息、用户审批/终审可产生泛化通知；Apple接受与实际手机显示分别验收。点击/收到通知不自动批准、解决或代表Worker已处理。

接口认证、幂等、错误与更完整路由见 [API](api.md)；角色细节见 [Leader](leader.md) / [Worker](worker.md)，隐私见 [安全](security.md)。
