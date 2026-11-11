<?php
/**
 * 第二阶段冒烟：到账发卡 + 更新发布/下载（含每日 5 次配额）
 *
 * 用法（先起 php -S 8080）：
 *   php server/tools/smoke2.php
 */

if (PHP_SAPI !== 'cli') {
    exit("CLI only\n");
}

$base = getenv('FX_BASE_URL') ?: 'http://127.0.0.1:8080';
$root = dirname(__DIR__);

require $root . '/app/bootstrap.php';

$pass = 0;
$fail = 0;
function check($cond, $label, $detail = '')
{
    global $pass, $fail;
    if ($cond) {
        $pass++;
        echo "  [PASS] " . $label . "\n";
    } else {
        $fail++;
        echo "  [FAIL] " . $label . ($detail !== '' ? '  -> ' . $detail : '') . "\n";
    }
}
function step($t)
{
    echo "\n== " . $t . " ==\n";
}

$db = douy_db($config);

// ---------------------------------------------------------------- 设备密钥（复用 smoke.php 生成的）
$keyPath = $root . '/storage/dev_device.pem';
if (!is_file($keyPath)) {
    exit("请先运行 php tools/smoke.php 生成测试设备密钥\n");
}
$priv = openssl_pkey_get_private(file_get_contents($keyPath));
$details = openssl_pkey_get_details($priv);
$pubDerB64 = preg_replace('/-----[^-]+-----|\s+/', '', $details['key']);
$deviceId = substr(hash('sha256', base64_decode($pubDerB64)), 0, 40);
$keyId = 'ec-p256-1';

$sessionToken = '';

function api($method, $path, array $body = [], $options = [])
{
    global $base, $keyId, $priv, $deviceId, $sessionToken;
    $raw = empty($body) ? '' : json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $time = (string)now_ms();
    $nonce = bin2hex(random_bytes(16));
    $canonical = "douy-ios-proof-v1\n" . $method . "\n" . $path . "\n" . $time . "\n" . $nonce . "\n"
        . hash('sha256', $raw) . "\n" . $deviceId . "\n" . $keyId;
    openssl_sign($canonical, $sig, $priv, OPENSSL_ALGO_SHA256);

    $headers = [
        'Content-Type: application/json',
        'X-DOUY-IOS-Proof: douy-ios-proof-v1',
        'X-DOUY-IOS-Key: ' . $keyId,
        'X-DOUY-IOS-Role: child',
        'X-DOUY-IOS-Time: ' . $time,
        'X-DOUY-IOS-Nonce: ' . $nonce,
        'X-DOUY-IOS-Device: ' . $deviceId,
        'X-DOUY-IOS-Signature: ' . base64_encode($sig),
    ];
    if ($sessionToken !== '') {
        $headers[] = 'Authorization: Frame-Session ' . $sessionToken;
    }

    $ch = curl_init($base . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_TIMEOUT        => 15,
    ]);
    if ($method !== 'GET' && $raw !== '') {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $raw);
    }
    $out = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    return ['status' => $status, 'body' => json_decode((string)$out, true), 'raw' => $out];
}

// ---------------------------------------------------------------- 重新登录（拿会话）
step('0. 登录（用上一阶段最新账号）');
$account = $db->one('SELECT * FROM douy_accounts ORDER BY id DESC LIMIT 1');
if ($account === null) {
    exit("没有账号，请先运行 smoke.php\n");
}
$username = $account['username'];
$password = 'pass1234';

$r = api('POST', '/api/ios/plugin/login', ['username' => $username, 'password' => $password]);
$challenge = $r['body']['challenge'];
$chSig = '';
openssl_sign($challenge, $chSig, $priv, OPENSSL_ALGO_SHA256);
$r = api('POST', '/api/ios/plugin/login_session', [
    'username' => $username, 'challenge' => $challenge, 'challenge_response' => base64_encode($chSig),
]);
check($r['body']['code'] === 'OK', '登录成功 (' . $username . ')', $r['raw']);
$sessionToken = $r['body']['session_token'];

// ---------------------------------------------------------------- 1. 到账发卡
step('1. 管理员确认到账 → 自动发卡进卡包');
$order = $db->one('SELECT * FROM douy_orders WHERE account_id = ? AND status = ? ORDER BY id DESC LIMIT 1',
    [$account['id'], 'pending']);
if ($order === null) {
    $r = api('POST', '/api/orders', ['plan_id' => (int)$db->scalar('SELECT id FROM douy_plans WHERE active = 1 ORDER BY id LIMIT 1')]);
    $order = ['id' => $r['body']['order']['id'], 'days' => $r['body']['order']['days']];
    echo "  （新建了一个订单 #" . $order['id'] . "）\n";
}

$cmd = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($root . '/bin/douyctl.php')
    . ' order:pay --id=' . (int)$order['id'] . ' 2>&1';
exec($cmd, $lines, $code);
echo '  CLI: ' . implode(' | ', $lines) . "\n";
check($code === 0, 'douyctl order:pay 执行成功');

$r = api('GET', '/api/orders/status?id=' . (int)$order['id']);
check($r['body']['code'] === 'OK' && $r['body']['order']['status'] === 'paid', '订单变为 paid', $r['raw']);
check(!empty($r['body']['order']['card_id']), '订单关联到新卡密');

$newCard = $db->one('SELECT * FROM douy_cards WHERE order_id = ?', [(int)$order['id']]);
check($newCard !== null && $newCard['status'] === 'standby', '新卡进入卡包且未开始计时');
check($newCard !== null && $newCard['expires_ms'] === null, '新卡 expires_ms 为空（未计时）');

// ---------------------------------------------------------------- 2. 发布更新
step('2. 发布一个测试更新');
$dummy = $root . '/storage/test_payload.bin';
file_put_contents($dummy, random_bytes(256 * 1024));
$cmd = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg($root . '/bin/douyctl.php')
    . ' update:publish --file=' . escapeshellarg($dummy)
    . ' --version-code=59 --version-name=0.1.9 --channel=stable --changelog="测试更新" 2>&1';
exec($cmd, $lines2, $code2);
echo '  CLI: ' . implode(' | ', array_slice($lines2, 0, 3)) . "\n";
check($code2 === 0, 'douyctl update:publish 执行成功');

// ---------------------------------------------------------------- 3. 检查更新
step('3. 检查更新 + 验签');
$r = api('POST', '/api/ios/update/check', [
    'channel' => 'stable', 'product' => 'DOUY', 'plugin_id' => 'douy-ios-hook',
    'ios_version' => '16.5', 'architecture' => 'arm64', 'platform' => 'ios',
    'installed_version_code' => 58, 'install_method' => 'injector',
    'update_protocol' => 'douy-ios-plugin-update', 'device_id' => $deviceId,
]);
check($r['body']['code'] === 'OK' && $r['body']['has_update'] === true, '发现新版', $r['raw']);

$serverKey = $db->one('SELECT public_key FROM douy_server_keys WHERE active = 1 LIMIT 1');
$pem = "-----BEGIN PUBLIC KEY-----\n" . chunk_split($serverKey['public_key'], 64, "\n") . "-----END PUBLIC KEY-----\n";
$pubKey = openssl_pkey_get_public($pem);
$verified = openssl_verify(
    base64_decode($r['body']['signed_update']['payload']),
    base64_decode($r['body']['signed_update']['signature']),
    $pubKey,
    OPENSSL_ALGO_SHA256
);
check($verified === 1, '更新清单签名可验');
$manifest = json_decode(base64_decode($r['body']['signed_update']['payload']), true);
check(isset($manifest['sha256']) && $manifest['sha256'] === $r['body']['sha256'], '清单 sha256 与响应一致');
check($manifest['aud'] === 'douy-ios-plugin-update', 'aud=douy-ios-plugin-update');

// ---------------------------------------------------------------- 4. 下载
step('4. 申请下载凭证并下载（含每日配额）');
$r = api('POST', '/api/ios/update/download', [
    'version_code' => 59, 'device_id' => $deviceId,
    'target_sha256' => $r['body']['sha256'], 'request_id' => bin2hex(random_bytes(8)),
]);
check($r['body']['code'] === 'OK' && !empty($r['body']['download_url']), '拿到下载地址', $r['raw']);
check(isset($r['body']['daily_limit']) && $r['body']['daily_limit'] === 5, '每日配额 = 5');

$downloadUrl = $r['body']['download_url'];
$data = @file_get_contents($downloadUrl);
check($data !== false && strlen($data) > 0, '下载到文件 (' . strlen((string)$data) . ' B)');
check(sha1((string)$data) === sha1(file_get_contents($dummy)), '下载内容与发布文件一致');

// 同一 token 再用一次 → 拒绝
$data2 = @file_get_contents($downloadUrl);
$json2 = json_decode((string)$data2, true);
check(isset($json2['code']) && $json2['code'] === 'IOS_REQUEST_INVALID', '下载凭证一次性', substr((string)$data2, 0, 120));

// 配额：连续申请 5 次，第 6 次应被限流
$limited = false;
for ($i = 0; $i < 6; $i++) {
    $rr = api('POST', '/api/ios/update/download', [
        'version_code' => 59, 'device_id' => $deviceId,
        'target_sha256' => $manifest['sha256'], 'request_id' => bin2hex(random_bytes(8)),
    ]);
    if ($rr['body']['code'] === 'IOS_RATE_LIMITED') {
        $limited = true;
        echo '  第 ' . ($i + 1) . ' 次被限流: ' . $rr['body']['message'] . "\n";
        break;
    }
}
check($limited, '超过每日 5 次被 IOS_RATE_LIMITED');

// ---------------------------------------------------------------- 5. 防篡改
$strict = !empty($config['license']['strict_module_check']);
step('5. 插件代码哈希变化 → ' . ($strict ? '严格模式应拒绝' : '宽松模式应自动跟随'));
$r = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId, 'module_text_sha256' => str_repeat('a', 64)]);
check($r['body']['code'] === 'OK', '首次上报哈希被记录', $r['raw']);

$r = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId, 'module_text_sha256' => str_repeat('b', 64)]);
if ($strict) {
    check($r['body']['code'] === 'IOS_MODULE_CHANGED', '哈希变化被拒绝', $r['raw']);
} else {
    // 宽松模式：换新版插件不应该把用户锁死，而是记录并跟随
    check($r['body']['code'] === 'OK', '哈希变化被接受（宽松模式）', $r['raw']);
    $again = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId, 'module_text_sha256' => str_repeat('b', 64)]);
    check($again['body']['code'] === 'OK', '同一新哈希再次请求仍然通过', $again['raw']);
}

echo "\n=========================================\n";
echo "  PASS: $pass   FAIL: $fail\n";
echo "=========================================\n";
exit($fail === 0 ? 0 : 1);
