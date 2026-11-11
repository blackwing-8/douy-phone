<?php
/**
 * 会话与账号
 */

class Auth
{
    public static function createSession(Db $db, array $config, $accountId, $deviceId, $ip, $ua)
    {
        $max = (int)$config['license']['max_sessions_per_account'];
        $active = (int)$db->scalar(
            'SELECT COUNT(*) FROM douy_sessions WHERE account_id = ? AND revoked = 0 AND expires_at_ms > ?',
            [$accountId, now_ms()]
        );
        if ($active >= $max) {
            // 顶掉最早的一个，而不是直接拒绝（原版是 IOS_SESSION_BUSY，这里给一次机会）
            $oldest = $db->one(
                'SELECT id FROM douy_sessions WHERE account_id = ? AND revoked = 0 AND expires_at_ms > ? ORDER BY created_at_ms ASC LIMIT 1',
                [$accountId, now_ms()]
            );
            if ($oldest !== null) {
                $db->exec('UPDATE douy_sessions SET revoked = 1 WHERE id = ?', [$oldest['id']]);
            }
        }

        $token = Crypto::randomHex(32);
        $now = now_ms();
        $db->insert(
            'INSERT INTO douy_sessions (token, account_id, device_id, created_at_ms, expires_at_ms, revoked, ip, ua)
             VALUES (?,?,?,?,?,0,?,?)',
            [$token, $accountId, $deviceId, $now, $now + (int)$config['license']['session_ttl_ms'], $ip, $ua]
        );
        return ['token' => $token, 'expires_ms' => $now + (int)$config['license']['session_ttl_ms']];
    }

    /** 返回 ['account'=>row, 'session'=>row]，未登录抛 IOS_LOGIN_REQUIRED */
    public static function requireAccount(Db $db, Request $req)
    {
        $auth = $req->header('authorization', '');
        $token = '';
        if (is_string($auth) && preg_match('/^Frame-Session\s+([0-9a-f]{32,128})$/i', trim($auth), $m)) {
            $token = $m[1];
        }
        if ($token === '') {
            $token = $req->str('session_token');
        }
        if ($token === '' || !preg_match('/^[0-9a-f]{32,128}$/', $token)) {
            throw new ApiException('IOS_LOGIN_REQUIRED', '已退出，请登录');
        }

        $row = $db->one(
            'SELECT s.*, a.username, a.email, a.status AS account_status
             FROM douy_sessions s JOIN douy_accounts a ON a.id = s.account_id
             WHERE s.token = ? AND s.revoked = 0 AND s.expires_at_ms > ?',
            [$token, now_ms()]
        );
        if ($row === null) {
            throw new ApiException('IOS_LOGIN_REQUIRED', '登录已过期，请重新登录');
        }
        if ($row['account_status'] !== 'active') {
            throw new ApiException('ACCOUNT_DISABLED', '账号已被停用，请联系服务人员');
        }

        $account = $db->one('SELECT * FROM douy_accounts WHERE id = ?', [$row['account_id']]);
        return ['account' => $account, 'session' => $row, 'token' => $token];
    }

    public static function revoke(Db $db, $token)
    {
        $db->exec('UPDATE douy_sessions SET revoked = 1 WHERE token = ?', [$token]);
    }

    public static function revokeAll(Db $db, $accountId)
    {
        $db->exec('UPDATE douy_sessions SET revoked = 1 WHERE account_id = ?', [$accountId]);
    }
}
