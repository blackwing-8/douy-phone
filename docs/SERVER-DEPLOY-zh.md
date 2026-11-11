# 授权服务部署手册（PHP + MySQL）

目标：把这套 `server/` 部署到你的服务器，让 iOS 插件能登录/激活/续租/更新。

---

## 1. 环境要求

| 项 | 最低 | 说明 |
|---|---|---|
| PHP | **7.3+**（推荐 8.1/8.2） | 需要 `openssl`、`pdo_mysql`、`curl`、`json`、`mbstring` |
| MySQL | 5.7+ / MariaDB 10.3+ | utf8mb4 |
| Web 服务器 | Apache 2.4 / Nginx / Caddy | 必须 **HTTPS**（iOS 端会拒绝 http） |
| 磁盘 | < 50 MB | 插件 dylib 约 200 KB/版本 |

检查扩展：

```bash
php -m | grep -E 'openssl|pdo_mysql|curl|json|mbstring'
```

---

## 2. 目录结构

```
server/
├── config.php            # 主配置（数据库、base_url、租约时长…）
├── config.local.php      # 本地/生产覆盖（不要提交）
├── app/
│   ├── bootstrap.php     # 启动、工具函数、openssl.cnf 兼容
│   ├── Http.php          # 响应与异常
│   ├── Db.php            # PDO 封装
│   ├── Crypto.php        # 验签/签名（ECDSA P-256、Ed25519）
│   ├── Proof.php         # douy-ios-proof-v1 校验、限流
│   ├── Auth.php          # 会话
│   ├── LicenseService.php# 卡密/计时/租约/自动续用
│   ├── Controllers.php   # 4 组接口
│   └── schema.sql        # 18 张表
├── public/               # ← Web 根目录
│   ├── index.php         # 路由
│   └── .htaccess
├── bin/douyctl.php         # 管理 CLI
├── keys/                 # 服务端签名私钥（必须在 webroot 之外！）
├── storage/              # 上传的 dylib、日志
└── tools/
    ├── smoke.php         # 接口冒烟（29 项）
    └── smoke2.php        # 到账发卡 + 更新下载（19 项）
```

---

## 3. 五步上线

### 3.1 建库 + 导表

```bash
mysql -uroot -p -e "CREATE DATABASE douy_license CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
mysql -uroot -p douy_license < server/app/schema.sql
```

或者先配好 `config.php` 再执行：

```bash
php server/bin/douyctl.php db:init
```

### 3.2 改配置

编辑 `server/config.php`（或新建 `server/config.local.php` 覆盖）：

```php
return [
    'app' => [
        'base_url' => 'https://license.your-domain.com',  // 用于拼 download_url
        'debug'    => false,                              // 生产必须 false
    ],
    'db' => [
        'dsn'      => 'mysql:host=127.0.0.1;port=3306;dbname=douy_license;charset=utf8mb4',
        'user'     => 'fx',
        'password' => '强密码',
    ],
];
```

### 3.3 生成服务端签名密钥（**只做一次**）

```bash
php server/bin/douyctl.php key:gen
```

输出：

```
已生成服务端签名密钥
  私钥: /path/server/keys/server_ec_private.pem   （务必放在 webroot 之外！）
  公钥(base64 SPKI):
  MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
```

**把公钥填进 iOS 端**：`ios/DOUYTweak/src/FXLicense.mm`

```objc
static NSString *const kFXServerPublicKeyECDSA = @"<这里粘贴>";
```

> 私钥丢了 = 所有已发出的授权凭证都没法再签新的（客户端会验不过）；
> 私钥泄露 = 别人能伪造授权凭证。建议 `chmod 600`，并纳入备份。

### 3.4 配 Web 服务器

**Apache**（站点根指向 `server/public`）：

```apache
<VirtualHost *:443>
    ServerName license.your-domain.com
    DocumentRoot /var/www/fx/server/public
    SSLEngine on
    SSLCertificateFile    /etc/ssl/fullchain.pem
    SSLCertificateKeyFile /etc/ssl/privkey.pem

    <Directory /var/www/fx/server/public>
        AllowOverride All
        Require all granted
    </Directory>

    # 就算配置错了也不要把 keys/ 暴露出去
    <Directory /var/www/fx/server/keys>
        Require all denied
    </Directory>
</VirtualHost>
```

**Nginx + PHP-FPM**：

```nginx
server {
    listen 443 ssl;
    server_name license.your-domain.com;
    root /var/www/fx/server/public;
    index index.php;

    location / {
        try_files $uri /index.php?$query_string;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
    location ~ ^/\.(git|env) { deny all; }
}
```

**本机测试（最快）**：

```bash
cd server
php -S 127.0.0.1:8080 -t public public/index.php
```

### 3.5 目录权限

```bash
chmod 700 server/keys
chmod 600 server/keys/server_ec_private.pem
chmod 775 server/storage
```

---

## 4. 日常运营（全部用 `bin/douyctl.php`）

```bash
# 套餐（收款码必须 https://）
php bin/douyctl.php plan:add --days=30 --price=68 --qr=https://cdn.x.com/qr30.png --title="30 天"
php bin/douyctl.php plan:list

# 批量生成卡密（会打印明文卡密，请保存好）
php bin/douyctl.php card:new --days=30 --count=20 --note="2026-11 首批"
php bin/douyctl.php card:list --status=unused --limit=50
php bin/douyctl.php card:revoke --key=DOUY-XXXX-XXXX-XXXX

# 用户扫码付款后 → 按备注码核对 → 确认到账自动发卡进卡包
php bin/douyctl.php order:pay --id=1001 --note="微信 68 元 2026-11-10"
php bin/douyctl.php account:list
php bin/douyctl.php account:disable --username=abc_01

# 封禁/解封设备
php bin/douyctl.php device:list
php bin/douyctl.php device:block --device-id=64b6961a2934c5b4e4e1d64fa2e0622f6e0fdee0
php bin/douyctl.php device:block --device-id=... --unblock

# 发布插件更新（version_code 必须递增）
php bin/douyctl.php update:publish \
    --file=./DOUY.dylib \
    --version-code=59 --version-name=0.1.9 \
    --channel=stable \
    --changelog="修复 USB 重连；优化旋转"
```

---

## 5. 自测（部署完必跑）

```bash
# 终端 A
php -S 127.0.0.1:8080 -t public public/index.php

# 终端 B（29 项：注册/设备签名/登录挑战/激活/租约/负例）
php tools/smoke.php DOUY-XXXX-XXXX-XXXX

# 终端 C（19 项：到账发卡/更新发布/下载配额/防篡改）
php tools/smoke2.php
```

本机实测输出（PHP 7.3.4 + MySQL 5.7.26）：

```
PASS: 29   FAIL: 0
PASS: 19   FAIL: 0
```

---

## 6. iOS 端配置

1. 改 `FXLicense.mm` 里的 `kFXServerPublicKeyECDSA`（§3.3 的公钥）。
2. 改默认服务地址（或运行时用 `NSUserDefaults` 的 `FXLicenseBaseURL` 覆盖，方便测试）：

```objc
static NSString *const kFXDefaultBaseURL = @"https://license.your-domain.com";
```

3. App 里第一次运行会 `device/register`，把 `device_id + 公钥` 落到 `douy_devices`。
4. 浮窗底部「账号与卡包」→ 登录 → 粘贴卡密 → 激活并绑定本机。
5. 之后每 60 秒自动续租（服务端租约 90 秒）；断网时用本地缓存凭证，
   到期或服务端判失败就自动恢复真实摄像头。

---

## 7. 安全清单

- [ ] `keys/`、`config.local.php`、`storage/` 不在 webroot 内（或 Web 层 deny）
- [ ] 全站 HTTPS，`certbot renew` 已配
- [ ] `app.debug = false`
- [ ] 数据库账号只授权 `douy_license` 库，禁用 `FILE`/`PROCESS`
- [ ] 定期清理：`DELETE FROM douy_nonces WHERE created_at_ms < ?`（接口里已自动清）
- [ ] `douy_audit_log` 保留 90 天足够排查
- [ ] 备份：`mysqldump douy_license` + `keys/` 私有目录（**备份里必须包含私钥，否则换机后无法续签**）
- [ ] 下载配额/登录限流阈值可按需在 `config.php` 里调

---

## 8. 常见问题

| 现象 | 原因/处理 |
|---|---|
| `openssl 生成 EC 密钥失败: system library:fopen:No such process` | Windows PHP 找不到 `openssl.cnf`；`douyctl key:gen` 已自动带 `config` 参数，若仍失败就手工设环境变量 `OPENSSL_CONF=<php>/extras/ssl/openssl.cnf` |
| 客户端一直 `IOS_LOCAL_IDENTITY_INVALID` | 服务端没存到设备公钥（先调 `device/register`），或客户端公钥与服务端 `kFXServerPublicKeyECDSA` 不配对 |
| 一直 `IOS_REQUEST_INVALID`（时间偏差） | 手机时间不准，或服务端时区/时钟漂移（允许 ±5 分钟） |
| 一直 `IOS_SESSION_BUSY` | nonce 重复：设备时钟回拨或重放了请求 |
| `IOS_MODULE_CHANGED` | 客户端上报的 `module_text_sha256` 变了（重新打包过插件）。清 `douy_devices.module_hash` 即可重新绑定 |
| 下载 403/404 | `storage/updates/` 里文件被删，或 `sha256` 与库记录不一致（会直接拒绝） |
| iOS 报 `无法生成安全请求` | Secure Enclave 不可用且 Keychain 被清（卸载重装会丢密钥 → 需要重新登录/激活） |
