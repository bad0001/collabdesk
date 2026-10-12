# 可选短信自动化与短期验证码库

此功能默认不自动上传。用户在自己的iPhone启用一次专用写入权限、设置个人自动化后，新短信才进入处理链路。App不读取短信历史数据库，不监听剪贴板，不上传整条短信或发件人号码。

## 1. 一次设置

1. 确认App连接自己的**HTTPS**服务、自己的admin账号；演示模式不导入真实短信。
2. 验证码库菜单/设置 → **短信自动入库** → 阅读共享说明 → 同意并启用。独立 `CodeIngest` 凭据存本机Keychain，不把admin Bearer交给后台动作。
3. iPhone快捷指令 → 自动化 → 信息，明确设“包含验证码”，或指定发件人。英文OTP可另设对应关键词。不要把所有私人信息都交给自动化。
4. 选择立即运行才能免逐次系统询问；想保留询问时选择确认后运行。
5. 添加协作台动作 **自动入库短信验证码**。将“短信内容”绑定**本次快捷指令输入的正文**，不是一条固定短信、剪贴板或历史列表。
6. 若系统实际提供本次信息收到时间，绑定“收到时间”；否则留空，平台明确标记提取时间。

旧 **提取短信验证码** 动作仍打开手动确认页，是备用流程，不是自动后台上传动作。

Apple个人自动化以设备事件触发，信息条件见 [Apple信息触发说明](https://support.apple.com/guide/shortcuts/communication-triggers-apdd711f9dff/ios)。自动运行设置随系统版本而异，参见 [Apple iOS 26 自动化说明](https://support.apple.com/en-us/guide/shortcuts/apd602971e63/9.0/ios/26)。

## 2. 提取与时间

- 只提取明确验证码/OTP等标签附近的4–8位数字，一次最多六个候选；订单、金额、电话号码不当作验证码。
- 短信开头 `【品牌】` / `[品牌]`可作为短来源标签，**只是短信自称，不是来源认证**。
- 明确login/register/reset用途可识别；冲突或没有明示则unknown。账号不猜测，标未知账号。
- 明确有效期取较短期限，未写默认300秒，最多900秒；这是平台清理上限，不保证网站仍接受它。
- `timeSource=received`是传入真实收到时间，`captured`是动作运行时刻。后者不能证明短信刚刚收到。

动作在后台单次HTTPS上传必要候选和元数据，没有持久短信缓存或失败重试队列，不返回号码到动作dialog、通知、Watch或Widget。后台/锁屏运行受iOS和网络影响；重启后需先解锁一次，Keychain才可供后台访问。[Apple后台AppIntent](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)、[Keychain首次解锁规则](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)。

## 3. AI怎样获取

Worker先登记自己的当前任务待码请求。列表只给适配候选**元数据**；手动项三标签匹配，自动项已知来源/用途匹配，未知字段保持未确定。Worker自行选择候选不等于所有AI看见所有号码。

原子claim检查当前负责人、任务阶段、申请、码version和授权；多任务竞争返回409，由Leader/admin明确assign。只有用户和当前被分派Worker临时读取数字。Leader可以看元数据/分派，但没有读码权限。普通审批、外部授权卡和验证码领取相互独立。

已知来源/用途新批替旧批，同条短信多个候选保留；未知来源的不同批不互相覆盖。同网站多账号并行而账号标签未知时，需要Leader协调，不能凭时间接近盲试。

## 4. 存储与清理

数字只在后端单进程RAM；数据库保存不含码的状态/来源/时间/分派审计。消费、到期、替换、任务交接/结束或服务重启会失效并清理在线数字。列表/value即时判断到期，后台维护再清内存。

去重也只在RAM，不把低熵验证码哈希保存在磁盘上当永久指纹。重复码不延长有效期、已用码不复活；重启丢失去重状态。导入时刻早于新进程启动会拒绝；只标captured时系统无法辨认“旧短信被用户重新运行”，因此不要重放历史消息。

关闭本机自动化/停用App内权限可停止继续上传。切换origin、成员、工作区或进入演示模式会使本机绑定失效。失败只报告结果不确定，先看库中现状或等待新码，不反复上传旧短信。

## 5. 接口契约

| 接口 | 权限 |
|---|---|
| `GET /v1/codes/automation/status` | admin，只读安装列表，不返回凭据 |
| `POST /v1/codes/automation/enable` | admin Bearer+幂等键，`installationId`；凭据仅首次响应 |
| `POST /v1/codes/automation/disable` | admin Bearer+幂等键，撤销本安装，不轮换成员Token |
| `POST /v1/codes/ingest` | 只接受 `Authorization: CodeIngest DEVICE_CREDENTIAL`，不接受成员Bearer |

ingest JSON字段仅 `codes/source/purpose/receivedAt/timeSource/expiresIn`：数字字符串列表、短品牌或空、用途枚举 `login/register/reset/verification/unknown`、带时区时间、`received/captured`、1–900秒整数。不接受rawSMS/account/fullPhone/额外字段。201表示新导入，200且imported=0表示重复；响应没有数字正文。

这个专用凭据只写入，不能读取成员/任务/号码或管理平台。若启用响应丢失，用户明确重新启用生成新凭据；旧幂等回执不会再次泄露凭据。数字不应通过普通消息或授权申请正文传递。

## 6. 分阶段验收

1. 单元测试解析合成文字，确认不会提取手机号/金额。
2. 临时库验证专用鉴权、版本、领取、过期、授权、RAM-only存储。
3. 真机一次新测试短信：触发正确输入 → 不打开表单 → 元数据入库 → 对应任务可领取。
4. 单独检查锁屏、重启后首次解锁、弱网和停用行为。

编译、模拟器或服务器测试不等于你自己的锁屏自动链路已完成。测试时用合成码，不截图/上传真实信息正文。
