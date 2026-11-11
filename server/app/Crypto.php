<?php
/**
 * 密码学：设备公钥验签（ECDSA P-256 / Ed25519）+ 服务端签名
 *
 * 依赖：openssl 扩展（PHP 7.3 自带）。
 * Ed25519 需要底层 OpenSSL >= 1.1.1；不可用时自动降级为"仅 ECDSA"，
 * 并在签名接口上只使用 ECDSA。
 */
class Crypto
{
    const ED25519_SPKI_PREFIX = '302a300506032b6570032100';
    const ED25519_PKCS8_PREFIX = '302e020100300506032b657004220420';

    private static $serverKey = null;      // ['kid'=>..., 'alg'=>..., 'pkey'=>resource]
    private static $ed25519Supported = null;

    public static function ed25519Supported()
    {
        if (self::$ed25519Supported !== null) {
            return self::$ed25519Supported;
        }
        self::$ed25519Supported = false;
        if (OPENSSL_VERSION_NUMBER >= 0x10101000) {
            $pem = self::ed25519PublicPem(str_repeat("\x11", 32));
            $key = @openssl_pkey_get_public($pem);
            if ($key !== false) {
                self::$ed25519Supported = true;
                openssl_free_key($key);
            }
        }
        return self::$ed25519Supported;
    }

    public static function randomHex($bytes = 32)
    {
        return bin2hex(random_bytes($bytes));
    }

    public static function sha256Hex($data)
    {
        return hash('sha256', $data);
    }

    public static function ed25519PublicPem($raw32)
    {
        $der = hex2bin(self::ED25519_SPKI_PREFIX) . $raw32;
        return "-----BEGIN PUBLIC KEY-----\n"
            . chunk_split(base64_encode($der), 64, "\n")
            . "-----END PUBLIC KEY-----\n";
    }

    public static function ed25519PrivatePem($seed32)
    {
        $der = hex2bin(self::ED25519_PKCS8_PREFIX) . $seed32;
        return "-----BEGIN PRIVATE KEY-----\n"
            . chunk_split(base64_encode($der), 64, "\n")
            . "-----END PRIVATE KEY-----\n";
    }

    /** 把客户端上传的 base64 公钥变成 PEM */
    public static function publicKeyPem($keyId, $publicKeyB64)
    {
        $raw = base64_decode($publicKeyB64, true);
        if ($raw === false || strlen($raw) < 32) {
            return null;
        }
        if ($keyId === 'ed25519-1') {
            if (strlen($raw) !== 32) {
                return null;
            }
            return self::ed25519PublicPem($raw);
        }
        // ec-p256-1：DER(SubjectPublicKeyInfo) 的 base64
        return "-----BEGIN PUBLIC KEY-----\n"
            . chunk_split(base64_encode($raw), 64, "\n")
            . "-----END PUBLIC KEY-----\n";
    }

    public static function deviceIdFromPublicKey($publicKeyB64)
    {
        $raw = base64_decode($publicKeyB64, true);
        if ($raw === false) {
            return null;
        }
        return substr(hash('sha256', $raw), 0, 40);
    }

    /**
     * 验设备签名。
     * @param string $keyId   'ec-p256-1' | 'ed25519-1'
     * @param string $publicKeyB64
     * @param string $data    待验签字节
     * @param string $sigB64  签名（base64）
     */
    public static function verifyDevice($keyId, $publicKeyB64, $data, $sigB64)
    {
        $sig = base64_decode($sigB64, true);
        if ($sig === false || $sig === '') {
            return false;
        }
        $pem = self::publicKeyPem($keyId, $publicKeyB64);
        if ($pem === null) {
            return false;
        }
        $pub = @openssl_pkey_get_public($pem);
        if ($pub === false) {
            return false;
        }

        if ($keyId === 'ed25519-1') {
            if (!self::ed25519Supported()) {
                return false;
            }
            $ok = @openssl_verify($data, $sig, $pub, 0) === 1;
        } else {
            $ok = @openssl_verify($data, $sig, $pub, OPENSSL_ALGO_SHA256) === 1;
        }
        self::freeKey($pub);
        return $ok;
    }

    private static function freeKey($key)
    {
        if (PHP_VERSION_ID < 80000 && function_exists('openssl_free_key')) {
            @openssl_free_key($key);
        }
    }

    /** 载入服务端签名私钥（优先 ECDSA P-256；没有则用 Ed25519） */
    public static function loadServerKey(Db $db, array $config)
    {
        if (self::$serverKey !== null) {
            return self::$serverKey;
        }

        $row = $db->one('SELECT * FROM douy_server_keys WHERE active = 1 ORDER BY (kid = ?) DESC, created_at ASC LIMIT 1', ['ec-p256-1']);
        if ($row === null) {
            throw new RuntimeException('服务端签名密钥未初始化：请先执行 php bin/douyctl.php key:gen');
        }

        $path = $row['private_path'];
        if (!is_file($path)) {
            // 允许配置里给绝对路径
            $alt = rtrim($config['paths']['keys'], '/\\') . DIRECTORY_SEPARATOR . basename($path);
            if (is_file($alt)) {
                $path = $alt;
            } else {
                throw new RuntimeException('服务端私钥文件不存在: ' . $row['private_path']);
            }
        }

        if (!is_readable($path)) {
            throw new RuntimeException(
                '服务端私钥不可读: ' . $path
                . ' （属主/权限问题：php-fpm 用户需要有读权限。'
                . '请在服务器执行：chown -R www:www keys && chmod 640 keys/*.pem）'
            );
        }

        $pem = @file_get_contents($path);
        if ($pem === false || trim($pem) === '') {
            throw new RuntimeException('服务端私钥为空或读取失败: ' . $path
                . '（如果是 key:gen 生成的，请检查磁盘空间与权限）');
        }
        if (strpos($pem, 'BEGIN') === false) {
            throw new RuntimeException('服务端私钥内容不是 PEM: ' . $path
                . '（文件可能被截断，重新执行 php bin/douyctl.php key:gen --force）');
        }
        $pkey = @openssl_pkey_get_private($pem);
        if ($pkey === false) {
            throw new RuntimeException('服务端私钥无法载入: ' . openssl_error_string());
        }

        self::$serverKey = [
            'kid'  => $row['kid'],
            'alg'  => $row['alg'],
            'pkey' => $pkey,
        ];
        return self::$serverKey;
    }

    /** 用服务端私钥签名，返回 ['signature'=>base64, 'kid'=>...] */
    public static function signPayload(Db $db, array $config, $data)
    {
        $key = self::loadServerKey($db, $config);
        $sig = '';
        if ($key['alg'] === 'Ed25519') {
            $ok = @openssl_sign($data, $sig, $key['pkey'], 0);
        } else {
            $ok = @openssl_sign($data, $sig, $key['pkey'], OPENSSL_ALGO_SHA256);
        }
        if (!$ok) {
            throw new RuntimeException('服务端签名失败: ' . openssl_error_string());
        }
        return ['signature' => base64_encode($sig), 'kid' => $key['kid']];
    }

    /** 服务端公钥（客户端内置的就是它） */
    public static function serverPublicKeyB64(Db $db)
    {
        $row = $db->one('SELECT kid, public_key FROM douy_server_keys WHERE active = 1 ORDER BY (kid = ?) DESC, created_at ASC LIMIT 1', ['ec-p256-1']);
        return $row;
    }

    /** 规范化 JSON（签名/验签必须两边一致：键有序、无多余空白） */
    public static function canonicalJson(array $data)
    {
        self::sortKeys($data);
        return json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    private static function sortKeys(array &$data)
    {
        ksort($data, SORT_STRING);
        foreach ($data as &$v) {
            if (is_array($v)) {
                self::sortKeys($v);
            }
        }
    }
}
