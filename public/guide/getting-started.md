# 快速开始

## 1. 准备

- 后端及 CLI：Python 3.10 或更新版本；只使用标准库。
- iOS：macOS、Xcode、XcodeGen，以及对应 iOS/watchOS SDK。当前源码含 iOS 26 的 AppIntents 类型，编译时需要支持这些类型的 SDK；部署目标查看 `ios/project.yml`。
- 真机：自己的 Apple 签名团队。模拟器试用不等于真机推送/短信验收。

下载源码后从仓库根目录执行后端命令。以下库和凭据文件必须是**新路径**：

```sh
umask 077
python3 -B backend/server.py --db .data/local-demo.sqlite3 \
  init --credentials .secrets/local-demo.json
```

会创建一个工作区以及 `user`（admin）、`leader`、`worker-b`、`worker-c`。成员显示名可改，稳定 ID 用于接口。工作区 ID 自动生成，不是从某个公开示例复制来的固定值。凭据文件是 0600；初始化命令不输出 Token。

该命令用于新的试用实例；重复使用同一凭据路径会停止，已有成员的库不能重新 init。不要删除真实数据库或凭据来“修复初始化”。

## 2. 启动回环 API

```sh
python3 -B backend/server.py --db .data/local-demo.sqlite3 \
  serve --port 8766 --check-seconds 60
```

服务绑定 `127.0.0.1`。另一个终端执行：

```sh
curl --fail --silent --show-error http://127.0.0.1:8766/healthz
```

默认不启用匿名状态端点。`--public-watch` 是明确选择公开计数/游标，不是给成员正文 API 免认证。详见 [AI 接入](api.md)。

普通服务启动会检查/迁移自身库，并清空重启前的在线验证码。不要为了只读检查数据库而实例化 `Store`；已有生产实例升级先备份、演练。

## 3. 在可信本机核对身份

下面示例只读取本轮生成的**本地试用**凭据，把 Token 放进 HTTP 头；输出身份和工作区，不输出 Token：

```sh
python3 - <<'PY'
import json, pathlib, urllib.request
credentials = json.loads(pathlib.Path('.secrets/local-demo.json').read_text())
request = urllib.request.Request(
    'http://127.0.0.1:8766/v1/snapshot',
    headers={'Authorization': 'Bearer ' + credentials['user']['token']})
with urllib.request.urlopen(request, timeout=10) as response:
    snapshot = json.load(response)
print({'memberId': snapshot['me']['id'],
       'role': snapshot['me']['role'],
       'workspaceId': snapshot['workspaceId']})
PY
```

匿名读取 `/v1/snapshot` 应返回 401。真实服务的凭据请放保管库，不发送到 issue、聊天、截图或终端录屏。

## 4. 添加自己的 AI 成员

```sh
python3 -B backend/server.py --db .data/local-demo.sqlite3 \
  add-member worker-design 'Design Worker' --role worker \
  --credentials .secrets/worker-design.json
```

`--credentials` 必须是新的私有文件，已有成员 ID 不会被覆盖。ID 格式是 `[a-z][a-z0-9_-]{0,47}`；名字不是凭证。此 CLI 不启动 AI。也可由用户账号在 App/成员 API 添加成员。

## 5. iPhone / Watch / Widget

1. 建立自己的 Bundle IDs 与 App Group。将工程设置、entitlements 和共享代码中的 App Group 一起改成自己团队可用的标识，主 App、Widget、Watch 及 Keychain 名字需一致。
2. 创建忽略提交的 `ios/LocalSigning.xcconfig`：

   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   ```

3. 生成工程：

   ```sh
   xcodegen generate --spec ios/project.yml
   open ios/CollabDesk.xcodeproj
   ```

4. Xcode 选择 CollabDesk scheme 和自己的目标设备，检查所有 targets 的 Signing & Capabilities。真机需要可用的 App Groups / Push Notifications 描述文件，不借用其他 App 的身份。
5. 模拟器可先看演示数据。连接真实服务时，在 App 的连接设置使用**用户 admin**凭据、自己的 HTTPS origin；AI 用各自成员凭据。
6. 演示数据不会合并到真实服务；覆盖安装与清除 App 数据是不同操作，正常更新不要为了重连删除 App。

手机的 `127.0.0.1` 指手机自身，不是 Mac。后端故意只监听回环；真机远程连接应完成 [HTTPS 部署](deployment.md)，不要把 Python 开发服务改成公网裸 HTTP。

## 6. 测试与停止

```sh
python3 -B -m unittest discover -s backend -p 'test_*.py'
python3 -B -m unittest discover -s clients -p 'test_*.py'
```

Xcode 选择测试 scheme/模拟器后运行 Test。Xcode 的设备列表因本机而异，不把别人的模拟器 UUID 复制进命令。

本地终端 `Ctrl-C` 停服务。试用库和凭据都留在私有目录，已验证不再需要时再自行清理；这些文件不属于源码发布材料。
