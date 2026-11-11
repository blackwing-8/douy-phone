<?php
/**
 * 生产环境配置覆盖（模板）
 *
 * 用法（服务器上）：
 *   cp config.local.example.php config.local.php
 *   然后按下面注释改 base_url 和 db
 *
 * 注意：config.local.php 已在 .gitignore 里，不会被提交；
 *      但如果你打包上传时带上了本地那份（指向 127.0.0.1:3307），
 *      它会覆盖 config.php，导致连不上数据库 —— 部署前请确认服务器上的
 *      config.local.php 只有下面这份内容。
 */

return [
    'app' => [
        // 对外访问地址，用于拼插件下载链接；必须是 https
        'base_url' => 'https://你的域名',

        // 生产必须 false（出错只返回统一错误码，不泄漏堆栈）
        'debug' => false,

        // 正式环境不要开这个（本机回环跳过限流，只给本地测试用）
        'skip_rate_limit_for_loopback' => false,
    ],

    'db' => [
        // 宝塔建库后把这三个值换成它给的
        'dsn'      => 'mysql:host=127.0.0.1;port=3306;dbname=douy_license;charset=utf8mb4',
        'user'     => 'douy_license',
        'password' => '把这里换成你的数据库密码',
    ],
];
