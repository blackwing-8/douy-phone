<?php
/**
 * 服务端 API 冒烟测试（开发用）
 *
 * 用法：
 *   1. 先起服务： php -S 127.0.0.1:8080 -t server/public server/public/index.php
 *   2. 再跑本脚本： php server/tools/smoke.php [卡密]
 *
 * 它会走完：注册 → 设备签名注册 → 登录挑战 → 会话 → 激活卡密 → 状态/租约
 *          → 备用卡入包 → 套餐/下单/查单 → 检查更新 → 校验服务端签名
 *          → 负例（错签名/重放/超时）
 */

if (PHP_SAPI !== 'cli') {
    exit("CLI only\n");
}

$base = getenv('FX_BASE_URL') ?: 'http://127.0.0.1:8080';
$cardCode = isset($argv[1]) ? $argv[1] : '';
$root = dirname(__DIR__);

require $root . '/app/bootstrap.php';

$pass = 0;
$fail = 0;

function step($name)
{
    echo "\n== " . $name . " ==\n";
}

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

// ---------------------------------------------------------------- 设备密钥
$keyPath = $root . '/storage/dev_device.pem';
if (!is_file($keyPath)) {
    $options = ['private_key_type' => OPENSSL_KEYTYPE_EC, 'curve_name' => 'prime256v1'];
    foreach ([
        dirname(PHP_BINARY) . '/extras/ssl/openssl.cnf',
        dirname(PHP_BINARY) . '/extras/openssl.cnf',
    ] as $cnf) {
        if (is_file($cnf)) {
            $options['config'] = $cnf;
            break;
        }
    }
    $res = openssl_pkey_new($options);
    if ($res === false) {
        exit("无法生成设备测试密钥: " . openssl_error_string() . "\n");
    }
    openssl_pkey_export($res, $pem, null, $options);
    if (!is_dir(dirname($keyPath))) {
        @mkdir(dirname($keyPath), 0755, true);
    }
    file_put_contents($keyPath, $pem);
    echo "已生成测试设备密钥: $keyPath\n";
}

$privPem = file_get_contents($keyPath);
$priv = openssl_pkey_get_private($privPem);
$details = openssl_pkey_get_details($priv);
$pubPem = $details['key'];
$pubDerB64 = preg_replace('/-----[^-]+-----|\s+/', '', $pubPem);
$deviceId = substr(hash('sha256', base64_decode($pubDerB64)), 0, 40);
$keyId = 'ec-p256-1';

echo "设备 device_id = $deviceId\n";

$sessionToken = '';

/**
 * 发一个带签名的请求
 * @param bool $tamper 故意破坏签名（负例）
 */
function api($method, $path, array $body = [], $options = [])
{
    global $base, $keyId, $priv, $deviceId, $sessionToken;

    $raw = empty($body) ? '' : json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($method === 'GET' && !empty($body)) {
        $raw = '';
        $body = [];
    }
    $time = (string)now_ms();
    $nonce = bin2hex(random_bytes(16));
    if (!empty($options['nonce'])) {
        $nonce = $options['nonce'];
    }
    if (!empty($options['time'])) {
        $time = (string)$options['time'];
    }

    $canonical = "douy-ios-proof-v1\n" . $method . "\n" . $path . "\n" . $time . "\n" . $nonce . "\n"
        . hash('sha256', $raw) . "\n" . $deviceId . "\n" . $keyId;

    $sig = '';
    if (!empty($options['bad_sig'])) {
        $sig = base64_encode(random_bytes(70));
    } else {
        openssl_sign($canonical, $sig, $priv, OPENSSL_ALGO_SHA256);
        $sig = base64_encode($sig);
    }

    $headers = [
        'Content-Type: application/json',
        'X-DOUY-IOS-Proof: douy-ios-proof-v1',
        'X-DOUY-IOS-Key: ' . $keyId,
        'X-DOUY-IOS-Role: child',
        'X-DOUY-IOS-Time: ' . $time,
        'X-DOUY-IOS-Nonce: ' . $nonce,
        'X-DOUY-IOS-Device: ' . $deviceId,
        'X-DOUY-IOS-Signature: ' . $sig,
    ];
    if ($sessionToken !== '' && empty($options['no_session'])) {
        $headers[] = 'Authorization: Frame-Session ' . $sessionToken;
    }

    $ch = curl_init($base . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST  => $method,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_TIMEOUT        => 10,
    ]);
    if ($method !== 'GET' && $raw !== '') {
        curl_setopt($ch, CURLOPT_POSTFIELDS, $raw);
    }
    $out = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    $json = json_decode((string)$out, true);
    return ['status' => $status, 'body' => $json, 'raw' => $out];
}

// ---------------------------------------------------------------- 1) 健康检查
step('1. 健康检查');
$r = api('GET', '/health');
check(isset($r['body']['code']) && $r['body']['code'] === 'OK', 'GET /health', $r['raw']);

// ---------------------------------------------------------------- 2) 注册
step('2. 注册账号');
$username = 't_' . substr(bin2hex(random_bytes(4)), 0, 8);
$password = 'pass1234';
$r = api('POST', '/api/register', [
    'username' => $username,
    'password' => $password,
    'confirm_password' => $password,
    'email' => $username . '@example.com',
]);
check(isset($r['body']['code']) && $r['body']['code'] === 'OK', '注册成功', $r['raw']);
check(isset($r['body']['code']) && $r['body']['code'] === 'IOS_REGISTER_INVALID' ? false : true, '密码规则校验未误伤');

$r = api('POST', '/api/register', [
    'username' => $username, 'password' => 'short', 'confirm_password' => 'short',
    'email' => $username . '@example.com',
]);
check($r['body']['code'] === 'IOS_REGISTER_INVALID', '弱密码被拒绝');

// ---------------------------------------------------------------- 3) 设备注册
step('3. 设备身份注册（自签验签）');
$r = api('POST', '/api/ios/plugin/device/register', [
    'device_id' => $deviceId,
    'key_id' => $keyId,
    'public_key' => $pubDerB64,
    'platform' => 'ios',
    'ios_version' => '16.5',
    'bundle_id' => 'com.example.host',
    'model' => 'iPhone14,2',
]);
check($r['body']['code'] === 'OK', '设备登记成功', $r['raw']);

// ---------------------------------------------------------------- 4) 登录
step('4. 登录（挑战 → 会话）');
$r = api('POST', '/api/ios/plugin/login', ['username' => $username, 'password' => $password]);
check($r['body']['code'] === 'OK' && !empty($r['body']['challenge']), '拿到 challenge', $r['raw']);

$challenge = isset($r['body']['challenge']) ? $r['body']['challenge'] : '';
$chSig = '';
openssl_sign($challenge, $chSig, $priv, OPENSSL_ALGO_SHA256);

$r = api('POST', '/api/ios/plugin/login_session', [
    'username' => $username,
    'challenge' => $challenge,
    'challenge_response' => base64_encode($chSig),
]);
check($r['body']['code'] === 'OK' && !empty($r['body']['session_token']), '挑战响应通过并拿到会话', $r['raw']);
$sessionToken = isset($r['body']['session_token']) ? $r['body']['session_token'] : '';

$r = api('POST', '/api/ios/plugin/login', ['username' => $username, 'password' => 'wrong-pass1']);
check($r['body']['code'] === 'IOS_LOGIN_INVALID', '错误密码被拒绝');

// 重放同一条请求（nonce 复用）
step('5. 负例：重放 / 错签名 / 时间偏差');
$fixedNonce = bin2hex(random_bytes(16));
$r1 = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId], ['nonce' => $fixedNonce]);
check($r1['body']['code'] === 'OK', '首次请求成功', $r1['raw']);
$r2 = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId], ['nonce' => $fixedNonce]);
check($r2['body']['code'] === 'IOS_SESSION_BUSY', 'nonce 重放被拒绝', $r2['raw']);

$r = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId], ['bad_sig' => true]);
check($r['body']['code'] === 'IOS_LOCAL_IDENTITY_INVALID', '错误签名被拒绝', $r['raw']);

$r = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId], ['time' => now_ms() - 3600000]);
check($r['body']['code'] === 'IOS_REQUEST_INVALID', '时间偏差过大被拒绝', $r['raw']);

// ---------------------------------------------------------------- 6) 激活
step('6. 激活卡密并绑定本机');
if ($cardCode === '') {
    echo "  （未传卡密参数，跳过激活相关用例；可运行: php tools/smoke.php DOUY-XXXX-XXXX-XXXX）\n";
} else {
    $r = api('POST', '/api/ios/plugin/activate', ['key_code' => $cardCode, 'device_id' => $deviceId]);
    check($r['body']['code'] === 'OK' && !empty($r['body']['license']), '激活成功', $r['raw']);

    // 校验服务端签名
    $lic = isset($r['body']['license']) ? $r['body']['license'] : [];
    if (!empty($lic['payload']) && !empty($lic['signature'])) {
        $serverKey = $db = douy_db($config)->one('SELECT public_key FROM douy_server_keys WHERE active = 1 LIMIT 1');
        $pem = "-----BEGIN PUBLIC KEY-----\n" . chunk_split($serverKey['public_key'], 64, "\n") . "-----END PUBLIC KEY-----\n";
        $pubKey = openssl_pkey_get_public($pem);
        $ok = openssl_verify(base64_decode($lic['payload']), base64_decode($lic['signature']), $pubKey, OPENSSL_ALGO_SHA256);
        check($ok === 1, '授权凭证的服务端签名可验', 'verify=' . var_export($ok, true));

        $payload = json_decode(base64_decode($lic['payload']), true);
        check(isset($payload['aud']) && $payload['aud'] === 'douy-ios-hook', 'aud=douy-ios-hook');
        check(isset($payload['device_id']) && $payload['device_id'] === $deviceId, '凭证绑定到本机');
        check(isset($payload['exp_ms']) && $payload['exp_ms'] > now_ms(), '凭证未过期');
    }

    // 状态 + 租约
    $r = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId]);
    check($r['body']['code'] === 'OK', '状态接口成功', $r['raw']);
    check(!empty($r['body']['lease']['token']), '拿到 90 秒租约');
    check(isset($r['body']['license_state']) && $r['body']['license_state'] === 'active', 'license_state=active');
    $leaseTtl = isset($r['body']['lease']['expires_ms']) ? $r['body']['lease']['expires_ms'] - now_ms() : 0;
    check($leaseTtl > 60000 && $leaseTtl <= 91000, '租约有效期约 90 秒 (' . $leaseTtl . ' ms)');

    // 重复激活同一张卡：允许（幂等）
    $r = api('POST', '/api/ios/plugin/activate', ['key_code' => $cardCode, 'device_id' => $deviceId]);
    check($r['body']['code'] === 'OK', '重复激活同一张卡幂等');

    // 错误卡密
    $r = api('POST', '/api/ios/plugin/activate', ['key_code' => 'DOUY-0000-0000-0000', 'device_id' => $deviceId]);
    check($r['body']['code'] === 'IOS_REQUEST_INVALID', '不存在的卡密被拒绝');
}

// ---------------------------------------------------------------- 7) 购买
step('7. 套餐 / 下单 / 查单');
$r = api('GET', '/api/payment_plans?software_id=douy_ios_injection', [], ['no_session' => false]);
check($r['body']['code'] === 'OK' && !empty($r['body']['plans']), '套餐列表非空', $r['raw']);
$planId = isset($r['body']['plans'][0]['id']) ? $r['body']['plans'][0]['id'] : 0;

$r = api('POST', '/api/orders', ['plan_id' => $planId]);
check($r['body']['code'] === 'OK' && !empty($r['body']['order']['remark_code']), '下单成功并给出备注码', $r['raw']);
$orderId = isset($r['body']['order']['id']) ? $r['body']['order']['id'] : 0;

$r = api('GET', '/api/orders/status?id=' . $orderId);
check($r['body']['code'] === 'OK' && $r['body']['order']['status'] === 'pending', '订单状态 pending', $r['raw']);

// ---------------------------------------------------------------- 8) 更新
step('8. 检查更新');
$r = api('POST', '/api/ios/update/check', [
    'channel' => 'stable',
    'product' => 'DOUY',
    'plugin_id' => 'douy-ios-hook',
    'ios_version' => '16.5',
    'architecture' => 'arm64',
    'platform' => 'ios',
    'installed_version_code' => 58,
    'install_method' => 'injector',
    'update_protocol' => 'douy-ios-plugin-update',
    'device_id' => $deviceId,
]);
check($r['body']['code'] === 'OK', '更新检查接口正常', $r['raw']);
$hasUpdate = isset($r['body']['has_update']) ? $r['body']['has_update'] : null;
echo "  has_update = " . var_export($hasUpdate, true) . "\n";
if ($hasUpdate === true) {
    check(!empty($r['body']['signed_update']['signature']), '带服务端签名');
    $serverKey = douy_db($config)->one('SELECT public_key FROM douy_server_keys WHERE active = 1 LIMIT 1');
    $pem = "-----BEGIN PUBLIC KEY-----\n" . chunk_split($serverKey['public_key'], 64, "\n") . "-----END PUBLIC KEY-----\n";
    $pubKey = openssl_pkey_get_public($pem);
    $ok = openssl_verify(
        base64_decode($r['body']['signed_update']['payload']),
        base64_decode($r['body']['signed_update']['signature']),
        $pubKey,
        OPENSSL_ALGO_SHA256
    );
    check($ok === 1, '更新清单签名可验');
}

// ---------------------------------------------------------------- 9) 退出
step('9. 退出登录');
$r = api('POST', '/api/ios/plugin/logout', []);
check($r['body']['code'] === 'OK', '退出成功', $r['raw']);

$r = api('POST', '/api/ios/plugin/account/status', ['device_id' => $deviceId]);
check($r['body']['code'] === 'IOS_LOGIN_REQUIRED', '退出后状态接口要求登录', $r['raw']);

// ---------------------------------------------------------------- 汇总
echo "\n=========================================\n";
echo "  PASS: $pass   FAIL: $fail\n";
echo "=========================================\n";
if ($cardCode === '') {
    echo "提示：传入一张未使用卡密可覆盖激活流程：\n";
    echo "  php server/tools/smoke.php DOUY-XXXX-XXXX-XXXX\n";
}
exit($fail === 0 ? 0 : 1);
