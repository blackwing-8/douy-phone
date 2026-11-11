<?php
/**
 * 统一响应与异常
 */

class ApiException extends Exception
{
    /** @var string */
    public $bizCode;
    /** @var int */
    public $httpStatus;
    /** @var array */
    public $extra;

    public function __construct($bizCode, $message = '', $httpStatus = 200, array $extra = [])
    {
        parent::__construct($message !== '' ? $message : $bizCode);
        $this->bizCode = $bizCode;
        $this->httpStatus = $httpStatus;
        $this->extra = $extra;
    }
}

class Response
{
    public static function send(array $payload, $httpStatus = 200)
    {
        if (!headers_sent()) {
            http_response_code($httpStatus);
            header('Content-Type: application/json; charset=utf-8');
            header('Cache-Control: no-store');
            header('X-Content-Type-Options: nosniff');
        }
        echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        return true;
    }

    public static function ok(array $fields = [])
    {
        $base = ['success' => true, 'code' => 'OK', 'message' => 'ok'];
        return self::send(array_merge($base, $fields));
    }

    public static function fail($code, $message, array $extra = [], $httpStatus = 200)
    {
        $base = ['success' => false, 'code' => $code, 'message' => $message];
        return self::send(array_merge($base, $extra), $httpStatus);
    }

    /** 发二进制（插件下载用） */
    public static function binary($path, $filename, $mime = 'application/octet-stream')
    {
        if (!is_file($path)) {
            return self::fail('IOS_REQUEST_INVALID', '文件不存在', [], 404);
        }
        if (!headers_sent()) {
            http_response_code(200);
            header('Content-Type: ' . $mime);
            header('Content-Length: ' . filesize($path));
            header('Content-Disposition: attachment; filename="' . $filename . '"');
            header('Cache-Control: no-store');
        }
        readfile($path);
        return true;
    }
}
