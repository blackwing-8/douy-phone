<?php
/**
 * 请求上下文 + 请求签名校验（douy-ios-proof-v1）
 */

class Request
{
    /** @var string GET/POST */
    public $method;
    /** @var string 带查询串的路径 */
    public $path;
    /** @var array 原始头（小写键） */
    public $headers = [];
    /** @var string 原始请求体字节 */
    public $rawBody = '';
    /** @var array 解析后的 JSON */
    public $json = [];
    /** @var string */
    public $ip = '';
    /** @var string */
    public $ua = '';

    public static function capture(array $config)
    {
        $req = new self();
        $req->method = isset($_SERVER['REQUEST_METHOD']) ? strtoupper($_SERVER['REQUEST_METHOD']) : 'GET';
        $uri = isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/';
        $req->path = $uri === '' ? '/' : $uri;

        foreach ($_SERVER as $k => $v) {
            if (strpos($k, 'HTTP_') === 0) {
                $name = strtolower(str_replace('_', '-', substr($k, 5)));
                $req->headers[$name] = $v;
            }
        }
        if (isset($_SERVER['CONTENT_TYPE'])) {
            $req->headers['content-type'] = $_SERVER['CONTENT_TYPE'];
        }
        $req->ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
        $req->ua = isset($req->headers['user-agent']) ? substr($req->headers['user-agent'], 0, 255) : '';

        $raw = file_get_contents('php://input');
        if ($raw === false) {
            $raw = '';
        }
        if (strlen($raw) > $config['app']['max_body']) {
            throw new ApiException('IOS_REQUEST_INVALID', '服务器响应过大', 413);
        }
        $req->rawBody = $raw;

        if ($raw !== '') {
            $decoded = json_decode($raw, true);
            if (!is_array($decoded)) {
                throw new ApiException('IOS_REQUEST_INVALID', '请求体不是合法 JSON', 400);
            }
            $req->json = $decoded;
        }

        return $req;
    }

    public function header($name, $default = null)
    {
        $name = strtolower($name);
        return isset($this->headers[$name]) ? $this->headers[$name] : $default;
    }

    public function input($key, $default = null)
    {
        return array_key_exists($key, $this->json) ? $this->json[$key] : $default;
    }

    public function str($key, $default = '')
    {
        $v = $this->input($key, $default);
        return is_string($v) ? $v : (is_scalar($v) ? (string)$v : $default);
    }

    public function int($key, $default = 0)
    {
        $v = $this->input($key, $default);
        if (is_int($v)) {
            return $v;
        }
        if (is_float($v)) {
            return (int)$v;
        }
        if (is_string($v) && preg_match('/^-?\d+$/', $v)) {
            return (int)$v;
        }
        return $default;
    }

    public function bool($key, $default = false)
    {
        $v = $this->input($key, $default);
        if (is_bool($v)) {
            return $v;
        }
        if (is_int($v)) {
            return $v !== 0;
        }
        return $default;
    }

    public function query($key, $default = null)
    {
        return isset($_GET[$key]) ? $_GET[$key] : $default;
    }
}

class Proof
{
    /**
     * 校验请求签名，返回设备行（未注册且允许时返回 null）。
     *
     * $opts:
     *   allow_unregistered  bool  未注册设备放行（不验签），用于 payment_plans / update/check
     *   self_signed_key     bool  用请求体里的 public_key 验签（device/register）
     */
    public static function verify(Db $db, array $config, Request $req, array $opts = [])
    {
        $proof = $req->header('x-douy-ios-proof');
        $keyId = $req->header('x-douy-ios-key');
        $role  = $req->header('x-douy-ios-role');
        $time  = $req->header('x-douy-ios-time');
        $nonce = $req->header('x-douy-ios-nonce');
        $deviceId = $req->header('x-douy-ios-device');
        $sig   = $req->header('x-douy-ios-signature');

        if ($proof !== 'douy-ios-proof-v1') {
            throw new ApiException('IOS_REQUEST_INVALID', '缺少或非法的 X-DOUY-IOS-Proof', 400);
        }
        if ($role === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '缺少 X-DOUY-IOS-Role', 400);
        }
        if (!in_array($keyId, ['ec-p256-1', 'ed25519-1'], true)) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '不支持的设备密钥类型: ' . (string)$keyId);
        }
        if ($time === null || !preg_match('/^\d{1,16}$/', $time)) {
            throw new ApiException('IOS_REQUEST_INVALID', '缺少或非法的 X-DOUY-IOS-Time', 400);
        }
        $nowMs = now_ms();
        if (abs($nowMs - (int)$time) > $config['app']['clock_skew_ms']) {
            throw new ApiException('IOS_REQUEST_INVALID', '设备时间与服务端偏差过大，请校准时间');
        }
        if ($nonce === null || !preg_match('/^[0-9a-f]{16,64}$/', $nonce)) {
            throw new ApiException('IOS_REQUEST_INVALID', '缺少或非法的 X-DOUY-IOS-Nonce', 400);
        }

        // 防重放
        try {
            $db->insert(
                'INSERT INTO douy_nonces (nonce, device_id, created_at_ms) VALUES (?,?,?)',
                [substr($nonce, 0, 32), $deviceId !== null ? substr($deviceId, 0, 40) : null, $nowMs]
            );
        } catch (PDOException $e) {
            throw new ApiException('IOS_SESSION_BUSY', '请求已被处理过（nonce 重复）', 200, ['retry_after_ms' => 1000]);
        }
        if ($db->scalar('SELECT COUNT(*) FROM douy_nonces WHERE created_at_ms < ?', [$nowMs - 600000]) > 20000) {
            // 顺手清理，避免表膨胀
            $db->exec('DELETE FROM douy_nonces WHERE created_at_ms < ?', [$nowMs - 600000]);
        }

        $device = null;
        if ($deviceId !== null) {
            $device = $db->one('SELECT * FROM douy_devices WHERE device_id = ?', [substr($deviceId, 0, 40)]);
        }

        if ($device === null && !empty($opts['self_signed_key'])) {
            // device/register：用请求体里的公钥验签
            $pub = $req->str('public_key');
            if ($pub === '') {
                throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '无法读取本机安全身份（缺少 public_key）');
            }
            self::checkSignature($keyId, $pub, $req, $time, $nonce, $deviceId, $sig);
            return null;
        }

        if ($device === null) {
            if (!empty($opts['allow_unregistered'])) {
                return null;
            }
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '无法读取本机安全身份（设备未注册）');
        }

        if ((int)$device['blocked'] === 1) {
            throw new ApiException('IOS_DEVICE_BLOCKED', '本机已被封禁，请联系服务人员');
        }
        if ($device['key_id'] !== $keyId) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '设备密钥类型与注册信息不一致');
        }

        self::checkSignature($keyId, $device['public_key'], $req, $time, $nonce, $deviceId, $sig);

        $db->exec('UPDATE douy_devices SET last_seen_ms = ? WHERE id = ?', [$nowMs, $device['id']]);
        return $device;
    }

    private static function checkSignature($keyId, $publicKeyB64, Request $req, $time, $nonce, $deviceId, $sig)
    {
        if ($sig === null) {
            throw new ApiException('IOS_REQUEST_INVALID', '缺少 X-DOUY-IOS-Signature', 400);
        }

        $canonical = 'douy-ios-proof-v1' . "\n"
            . $req->method . "\n"
            . $req->path . "\n"
            . $time . "\n"
            . $nonce . "\n"
            . Crypto::sha256Hex($req->rawBody) . "\n"
            . (string)$deviceId . "\n"
            . $keyId;

        if (!Crypto::verifyDevice($keyId, $publicKeyB64, $canonical, $sig)) {
            throw new ApiException('IOS_LOCAL_IDENTITY_INVALID', '本机签名失败（请求验签不通过）');
        }
    }
}

class RateLimit
{
    public static function hit(Db $db, $bucket, $limit, $windowSec)
    {
        $now = time();
        $windowStart = $now - ($now % $windowSec);
        $db->q(
            'INSERT INTO douy_rate (bucket, window_start, counter) VALUES (?,?,1)
             ON DUPLICATE KEY UPDATE counter = counter + 1',
            [$bucket, $windowStart]
        );
        $count = (int)$db->scalar('SELECT counter FROM douy_rate WHERE bucket = ? AND window_start = ?', [$bucket, $windowStart]);
        if ($count > $limit) {
            throw new ApiException('IOS_RATE_LIMITED', '请求过于频繁，请稍后再试', 200, [
                'retry_after_ms' => ($windowStart + $windowSec - $now) * 1000,
            ]);
        }
        return $count;
    }
}
