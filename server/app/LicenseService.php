<?php
/**
 * 卡密 / 授权 / 租约 的核心业务逻辑
 *
 * 术语（与原版一致）：
 *   unused  卡密未售出或未入卡包
 *   standby 已入卡包但未绑定（未计时 / 或解绑后继续计时）
 *   bound   已绑定某台设备、计时中
 *   expired 已过期
 *   revoked 已吊销
 */

class LicenseService
{
    const DAY_MS = 86400000;

    public static function maskKey($keyCode)
    {
        $clean = preg_replace('/[^A-Za-z0-9]/', '', $keyCode);
        $tail = substr($clean, -4);
        $prefix = 'DOUY';
        return $prefix . '-****-' . strtoupper($tail);
    }

    public static function generateKeyCode(array $config)
    {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 去掉易混字符
        $groups = [];
        for ($g = 0; $g < 3; $g++) {
            $s = '';
            for ($i = 0; $i < 4; $i++) {
                $s .= $alphabet[random_int(0, strlen($alphabet) - 1)];
            }
            $groups[] = $s;
        }
        return $config['license']['card_prefix'] . '-' . implode('-', $groups);
    }

    /** 卡密是否在计时（已激活） */
    public static function isCounting(array $card)
    {
        return $card['activated_at_ms'] !== null && $card['expires_ms'] !== null;
    }

    public static function normalizeCardStatus(array $card)
    {
        if ($card['status'] === 'revoked') {
            return 'revoked';
        }
        if ($card['expires_ms'] !== null && (int)$card['expires_ms'] <= now_ms()) {
            return 'expired';
        }
        return $card['status'];
    }

    /** 设备当前的有效绑定卡（可能为 null） */
    public static function boundCardForDevice(Db $db, $accountId, $deviceId)
    {
        return $db->one(
            'SELECT * FROM douy_cards
             WHERE account_id = ? AND device_id = ? AND status = ?
             ORDER BY expires_ms DESC, id DESC LIMIT 1',
            [$accountId, $deviceId, 'bound']
        );
    }

    /** 账号下可用的备用卡（优先未计时的新卡，其次已计时但解绑的） */
    public static function pickStandbyCard(Db $db, $accountId)
    {
        return $db->one(
            'SELECT * FROM douy_cards
             WHERE account_id = ? AND status = ? AND (expires_ms IS NULL OR expires_ms > ?)
             ORDER BY (activated_at_ms IS NULL) DESC, expires_ms ASC, id ASC LIMIT 1',
            [$accountId, 'standby', now_ms()]
        );
    }

    /**
     * 结算一次"当前授权"：
     *  - 绑定卡过期 → 若开启自动续用，取备用卡接续
     *  - 返回 [license|null, switched(bool), card|null]
     */
    public static function resolveLicense(Db $db, array $config, array $account, $deviceId)
    {
        $card = self::boundCardForDevice($db, $account['id'], $deviceId);
        $switched = false;

        if ($card !== null && (int)$card['expires_ms'] <= now_ms()) {
            // 过期：标记 + 尝试续用
            $db->exec('UPDATE douy_cards SET status = ? WHERE id = ?', ['expired', $card['id']]);
            $card = null;

            if (!empty($config['license']['automatic_renewal'])) {
                $next = self::pickStandbyCard($db, $account['id']);
                if ($next !== null) {
                    $card = self::bindCardToDevice($db, $config, $next, $account['id'], $deviceId, 'auto_switch');
                    $switched = true;
                }
            }
        }

        if ($card === null) {
            $standby = self::pickStandbyCard($db, $account['id']);
            $state = $standby !== null ? 'standby' : 'none';
            return [null, $switched, null, $state];
        }

        $state = (int)$card['expires_ms'] > now_ms() ? 'active' : 'expired';
        return [$card, $switched, $card, $state];
    }

    /** 把卡绑到设备：若未计时则开始计时 */
    public static function bindCardToDevice(Db $db, array $config, array $card, $accountId, $deviceId, $action = 'bind')
    {
        $now = now_ms();
        $expires = $card['expires_ms'];
        if ($expires === null) {
            $expires = $now + (int)$card['days'] * self::DAY_MS;
        }

        $db->exec(
            'UPDATE douy_cards SET account_id = ?, device_id = ?, status = ?, activated_at_ms = COALESCE(activated_at_ms, ?),
                    expires_ms = ?, duration_ms = COALESCE(NULLIF(duration_ms,0), ?) WHERE id = ?',
            [$accountId, $deviceId, 'bound', $now, $expires, (int)$card['days'] * self::DAY_MS, $card['id']]
        );

        $db->insert(
            'INSERT INTO douy_bindings (card_id, device_id, account_id, action, reason, ip) VALUES (?,?,?,?,?,?)',
            [$card['id'], $deviceId, $accountId, $action, null, null]
        );

        // 旧租约作废
        $db->exec('UPDATE douy_leases SET revoked = 1 WHERE card_id = ? AND device_id <> ?', [$card['id'], $deviceId]);

        return $db->one('SELECT * FROM douy_cards WHERE id = ?', [$card['id']]);
    }

    /** 生成并签名授权凭证（客户端存 Keychain） */
    public static function issueLicense(Db $db, array $config, array $account, array $card, $deviceIos = null)
    {
        $generation = (int)$db->scalar(
            'SELECT COALESCE(MAX(generation),0) + 1 FROM douy_leases WHERE card_id = ?',
            [$card['id']]
        );

        $payload = [
            'v'                 => 1,
            'aud'               => $config['license']['signal_aud_license'],
            'user_id'           => (int)$account['id'],
            'card_id'           => (int)$card['id'],
            'device_id'         => $card['device_id'],
            'iat_ms'            => now_ms(),
            'exp_ms'            => (int)$card['expires_ms'],
            'license_expiry_ms' => (int)$card['expires_ms'],
            'duration_ms'       => (int)$card['duration_ms'],
            'generation'        => $generation,
            'channel'           => 'stable',
        ];
        if ($deviceIos !== null) {
            $payload['ios_version'] = (string)$deviceIos;
        }

        $json = Crypto::canonicalJson($payload);
        $signed = Crypto::signPayload($db, $config, $json);

        return [
            'state'      => 'active',
            'card_id'    => (int)$card['id'],
            'masked'     => $card['masked'],
            'expires_ms' => (int)$card['expires_ms'],
            'generation' => $payload['generation'],
            'payload'    => base64_encode($json),
            'signature'  => $signed['signature'],
            'kid'        => $signed['kid'],
        ];
    }

    /** 90 秒租约（续租/新建） */
    public static function ensureLease(Db $db, array $config, $accountId, $cardId, $deviceId)
    {
        $now = now_ms();
        $ttl = (int)$config['license']['lease_ttl_ms'];

        $existing = $db->one(
            'SELECT * FROM douy_leases WHERE card_id = ? AND device_id = ? AND revoked = 0 AND expires_ms > ?
             ORDER BY id DESC LIMIT 1',
            [$cardId, $deviceId, $now + 5000]
        );
        if ($existing !== null) {
            $db->exec('UPDATE douy_leases SET last_seen_ms = ? WHERE id = ?', [$now, $existing['id']]);
            return ['token' => $existing['token'], 'expires_ms' => (int)$existing['expires_ms']];
        }

        $db->exec('UPDATE douy_leases SET revoked = 1 WHERE device_id = ? AND revoked = 0', [$deviceId]);

        $token = Crypto::randomHex(32);
        $generation = (int)$db->scalar('SELECT COALESCE(MAX(generation),0) FROM douy_leases WHERE card_id = ?', [$cardId]) + 1;
        $db->insert(
            'INSERT INTO douy_leases (token, card_id, device_id, account_id, generation, issued_at_ms, expires_ms, revoked, last_seen_ms)
             VALUES (?,?,?,?,?,?,?,0,?)',
            [$token, $cardId, $deviceId, $accountId, $generation, $now, $now + $ttl, $now]
        );

        return ['token' => $token, 'expires_ms' => $now + $ttl];
    }

    /** 卡包列表（客户端 UI 用） */
    public static function listCards(Db $db, $accountId, $deviceId)
    {
        $rows = $db->all(
            'SELECT * FROM douy_cards WHERE account_id = ? ORDER BY (status = ?) DESC, expires_ms DESC, id DESC LIMIT 50',
            [$accountId, 'bound']
        );
        $out = [];
        $now = now_ms();
        foreach ($rows as $r) {
            $status = self::normalizeCardStatus($r);
            $current = ($r['device_id'] !== null && $r['device_id'] === $deviceId);
            $out[] = [
                'id'             => (int)$r['id'],
                'expires_ms'     => $r['expires_ms'] !== null ? (int)$r['expires_ms'] : null,
                'days'           => (int)$r['days'],
                'masked'         => $r['masked'],
                'device_id'      => $r['device_id'],
                'current_device' => $current,
                'usable'         => ($status === 'bound' && (int)$r['expires_ms'] > $now) || $status === 'standby',
                'fresh'          => ($r['activated_at_ms'] === null),
                'status'         => $status,
            ];
        }
        return $out;
    }
}
