<?php
/**
 * 兜鱼复刻版 · 服务端管理 CLI
 *
 * 用法（在 server/ 目录下）：
 *   php bin/douyctl.php db:init                    初始化表结构
 *   php bin/douyctl.php key:gen                    生成服务端签名密钥（ECDSA P-256）
 *   php bin/douyctl.php key:show                   打印服务端公钥（要内置到 iOS 客户端）
 *   php bin/douyctl.php plan:list                  套餐列表
 *   php bin/douyctl.php plan:add --days=30 --price=68 --qr=https://... --title="30 天"
 *   php bin/douyctl.php card:new --days=30 --count=10 --note="首批"
 *   php bin/douyctl.php card:list [--status=unused] [--limit=50]
 *   php bin/douyctl.php card:revoke --key=DOUY-XXXX-XXXX-XXXX
 *   php bin/douyctl.php order:pay --id=1           确认到账并发卡进卡包
 *   php bin/douyctl.php update:publish --file=/path/DOUY.dylib --version-name=0.1.9 --version-code=59
 *   php bin/douyctl.php device:list
 *   php bin/douyctl.php device:block --device-id=xxxx [--unblock]
 *   php bin/douyctl.php account:list
 *   php bin/douyctl.php account:disable --username=abc_01 [--enable]
 */

if (PHP_SAPI !== 'cli') {
    fwrite(STDERR, "只允许 CLI 运行\n");
    exit(1);
}

require dirname(__DIR__) . '/app/bootstrap.php';

/** 解析 --key=value / --flag */
function cli_args(array $argv)
{
    $out = [];
    foreach (array_slice($argv, 2) as $arg) {
        if (strpos($arg, '--') !== 0) {
            continue;
        }
        $arg = substr($arg, 2);
        if (strpos($arg, '=') !== false) {
            list($k, $v) = explode('=', $arg, 2);
            $out[$k] = $v;
        } else {
            $out[$arg] = true;
        }
    }
    return $out;
}

function out($text = '')
{
    fwrite(STDOUT, $text . PHP_EOL);
}

function fail($text)
{
    fwrite(STDERR, "[错误] " . $text . PHP_EOL);
    exit(1);
}

$command = isset($argv[1]) ? $argv[1] : 'help';
$args = cli_args($argv);

try {
    $db = douy_db($config);
} catch (Throwable $e) {
    fail('数据库连接失败：' . $e->getMessage() . "\n请检查 server/config.php 里的 db.dsn / user / password");
}

switch ($command) {
    case 'help':
    case '--help':
        out("兜鱼复刻版 · 服务端管理 CLI");
        out("");
        out("  db:init                                 初始化数据库表结构");
        out("  key:gen                                 生成服务端签名密钥（ECDSA P-256）");
        out("  key:show                                打印服务端公钥（内置到 iOS 客户端）");
        out("  plan:list / plan:add                    套餐");
        out("  card:new --days=30 --count=10           批量生成卡密");
        out("  card:list [--status=] [--limit=]         卡密列表");
        out("  card:revoke --key=...                   吊销卡密");
        out("  order:pay --id=1                        确认到账并发卡");
        out("  update:publish --file=... --version-code=59 --version-name=0.1.9");
        out("  device:list / device:block --device-id=... [--unblock]");
        out("  account:list / account:disable --username=... [--enable]");
        break;

    // ------------------------------------------------------------ 数据库
    case 'db:init':
    case 'db:reset':
        $sql = file_get_contents(__DIR__ . '/../app/schema.sql');
        if ($sql === false) {
            fail('找不到 app/schema.sql');
        }
        // 去掉行注释再按分号切分（schema 里没有存储过程/触发器，够用）
        $sql = preg_replace('/^\s*--.*$/m', '', $sql);
        $statements = array_filter(array_map('trim', explode(';', $sql)));
        $n = 0;
        foreach ($statements as $stmt) {
            if ($stmt === '') {
                continue;
            }
            try {
                $db->pdo()->exec($stmt);
                $n++;
            } catch (Throwable $e) {
                out("  跳过/失败: " . substr(preg_replace('/\s+/', ' ', $stmt), 0, 60) . ' … ' . $e->getMessage());
            }
        }
        out("db:init 完成，执行了 {$n} 条语句");
        $tables = $db->all('SHOW TABLES');
        out('当前表数量: ' . count($tables));
        break;

    // ------------------------------------------------------------ 密钥
    case 'key:gen':
        $kid = 'ec-p256-1';
        $existing = $db->one('SELECT * FROM douy_server_keys WHERE kid = ?', [$kid]);
        if ($existing !== null && empty($args['force'])) {
            fail('已存在 ' . $kid . '，如需重新生成请加 --force（会让所有旧签名失效）');
        }

        $keysDir = rtrim($config['paths']['keys'], '/\\');
        if (!is_dir($keysDir) && !@mkdir($keysDir, 0700, true)) {
            fail('无法创建密钥目录: ' . $keysDir);
        }

        $options = [
            'private_key_type' => OPENSSL_KEYTYPE_EC,
            'curve_name'       => 'prime256v1',
            'digest_alg'       => 'sha256',
        ];
        // Windows 的 PHP 找不到 openssl.cnf 时 openssl_pkey_new 会报
        // "system library:fopen:No such process"；显式传 config 最可靠。
        if (DIRECTORY_SEPARATOR === '\\') {
            $candidates = [
                dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . 'extras' . DIRECTORY_SEPARATOR . 'ssl' . DIRECTORY_SEPARATOR . 'openssl.cnf',
                dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . 'extras' . DIRECTORY_SEPARATOR . 'openssl.cnf',
                dirname(PHP_BINARY) . DIRECTORY_SEPARATOR . 'openssl.cnf',
            ];
            foreach ($candidates as $cnf) {
                if (is_file($cnf)) {
                    $options['config'] = $cnf;
                    break;
                }
            }
        }

        $res = openssl_pkey_new($options);
        if ($res === false) {
            fail('openssl 生成 EC 密钥失败: ' . openssl_error_string());
        }
        // 导出也必须带 config，否则 EC 私钥导不出来（Windows 上会静默失败）
        if (!openssl_pkey_export($res, $pem, null, $options) || empty($pem)) {
            fail('导出私钥失败: ' . openssl_error_string());
        }
        $details = openssl_pkey_get_details($res);
        if (!isset($details['ec']['x']) || !isset($details['ec']['y'])) {
            fail('无法导出 EC 公钥坐标');
        }

        // 未压缩点 65 字节 → 再包成 SPKI DER（与 openssl 导出的 PEM 一致）
        $pubPem = $details['key'];
        $derB64 = preg_replace('/-----[^-]+-----/', '', $pubPem);
        $derB64 = preg_replace('/\s+/', '', $derB64);

        $privPath = $keysDir . DIRECTORY_SEPARATOR . 'server_ec_private.pem';
        if (file_put_contents($privPath, $pem) === false) {
            fail('写入私钥失败: ' . $privPath);
        }
        @chmod($privPath, 0600);

        /*
         * 以 root 跑 key:gen 时，私钥属主是 root、权限 600，而 php-fpm 一般跑在
         * www / www-data 下 → Web 请求读不到，表现为接口 500（"服务端私钥无法载入"）。
         * 这里顺手把属主交给 Web 用户，避免这个坑。
         */
        if (function_exists('posix_geteuid') && posix_geteuid() === 0 && function_exists('posix_getpwnam')) {
            foreach (['www', 'www-data', 'nginx', 'apache', 'httpd'] as $candidate) {
                if (posix_getpwnam($candidate) !== false) {
                    @chown($privPath, $candidate);
                    @chgrp($privPath, $candidate);
                    out('  已把私钥属主改为 ' . $candidate . '（php-fpm 需要可读）');
                    break;
                }
            }
        }

        $db->exec('UPDATE douy_server_keys SET active = 0 WHERE kid = ?', [$kid]);
        $db->q(
            'INSERT INTO douy_server_keys (kid, alg, public_key, private_path, active) VALUES (?,?,?,?,1)
             ON DUPLICATE KEY UPDATE public_key = VALUES(public_key), private_path = VALUES(private_path), active = 1',
            [$kid, 'ES256', $derB64, $privPath]
        );

        out('已生成服务端签名密钥');
        out('  私钥: ' . $privPath . '   （务必放在 webroot 之外！）');
        out('  公钥(base64 SPKI):');
        out('  ' . $derB64);
        out('');
        out('把上面这串公钥填到 iOS 端 FXLicense.mm 的 kFXServerPublicKeyECDSA 里。');
        break;

    case 'key:show':
        $row = $db->one('SELECT * FROM douy_server_keys WHERE active = 1 ORDER BY created_at DESC LIMIT 1');
        if ($row === null) {
            fail('还没有服务端密钥，请先 key:gen');
        }
        out('kid: ' . $row['kid'] . '  alg: ' . $row['alg']);
        out('public_key:');
        out($row['public_key']);
        break;

    // ------------------------------------------------------------ 套餐
    case 'plan:list':
        foreach ($db->all('SELECT * FROM douy_plans ORDER BY sort_order, days_valid') as $r) {
            out(sprintf('#%-4d %-6s %4d天  ¥%-8s %s  active=%d',
                $r['id'], $r['title'], $r['days_valid'], $r['price'], $r['qr_code_url'], $r['active']));
        }
        break;

    case 'plan:add':
        $days = isset($args['days']) ? (int)$args['days'] : 0;
        $price = isset($args['price']) ? (float)$args['price'] : 0;
        $qr = isset($args['qr']) ? (string)$args['qr'] : '';
        $title = isset($args['title']) ? (string)$args['title'] : ($days . ' 天');
        if ($days <= 0 || $price <= 0) {
            fail('需要 --days 和 --price');
        }
        if (stripos($qr, 'https://') !== 0) {
            fail('--qr 必须是 https:// 开头的收款码地址（原版也强制 HTTPS）');
        }
        $id = $db->insert(
            'INSERT INTO douy_plans (software_id, title, days_valid, price, qr_code_url, recommend, sort_order, active)
             VALUES (?,?,?,?,?,?,?,1)',
            ['douy_ios_injection', $title, $days, $price, $qr, 0, $days]
        );
        out('已添加套餐 #' . $id);
        break;

    // ------------------------------------------------------------ 卡密
    case 'card:new':
        $days = isset($args['days']) ? (int)$args['days'] : 0;
        $count = isset($args['count']) ? (int)$args['count'] : 1;
        $note = isset($args['note']) ? (string)$args['note'] : '';
        if ($days <= 0) {
            fail('需要 --days（天数）');
        }
        if ($count <= 0 || $count > 5000) {
            fail('--count 需在 1..5000');
        }

        $batchId = $db->insert(
            'INSERT INTO douy_card_batches (name, plan_id, days, quantity, created_by, note) VALUES (?,?,?,?,?,?)',
            [isset($args['batch']) ? (string)$args['batch'] : ('batch-' . date('Ymd-His')), null, $days, $count, 'cli', $note]
        );

        $codes = [];
        for ($i = 0; $i < $count; $i++) {
            $code = LicenseService::generateKeyCode($config);
            $masked = LicenseService::maskKey($code);
            for ($try = 0; $try < 5; $try++) {
                try {
                    $db->insert(
                        'INSERT INTO douy_cards (key_code, masked, batch_id, days, status, duration_ms, note)
                         VALUES (?,?,?,?,?,?,?)',
                        [$code, $masked, $batchId, $days, 'unused', $days * LicenseService::DAY_MS, $note]
                    );
                    $codes[] = $code;
                    break;
                } catch (PDOException $e) {
                    $code = LicenseService::generateKeyCode($config);
                    $masked = LicenseService::maskKey($code);
                }
            }
        }

        out('批次 #' . $batchId . '：生成 ' . count($codes) . ' 张 ' . $days . ' 天卡密');
        foreach ($codes as $c) {
            out('  ' . $c);
        }
        break;

    case 'card:list':
        $status = isset($args['status']) ? (string)$args['status'] : '';
        $limit = isset($args['limit']) ? (int)$args['limit'] : 30;
        $sql = 'SELECT * FROM douy_cards';
        $params = [];
        if ($status !== '') {
            $sql .= ' WHERE status = ?';
            $params[] = $status;
        }
        $sql .= ' ORDER BY id DESC LIMIT ' . max(1, min(500, $limit));
        foreach ($db->all($sql, $params) as $r) {
            out(sprintf('#%-5d %-24s %3d天 %-8s acct=%-5s dev=%-10s exp=%s',
                $r['id'], $r['key_code'], $r['days'], $r['status'],
                (string)$r['account_id'],
                $r['device_id'] === null ? '-' : substr($r['device_id'], 0, 10),
                $r['expires_ms'] === null ? '-' : date('Y-m-d H:i', (int)($r['expires_ms'] / 1000))));
        }
        break;

    case 'card:revoke':
        $key = normalize_key_code(isset($args['key']) ? $args['key'] : '');
        if ($key === '') {
            fail('需要 --key=DOUY-....');
        }
        $n = $db->exec('UPDATE douy_cards SET status = ? WHERE key_code = ?', ['revoked', $key]);
        $db->exec('UPDATE douy_leases SET revoked = 1 WHERE card_id IN (SELECT id FROM douy_cards WHERE key_code = ?)', [$key]);
        out($n > 0 ? '已吊销 ' . $key : '没找到该卡密');
        break;

    // ------------------------------------------------------------ 订单
    case 'order:pay':
        $id = isset($args['id']) ? (int)$args['id'] : 0;
        if ($id <= 0) {
            fail('需要 --id=订单号');
        }
        $order = $db->one('SELECT * FROM douy_orders WHERE id = ?', [$id]);
        if ($order === null) {
            fail('订单不存在');
        }
        if ($order['status'] === 'paid') {
            fail('该订单已确认到账');
        }

        $db->begin();
        try {
            $code = LicenseService::generateKeyCode($config);
            $masked = LicenseService::maskKey($code);
            $cardId = $db->insert(
                'INSERT INTO douy_cards (key_code, masked, plan_id, days, account_id, status, duration_ms, order_id)
                 VALUES (?,?,?,?,?,?,?,?)',
                [$code, $masked, $order['plan_id'], $order['days'], $order['account_id'], 'standby',
                 (int)$order['days'] * LicenseService::DAY_MS, $order['id']]
            );
            $db->exec('UPDATE douy_orders SET status = ?, card_id = ?, paid_at_ms = ?, paid_note = ? WHERE id = ?',
                ['paid', $cardId, now_ms(), isset($args['note']) ? $args['note'] : 'admin', $order['id']]);
            $db->commit();
        } catch (Throwable $e) {
            $db->rollback();
            fail('确认到账失败：' . $e->getMessage());
        }

        $db->audit('order_paid', ['account_id' => $order['account_id'], 'card_id' => $cardId], ['order_id' => $order['id']]);
        out('订单 #' . $order['id'] . ' 已确认到账，新卡已进用户卡包（未计时）');
        out('  卡密: ' . $code);
        out('  天数: ' . $order['days']);
        break;

    // ------------------------------------------------------------ 更新
    case 'update:publish':
        $file = isset($args['file']) ? (string)$args['file'] : '';
        $versionCode = isset($args['version-code']) ? (int)$args['version-code'] : 0;
        $versionName = isset($args['version-name']) ? (string)$args['version-name'] : '';
        $channel = isset($args['channel']) ? (string)$args['channel'] : 'stable';
        $changelog = isset($args['changelog']) ? (string)$args['changelog'] : '';
        $force = !empty($args['force']);

        if ($file === '' || !is_file($file)) {
            fail('需要 --file=/path/to/DOUY.dylib');
        }
        if ($versionCode <= 0 || $versionName === '') {
            fail('需要 --version-code 和 --version-name');
        }

        $sha = hash_file('sha256', $file);
        $size = filesize($file);
        $updatesDir = rtrim($config['paths']['updates'], '/\\');
        if (!is_dir($updatesDir) && !@mkdir($updatesDir, 0755, true)) {
            fail('无法创建目录: ' . $updatesDir);
        }
        $storedName = sprintf('DOUY-%s-%d.dylib', preg_replace('/[^0-9A-Za-z._-]/', '', $versionName), $versionCode);
        if (!@copy($file, $updatesDir . DIRECTORY_SEPARATOR . $storedName)) {
            fail('拷贝文件失败');
        }

        // 同名版本号就覆盖
        $db->exec('DELETE FROM douy_updates WHERE channel = ? AND version_code = ?', [$channel, $versionCode]);
        $id = $db->insert(
            'INSERT INTO douy_updates (product, plugin_id, channel, version_code, version_name, min_ios, size, sha256,
                                    file_path, changelog, release_tag, generation, force_update, active)
             VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,1)',
            ['DOUY', 'douy-ios-hook', $channel, $versionCode, $versionName,
             isset($args['min-ios']) ? (string)$args['min-ios'] : '14.0',
             $size, $sha, $storedName, $changelog,
             'release-' . $versionCode . '-' . substr($sha, 0, 12), $versionCode, $force ? 1 : 0]
        );

        out('已发布更新 #' . $id);
        out('  version_code : ' . $versionCode);
        out('  version_name : ' . $versionName);
        out('  size         : ' . $size);
        out('  sha256       : ' . $sha);
        out('  file         : ' . $storedName);
        break;

    // ------------------------------------------------------------ 设备/账号
    case 'device:list':
        foreach ($db->all('SELECT * FROM douy_devices ORDER BY id DESC LIMIT 50') as $r) {
            out(sprintf('#%-4d %-42s acct=%-5s ios=%-8s blocked=%d last=%s',
                $r['id'], $r['device_id'], (string)$r['account_id'], (string)$r['ios_version'],
                (int)$r['blocked'], date('Y-m-d H:i', (int)($r['last_seen_ms'] / 1000))));
        }
        break;

    case 'device:block':
        $deviceId = isset($args['device-id']) ? (string)$args['device-id'] : '';
        if ($deviceId === '') {
            fail('需要 --device-id=');
        }
        $blocked = empty($args['unblock']) ? 1 : 0;
        $n = $db->exec('UPDATE douy_devices SET blocked = ? WHERE device_id = ?', [$blocked, $deviceId]);
        if ($blocked === 1) {
            $db->exec('UPDATE douy_leases SET revoked = 1 WHERE device_id = ?', [$deviceId]);
        }
        out($n > 0 ? ('已' . ($blocked ? '封禁' : '解封') . ' ' . $deviceId) : '没找到该设备');
        break;

    case 'account:list':
        foreach ($db->all('SELECT * FROM douy_accounts ORDER BY id DESC LIMIT 50') as $r) {
            out(sprintf('#%-4d %-20s %-28s %-8s cards=%d',
                $r['id'], $r['username'], $r['email'], $r['status'],
                (int)$db->scalar('SELECT COUNT(*) FROM douy_cards WHERE account_id = ?', [$r['id']])));
        }
        break;

    case 'account:disable':
        $username = isset($args['username']) ? (string)$args['username'] : '';
        if ($username === '') {
            fail('需要 --username=');
        }
        $status = empty($args['enable']) ? 'disabled' : 'active';
        $n = $db->exec('UPDATE douy_accounts SET status = ? WHERE username = ?', [$status, $username]);
        if ($status === 'disabled') {
            $row = $db->one('SELECT id FROM douy_accounts WHERE username = ?', [$username]);
            if ($row !== null) {
                Auth::revokeAll($db, (int)$row['id']);
            }
        }
        out($n > 0 ? ('已' . ($status === 'disabled' ? '停用' : '启用') . ' ' . $username) : '没找到该账号');
        break;

    default:
        fail('未知命令: ' . $command . '（运行 php bin/douyctl.php help）');
}
