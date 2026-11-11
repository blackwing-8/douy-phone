<?php
/**
 * 所有 API 控制器
 *  - AuthController    注册 / 设备注册 / 登录 / 会话 / 退出
 *  - LicenseController 状态 / 激活 / 加卡包 / 绑定 / 解绑 / 换绑
 *  - PaymentController 套餐 / 下单 / 查单
 *  - UpdateController  检查更新 / 申请下载凭证 / 下载
 */

class AuthController
{
    public static function register(Db $db, array $config, Request $req, $ctx)
    {
        // 本机回环 + 显式开关时跳过限流，方便本地反复跑冒烟测试（生产别开）
        $loopback = ($req->ip === '127.0.0.1' || $req->ip === '::1');
        $skipLimit = !empty($config['app']['skip_rate_limit_for_loopback']) && $loopback;
        if (!$skipLimit) {
            RateLimit::hit($db, 'register:' . $req->ip, 5, 3600);
        }

        $username = trim($req->str('username'));
        $password = $req->str('password');
        $confirm  = $req->str('confirm_password', $req->str('password_confirm', ''));
        $email    = trim($req->str('email'));
        $referral = trim($req->str('referral_code', ''));

        if (!preg_match('/^[A-Za-z0-9_]{3,20}$/', $username)) {
            throw new ApiException('IOS_REGISTER_INVALID', '账号需为 3–20 位字母、数字或下划线');
        }
        if (strlen($password) < 6 || strlen($password) > 50
            || !preg_match('/[A-Za-z]/', $password) || !preg_match('/\d/', $password)) {
            throw new ApiException('IOS_REGISTER_INVALID', "密码需 6–50 位，并包含字母和数字。\n注册沿用现有兜鱼账号规则。");
        }
        if ($confirm !== '' && $confirm !== $password) {
            throw new ApiException('IOS_REGISTER_INVALID', '两次密码不一致');
        }
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            throw new ApiException('IOS_REGISTER_INVALID', '请填写有效邮箱');
        }
        if ($db->one('SELECT id FROM douy_accounts WHERE username = ?', [$username]) !== null) {
            throw new ApiException('IOS_REGISTER_INVALID', '该账号已被注册');
        }
        if ($db->one('SELECT id FROM douy_accounts WHERE email = ?', [$email]) !== null) {
            throw new ApiException('IOS_REGISTER_INVALID', '该邮箱已被注册');
        }

        $referredBy = null;
        if ($referral !== '') {
            $referrer = $db->one('SELECT id FROM douy_accounts WHERE referral_code = ?', [$referral]);
            if ($referrer === null) {
                throw new ApiException('IOS_REGISTER_INVALID', '推荐码不存在');
            }
            $referredBy = (int)$referrer['id'];
        }

        $id = $db->insert(
            'INSERT INTO douy_accounts (username, password_hash, email, referral_code, referred_by, status)
             VALUES (?,?,?,?,?,?)',
            [
                $username,
                password_hash($password, PASSWORD_DEFAULT),
                $email,
                strtoupper(substr(Crypto::randomHex(4), 0, 6)),
                $referredBy,
                'active',
            ]
        );

        $db->audit('register', ['account_id' => $id, 'ip' => $req->ip], ['username' => $username]);
        Response::ok(['message' => '注册成功，请登录', 'account' => ['id' => $id, 'username' => $username]]);
    }

    /** 设备首次上报身份（自签验签，用请求体里的 public_key） */
    public static function deviceRegister(Db $db, array $config, Request $req, $ctx)
    {
        $deviceId = $req->str('device_id');
        $keyId = $req->str('key_id', $req->header('x-douy-ios-key', 'ec-p256-1'));
        $publicKey = $req->str('public_key');

        if (!preg_match('/^[0-9a-f]{16,40}$/', $deviceId)) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', 'device_id 非法');
        }
        if ($publicKey === '') {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '缺少 public_key');
        }
        if (!in_array($keyId, ['ec-p256-1', 'ed25519-1'], true)) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '不支持的密钥类型');
        }
        if (Crypto::publicKeyPem($keyId, $publicKey) === null) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '公钥格式无效');
        }

        $expect = Crypto::deviceIdFromPublicKey($publicKey);
        if (!empty($config['app']['strict_device_id']) && $expect !== null && $expect !== $deviceId) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '设备指纹与公钥不匹配');
        }

        $now = now_ms();
        $existing = $db->one('SELECT * FROM douy_devices WHERE device_id = ?', [$deviceId]);
        if ($existing === null) {
            $db->insert(
                'INSERT INTO douy_devices (device_id, account_id, platform, key_id, public_key, ios_version, bundle_id, model, module_hash, blocked, first_seen_ms, last_seen_ms)
                 VALUES (?,?,?,?,?,?,?,?,?,0,?,?)',
                [
                    $deviceId,
                    null,
                    $req->str('platform', 'ios'),
                    $keyId,
                    $publicKey,
                    $req->str('ios_version'),
                    $req->str('bundle_id'),
                    $req->str('model'),
                    $req->str('module_text_sha256', null),
                    $now,
                    $now,
                ]
            );
            $db->audit('device_register', ['device_id' => $deviceId, 'ip' => $req->ip]);
        } else {
            if ((int)$existing['blocked'] === 1) {
                throw new ApiException('IOS_DEVICE_BLOCKED', '本机已被封禁，请联系服务人员');
            }
            $db->exec(
                'UPDATE douy_devices SET public_key = ?, key_id = ?, ios_version = ?, bundle_id = ?, model = ?, last_seen_ms = ? WHERE id = ?',
                [$publicKey, $keyId, $req->str('ios_version'), $req->str('bundle_id'), $req->str('model'), $now, $existing['id']]
            );
        }

        $device = $db->one('SELECT * FROM douy_devices WHERE device_id = ?', [$deviceId]);
        Response::ok([
            'message' => '设备已登记',
            'device'  => ['device_id' => $device['device_id'], 'key_id' => $device['key_id'], 'blocked' => (int)$device['blocked'] === 1],
        ]);
    }

    public static function login(Db $db, array $config, Request $req, $ctx)
    {
        $loopback = ($req->ip === '127.0.0.1' || $req->ip === '::1');
        $skipLimit = !empty($config['app']['skip_rate_limit_for_loopback']) && $loopback;
        if (!$skipLimit) {
            RateLimit::hit($db, 'login:' . $req->ip, 10, 60);
        }

        $username = trim($req->str('username'));
        $password = $req->str('password');

        $account = $db->one('SELECT * FROM douy_accounts WHERE username = ?', [$username]);
        if ($account === null || !password_verify($password, $account['password_hash'])) {
            $db->audit('login_fail', ['ip' => $req->ip], ['username' => $username]);
            throw new ApiException('IOS_LOGIN_INVALID', '账号或密码错误，验证失败，请重试');
        }
        if ($account['status'] !== 'active') {
            throw new ApiException('ACCOUNT_DISABLED', '账号已被停用，请联系服务人员');
        }

        // 第一步只发挑战，不发会话
        $challenge = Crypto::randomHex(32);
        $now = now_ms();
        $db->insert(
            'INSERT INTO douy_challenges (challenge, username, device_id, created_at_ms, expires_at_ms, used) VALUES (?,?,?,?,?,0)',
            [$challenge, $username, $req->header('x-douy-ios-device'), $now, $now + (int)$config['license']['challenge_ttl_ms']]
        );

        Response::ok([
            'challenge'              => $challenge,
            'login_session_protocol' => 'douy-ios-challenge-v1',
            'expires_ms'             => $now + (int)$config['license']['challenge_ttl_ms'],
            'account'                => ['id' => (int)$account['id'], 'username' => $account['username']],
        ]);
    }

    public static function loginSession(Db $db, array $config, Request $req, $ctx)
    {
        $username  = trim($req->str('username'));
        $challenge = $req->str('challenge');
        $response  = $req->str('challenge_response');

        $row = $db->one('SELECT * FROM douy_challenges WHERE challenge = ? AND username = ?', [$challenge, $username]);
        if ($row === null || (int)$row['used'] === 1 || (int)$row['expires_at_ms'] <= now_ms()) {
            throw new ApiException('IOS_LOGIN_INVALID', '登录挑战已失效，请重新登录');
        }
        if ($response === '') {
            throw new ApiException('IOS_REQUEST_INVALID', '缺少 challenge_response');
        }

        // 用本机设备公钥验签挑战
        $device = $db->one('SELECT * FROM douy_devices WHERE device_id = ?', [(string)$req->header('x-douy-ios-device')]);
        if ($device === null) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '无法读取本机安全身份');
        }
        if (!Crypto::verifyDevice($device['key_id'], $device['public_key'], $challenge, $response)) {
            throw new ApiException('IOS_LOGIN_INVALID', '本机签名失败（挑战响应不通过）');
        }

        $db->exec('UPDATE douy_challenges SET used = 1 WHERE id = ?', [$row['id']]);

        $account = $db->one('SELECT * FROM douy_accounts WHERE username = ?', [$username]);
        if ($account === null || $account['status'] !== 'active') {
            throw new ApiException('ACCOUNT_DISABLED', '账号已被停用，请联系服务人员');
        }

        $session = Auth::createSession($db, $config, $account['id'], $device['device_id'], $req->ip, $req->ua);
        $db->exec('UPDATE douy_accounts SET last_login_at = NOW(), last_login_ip = ? WHERE id = ?', [$req->ip, $account['id']]);
        $db->exec('UPDATE douy_devices SET account_id = ? WHERE id = ?', [$account['id'], $device['id']]);
        $db->audit('login', ['account_id' => $account['id'], 'device_id' => $device['device_id'], 'ip' => $req->ip]);

        Response::ok([
            'session_token' => $session['token'],
            'expires_ms'    => $session['expires_ms'],
            'account'       => [
                'id'           => (int)$account['id'],
                'username'     => $account['username'],
                'email'        => $account['email'],
                'status'       => $account['status'],
                'device_id'    => $device['device_id'],
                'capabilities' => [
                    'wallet_add'         => true,
                    'automatic_renewal'  => !empty($config['license']['automatic_renewal']),
                ],
            ],
        ]);
    }

    public static function logout(Db $db, array $config, Request $req, $ctx)
    {
        if (!empty($ctx['token'])) {
            Auth::revoke($db, $ctx['token']);
        }
        Response::ok(['message' => '已退出，请登录']);
    }
}

class LicenseController
{
    public static function status(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $device = $ctx['device'];
        if ($device === null) {
            $device = $db->one('SELECT * FROM douy_devices WHERE device_id = ?', [(string)$req->header('x-douy-ios-device')]);
        }
        $deviceId = $device !== null ? $device['device_id'] : '';

        // 防篡改（可选）：与登记时的哈希比对
        $moduleHash = $req->str('module_text_sha256', '');
        if ($moduleHash !== '' && $device !== null) {
            if (empty($device['module_hash'])) {
                $db->exec('UPDATE douy_devices SET module_hash = ? WHERE id = ?', [$moduleHash, $device['id']]);
            } elseif ($device['module_hash'] !== $moduleHash) {
                $db->audit('module_changed', ['account_id' => $account['id'], 'device_id' => $deviceId],
                    ['old' => $device['module_hash'], 'new' => $moduleHash]);
                throw new ApiException('IOS_MODULE_CHANGED', '插件运行代码发生变化，请重新安装官方版本');
            }
        }

        list($card, $switched, , $state) = LicenseService::resolveLicense($db, $config, $account, $deviceId);

        $license = null;
        $lease = null;
        if ($card !== null) {
            $license = LicenseService::issueLicense($db, $config, $account, $card, $device !== null ? $device['ios_version'] : null);
            $lease = LicenseService::ensureLease($db, $config, $account['id'], $card['id'], $deviceId);
        }

        $cards = LicenseService::listCards($db, $account['id'], $deviceId);

        Response::ok([
            'account' => [
                'id'         => (int)$account['id'],
                'username'   => $account['username'],
                'email'      => $account['email'],
                'status'     => $account['status'],
                'device_id'  => $deviceId,
            ],
            'license'  => $license,
            'license_state' => $state,
            'license_switched' => $switched,
            'lease'    => $lease,
            'cards'    => $cards,
            'has_more' => false,
            'automatic_renewal' => !empty($config['license']['automatic_renewal']),
            'message'  => $switched ? '已自动续用备用卡，授权到期时间已更新'
                        : ($card !== null ? '授权有效' : '已登录 · 请激活卡密或刷新核实授权'),
        ]);
    }

    public static function activate(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $device = $ctx['device'];
        $deviceId = $device !== null ? $device['device_id'] : $req->str('device_id');
        if ($deviceId === '') {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '无法读取本机安全身份');
        }

        $keyCode = normalize_key_code($req->str('key_code'));
        if ($keyCode === '') {
            throw new ApiException('IOS_REQUEST_INVALID', '请先输入兜鱼 iOS 卡密');
        }

        $card = $db->one('SELECT * FROM douy_cards WHERE key_code = ?', [$keyCode]);
        if ($card === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '卡密不存在，请检查是否输入正确');
        }
        if ($card['status'] === 'revoked') {
            throw new ApiException('IOS_REQUEST_INVALID', '该卡密已被吊销，请联系服务人员');
        }
        if ($card['account_id'] !== null && (int)$card['account_id'] !== (int)$account['id']) {
            throw new ApiException('IOS_REQUEST_INVALID', '该卡密已归属其他账号');
        }
        if ($card['device_id'] !== null && $card['device_id'] !== $deviceId) {
            throw new ApiException('LICENSE_BOUND_TO_OTHER_DEVICE', '该卡密已绑定其他手机，请先解绑或使用“换绑到本机”');
        }
        if ($card['expires_ms'] !== null && (int)$card['expires_ms'] <= now_ms()) {
            throw new ApiException('IOS_REQUEST_INVALID', '该卡密已过期');
        }

        $db->begin();
        try {
            if ($card['account_id'] === null) {
                $db->exec('UPDATE douy_cards SET account_id = ? WHERE id = ?', [$account['id'], $card['id']]);
                $card['account_id'] = $account['id'];
            }
            $card = LicenseService::bindCardToDevice($db, $config, $card, $account['id'], $deviceId, 'bind');

            // 签名放在同一个事务里：万一服务端密钥有问题，绑定也一起回滚，
            // 不会出现"卡已被绑定并开始计时，但客户端只拿到 500"的脏状态。
            $license = LicenseService::issueLicense($db, $config, $account, $card);

            $db->commit();
        } catch (Throwable $e) {
            $db->rollback();
            throw $e;
        }

        $db->audit('activate', ['account_id' => $account['id'], 'device_id' => $deviceId, 'card_id' => $card['id'], 'ip' => $req->ip]);
        Response::ok([
            'message' => '卡密已激活并绑定本机，正在核实授权',
            'license' => $license,
            'cards'   => LicenseService::listCards($db, $account['id'], $deviceId),
        ]);
    }

    public static function walletAdd(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $deviceId = (string)$req->header('x-douy-ios-device', '');

        $keyCode = normalize_key_code($req->str('key_code'));
        $card = $db->one('SELECT * FROM douy_cards WHERE key_code = ?', [$keyCode]);
        if ($card === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '卡密不存在，请检查是否输入正确');
        }
        if ($card['status'] === 'revoked') {
            throw new ApiException('IOS_REQUEST_INVALID', '该卡密已被吊销');
        }
        if ($card['account_id'] !== null && (int)$card['account_id'] !== (int)$account['id']) {
            throw new ApiException('IOS_REQUEST_INVALID', '该卡密已归属其他账号');
        }

        if ($card['account_id'] === null) {
            $db->exec('UPDATE douy_cards SET account_id = ?, status = ? WHERE id = ?', [$account['id'], 'standby', $card['id']]);
        } elseif ($card['status'] === 'unused') {
            $db->exec('UPDATE douy_cards SET status = ? WHERE id = ?', ['standby', $card['id']]);
        }

        $card = $db->one('SELECT * FROM douy_cards WHERE id = ?', [$card['id']]);
        $db->audit('wallet_add', ['account_id' => $account['id'], 'device_id' => $deviceId, 'card_id' => $card['id']]);

        Response::ok([
            'message' => '新卡已加入卡包',
            'card'    => [
                'id'        => (int)$card['id'],
                'days'      => (int)$card['days'],
                'masked'    => $card['masked'],
                'status'    => $card['status'],
                'expires_ms' => $card['expires_ms'] !== null ? (int)$card['expires_ms'] : null,
            ],
            'cards'   => LicenseService::listCards($db, $account['id'], $deviceId),
        ]);
    }

    public static function bind(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $cardId = $req->int('card_id');
        $deviceId = (string)$req->header('x-douy-ios-device', '');

        $card = $db->one('SELECT * FROM douy_cards WHERE id = ? AND account_id = ?', [$cardId, $account['id']]);
        if ($card === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '卡密不存在或不属于当前账号');
        }
        if ($card['device_id'] !== null && $card['device_id'] !== $deviceId) {
            throw new ApiException('LICENSE_BOUND_TO_OTHER_DEVICE', '将这张卡密转到当前安装前，请先确认旧安装已停止');
        }

        $db->begin();
        try {
            $card = LicenseService::bindCardToDevice($db, $config, $card, $account['id'], $deviceId, 'bind');
            $license = LicenseService::issueLicense($db, $config, $account, $card);
            $db->commit();
        } catch (Throwable $e) {
            $db->rollback();
            throw $e;
        }

        $db->audit('bind', ['account_id' => $account['id'], 'device_id' => $deviceId, 'card_id' => $card['id']]);

        Response::ok([
            'message' => $card['activated_at_ms'] === null ? '已开始计时并绑定本机' : '已绑定到本机',
            'license' => $license,
            'cards'   => LicenseService::listCards($db, $account['id'], $deviceId),
        ]);
    }

    public static function unbind(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $cardId = $req->int('card_id');
        $deviceId = (string)$req->header('x-douy-ios-device', '');

        $card = $db->one('SELECT * FROM douy_cards WHERE id = ? AND account_id = ?', [$cardId, $account['id']]);
        if ($card === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '卡密不存在或不属于当前账号');
        }
        if ($card['device_id'] === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '这张卡密当前没有绑定设备');
        }

        $db->exec('UPDATE douy_cards SET device_id = NULL, status = ? WHERE id = ?', ['standby', $card['id']]);
        $db->exec('UPDATE douy_leases SET revoked = 1 WHERE card_id = ?', [$card['id']]);
        $db->insert(
            'INSERT INTO douy_bindings (card_id, device_id, account_id, action, reason, ip) VALUES (?,?,?,?,?,?)',
            [$card['id'], $card['device_id'], $account['id'], 'unbind', 'user', $req->ip]
        );
        $db->audit('unbind', ['account_id' => $account['id'], 'device_id' => $deviceId, 'card_id' => $card['id']]);

        Response::ok([
            'message' => '解绑后本机停止替换，卡密保留在此账号；剩余时间不会暂停。',
            'cards'   => LicenseService::listCards($db, $account['id'], $deviceId),
        ]);
    }

    public static function move(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $cardId = $req->int('card_id');
        $deviceId = (string)$req->header('x-douy-ios-device', '');

        $card = $db->one('SELECT * FROM douy_cards WHERE id = ? AND account_id = ?', [$cardId, $account['id']]);
        if ($card === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '卡密不存在或不属于当前账号');
        }

        $expected = $req->str('expected_device_id', '');
        if ($expected !== '' && $card['device_id'] !== null && $card['device_id'] !== $expected) {
            throw new ApiException('IOS_REQUEST_INVALID', '该卡密绑定的设备已变化，请刷新卡包后重试');
        }

        $oldDevice = $card['device_id'];

        $db->begin();
        try {
            $card = LicenseService::bindCardToDevice($db, $config, $card, $account['id'], $deviceId, 'move');
            $db->exec('UPDATE douy_leases SET revoked = 1 WHERE card_id = ? AND device_id <> ?', [$card['id'], $deviceId]);
            $license = LicenseService::issueLicense($db, $config, $account, $card);
            $db->commit();
        } catch (Throwable $e) {
            $db->rollback();
            throw $e;
        }

        if ($oldDevice !== null && $oldDevice !== $deviceId) {
            $db->insert(
                'INSERT INTO douy_bindings (card_id, device_id, account_id, action, reason, ip) VALUES (?,?,?,?,?,?)',
                [$card['id'], $oldDevice, $account['id'], 'move', 'to:' . $deviceId, $req->ip]
            );
        }
        $db->audit('move', ['account_id' => $account['id'], 'device_id' => $deviceId, 'card_id' => $card['id']],
            ['from' => $oldDevice, 'to' => $deviceId]);

        Response::ok([
            'message' => '已换绑到本机；旧安装的短期授权最迟 90 秒失效，到期时间不变。',
            'license' => $license,
            'cards'   => LicenseService::listCards($db, $account['id'], $deviceId),
        ]);
    }
}

class PaymentController
{
    public static function plans(Db $db, array $config, Request $req, $ctx)
    {
        $softwareId = (string)$req->query('software_id', 'douy_ios_injection');
        $rows = $db->all(
            'SELECT id, title, days_valid, price, qr_code_url, recommend FROM douy_plans
             WHERE software_id = ? AND active = 1 ORDER BY sort_order ASC, days_valid ASC',
            [$softwareId]
        );
        $plans = [];
        foreach ($rows as $r) {
            if (stripos($r['qr_code_url'], 'https://') !== 0) {
                // 与原版一致：收款码必须来自授权服务器的 HTTPS 地址
                continue;
            }
            $plans[] = [
                'id'          => (int)$r['id'],
                'days_valid'  => (int)$r['days_valid'],
                'price'       => (float)$r['price'],
                'qr_code_url' => $r['qr_code_url'],
                'title'       => $r['title'],
                'recommend'   => (int)$r['recommend'] === 1,
            ];
        }
        Response::ok(['plans' => $plans]);
    }

    public static function createOrder(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $planId = $req->int('plan_id');

        $plan = $db->one('SELECT * FROM douy_plans WHERE id = ? AND active = 1', [$planId]);
        if ($plan === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '套餐不存在或已下架');
        }
        if (stripos($plan['qr_code_url'], 'https://') !== 0) {
            throw new ApiException('IOS_REQUEST_INVALID', '收款码必须来自授权服务器的 HTTPS 地址，请管理员检查套餐配置。');
        }

        $now = now_ms();
        $remark = 'FX' . strtoupper(substr(Crypto::randomHex(4), 0, 8));
        $orderId = $db->insert(
            'INSERT INTO douy_orders (account_id, plan_id, days, price, status, remark_code, qr_code_url, created_at_ms, expires_at_ms)
             VALUES (?,?,?,?,?,?,?,?,?)',
            [$account['id'], $plan['id'], (int)$plan['days_valid'], $plan['price'], 'pending', $remark,
             $plan['qr_code_url'], $now, $now + 1800000]
        );

        $db->audit('order_create', ['account_id' => $account['id'], 'ip' => $req->ip],
            ['order_id' => $orderId, 'plan_id' => $plan['id']]);

        Response::ok([
            'order' => [
                'id'          => $orderId,
                'status'      => 'pending',
                'days'        => (int)$plan['days_valid'],
                'price'       => (float)$plan['price'],
                'remark_code' => $remark,
                'qr_code_url' => $plan['qr_code_url'],
                'expires_ms'  => $now + 1800000,
            ],
            'message' => '付款备注必须填写：' . $remark,
        ]);
    }

    public static function orderStatus(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $orderId = (int)$req->query('id', 0);

        $order = $db->one('SELECT * FROM douy_orders WHERE id = ? AND account_id = ?', [$orderId, $account['id']]);
        if ($order === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '订单不存在');
        }

        $payload = [
            'order' => [
                'id'          => (int)$order['id'],
                'status'      => $order['status'],
                'days'        => (int)$order['days'],
                'price'       => (float)$order['price'],
                'remark_code' => $order['remark_code'],
                'card_id'     => $order['card_id'] !== null ? (int)$order['card_id'] : null,
                'paid_at_ms'  => $order['paid_at_ms'] !== null ? (int)$order['paid_at_ms'] : null,
            ],
        ];

        if ($order['status'] === 'paid') {
            $payload['message'] = '检测到新增卡密，已存入下方卡包。全新备用卡尚未开始计时。';
        } elseif ((int)$order['expires_at_ms'] <= now_ms()) {
            $payload['message'] = '暂未检测到新卡，请稍后刷新卡包。如已付款，请勿重复支付。';
        } else {
            $payload['message'] = '正在查询新卡到账…如已付款，请勿重复支付。';
        }

        Response::ok($payload);
    }
}

class UpdateController
{
    public static function check(Db $db, array $config, Request $req, $ctx)
    {
        $channel = $req->str('channel', 'stable');
        $installed = $req->int('installed_version_code', 0);
        $product = $req->str('product', 'DOUY');
        $pluginId = $req->str('plugin_id', 'douy-ios-hook');
        $iosVersion = $req->str('ios_version', '14.0');
        $architecture = $req->str('architecture', 'arm64');
        $platform = $req->str('platform', 'ios');

        if ($architecture !== 'arm64' || $platform !== 'ios') {
            throw new ApiException('IOS_REQUEST_INVALID', '文件不是正确渠道和序号的 arm64 插件');
        }
        if (version_compare($iosVersion, '14.0', '<')) {
            throw new ApiException('IOS_REQUEST_INVALID', '当前系统版本过低，最低要求 iOS 14.0');
        }

        $row = $db->one(
            'SELECT * FROM douy_updates WHERE product = ? AND plugin_id = ? AND channel = ? AND active = 1
             ORDER BY version_code DESC LIMIT 1',
            [$product, $pluginId, $channel]
        );

        if ($row === null || (int)$row['version_code'] <= $installed) {
            Response::ok(['has_update' => false, 'message' => '当前没有可用的新版本，现有授权正常使用。']);
            return;
        }

        $payload = [
            'v'            => 1,
            'aud'          => $config['license']['signal_aud_update'],
            'version_code' => (int)$row['version_code'],
            'version_name' => $row['version_name'],
            'sha256'       => $row['sha256'],
            'size'         => (int)$row['size'],
            'channel'      => $row['channel'],
            'generation'   => (int)$row['generation'],
            'release'      => (string)$row['release_tag'],
            'iat_ms'       => now_ms(),
            'exp_ms'       => now_ms() + 600000,
        ];
        $json = Crypto::canonicalJson($payload);
        $signed = Crypto::signPayload($db, $config, $json);

        Response::ok([
            'has_update'      => true,
            'version_code'    => (int)$row['version_code'],
            'version_name'    => $row['version_name'],
            'size'            => (int)$row['size'],
            'sha256'          => $row['sha256'],
            'changelog'       => (string)$row['changelog'],
            'min_ios'         => $row['min_ios'],
            'force_update'    => (int)$row['force_update'] === 1,
            'target_sha256'   => $row['sha256'],
            'release_channel' => $row['channel'],
            'generation'      => (int)$row['generation'],
            'message'         => '发现新版 ' . $row['version_name'] . '，建议下播后下载。',
            'signed_update'   => [
                'payload'   => base64_encode($json),
                'signature' => $signed['signature'],
                'kid'       => $signed['kid'],
            ],
        ]);
    }

    /** 申请一次性下载凭证（要求登录 + 本机有有效授权） */
    public static function requestDownload(Db $db, array $config, Request $req, $ctx)
    {
        $auth = Auth::requireAccount($db, $req);
        $account = $auth['account'];
        $device = $ctx['device'];
        if ($device === null) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '无法读取本机安全身份');
        }

        $versionCode = $req->int('version_code');
        $target = $req->str('target_sha256');
        $row = $db->one(
            'SELECT * FROM douy_updates WHERE version_code = ? AND active = 1 ORDER BY id DESC LIMIT 1',
            [$versionCode]
        );
        if ($row === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '新版下载信息无效，已拒绝下载');
        }
        if ($target !== '' && !hash_equals($row['sha256'], $target)) {
            throw new ApiException('IOS_REQUEST_INVALID', '下载内容与已确认的新版本不一致');
        }

        list($card, , , $state) = LicenseService::resolveLicense($db, $config, $account, $device['device_id']);
        if ($card === null || $state !== 'active') {
            throw new ApiException('IOS_LOGIN_REQUIRED', '本机下载身份验证失败，请先登录并激活卡密。');
        }

        // 每日配额
        $dayKey = date('Y-m-d');
        $limit = (int)$config['license']['download_daily_limit'];
        $db->q(
            'INSERT INTO douy_downloads (card_id, account_id, device_id, day_key, count) VALUES (?,?,?,?,1)
             ON DUPLICATE KEY UPDATE count = count + 1',
            [$card['id'], $account['id'], $device['device_id'], $dayKey]
        );
        $count = (int)$db->scalar(
            'SELECT count FROM douy_downloads WHERE card_id = ? AND day_key = ?',
            [$card['id'], $dayKey]
        );
        if ($count > $limit) {
            throw new ApiException('IOS_RATE_LIMITED', '今日下载次数已用完（每张卡密每天 ' . $limit . ' 次），请明天再试');
        }

        $token = Crypto::randomHex(32);
        $now = now_ms();
        $db->insert(
            'INSERT INTO douy_download_tokens (token, version_code, card_id, device_id, sha256, created_at_ms, expires_at_ms, used)
             VALUES (?,?,?,?,?,?,?,0)',
            [$token, (int)$row['version_code'], $card['id'], $device['device_id'], $row['sha256'], $now,
             $now + (int)$config['license']['download_token_ttl_ms']]
        );

        $db->audit('download_request', ['account_id' => $account['id'], 'device_id' => $device['device_id'],
            'card_id' => $card['id'], 'ip' => $req->ip], ['version_code' => (int)$row['version_code']]);

        Response::ok([
            'download_url' => rtrim($config['app']['base_url'], '/') . '/api/ios/update/download?token=' . $token,
            'expires_ms'   => $now + (int)$config['license']['download_token_ttl_ms'],
            'daily_limit'  => $limit,
            'remaining'    => max(0, $limit - $count),
            'sha256'       => $row['sha256'],
            'size'         => (int)$row['size'],
        ]);
    }

    /** GET 二进制下载 */
    public static function download(Db $db, array $config, Request $req, $ctx)
    {
        $token = (string)$req->query('token', '');
        if (!preg_match('/^[0-9a-f]{32,128}$/', $token)) {
            throw new ApiException('IOS_REQUEST_INVALID', '下载地址无效');
        }

        $row = $db->one('SELECT * FROM douy_download_tokens WHERE token = ?', [$token]);
        if ($row === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '下载地址无效');
        }
        if ((int)$row['used'] === 1) {
            throw new ApiException('IOS_REQUEST_INVALID', '下载链接已用过，请重新申请');
        }
        if ((int)$row['expires_at_ms'] <= now_ms()) {
            throw new ApiException('IOS_REQUEST_INVALID', '下载链接已过期，或设备时间不正确，请重新检查');
        }

        $update = $db->one('SELECT * FROM douy_updates WHERE version_code = ? AND active = 1 ORDER BY id DESC LIMIT 1',
            [(int)$row['version_code']]);
        if ($update === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '新版下载信息无效，已拒绝下载');
        }

        $path = rtrim($config['paths']['updates'], '/\\') . DIRECTORY_SEPARATOR . $update['file_path'];
        if (!is_file($path)) {
            throw new ApiException('IOS_REQUEST_INVALID', '更新文件暂不可用，请稍后重试');
        }
        if (!hash_equals($update['sha256'], hash_file('sha256', $path))) {
            throw new ApiException('IOS_REQUEST_INVALID', '文件大小或 SHA-256 校验失败，已删除下载文件');
        }

        $db->exec('UPDATE douy_download_tokens SET used = 1 WHERE token = ?', [$token]);
        $db->audit('download', ['device_id' => $row['device_id'], 'card_id' => $row['card_id'], 'ip' => $req->ip],
            ['version_code' => (int)$row['version_code']]);

        Response::binary($path, 'DOUY.dylib');
    }
}
