# 兜鱼 DOUY · OBS 手机输出

<img src="assets/logo-256.png" width="96" align="right" alt="兜鱼 DOUY" />

把电脑（OBS）的画面和声音，变成手机直播 App 的"摄像头/麦克风"。
双端自研：Windows 端负责编码与传输，iPhone 端注入宿主 App 替换采集画面。

> | 文档 | 内容 |
> |---|---|
> | [`docs/PLAN-zh.md`](docs/PLAN-zh.md) | **后续推进计划（待拍板）** |
> | [`docs/NAMING-zh.md`](docs/NAMING-zh.md) | **命名规范（兜鱼/DOUY 全量映射）** |
> | [`docs/ANALYSIS-zh.md`](docs/ANALYSIS-zh.md) | 原版二进制逆向分析 |
> | [`docs/DIFF-zh.md`](docs/DIFF-zh.md) | 与原版的差异清单 |
> | [`docs/API-zh.md`](docs/API-zh.md) | 授权服务 API（`douy-ios-proof-v1`） |
> | [`docs/SERVER-DEPLOY-zh.md`](docs/SERVER-DEPLOY-zh.md) | 服务端部署手册 |
> | [`docs/PROTOCOL-zh.md`](docs/PROTOCOL-zh.md) | `FXP/2` 线协议（USB 隧道 + RTMP） |

```
┌─ 电脑 ─────────────────────────────┐      ┌─ iPhone ──────────────────┐
│ OBS ──RTMP──► DOUY.Pc.exe          │      │ 直播 App                  │
│               ├ 内置 RTMP 服务      │      │  └ AVCaptureVideoDataOutput│
│               ├ USB 隧道(usbmuxd)   │ USB  │        ▲                  │
│               └ 外部转推(ffmpeg)    │─────►│   DOUY.dylib              │
│                  H.264 + AAC        │ WiFi │   （hook delegate，替换帧）│
└────────────────────────────────────┘      └───────────────────────────┘
```

## 内容

| 路径 | 说明 |
|---|---|
| `assets/` | Logo 全套（`logo.png` 1254²、多尺寸、`app.ico`） |
| `docs/` | 见上表 |
| `pc/DOUY.Pc` | Windows 端：RTMP 服务 + USB 隧道 + 转推 + 控制面板（C# / .NET 7） |
| `ios/DOUYTweak` | iOS 注入插件：hook 采集、三种帧源、浮窗、账号/卡密（ObjC++，零依赖） |
| `server/` | 授权服务：MySQL 18 张表 + PHP 接口 + 管理 CLI + 冒烟测试 |
| `tools/test-phone.py` | 模拟手机端，用于在没有真机时验证 USB 隧道 |
| `.github/workflows/` | `build-ios.yml`（macOS 编 dylib）、`build-server.yml`（PHP+MySQL 冒烟）、`build-pc.yml`（.NET 编 PC 端） |

## 授权体系（卡密计费 + 更新）

复刻版**包含**与原版同构的卡密/计时/租约/购买/更新体系（服务端在本仓库 `server/`）：

```
iOS 插件 ──(douy-ios-proof-v1 签名请求)──► PHP 授权服务 ──► MySQL
   ▲                                            │
   └──── 授权凭证(ECDSA 签名) / 90 秒租约 ◄──────┘
```

- 设备身份：Secure Enclave / Keychain 里的 **ECDSA P-256**，私钥不出设备
- 每个请求带 6 个头（`X-DOUY-IOS-Proof/Role/Time/Nonce/Key/Signature`）+ 设备 id
- 卡密：首次绑定开始计时 → 90 秒租约续租 → 到期自动接续备用卡 → 解绑不停表 → 换绑旧机 90 秒失效
- 购买：套餐 → 收款码 + 付款备注码 → 管理员确认到账自动发卡进卡包
- 更新：服务端签名的清单（SHA-256 + 版本号），每卡每天 5 次下载配额
- 防篡改：客户端上报 `__text` 段的 SHA-256，变了就 `IOS_MODULE_CHANGED`

> 密钥是你自己的：`php server/bin/douyctl.php key:gen` 生成，公钥填进
> `ios/DOUYTweak/src/FXLicense.mm`。原版厂商的私钥不可能拿到，也不可能伪造它的卡密
> —— 详见 [`docs/DIFF-zh.md`](docs/DIFF-zh.md) §1.C。

服务端自测（需 PHP 7.3+ / MySQL 5.7+）：

```bash
cd server
php bin/douyctl.php db:init      # 建 18 张表
php bin/douyctl.php key:gen      # 生成服务端签名密钥
php bin/douyctl.php card:new --days=30 --count=10
php -S 127.0.0.1:8080 -t public public/index.php &
php tools/smoke.php DOUY-XXXX-XXXX-XXXX   # 31 项
php tools/smoke2.php                        # 19 项
```

本机实测：`PASS: 31 FAIL: 0` / `PASS: 19 FAIL: 0`。

## 快速开始（Windows 端）

```powershell
# 1) 编译
dotnet build .\pc\DOUY.Pc\DOUY.Pc.csproj -c Release

# 2) 图形界面
.\pc\DOUY.Pc\bin\Release\net7.0-windows\DOUY.Pc.exe

# 3) 命令行 / 无界面（服务器或脚本）
DOUY.Pc.exe serve --port 19350
DOUY.Pc.exe serve --phone 127.0.0.1:28767      # 直连某个 FXP 端点（调试）
DOUY.Pc.exe serve --port 19350 --dump captest  # 把收到的码流落盘，便于验证
DOUY.Pc.exe list                               # 列出 iPhone（走 Apple Mobile Device 服务）
```

OBS 侧设置（**不需要装 OBS 插件**，用 OBS 原生推流即可）：

```
设置 → 直播 → 服务：自定义…
服务器：rtmp://127.0.0.1:19350/live
推流码：douy
```

手机侧（与 PC 同一 WiFi）：任意 RTMP 播放器拉
`rtmp://<PC的局域网IP>:19350/live/douy` 即可预览；注入插件则在浮窗里选「RTMP」并填同一地址。

## 快速开始（iPhone 端）

本机没有 Xcode，用 GitHub Actions 编译：

```bash
git init && git add . && git commit -m "DOUY replica"
git remote add origin https://github.com/<你>/<仓库>.git
git push -u origin main
```

推上去后 Actions 会自动跑 `build-ios-dylib`，产物在 Artifacts 里的 `DOUY.dylib`。
本地 macOS 也可以直接：

```bash
cd ios/DOUYTweak
make            # 需要 Xcode 命令行工具 + iPhoneOS SDK
make info       # 打印 Mach-O 信息，确认是 arm64 dylib
```

注入：用你的注入器（TrollFools / Sideloadly / 自建 `insert_dylib` + 重签）把
`DOUY.dylib` 塞进目标 App，安装后重启目标 App，会看到「兜鱼」浮窗。

## 验证（无需真机）

一条命令跑完整链路（会自动编译、起服务、模拟手机、推流、拉流、校验）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\run-e2e.ps1 -Seconds 12
```

### 实测结果（本机 Windows 10 / .NET 7 / ffmpeg 8.x）

```
模拟手机（FXP/2 隧道）
  时长            : 15.4s
  视频帧          : 360 (关键帧 6)  3665.7 KiB
  音频帧          : 564  189.3 KiB
  PING/PONG       : 16
  时间戳倒退      : 0
  结果            : PASS

ffprobe 校验 USB 收到的码流
  received.h264 → h264 1280x720 yuv420p
  received.aac  → aac 48000 Hz 2 ch

ffprobe 校验 RTMP 拉流
  pull.flv = 807.5 KiB / duration 5.022s / h264 1280x720 + aac 48000

==== 端到端验证通过 ====
```

另外验证过：

- `received.h264` 与服务端落盘的 `hub.h264` **字节完全一致**（3,134,220 B），
  说明 FXP/2 隧道没有丢包/错序；
- 推流 12 秒恰好 360 帧 @30fps，音频 564 帧 ≈ 12.03 秒（564×1024/48000），
  时间戳无倒退；
- GUI 可正常启动（窗口标题「兜鱼手机输出 · DOUY」），
  找不到 Apple Devices / iPhone 时降级为提示而不崩溃。

### 手工验证

```powershell
# 终端 A：PC 端（USB 模式直连本机的模拟手机）
DOUY.Pc.exe serve --port 19350 --phone 127.0.0.1:28767 --dump dump

# 终端 B：模拟手机
python tools\test-phone.py --port 28767 --out received --duration 15

# 终端 C：推流（当 OBS 用）
ffmpeg -re -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" ^
       -c:v libx264 -preset veryfast -tune zerolatency -g 60 -pix_fmt yuv420p -b:v 2500k ^
       -c:a aac -b:a 128k -ar 48000 -ac 2 -f flv rtmp://127.0.0.1:19350/live/douy
```

`tools/` 下还有几个排查用的诊断脚本（`_rtmp_diag.py` 单调 connect、
`_rtmp_diag2.py` 完整命令序列、`_tcp_proxy.py` 抓包代理），
本次就是靠它们定位到 AMF0 object 多写了 4 字节计数导致 ffmpeg 在 publish 后 EIO 的问题。

## 与正版的差异

完整的差异分析见 [`docs/DIFF-zh.md`](docs/DIFF-zh.md)。摘要：

- **一致**：接口路径、请求头名、`douy-ios-proof-v1`、全套 `IOS_*` 错误码、响应字段名、
  卡密计时/租约/换绑/解绑语义、UI 文案、设备端口 28767、RTMP 路径 `live/douy`（**刻意与原版 28766 / live\reecho 错开**，便于两套并存）。
- **同构重写**：服务端代码（原版闭源，仅能从客户端字符串反推契约）、数据库结构、
  签名原文格式（原版未泄漏，必须自定义才能验签）。
- **不可能一致**：原版厂商的**根签名私钥**只在他们的服务器上，客户端里只有公钥。
  所以本项目的密钥是你自己的（`douyctl key:gen`），原版卡密不会在你的服务器上生效，
  你的卡密也不会通过原版插件的校验。
- **媒体帧格式**：原版 `CSU1/CSC2/media packet` 的位布局未泄漏；复刻版两端都用 `FXP/2`。
- 手机端不含 FFmpeg（原版静态链接），改为自写 RTMP 客户端；PC 端不自带 MediaMTX，
  改为内置 RTMP 服务。

## 免责声明

本项目仅用于学习与自有设备的互操作研究。原版软件的授权/计费机制未被绕过，
也不应被绕过；请在符合当地法律与各 App 服务条款的前提下使用。
