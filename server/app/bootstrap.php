<?php
/**
 * 启动引导：配置、自动加载、错误处理、通用工具
 */

declare(strict_types=0);

error_reporting(E_ALL);
ini_set('display_errors', '0');   // 统一走我们的响应格式

$config = require dirname(__DIR__) . '/config.php';

date_default_timezone_set($config['app']['timezone']);

spl_autoload_register(function ($class) {
    $dir = __DIR__;
    $candidates = [
        $dir . '/' . $class . '.php',
        $dir . '/Controllers/' . $class . '.php',
    ];
    foreach ($candidates as $file) {
        if (is_file($file)) {
            require $file;
            return;
        }
    }
});

require __DIR__ . '/Http.php';
require __DIR__ . '/Db.php';
require __DIR__ . '/Crypto.php';
require __DIR__ . '/Proof.php';
require __DIR__ . '/Auth.php';
require __DIR__ . '/LicenseService.php';
require __DIR__ . '/Controllers.php';

/*
 * Windows 上的 PHP 常找不到 openssl.cnf，导致 openssl_pkey_new / openssl_pkey_get_private
 * 报 "system library:fopen:No such process"。这里自动探测并设置 OPENSSL_CONF。
 */
if (DIRECTORY_SEPARATOR === '\\' && getenv('OPENSSL_CONF') === false && defined('PHP_BINARY') && PHP_BINARY !== '') {
    $phpDir = dirname(PHP_BINARY);
    $candidates = [
        $phpDir . '/extras/ssl/openssl.cnf',
        $phpDir . '/extras/openssl.cnf',
        $phpDir . '/openssl.cnf',
    ];
    foreach ($candidates as $candidate) {
        if (is_file($candidate)) {
            putenv('OPENSSL_CONF=' . $candidate);
            break;
        }
    }
}

function now_ms()
{
    return (int)floor(microtime(true) * 1000);
}

/** 卡密规范化：只保留 A-Z0-9- */
function normalize_key_code($raw)
{
    $s = strtoupper(trim((string)$raw));
    $s = preg_replace('/[^A-Z0-9\-]/', '', $s);
    $s = preg_replace('/-+/', '-', $s);
    return trim($s, '-');
}

function douy_log($message)
{
    $line = '[' . date('Y-m-d H:i:s') . '] ' . $message . PHP_EOL;
    @file_put_contents(dirname(__DIR__) . '/storage/app.log', $line, FILE_APPEND);
}

function douy_db(array $config)
{
    static $db = null;
    if ($db === null) {
        $db = new Db($config['db']);
    }
    return $db;
}

/** 统一异常出口 */
function douy_handle_exception($e)
{
    global $config;
    if ($e instanceof ApiException) {
        Response::fail($e->bizCode, $e->getMessage(), $e->extra, $e->httpStatus);
        return;
    }

    douy_log('unhandled: ' . get_class($e) . ': ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine());

    $extra = [];
    if (!empty($config['app']['debug'])) {
        $extra['debug'] = [
            'type'    => get_class($e),
            'message' => $e->getMessage(),
            'file'    => $e->getFile() . ':' . $e->getLine(),
        ];
    }
    Response::fail('IOS_SERVER_UPGRADE_REQUIRED', '服务器内部错误，请稍后重试', $extra, 500);
}
