================================================================
 DOUY 兜鱼 · 授权服务 部署包（宝塔 / Nginx / Apache 通用）
================================================================

本包 = server/ 目录内容（已剔除 keys/、storage/、config.local.php）

----------------------------------------------------------------
第 1 步：建库
----------------------------------------------------------------
宝塔 → 数据库 → 添加数据库
  数据库名 : douy_license
  字符集   : utf8mb4
  用户名/密码：记下来，第 3 步要用
（或在终端执行：
  mysql -uroot -p -e "CREATE DATABASE douy_license CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"）

----------------------------------------------------------------
第 2 步：上传 + 解压
----------------------------------------------------------------
宝塔 → 文件 → 进入站点根目录（/www/wwwroot/你的域名/）
上传本 zip → 右键解压 → 把 server 里的内容放到站点根目录，
要求最终结构是：

  站点根/
    config.php
    app/            ← schema.sql、Controllers.php ...
    bin/            ← douyctl.php
    public/         ← index.php、.htaccess
    tools/          ← smoke.php、smoke2.php
    keys/           ← 空目录即可（第 5 步会生成）
    storage/        ← 空目录即可（需可写）

----------------------------------------------------------------
第 3 步：宝塔站点配置（三处，缺一不可）
----------------------------------------------------------------
① 网站 → 设置 → 网站目录 → **运行目录 选 public**（不做会 404）
② 网站 → 设置 → 伪静态 → 选「自定义」，粘：

   location / {
       try_files $uri /index.php?$query_string;
   }

③ 网站 → 设置 → SSL → Let's Encrypt 申请证书 → 打开「强制 HTTPS」

   （Apache 用户：把 DocumentRoot 指到 public，AllowOverride All，
     .htaccess 自带重写规则）

   ⚠️ 顺便检查：网站目录 → 「防跨站攻击(open_basedir)」如果是开启的，
      请关闭，否则 PHP 读不到 keys/ 与 storage/

----------------------------------------------------------------
第 4 步：配置数据库（复制模板改三处）
----------------------------------------------------------------
   cd /www/wwwroot/你的域名
   cp config.local.example.php config.local.php

   编辑 config.local.php：
     base_url → https://你的域名
     dsn/user/password → 第 1 步宝塔给的值

   ⚠️ 如果本地打包时带上了 config.local.php（指向 127.0.0.1:3307），
      一定要删掉它，否则会覆盖这里的配置。

----------------------------------------------------------------
第 5 步：建表 + 生成签名密钥 + 造卡（终端里跑）
----------------------------------------------------------------
   cd /www/wwwroot/你的域名

   php bin/douyctl.php db:init                 # 建 18 张表
   php bin/douyctl.php key:gen                 # ← 记下输出的公钥！
   php bin/douyctl.php plan:add --days=30 --price=68 \
        --qr=https://你的域名/qr/30.png --title="30 天"
   php bin/douyctl.php card:new --days=30 --count=10

   权限：
     chmod 700 keys && chmod 600 keys/*.pem
     chmod -R 775 storage && chown -R www:www storage keys

   ⚠️ key:gen 输出的那串 MFkw...== 必须粘到 iOS 端：
      ios/DOUYTweak/src/FXLicense.mm 的 kFXServerPublicKeyECDSA
      否则客户端一定报「授权签名或绑定验证失败」

----------------------------------------------------------------
第 6 步：验证
----------------------------------------------------------------
浏览器打开：
   https://你的域名/health
   期望：{"success":true,"code":"OK","message":"DOUY license server",...}

终端跑冒烟：
   php tools/smoke.php DOUY-XXXX-XXXX-XXXX     # 期望 PASS: 31  FAIL: 0
   php tools/smoke2.php                        # 期望 PASS: 19  FAIL: 0

   注意：smoke2.php 用到 exec()，宝塔默认禁用。
   如果报「exec has been disabled」，二选一：
     a) 宝塔 → 软件商店 → PHP 设置 → 禁用函数 → 删掉 exec（测试完再恢复）
     b) 跳过 smoke2，改手工验证：后台 card:new 造卡 → 客户端激活看看

----------------------------------------------------------------
常见问题
----------------------------------------------------------------
- 404 / 空白页         → 运行目录没选 public，或伪静态没配
- 500 且 app.log 有 openssl 错 → keys/ 权限不对，或没执行 key:gen
- 「无法连接数据库」    → config.local.php 里 dsn/账号密码不对
- 客户端「本机签名失败」 → 服务端没存到设备公钥（先调 device/register，客户端会自动）
- 客户端「授权签名或绑定验证失败」→ iOS 里的公钥和服务端 keys/ 不配对
- 「设备时间与服务端偏差过大」→ 检查服务器时区（config.php 里 Asia/Shanghai）与客户端时间
- 下载 404               → base_url 没改成你的域名

----------------------------------------------------------------
安全清单（上线前逐条确认）
----------------------------------------------------------------
[ ] keys/ 与 storage/ 不在 public 下（本包结构已满足）
[ ] app.debug = false
[ ] 全站 HTTPS，已开强制跳转
[ ] 数据库账号只授权 douy_license 库
[ ] 备份：mysqldump douy_license + keys/server_ec_private.pem（私钥丢了所有已发凭证无法续签）
[ ] config.local.php 权限 600
