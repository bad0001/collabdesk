# 通用自托管部署

本说明针对一个**全新的、独立的 Linux 实例**，不导入任何现有用户数据。使用自己的域名、服务账户、签名身份和秘密；仓库不分发已上线数据库、推送私钥、备份或现场迁移控制器。

## 架构与边界

```text
Client ── HTTPS :443 ── nginx ── HTTP 127.0.0.1:8766 ── Python + SQLite
```

后端只绑定回环。仅开放所需 HTTPS/管理入口，数据库目录不由 nginx 静态托管。采用**一个后端进程**：验证码及去重数据在进程 RAM，不支持多个独立进程分摊请求。不要直接给它增加多 worker gunicorn、负载均衡副本或无共享内存的滚动部署。

## 1. 独立路径

建议布局（示例，不是必须的路径）：

```text
/opt/collabdesk/current/             只读源码，root 管理
/var/lib/collabdesk/collab.sqlite3   服务账户600
/var/lib/collabdesk/backups/         服务账户700
/etc/collabdesk/                     私有运行配置/可选APNs材料
```

创建非登录服务账户，安装 Python 3.10+。若启用 APNs，另准备 OpenSSL 和支持 HTTP/2 的 curl；用 `curl --version` 确认 HTTP2 功能。服务账户只能写自己的数据库目录，不能写源码、nginx 配置、其他站点或 systemd unit。

复制经审查的源码到独立路径。只对全新的库用初始化 CLI；初始凭据文件放私有路径，经保管库交接后由管理员妥善保管，不要把它放到 Web 根目录。

## 2. systemd 样板

保存自己的 unit，例如 `/etc/systemd/system/collabdesk.service`。示例需按真实路径/账户调整：

```ini
[Unit]
Description=CollabDesk collaboration API
After=network.target

[Service]
Type=simple
User=collabdesk
Group=collabdesk
WorkingDirectory=/opt/collabdesk/current
ExecStart=/usr/bin/python3 -B backend/server.py --db /var/lib/collabdesk/collab.sqlite3 serve --port 8766 --check-seconds 60
EnvironmentFile=-/etc/collabdesk/runtime.env
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/collabdesk
CapabilityBoundingSet=
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
```

不要把其他项目的 unit/drop-in 覆盖掉。检查自己 unit 后再 `systemctl daemon-reload`、启用并启动**自己的**服务。启动后检查回环 `/healthz`、匿名业务 401，以及原成员身份。硬件资源限额按实际负载设定，本仓库不提供已压测的吞吐上限。

匿名哨兵默认关闭。需要它时，运行配置可显式设置 `COLLABDESK_PUBLIC_WATCH=1`，并先阅读 [隐私边界](security.md)；这会公开工作量及更新时序，不只是一段本机配置。

## 3. HTTPS 网关样板

域名和证书示例使用保留域 `collab.example.com`，必须换成自己的。先用自己的 ACME/证书流程取得可信 TLS 证书，再启用 HTTPS；不在拿不到证书时关闭客户端证书验证。

以下 zone/log_format 放在 nginx **http** 上下文，别重复定义：

```nginx
limit_req_zone $binary_remote_addr zone=collab_api:10m rate=10r/s;
log_format collab_minimal '$time_iso8601 $request_method $status $request_time';
```

独立站点示例：

```nginx
server {
    listen 80;
    server_name collab.example.com;
    return 308 https://collab.example.com$request_uri;
}
server {
    listen 443 ssl;
    server_name collab.example.com;
    ssl_certificate /etc/ssl/collabdesk/fullchain.pem;
    ssl_certificate_key /etc/ssl/collabdesk/privkey.pem;
    client_max_body_size 64k;
    access_log /var/log/nginx/collabdesk-access.log collab_minimal;
    error_log /var/log/nginx/collabdesk-error.log warn;
    location / {
        limit_req zone=collab_api burst=20 nodelay;
        proxy_pass http://127.0.0.1:8766;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 5s;
        proxy_read_timeout 25s;
        proxy_send_timeout 25s;
        proxy_cache off;
        add_header Cache-Control "no-store" always;
    }
}
```

示例省略请求体、Authorization、Cookie 和查询参数日志。也检查上游 CDN/WAF/托管平台的日志策略。位于其他代理后面时，仅信任明确配置的代理地址；不要无条件相信客户端的 X-Forwarded-For。

用 `nginx -t` 检查，再 reload。防火墙不要开放 8766。保留现有站点，使用独立 `server_name`；不修改无关域名的 DNS/A/AAAA 记录。

后端本身提供 REST，不提供用户浏览器登录的完整 Web SPA。iPhone 是用户客户端；可静态托管通用 Markdown 指南，指南里没有密钥，也不会自动给 AI 接入权限。

### 可选：仅白名单公开指南

发行源码中的 `public/guide/` 是经审查的通用Markdown镜像。需要App分享在线手册时，给自己的HTTPS server增加以下**正则白名单**location，放在API的通用代理配置旁；不把整个源码、数据库或私有目录设为Web根：

```nginx
location = /guide/PUSH-SETUP.md {
    rewrite ^ /guide/push-setup.md last;
}
location ~ ^/guide/(api|leader|worker|platform|user-inbox|sms-code-import|watch|push-setup|PUSH-SETUP|security|contributing|getting-started|deployment|ios)\.md$ {
    root /opt/collabdesk/current/public;
    try_files $uri =404;
    default_type text/markdown;
    add_header X-Content-Type-Options nosniff always;
    autoindex off;
}
```

这里的 `root` 与 `/guide/文件.md` 组合只读取 `public/guide/白名单文件.md`。其他路径仍进入认证API或404；不开放credentials、backups、logs、verification、数据库或任意下载目录。镜像链接采用同目录slug，不指向作者机器或私人部署。修改自己的模板前先确认source release确实包含这些通用页，再 `nginx -t` / reload。

Git在大小写不敏感的工作目录中应只保留规范 `push-setup.md`；上面的内部rewrite兼容旧 `PUSH-SETUP.md` URL，不要求同一目录跟踪两个仅大小写不同的文件。

## 4. 上线验收

分开检查：DNS → 证书/SNI → 网关 → API认证 → 业务权限。只读检查至少包括：

- `/healthz`：200；异常维护线程正常。
- 匿名 `/v1/snapshot`：401。
- 各成员 `/v1/snapshot`：自己的 member ID/role/workspace，Worker 不看到他人的私有任务。
- `/v1/updates`：初次及下一次增量；状态缓存绑定 origin/工作区/成员。
- 可选 `/v1/watch`：未开启404；开启后只公开规定的计数与游标。
- 可选 APNs：配置就绪、Apple接受、手机显示分别验证。

不要向真实库写演示任务来冒充上线测试。失败时保留 HTTP状态、UTC时间、耗时与错误阶段，不保存凭据或验证码；代理错误不能直接等同于服务宕机。

## 5. 备份与升级

内置维护线程约每24小时创建数据库邻近的私有在线备份，保留14份，并核验 SQLite integrity。它是**本机备份**，不等于异地备份或灾难恢复。

另行设置加密、访问受限的异地备份。SQLite 库包含业务历史及设备标识，自动输入的验证码数字不在库内，但仍应视为私有数据。恢复演练在隔离新路径进行；不要把生产库复制到公开测试或 issue。

升级前：一致备份 → 新库副本演练迁移 → 版本/权限/原历史核验 → 更新自己的源码 → 只重启自己的服务。源码回退不能恢复旧数据库覆盖升级后的新写入。旧版本是否接受当前 schema，需事先演练；不可假定任意旧 Git commit 都能直接运行。

任何服务重启都会清空 RAM 中的验证码和去重状态。安排维护时告知用户，必要时获取新码；不把验证码加入持久化恢复文件。
