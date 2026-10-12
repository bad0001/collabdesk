# 可选 Apple 推送

系统推送用于提醒用户处理新消息、找用户请求、用户审批/外部授权卡和转交用户终审。它不运行AI，不表示Worker已完成工作，也不把正文、密码或验证码送到锁屏。

Apple材料、签名、服务器配置和用户通知权限缺一不可。无推送时仍可手动打开App同步；短信自动入库是独立功能。

## 1. Apple端准备

1. 使用自己的开发者团队，为**自己的主App Bundle ID**启用 Push Notifications；Widget/Watch/App Group配套身份也由该团队配置。
2. 根据自己的签名/安装方式选择APNs sandbox或production。Xcode开发签名通常使用sandbox；发布签名环境以实际entitlement/设备登记为准，不能只凭文件名猜。
3. 在Apple开发者后台创建APNs认证密钥，尽量限制到所需App/topic和环境；保存 `.p8` 私钥、Key ID、Team ID。
4. 私钥仅能下载一次，下载后立即核对本机文件真实存在并私密保存；不要将一次性“创建成功”当作文件已保存。不要撤销或借用其他App密钥来配置本项目。

使用Apple官方 [远程通知服务器指南](https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server) 和 [App登记指南](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns) 完成各自账号设置。

## 2. 服务器环境变量

通过root管理的私有EnvironmentFile配置，不写进源码、容器镜像、shell历史或公开服务日志：

```dotenv
COLLAB_APNS_KEY_FILE=/etc/collabdesk/private/AuthKey.p8
COLLAB_APNS_KEY_ID=YOUR_KEY_ID
COLLAB_APNS_TEAM_ID=YOUR_TEAM_ID
COLLAB_APNS_TOPIC=YOUR_MAIN_APP_BUNDLE_ID
```

`YOUR_*` 都是占位符，部署前替换自己的。Key ID/Team ID按后端格式验证；topic必须等于自己App的实际Bundle ID，不能沿用开发者示例身份。

私钥0600、目录访问受限，文件由服务进程可读的账户所有；EnvironmentFile由root600管理。服务无需写私钥。若unit启用了ProtectHome，把材料放在独立 `/etc` 配置目录，不放个人家目录。确认systemd实际加载配置，不覆盖无关项目的drop-in。

运行端需要OpenSSL（ES256签名）和HTTP/2 curl。后端按登记设备的environment选择sandbox/production APNs地址；同一设备token、签名环境、topic和密钥范围必须一致。

## 3. 手机登记

1. Xcode检查主App的Push Notifications与App Group签名描述文件，覆盖安装自己的版本。
2. 在协作台连接自己的admin身份，打开通知设置并允许系统提示。
3. App把本安装的device token/environment登记到 `/v1/push/devices`；这是设备凭据，不是AI成员Bearer。
4. `GET /v1/push/status`（admin）检查configured、configProblem、registeredDevices、queued、acceptedByAPNs、failed。

切换账号/安装/设备可能需要重新登记。不要复制某次设备token当永久配置；App承担当前登记，Token不进Markdown或issue。

## 4. 发出机制

业务事务先写outbox，提交后唤醒单进程推送worker。未读消息/待处理求助/审批/终审生成泛化提醒。发送前再核对该事项、成员和设备仍有效；已读、解决、撤销或停用会取消待发提醒。

临时网络错误/限流有有界退避；无效设备会停用登记。平台不在推送载荷里复制普通聊天正文或验证码，因此通知到达后仍需App认证读取业务。

## 5. 验收分开记

| 阶段 | 代表什么 |
|---|---|
| 源码编译/签名通过 | 程序可构建，不代表通知配置正确 |
| configured=true | 本地配置就绪，不代表Apple接受 |
| APNs HTTP200 | Apple接受这次发送，不代表设备显示 |
| 手机实际显示 | 当前通知确实到达；锁屏、声音、点击路由仍可各自检查 |

使用合成、不含秘密的提醒测试。先确认手机系统通知权限、网络、专注模式、通知摘要、当前签名环境；点击提醒应打开正确事项或提示当前对象已结束，而不是误批准操作。

生产安装没有经过本人的真机显示验收时，不标成“推送已完成”。也不保证绕过用户的静音、专注或系统调度。

## 6. 故障定位

- 401/403：检查APNs密钥、Team、签名和topic；不要通过关闭TLS来修。
- BadDeviceToken/DeviceTokenNotForTopic/Unregistered：核对实际环境与当前安装登记，必要时由App重登记。
- TransportError：确认HTTP2 curl、网络出口与代理；本地config ready不等于Apple网络可达。
- Apple接受但没显示：检查手机权限/专注/摘要，再核对当次事项是否已读或取消。

报告状态、UTC时间和泛化错误类别即可。不要分享 `.p8`、JWT、成员Token、device token、完整业务库或私人截图。
