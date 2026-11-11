# 为什么会有差异？—— 复刻差异清单（诚实版）

> **命名阶段已更新（2026-11）**：产品正式定名 **兜鱼 / DOUY**。
> 因此下文 §1.A 里"与原版逐字一致"的那些字符串，除了**接口路径与字段名**之外，
> 协议标识已统一改为 `douy-ios-*` / `X-DOUY-IOS-*`（见 `NAMING-zh.md` §3），
> 也就是说：**我们不再追求与原版的字符串一致，而是有意识地做区分**；
> §1.A 保留的是"当初从原版那里学到了什么"的记录。

> 你问"为什么有差异"。一句话：**能看到的都对齐了，看不到的只能同构重写。**
> 下面把"哪些一致、哪些是我补的、哪些数学上不可能一样"逐条列清楚。

---

## 1. 三种差异，性质完全不同

### A. 已经完全一致（从二进制里直接读出来的）

这些是原版 iOS 插件与 PC 插件字符串表里**明文存在**的东西，复刻版逐字对齐：

| 项 | 值 |
|---|---|
| 接口路径 | `/api/register`、`/api/ios/plugin/…`、`/api/payment_plans?software_id=douy_ios_injection`、`/api/ios/update/check`、`/api/ios/update/download` |
| 请求头名 | `X-DOUY-IOS-Proof`、`X-DOUY-IOS-Role`、`X-DOUY-IOS-Time`、`X-DOUY-IOS-Nonce`、`X-DOUY-IOS-Key`、`X-DOUY-IOS-Signature` |
| 证明方案标识 | `douy-ios-proof-v1`、`douy-ios-hook`、`douy-ios-plugin-update`、`douy-ios-challenge-v1` |
| 错误码 | `IOS_REQUEST_INVALID`、`IOS_LOGIN_REQUIRED`、`IOS_LOGIN_INVALID`、`ACCOUNT_DISABLED`、`IOS_DEVICE_BLOCKED`、`IOS_LOCAL_IDENTITY_INVALID`、`LICENSE_BOUND_TO_OTHER_DEVICE`、`IOS_MODULE_CHANGED`、`IOS_LEASE_REJECTED`、`IOS_SESSION_BUSY`、`IOS_RATE_LIMITED`、`IOS_RESPONSE_INVALID`、`IOS_SERVER_UPGRADE_REQUIRED`、`IOS_NETWORK_FAILED` |
| 响应字段 | `success` / `code` / `message`、`cards[]`（`id/expires_ms/days/masked/device_id/current_device/usable/fresh/has_more`）、`capabilities.wallet_add`、`automatic_renewal`、`license_expired_ms`、`duration_ms`、`generation`、`nonce`、`challenge`、`challenge_response`、`login_session_protocol`、`key_code`、`card_id`、`expected_device_id` |
| 卡密/租约语义 | 首次绑定开始计时、解绑不停表、备用卡自动接续、换绑旧机"最迟 90 秒失效"、每卡每天 5 次下载 |
| UI 文案 | 全部沿用原版字符串（如 `插件运行代码发生变化，请重新安装官方版本`、`已自动续用备用卡，授权到期时间已更新`、`本机已有有效授权；新卡请仅加入备用卡包`） |
| 设备端口 / 路径 | iPhone `28766`、RTMP 路径 `live/reecho`、`live` app（**我们刻意改为 28767 / live/douy，便于与原版共存**） |
| 数据库商品标识 | `software_id = douy_ios_injection`、`platform = ios`、`architecture = arm64`、`min_ios = 14.0` |

### B. 我按合理方式补的（原版没落在二进制里，必须自定义才能跑起来）

| 项 | 原版 | 复刻版 | 为什么要补 |
|---|---|---|---|
| **签名原文格式** | 未知。只能看到 `douy-ios-proof-v1` 字面量与 6 个头名 | `docs/API-zh.md §2.3` 明确定义（method/path/time/nonce/bodyhash/device/key 七段） | 服务端要能重算同一串字节才能验签，这段原文只能由我们定 |
| `device_id` 算法 | 未知（只有 `device_id` 字段名） | `SHA256(公钥 DER)[0:40]` | 同上；`strict_device_id=false` 时只作索引 |
| `challenge_response` 内容 | 未知 | 对 challenge 字符串做 ECDSA 签名 | 需要双方一致 |
| 服务端数据库结构 | 未知（只有 `software_id=douy_ios_injection` 这种线索） | 18 张表（见 `server/app/schema.sql`） | 表结构本来就在服务器上，客户端看不到 |
| 授权凭证 payload 字段顺序 | 未知 | 规范化 JSON（键排序）后签名 | 保证两端一致 |
| 接口补充 | 未见 `device/register` | 新增 `/api/ios/plugin/device/register` | 服务端必须先知道公钥才能验签；原版大概在其它接口里捎带 |

> 这些"补"的部分**不影响与原版的观感一致**（同样的头、同样的路径、同样的错误码、同样的文案），
> 只是位级格式由我们定义，PHP 端与 iOS 端都用它。

### C. 数学上不可能一样（这是重点）

| 项 | 为什么不可能 |
|---|---|
| **原版根签名私钥** | 私钥只在厂商服务器上。客户端里只有公钥/指纹（我们确实看到了 `ed25519-1`、Secure Enclave 相关 API）。**任何拿到 dylib 的人都无法生成能通过原版服务器校验的卡密，反过来也一样** —— 这是非对称密码的基本保证。所以我们只能用自己的密钥对。 |
| **原版签发的卡密/授权** | 同上。你的 PHP 服务端签出来的授权，只有你的客户端（内置你 `key:gen` 出来的公钥）认。 |
| **原版数据库里的真实数据** | 数据在厂商服务器上。 |

**推论**：这套复刻是"自己开一家店"，不是"复制厂商的钥匙"。
它不会让你的服务器去骗过原版插件，也不会让原版的卡密在你的服务器上生效。
如果你要的是"用原版 `DOUY.dylib` + 自己的服务器" —— 那需要伪造原版签名，
属于破解厂商的授权系统，这部分我不做，也做不了（没有私钥）。

---

## 2. 媒体链路（USB/RTMP）的差异

原版手机端解析的是 `CSU1` / `CSC2` / `media packet` 三层自定义二进制（字符串只有报错文案：
`invalid CSU1 magic`、`unsupported CSC2 version`、`media payload length is invalid`…），
**看不到字段布局**。要 100% 位级对齐必须反汇编 arm64 机器码，从几十个函数里还原结构体，
工作量很大且没有额外收益（两端都是我们的）。

复刻版用了重新设计的 `FXP/2`（28 字节头：magic/type/flags/channel/pts/dts/length），
对照见 `docs/PROTOCOL-zh.md`。校验规则是一一对应的：
magic 错、版本不支持、保留位非零、长度非法、PTS 超范围 —— 全都实现了。

> 如果你**一定要**位级还原 `CSU1`，那是另一个任务：需要我带 capstone 反汇编那 1.03 MB 的
> `__text`，定位到解析函数，把结构体一个字段一个字段抠出来。可以做，但请注意：
> 即使位级完全一致，原版手机端仍然会去原版服务器验授权（见 §1.C），**链路通了也用不了**。

---

## 3. 现在这套复刻的差异总表

| 维度 | 原版 | 复刻版 | 差异等级 |
|---|---|---|---|
| 手机端注入方式 | dylib + 注入器 | 同 | 无 |
| hook 位置 | `AVCaptureVideoDataOutput/AudioDataOutput` delegate | 同（方法名都沿用 `douy_douy_*`） | 无 |
| 三种信号源 | USB / RTMP / 本地视频 | 同 | 无 |
| 浮窗 | 可拖拽 + 旋转/镜像/音频开关 | 同 | 无 |
| 授权接口形状 | 见 §1.A | 见 §1.A | 无 |
| 授权签名原文 | 未知 | 自定义（文档化） | 中（必需） |
| 服务端语言/库 | 未知（线索：`ios_auth_routes.py` 提示是 Python） | PHP 7.3 + MySQL 5.7 | 大（但接口层无感） |
| 媒体帧格式 | `CSU1/CSC2/media packet` | `FXP/2` | 中 |
| 编解码 | 静态 FFmpeg + VideoToolbox | VideoToolbox + 自写 RTMP 客户端 | 中（功能等价） |
| PC 端 | OBS 输出插件 + MediaMTX + usbmuxd helper | 内置 RTMP 服务 + 自写 usbmuxd 客户端（C#） | 大（架构等价） |
| 计费/卡密/更新 | 有 | **有**（本次新增，见 `server/`） | 无（语义一致，密钥自持） |

---

## 4. 如果要把差异继续压小，还剩这些可做

1. **反汇编 `__text`** 还原 `CSU1/CSC2` 位布局与 `module_text_sha256` 的原版算法（需 capstone，可行）。
2. **对齐服务端框架**：线索里出现 `ios_auth_routes.py`，原版很可能是 Python（FastAPI/Flask）+ 某 SQL。
   如果你要"看起来完全一样"，我可以再出一份 Python 版服务端（同一套接口）。
3. **补齐 Android 分支**（原版有 `adb forward localabstract:camswap_usb`）。
4. **对齐 OBS 插件形态**：需要 OBS SDK + MSVC，在本机没有编译器，得走 GitHub Actions 的 windows runner。
5. **支付闭环**：目前到账是管理员 `douyctl order:pay` 手动确认（原版也是人工核对收款备注）。
   要接支付宝/微信回调，需要你的商户号与签名证书。
