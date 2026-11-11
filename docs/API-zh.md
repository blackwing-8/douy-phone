# 兜鱼复刻版 · 授权服务 API 规范（douy-ios-proof-v1）

> 这份文档是 **iOS 客户端** 与 **PHP 服务端** 的唯一契约。
> 路径、请求头、错误码、字段名都尽量沿用原版二进制里能看到的字符串，
> 以便把"复刻差异"压到最小；原版私有实现无法看到的部分（服务端代码、根私钥、
> 数据库结构）在这里是**同构重写**，不是复制，见 §9。

---

## 1. 约定

- 基础地址：`https://<你的域名>`（例：`https://www.ybdskj.top`，可配置）
- 所有业务接口：`POST` + `Content-Type: application/json`
- 响应：`200` + JSON 信封；协议级错误也走 200，业务码放在 `code`
- 时间统一 **Unix 毫秒**（`*_ms`）
- 字符集 UTF-8，服务端严格校验 JSON（拒绝 > 64 KB 的请求体）

### 1.1 响应信封

```json
{ "success": true,  "code": "OK",      "message": "…", ...业务字段 }
{ "success": false, "code": "IOS_LOGIN_REQUIRED", "message": "请先登录" }
```

### 1.2 业务码（与原版字符串一致）

| code | HTTP 场景 | 含义 |
|---|---|---|
| `OK` | — | 成功 |
| `IOS_REQUEST_INVALID` | 400 | 请求体/字段非法 |
| `IOS_REGISTER_INVALID` | 200 | 注册字段不合法（含两次密码不一致） |
| `IOS_LOGIN_REQUIRED` | 200 | 未登录 / 会话失效 |
| `IOS_LOGIN_INVALID` | 200 | 账号或密码错误 |
| `ACCOUNT_DISABLED` | 200 | 账号被停用 |
| `IOS_DEVICE_BLOCKED` | 200 | 设备被封禁 |
| `IOS_LOCAL_IDENTITY_INVALID` | 200 | 设备身份（公钥/指纹）无效 |
| `LICENSE_BOUND_TO_OTHER_DEVICE` | 200 | 卡密已绑定别的设备 |
| `IOS_MODULE_CHANGED` | 200 | 插件代码哈希不匹配（防篡改） |
| `IOS_LEASE_REJECTED` | 200 | 短期租约被拒（过期/错绑/被顶号） |
| `IOS_SESSION_BUSY` | 200 | 同账号并发会话过多（附 `retry_after_ms`） |
| `IOS_RATE_LIMITED` | 200 | 频率限制（附 `retry_after_ms`） |
| `IOS_RESPONSE_INVALID` | 200 | 服务端返回结构异常（客户端侧使用） |
| `IOS_SERVER_UPGRADE_REQUIRED` | 200 | 服务端接口需升级 |
| `IOS_NETWORK_FAILED` | 200 | 网络异常（客户端侧使用） |

---

## 2. 设备身份与请求签名（核心）

### 2.1 设备密钥

客户端首次运行生成 **ECDSA P-256** 密钥对（优先 Secure Enclave，失败则普通 Keychain），
或 **Ed25519**（CryptoKit `Curve25519.Signing`）。私钥永不离开设备。

| `X-DOUY-IOS-Key` | 算法 | 公钥格式 |
|---|---|---|
| `ec-p256-1` | ECDSA P-256 + SHA-256 | base64(X.509 SubjectPublicKeyInfo DER) |
| `ed25519-1` | Ed25519 | base64(32 字节裸公钥) |

`device_id` = `SHA256(公钥 DER)` 的 hex 前 40 字符（客户端计算，服务端复核）。

### 2.2 每个请求都带这些头

```
X-DOUY-IOS-Proof:     douy-ios-proof-v1
X-DOUY-IOS-Key:       ec-p256-1 | ed25519-1
X-DOUY-IOS-Role:      child
X-DOUY-IOS-Time:      1730000000000          ; unix ms
X-DOUY-IOS-Nonce:     32 位 hex（每次唯一）
X-DOUY-IOS-Device:    <device_id>
X-DOUY-IOS-Signature: base64(签名)
Authorization:         Frame-Session <session_token>   ; 登录后必需
```

### 2.3 签名原文（逐字节）

```
douy-ios-proof-v1\n
<METHOD>\n
<PATH_WITH_QUERY>\n
<X-DOUY-IOS-Time>\n
<X-DOUY-IOS-Nonce>\n
<SHA256_HEX(请求体)>\n
<X-DOUY-IOS-Device>\n
<X-DOUY-IOS-Key>
```

- 方法大写；路径以 `/` 开头，**包含查询串**（如 `/api/payment_plans?software_id=douy_ios_injection`）
- 请求体为空时 `SHA256_HEX("")`；**必须是发送的原始字节**，不要重新序列化
- ECDSA 用 SHA-256 + DER 签名；Ed25519 为 64 字节裸签名
- 末尾**不带换行**

### 2.4 服务端校验

1. `X-DOUY-IOS-Proof` 必须等于 `douy-ios-proof-v1`
2. `|now - time| <= 300_000 ms`
3. `nonce` 未用过（`douy_nonces` 唯一索引，保留 10 分钟）
4. 用 `douy_devices.public_key` 验签，失败 → `IOS_LOCAL_IDENTITY_INVALID`
5. 设备 `blocked=1` → `IOS_DEVICE_BLOCKED`
6. 缺签名/头不全 → `IOS_REQUEST_INVALID`

> 未注册的设备只允许调用 `device/register`、`payment_plans`、`update/check`。

---

## 3. 账号

### 3.1 `POST /api/register`

```json
{"username":"abc_01","password":"pass1234","confirm_password":"pass1234",
 "email":"a@b.com","referral_code":"XYZ123"}
```
- 用户名 3–20 位字母/数字/下划线；密码 6–50 位且**必须含字母和数字**；邮箱必填
- 成功：`{"success":true,"code":"OK","message":"注册成功，请登录"}`

### 3.2 `POST /api/ios/plugin/login`

```json
{"username":"abc_01","password":"pass1234"}
```
成功返回挑战（用于二次验证，避免密码留在设备）：

```json
{"success":true,"code":"OK",
 "challenge":"<随机 hex>","login_session_protocol":"douy-ios-challenge-v1",
 "expires_ms": 1730000060000}
```

### 3.3 `POST /api/ios/plugin/login_session`

```json
{"username":"abc_01","challenge":"<上一步 challenge>",
 "challenge_response":"base64(设备私钥对 challenge 的签名)"}
```
成功：

```json
{"success":true,"code":"OK",
 "session_token":"<64 hex>","expires_ms":1730086400000,
 "account":{"id":12,"username":"abc_01","email":"a@b.com","status":"active",
            "device_id":"<本机>","capabilities":{"wallet_add":true,"automatic_renewal":true}}}
```

### 3.4 `POST /api/ios/plugin/logout`
`{}` → `{"success":true,"code":"OK"}`（作废当前 session_token）

---

## 4. 卡密与授权

### 4.1 `POST /api/ios/plugin/account/status`

请求：`{"device_id":"<本机>","module_text_sha256":"<可选>"}`

响应（这是客户端主页最主要的数据源）：

```json
{"success":true,"code":"OK",
 "account":{"id":12,"username":"abc_01","device_id":"<本机>","status":"active"},
 "license":{"state":"active","expires_ms":1732500000000,
            "card_id":34,"masked":"DOUY-****-9F2A","generation":7,
            "payload":{...},"signature":"base64","kid":"ec-p256-1"},
 "lease":{"token":"<hex>","expires_ms":1730000090000},
 "cards":[{"id":34,"expires_ms":1732500000000,"days":30,"masked":"DOUY-****-9F2A",
           "device_id":"<本机>","current_device":true,"usable":true,"fresh":false,
           "status":"bound"}],
 "has_more":false,
 "automatic_renewal":true}
```

- `license.state` ∈ `active` / `standby`（备用卡未计时）/ `expired` / `none`
- `lease.expires_ms` 默认 **+90 秒**（与原版"最迟 90 秒失效"一致），客户端每 60 秒续租
- 服务端对 `module_text_sha256`（若提供）与 `douy_devices.module_hash` 比对，
  不一致且已激活 → `IOS_MODULE_CHANGED`

### 4.2 `POST /api/ios/plugin/activate`（激活并绑定本机）

```json
{"key_code":"DOUY-XXXXXXXXXXXX","device_id":"<本机>"}
```
- 卡密不存在/已用/被吊销 → `IOS_REQUEST_INVALID` + 原因
- 卡密已绑其他设备 → `LICENSE_BOUND_TO_OTHER_DEVICE`
- 本机已有有效授权 → 仍允许激活新卡（原版允许"换绑"，但 UI 会提示"仅加入备用卡包"）
- 成功：`{"success":true,"code":"OK","license":{...同 4.1...},"cards":[...]}`

### 4.3 `POST /api/ios/plugin/wallet/add`（仅存备用，不计时）

```json
{"key_code":"DOUY-XXXXXXXXXXXX"}
```
→ `{"success":true,"code":"OK","card":{"id":41,"status":"standby","days":30}}`

### 4.4 `POST /api/ios/plugin/bind` / `unbind` / `move`

```json
{"card_id":34}                                  // bind：备用卡绑到本机并开始计时
{"card_id":34}                                  // unbind：解绑（剩余时间不暂停）
{"card_id":41,"expected_device_id":"<旧设备>"}   // move：把卡换绑到本机（旧安装 90 秒内失效）
```

### 4.5 计时语义（与原版一致）

- 卡密在**首次绑定**时开始计时：`expires_ms = now + days*86400000`
- 解绑不暂停计时（余额继续走）
- 到期后若账号还有备用卡，`automatic_renewal=true` 时自动接续
  （响应里带 `license_switched:true` + 新卡信息）

---

## 5. 购买

### 5.1 `GET /api/payment_plans?software_id=douy_ios_injection`

```json
{"success":true,"code":"OK",
 "plans":[{"id":3,"days_valid":30,"price":68.00,"qr_code_url":"https://…/qr30.png",
           "title":"30 天","recommend":true}]}
```

### 5.2 `POST /api/orders`（创建订单，返回收款码与备注码）

```json
{"plan_id":3}
```
```json
{"success":true,"code":"OK",
 "order":{"id":1001,"status":"pending","days":30,"price":68.00,
          "remark_code":"FX12AB34","qr_code_url":"https://…/qr30.png",
          "expires_ms":1730001800000}}
```

### 5.3 `GET /api/orders/status?id=1001`

- `status` ∈ `pending` / `paid` / `cancelled`
- `paid` 时附 `card_id`（新卡已进卡包，`status=standby`，未计时）

> 到账由管理员在后台确认（`php bin/douyctl.php order:pay 1001`），
> 自动发卡逻辑同原版："付款备注写账号/备注码，确认后自动进卡包"。

---

## 6. 更新

### 6.1 `POST /api/ios/update/check`

```json
{"channel":"stable","product":"DOUY","plugin_id":"douy-ios-hook",
 "ios_version":"14.0","architecture":"arm64","platform":"ios",
 "installed_version_code":58,"install_method":"injector","agent_channel":"stable",
 "update_protocol":"douy-ios-plugin-update","device_id":"<本机>"}
```
有新版：

```json
{"success":true,"code":"OK","has_update":true,
 "version_code":59,"version_name":"0.1.9","size":2421936,
 "sha256":"<hex>","changelog":"…","min_ios":"14.0","force_update":false,
 "target_sha256":"<hex>","release_channel":"stable","generation":59,
 "signed_update":{"payload":"base64(JSON)","signature":"base64","kid":"ec-p256-1"}}
```
无新版：`{"success":true,"code":"OK","has_update":false,"message":"当前没有可用的新版本，现有授权正常使用。"}`

`signed_update.payload` 解码后：

```json
{"v":1,"aud":"douy-ios-plugin-update","kid":"ec-p256-1","version_code":59,
 "version_name":"0.1.9","sha256":"<hex>","size":2421936,"channel":"stable",
 "generation":59,"release":"release-59","iat_ms":1730000000000,"exp_ms":1730000600000}
```

### 6.2 `POST /api/ios/update/download` → 一次性下载凭证

```json
{"version_code":59,"device_id":"<本机>","target_sha256":"<hex>","request_id":"<uuid>"}
```
```json
{"success":true,"code":"OK",
 "download_url":"https://…/api/ios/update/download?token=<hex>",
 "expires_ms":1730000060000,"daily_limit":5,"remaining":4}
```

### 6.3 `GET /api/ios/update/download?token=…`

直接返回**二进制**（`application/octet-stream`），凭证一次性、绑定设备与本机卡密、
24 小时内有效；每张已激活卡密**每天 5 次**。

---

## 7. 频率限制

| 维度 | 限制 |
|---|---|
| 单设备非查询类接口 | 30 次 / 分钟 |
| 登录 | 10 次 / 分钟 / 账号 |
| 注册 | 5 次 / 小时 / IP |
| 更新下载 | 5 次 / 天 / 卡密 |
| 同账号并发会话 | 8（超出 `IOS_SESSION_BUSY`） |

---

## 8. 客户端行为（与原版文案对齐）

| 场景 | 提示文案（沿用原版） |
|---|---|
| 未登录 | `已退出，请登录` |
| 联网验证中 | `正在联网验证授权…` |
| 授权有效 | `授权有效` |
| 备用卡接续 | `已自动续用备用卡，授权到期时间已更新` |
| 代码被改 | `插件运行代码发生变化，请重新安装官方版本` |
| 卡密错绑 | `授权签名或绑定验证失败` |
| 租约被拒 | `授权凭证格式无效` |
| 离线宽限 | 本地 `license.expires_ms` 到期 + 宽限 0 秒（原版无离线宽限，只有 90 秒租约） |

---

## 9. 与原版的差异（诚实清单）

| 项 | 原版 | 本实现 | 为什么 |
|---|---|---|---|
| 服务端代码 | 闭源，不在二进制里 | 同构重写（PHP + MySQL） | 只能从客户端字符串反推契约 |
| 根签名私钥 | 只在厂商服务器 | **我们自己的**密钥（`bin/douyctl.php key:gen`） | 原版私钥不可能从客户端取得；这是数学上不可复制的部分 |
| 签名原文格式 | 未泄漏（只能看到 `douy-ios-proof-v1` 字面量与 6 个头名） | §2.3 明确定义 | 需要双方一致；原文细节是我们补的 |
| `device_id` 算法 | 未泄漏 | `SHA256(公钥)` 前 40 hex | 同上 |
| 数据库 | 未泄漏（只能看到 `software_id=douy_ios_injection` 之类） | 见 `server/app/schema.sql` | 同上 |
| 接口路径 | `/api/register`、`/api/ios/plugin/*`、`/api/payment_plans`、`/api/ios/update/*` | **完全一致** | 字符串表里能直接读到 |
| 请求头名 | `X-DOUY-IOS-Proof/Role/Time/Nonce/Key/Signature` | **完全一致**（+`X-DOUY-IOS-Device`） | 同上 |
| 错误码 | `IOS_*` 全套 | **完全一致** | 同上 |
| 卡密计时/租约/换绑/解绑语义 | 见分析报告 | 按同样语义实现 | 文案与字段表可反推 |
| 更新校验 | SHA-256 + arm64 dylib + 构建序号 + 5 次/天 | **一致** | 字符串表明确 |
| 媒体帧格式 | `CSU1`/`CSC2`/`media packet` | 复刻版用 `FXP/2`（USB 链路） | 原版字节布局未泄漏，需要反汇编；两端都是我们的 |
