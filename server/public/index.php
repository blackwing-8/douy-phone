<?php
/**
 * 兜鱼复刻版 · 授权服务入口（前端控制器）
 *
 * 支持：
 *   - Apache + .htaccess（推荐）
 *   - Nginx: location / { try_files $uri /index.php?$query_string; }
 *   - PHP 内置服务器：php -S 127.0.0.1:8080 -t public public/index.php
 */

require dirname(__DIR__) . '/app/bootstrap.php';

set_exception_handler('douy_handle_exception');

// 路由表：[方法 路径] => [控制器, 方法, 签名策略]
//   签名策略：none=不需要设备签名  optional=有就验  required=必须验  self=用请求体公钥自验签
$routes = [
    'POST /api/register'                            => ['AuthController', 'register', 'none'],
    'POST /api/ios/plugin/device/register'          => ['AuthController', 'deviceRegister', 'self'],
    'POST /api/ios/plugin/login'                    => ['AuthController', 'login', 'optional'],
    'POST /api/ios/plugin/login_session'             => ['AuthController', 'loginSession', 'optional'],
    'POST /api/ios/plugin/logout'                    => ['AuthController', 'logout', 'required'],
    'POST /api/ios/plugin/account/status'            => ['LicenseController', 'status', 'required'],
    'POST /api/ios/plugin/activate'                  => ['LicenseController', 'activate', 'required'],
    'POST /api/ios/plugin/wallet/add'                => ['LicenseController', 'walletAdd', 'required'],
    'POST /api/ios/plugin/bind'                      => ['LicenseController', 'bind', 'required'],
    'POST /api/ios/plugin/unbind'                    => ['LicenseController', 'unbind', 'required'],
    'POST /api/ios/plugin/move'                      => ['LicenseController', 'move', 'required'],
    'GET /api/payment_plans'                         => ['PaymentController', 'plans', 'none'],
    'POST /api/orders'                               => ['PaymentController', 'createOrder', 'required'],
    'GET /api/orders/status'                         => ['PaymentController', 'orderStatus', 'required'],
    'POST /api/ios/update/check'                     => ['UpdateController', 'check', 'optional'],
    'POST /api/ios/update/download'                  => ['UpdateController', 'requestDownload', 'required'],
    'GET /api/ios/update/download'                   => ['UpdateController', 'download', 'none'],
];

try {
    $req = Request::capture($config);

    // 去掉查询串得到纯路径
    $purePath = parse_url($req->path, PHP_URL_PATH);
    if (!is_string($purePath) || $purePath === '') {
        $purePath = '/';
    }
    $purePath = rtrim($purePath, '/');
    if ($purePath === '') {
        $purePath = '/';
    }

    // 健康检查
    if ($purePath === '/' || $purePath === '/health') {
        Response::send(['success' => true, 'code' => 'OK', 'message' => 'DOUY license server', 'time_ms' => now_ms()]);
        return;
    }

    $key = $req->method . ' ' . $purePath;
    if (!isset($routes[$key])) {
        Response::fail('IOS_REQUEST_INVALID', '接口不存在: ' . $key, [], 404);
        return;
    }

    list($controller, $action, $proofMode) = $routes[$key];
    $db = douy_db($config);

    // 设备签名
    $device = null;
    if ($proofMode === 'required') {
        $device = Proof::verify($db, $config, $req);
    } elseif ($proofMode === 'optional') {
        try {
            $device = Proof::verify($db, $config, $req);
        } catch (ApiException $e) {
            // 允许未注册设备调用（登录第一步 / 更新检查）
            $device = null;
        }
    } elseif ($proofMode === 'self') {
        Proof::verify($db, $config, $req, ['self_signed_key' => true]);
        $device = null;
    }

    // 会话（有就解析，没有则由控制器决定是否必须）
    $token = '';
    $authHeader = (string)$req->header('authorization', '');
    if (preg_match('/^Frame-Session\s+([0-9a-f]{32,128})$/i', trim($authHeader), $m)) {
        $token = $m[1];
    } elseif ($req->str('session_token') !== '') {
        $token = $req->str('session_token');
    }

    $ctx = ['device' => $device, 'token' => $token, 'ip' => $req->ip, 'config' => $config];

    call_user_func([$controller, $action], $db, $config, $req, $ctx);
} catch (ApiException $e) {
    douy_handle_exception($e);
} catch (Throwable $e) {
    douy_handle_exception($e);
}
