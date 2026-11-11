<?php
/**
 * 兜鱼复刻版 · 授权服务配置
 *
 * 部署时把本文件复制成 config.local.php 再改，或直接改这里。
 * 生产环境务必：
 *   1. 关闭 app.debug
 *   2. 把 keys/ 目录放到 webroot 之外（或确保 Web 服务器禁止访问 keys/）
 *   3. 用 HTTPS（客户端会拒绝 http:// 之外的授权地址）
 */

$config = [
    'app' => [
        'name'          => 'DOUY License',
        'base_url'      => 'https://example.com',   // 对外地址，用于拼 download_url / qr 校验
        'debug'         => false,
        'timezone'      => 'Asia/Shanghai',
        'max_body'      => 65536,                    // 请求体上限 64 KB
        'clock_skew_ms' => 300000,                   // 签名时间允许偏差 ±5 分钟
        'strict_device_id' => false,                 // true 则强校验 device_id == sha256(pubkey)[0:40]
    ],

    'db' => [
        'dsn'      => 'mysql:host=127.0.0.1;port=3306;dbname=douy_license;charset=utf8mb4',
        'user'     => 'root',
        'password' => 'root',
        'options'  => [],
    ],

    'paths' => [
        'keys'     => __DIR__ . '/keys',            // 服务端签名私钥
        'storage'  => __DIR__ . '/storage',         // 上传的 dylib 等
        'updates'  => __DIR__ . '/storage/updates',
    ],

    'license' => [
        'lease_ttl_ms'          => 90000,   // 原版："已有短期授权最迟 90 秒失效"
        'session_ttl_ms'        => 86400000,
        'challenge_ttl_ms'      => 60000,
        'card_prefix'           => 'DOUY',
        'download_daily_limit'  => 5,       // 每张卡每天可下载次数
        'download_token_ttl_ms' => 86400000,
        'max_sessions_per_account' => 8,
        'signal_aud_license'    => 'douy-ios-hook',
        'signal_aud_update'     => 'douy-ios-plugin-update',
        'automatic_renewal'     => true,    // 到期自动续用备用卡
        'auto_promote_standby'  => true,    // 卡包里的备用卡在有绑定时不自动生效

        /*
         * 插件代码哈希防篡改：
         *   false（默认）—— 哈希变化时只记审计并自动更新，正常发版/热更新不会被误杀；
         *   true         —— 哈希变化直接拒绝（IOS_MODULE_CHANGED），适合正式发布后开启。
         */
        'strict_module_check'   => false,
    ],
];

// 本地覆盖（不入库）：config.local.php 返回一个数组，做递归合并
$localFile = __DIR__ . '/config.local.php';
if (is_file($localFile)) {
    $local = require $localFile;
    if (is_array($local)) {
        $merge = function (array $a, array $b) use (&$merge) {
            foreach ($b as $k => $v) {
                if (isset($a[$k]) && is_array($a[$k]) && is_array($v)) {
                    $a[$k] = $merge($a[$k], $v);
                } else {
                    $a[$k] = $v;
                }
            }
            return $a;
        };
        $config = $merge($config, $local);
    }
}

return $config;
