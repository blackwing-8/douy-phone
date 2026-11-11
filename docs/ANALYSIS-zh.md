# 帧相（FrameXiang）双端软件逆向分析报告

分析对象（只读，未执行安装包）：

| 文件 | 大小 | 类型 |
|---|---|---|
| `帧相-OBS-Phone-Setup-0.1.8-win64.exe` | 29,021,773 B | Inno Setup 6.7.0 安装包（PC 端） |
| `FrameXiang.dylib` | 2,421,936 B | Mach-O arm64 动态库（iPhone 端注入插件） |

分析方式：纯静态。安装包用 innoextract 1.12-dev 解包（不运行安装程序），
Mach-O 用自写解析器读取 load command / 符号表 / 段表，PE 用自写解析器读取
导入导出表、RTTI、字符串表。未连接真机、未运行任何厂商代码。

---

## 0. 一句话结论

「帧相」是一套 **把电脑（OBS）的画面和声音，变成手机直播 App 的"摄像头/麦克风"** 的双端系统：

```
OBS 输出 ──► PC 插件（H.264/AAC 编码） ──► 本地 RTMP 服务 / USB 隧道
                                                   │
                                                   ▼
                                   iPhone 注入插件（劫持采集回调）
                                                   │
                                                   ▼
                                   抖音/快手等直播 App 认为这是"后置摄像头"
```

- **手机端（`FrameXiang.dylib`）**：不是独立 App，而是一个**注入式 tweak**。
  它 hook 掉宿主 App 的 `AVCaptureVideoDataOutput` / `AVCaptureAudioDataOutput`
  代理回调，把真实的摄像头/麦克风数据**替换**成从电脑收到的画面和声音，并在
  宿主 App 之上浮一个控制面板。支持三种"信号源"：USB 直连、RTMP 拉流、本地视频。
- **电脑端（安装包）**：一个 **OBS 输出插件**（`zj-phone-output.dll`），加上三个
  外挂组件（`frame-ios-usb-helper.exe`、`zj-network-helper.exe`、`mediamtx.exe`）。
  它用 OBS 的 encoder API 自己编一路 H.264/AAC，通过 **USB（usbmuxd/adb）** 或
  **局域网 RTMP（自带 MediaMTX 服务）** 送到手机。
- 附带一套完整的**账号 / 卡密 / 计时授权 / 在线购买 / 联网强制更新**体系
  （服务器 `https://www.ybdskj.top`），并对插件代码做哈希防篡改。

---

## 1. 手机端：`FrameXiang.dylib`

### 1.1 二进制事实

| 项 | 值 |
|---|---|
| 魔数 / 类型 | `0xFEEDFACF`，`MH_DYLIB`（filetype 6） |
| 架构 | `arm64`（cputype `0x0100000C`） |
| 平台 / 最低系统 | `PLATFORM_IOS`，minos **iOS 14.0**，SDK iOS 18.5 |
| Install Name | `@rpath/FrameXiang.dylib` |
| 签名 | **无** `LC_CODE_SIGNATURE`（未签名，典型注入产物） |
| 加密 | `LC_ENCRYPTION_INFO_64.cryptid = 0`（App Store 加密已剥除/本就没上架） |
| 导出符号 | 几乎为 0（无导出表内容，全部为内部类） |
| 段 | `__TEXT` 2.1 MB（其中 `__text` 1.03 MB、`__const` 0.78 MB）、`__DATA_CONST`、`__DATA`（含约 17 MB bss） |
| 关键 section | `__objc_methname`、`__objc_classname`、`__ustring`（中文 UI 字符串表） |

链接框架（从 `LC_LOAD_DYLIB` 看功能轮廓）：

```
Foundation Security CoreFoundation CoreGraphics CoreImage QuartzCore Accelerate
PhotosUI UniformTypeIdentifiers CoreMedia CoreVideo AVFoundation UIKit
VideoToolbox AudioToolbox Network Metal CryptoKit
libc++ libobjc libswiftCore libswiftFoundation …
```

> `UIKit + PhotosUI` 说明它是 **iOS 界面代码**（不是 macOS OBS 插件）；
> `Accelerate/vImage + VideoToolbox + Metal + CoreVideo` 说明有**视频解码/色彩转换**；
> `Security + CryptoKit` 说明有**设备身份签名**；此外 `__const` 里塞了一整份
> 静态链接的 **FFmpeg（libavformat/libavcodec）**，字符串里能看到
> `libavformat/tcp.c`、`RTMP Handshake C1 Error`、`rtmp,rtmps,tcp,tls` 白名单等。

### 1.2 注入与劫持方式（核心机制）

类表里只有 30 个类名，真正干活的是这几个：

```
FrameXiangHook               FrameXiangAudioHook
FXCaptureDelegateProxy       FXAudioCaptureDelegateProxy
FXCaptureClockContext        FrameXiangTiming
FXOverlayWindow              FXPluginPanel  FXActionButton  FXSheetButton
FXBrandSheet  FXCommerceRequest  FXUpdateTransfer  FXPluginUpdateClient
```

它用的是 **method swizzling + 代理转发**（`method_exchangeImplementations`、
`class_getInstanceMethod`、`objc_setAssociatedObject`），而不是私有 API 或内核 hook。
被交换的方法（`__objc_methname` 里的原样字符串）：

```objc
-[AVCaptureVideoDataOutput fx_framexiang_setSampleBufferDelegate:queue:]   // 换入
-[AVCaptureVideoDataOutput fx_framexiang_sampleBufferDelegate]             // 换入
-[AVCaptureAudioDataOutput fx_framexiang_audio_setSampleBufferDelegate:queue:]
-[AVCaptureAudioDataOutput fx_framexiang_audio_sampleBufferDelegate]
-[AVCaptureSession fx_framexiang_timing_addOutput:]
-[AVCaptureSession fx_framexiang_timing_removeOutput:]
-[AVCaptureSession fx_framexiang_timing_startRunning]
-[AVCaptureSession fx_framexiang_timing_commitConfiguration]
```

工作流程：

1. 宿主 App 调 `setSampleBufferDelegate:queue:` 时，被换入的实现把**真正的 delegate**
   存进 `FXCaptureDelegateProxy`（ivar 类型签名为
   `T@"<AVCaptureVideoDataOutputSampleBufferDelegate>",W,N,V_originalDelegate`，弱引用），
   再把 proxy 交给系统。
2. 系统每帧回调到 proxy。若「替换开关」打开且有可用帧源，proxy 就**丢掉**这一帧，
   改用自己的 `CMSampleBuffer` 往下送；否则原样转发给真 delegate。
   —— 宿主 App 完全无感，它只看到"摄像头变慢了/画面变了"。
3. `AVCaptureSession` 的 4 个方法也被 hook，用来在会话重配时保持代理和输出绑定
   不被踩掉（`FXCaptureClockContext` + `FrameXiangTiming` 负责**时钟对齐**，把外来帧
   的 PTS 映射到采集会话的时间轴，避免直播 App 的音画漂移/丢帧）。

音频同理：`AudioToolbox` 的 `AudioUnitRender` 也被挂（字符串
`AudioUnitRender`、`已接入 AudioUnit 麦克风采集`），所以两种情况都覆盖：
宿主用 **AVFoundation 麦克风** 或 用 **AudioUnit 直接拉麦**。

### 1.3 三种信号源

| 模式 | 实现 | 相关字符串 |
|---|---|---|
| **USB 直连** | 手机侧监听 TCP，电脑通过 USB(usbmuxd) 连进来推流 | `USB 视频已连接 · 缺帧时保持画面`、`USB 等待连接`、`USB 音频已到达 · 等待直播 App 麦克风采集` |
| **RTMP 拉流** | 自带 FFmpeg 拉 `rtmp(s)://`，H.264 硬解 | `rtmp,rtmps,tcp,tls`、`仅支持 H.264 拉流`、`RTMP 解码恢复中 · 等待 IDR 关键帧`、`RTMP 断开，正在重连…` |
| **本地视频** | `AVAssetReader` / `AVPlayerItemVideoOutput` 循环播放 MP4/MOV（相册 `PHPickerViewController` 或文件 `UIDocumentPickerViewController` 选取） | `本地视频 · 循环播放`、`视频无法解码，请选择 MP4 / MOV` |

解码链：`VTDecompressionSession`（`kVTDecompressionPropertyKey_RealTime=1`）→
`CVPixelBufferPool` → 必要时 `vImageConvert_ARGB8888To420Yp8_CbCr8` /
`kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2` 做色彩空间转换 → `CMSampleBufferCreateReadyWithImageBuffer`
→ 交给宿主。音频走 `CMSampleBufferCreateReady` + `CMSampleBufferSetDataBufferFromAudioBufferList`。

画面控制：`旋转 0/90/180/270°`、`镜像：开/关`、`暂停本地视频`、
`恢复摄像头`（释放替换）、`音频替换：开/关`（可只替换声音、保留真实后置摄像头）。
音量/音频源提示很细：`USB 音频已到达 · 正在恢复同步`、`USB 音频未持续到达 · 请检查电脑输出`、
`宿主麦克风采集已暂停，请检查直播麦克风`。

浮窗：`FXOverlayWindow`（`UIWindowLevelAlert` 级别窗口）+ `FXPluginPanel` 面板，
一个可拖拽气泡 `_draggingBubble`，`帧相，展开或收起画面控制`；
有 `CADisplayLink` 做动画，`CAGradientLayer` 做渐变，`logo` 走 `GDI+`/`UIImage`。

### 1.4 授权/计费/更新（仅描述，不复刻）

字符串表把整个商业模型暴露得很完整：

- 服务器：`https://www.ybdskj.top`；接口
  `/api/register`、`/api/ios/plugin/…`（`account/status`、`wallet/add`、`activate`、
  `login`、`logout`、`bind`/`unbind`/`move`）、`/api/payment_plans?software_id=ios_injection`、
  `/api/ios/update/check`、`/api/ios/update/download`。
- 请求头签名字段：`X-Frame-IOS-Proof / -Role / -Time / -Nonce / -Key / -Signature`，
  证明方案 `frame-ios-proof-v1`，签名算法 `ed25519-1`，另有
  `kSecAttrTokenIDSecureEnclave` + `kSecKeyAlgorithmECDSASignatureMessageX962SHA256`
  的 **Secure Enclave P-256 设备身份**，凭证放 Keychain
  （`app.douy.plugin-auth`）。
- 卡密模型：卡密（`key_code`）→ 激活绑定本机（`LICENSE_BOUND_TO_OTHER_DEVICE`）
  → 按天计时（`duration_ms`/`license_expiry_ms`）→ 到期前 90 秒续租
  （`ExpectedLeaseBinding{…4×32 字节…}`、`lease`、`IOS_LEASE_REJECTED`）→
  备用卡自动接续（`已自动续用备用卡，授权到期时间已更新`）→ 解绑/换绑。
- 在线购买：套餐 `days_valid/price/qr_code_url`，展示收款码，**要求付款备注写账号**，
  轮询 `/wallet/add` 确认到账。
- 防篡改：`module_text_sha256`（对 `__text` 段做哈希）、`build_id`、`bundle_id`、
  `generation`、`release-58-6c8165e6…`；代码一变就报
  `插件运行代码发生变化，请重新安装官方版本`（`IOS_MODULE_CHANGED`）。
- 强制更新：下载新 `FrameXiang.dylib`，校验 **SHA-256 + 必须是 arm64 dylib + 构建序号**，
  每张已激活卡密每天限 5 次下载，下载后交给"注入器"安装。

> 本报告只做事实描述。**复刻版一律不含这套计费/DRM**（见 §4.6）。

---

## 2. 电脑端：安装包与四个组件

### 2.1 安装包本体

| 项 | 值 |
|---|---|
| 打包器 | **Inno Setup 6.7.0**（unicode，仅简体中文 `zhcn`） |
| 应用名 | `帧相 OBS 手机输出`，版本 `0.1.8` |
| PE | 32 位 Delphi 外壳（`kernel32/comctl32/user32/oleaut32/advapi32`），节表正常 |
| 载荷 | 从 `0xDA400` 起整段高熵（H=8.00）——setup data 被压缩/加密，静态看不到文件表 |
| 密码 | `Setup is not passworded` |

解包后只有 13 个文件（约 74 MB，主要是 MediaMTX 和 adb）：

```
app\obs-plugins\64bit\zj-phone-output.dll                     997 KiB   ← OBS 插件
app\data\obs-plugins\zj-phone-output\frame-ios-usb-helper.exe   1.65 MiB ← iPhone USB 隧道
app\data\obs-plugins\zj-phone-output\zj-network-helper.exe      570 KiB  ← 提权/防火墙助手
app\data\obs-plugins\zj-phone-output\mediamtx\mediamtx.exe       53.4 MiB ← 本地 RTMP/RTSP 服务
app\data\obs-plugins\zj-phone-output\platform-tools\adb.exe      7.89 MiB ← Android USB
app\data\obs-plugins\zj-phone-output\platform-tools\AdbWinApi.dll / AdbWinUsbApi.dll / libwinpthread-1.dll
app\data\obs-plugins\zj-phone-output\logo3.png / README.txt
```

README 原文信息量很大：

> 在 OBS 的"工具"菜单中打开"帧相手机输出（USB / RTMP）"。
> `platform-tools/` 需要 adb.exe…；`frame-ios-usb-helper.exe` 用于通过
> **Apple Mobile Device/usbmuxd** 服务连接受支持的 iPhone。
> iPhone 使用前请停止其他软件对同一手机的 USB 输出，并在帧相悬浮窗选择 USB。
> **电脑桥接已连接不代表手机已播放**；请在手机确认画面、声音和授权状态。

最后一句正好印证架构：PC 侧只是"管道"，真正替换发生在手机端。

### 2.2 `zj-phone-output.dll` —— OBS 输出插件

**形态**：标准 OBS 插件（`obs_module_load/unload/name/author/ver`），
只依赖 `obs.dll` + `obs-frontend-api.dll`，用 **obs-frontend 的"工具"菜单**加一个自绘
Win32 窗口（窗口类 `ZJObsPhoneOutputPanel`，标题 `帧相手机输出 · OBS`，
GDI + GDI+ 绘制 `logo3.png` 横幅，`DwmSetWindowAttribute` 深色标题栏）。

**关键导入**说明它到底干了什么：

```c
// 自己编码、自己出流，不碰用户的直播/录制设置
obs_register_output_s            // 注册输出类型：zj_usb_output、rtmp_output
obs_video_encoder_create / obs_audio_encoder_create      // 自建 H.264 / AAC
obs_output_set_service / obs_output_start / obs_output_force_stop
obs_add_raw_audio_callback / obs_remove_raw_audio_callback  // 多音轨混合
obs_data_save_json_safe / obs_module_get_config_path       // settings.json
obs_service_create                                        // RTMP 服务对象

// 外挂进程与网络
CreateProcessW / CreatePipe / PeekNamedPipe   // 启动并读 helper/mediamtx 的 stdout
WS2_32: socket/bind/listen/connect/send/recv  // 自己的本地 TCP 通道
IPHLPAPI: GetAdaptersAddresses / GetExtendedTcpTable  // 找局域网 IP、查端口占用者 PID
ShellExecuteExW                               // 提权跑 helper
```

**三种工作模式**（UI 原文）：

| 模式 | UI | 行为 |
|---|---|---|
| USB 连接 | `USB` / `USB 连接` | 通过 `adb`（Android）或 `frame-ios-usb-helper.exe`（iPhone）把码流塞进手机 |
| 局域网 RTMP | `局域网` / `局域网 RTMP` | 自带 MediaMTX 起 `rtmp://127.0.0.1:1935/live/reecho`，手机在同一 WiFi 拉流 |
| 外部推流 | `外部推流` | 直接往用户填的 `rtmp(s)://…` 推（转发/中继） |

**编解码参数**：分辨率/帧率跟随 OBS 输出；`自动 · 优先 NVENC` / `x264` / `NVENC · NVIDIA`
三种编码器选择；可设码率（kbps）与端口（`1024～65535`，插件自己做校验与占用检测，
`监听 PID`、`其他程序占用此端口`、`所选 MediaMTX`）；**音轨可多选**，插件内部
把多轨混成一路（`帧相多音轨混合`、`TRACK_MASK mask=%u`、`MIX_QUEUE_DROPS`）；
只支持 **SDR 8-bit、最高 60 FPS**（`首版支持 SDR 8-bit、最高 60 FPS`、
`请先将 OBS 设置为 SDR；首版不自动修改全局色彩设置`）。

**H.264 处理**：自己实现 AVCC↔Annex-B 转换（`Invalid AVC configuration`、
`Truncated SPS/PPS`、`Missing PPS`、`Invalid H264 NAL`、`Truncated H264 length`），
因为 OBS 的 encoder 出的是 AVCC（长度前缀 + SPS/PPS in extradata），
而手机侧/RTMP 需要 Annex-B 或带参数的 AVCDecoderConfigurationRecord。

**MediaMTX 配置**（插件生成 `mediamtx.json`，只开 RTMP，其余全关）：

```json
{"logLevel":"info","rtmp":true,"rtmpAddress":"127.0.0.1:<port>",
 "rtsp":false,"hls":false,"webrtc":false,"srt":false,"moq":false,
 "api":false,"metrics":false,"pprof":false,"playback":false,
 "authInternalUsers":[
   {"user":"any","ips":["127.0.0.1","::1"],"permissions":[{"action":"publish"}]},
   {"user":"any","ips":[],"permissions":[{"action":"read"}]}],
 "paths":{"live/reecho":{"overridePublisher":false}}}
```

即：**只有本机能发布**（OBS 插件推流），**任何 IP 都能读**（手机拉流），
路径固定 `live/reecho`，日志写 `mediamtx.log`，插件再 tail 日志判断
`is publishing to path 'live/reecho'` / `is reading from path 'live/reecho'` / ` 个客户端正在拉流`。

**防火墙**：`修复访问权限` 按钮 → 通过 `zj-network-helper.exe` 提权写防火墙规则，
规则描述固定为
`帧相 OBS 手机局域网接收；仅选定 IP/网段/TCP 端口。由插件管理，不用于桌面独立软件。`，
并且会回读校验（`规则写入后校验失败，已尝试恢复旧规则`、`所选规则已被修改为非 TCP 端口`、
`所选 IP 已不在当前网卡上，请刷新地址`）——即它**按当前网卡 IP 精确放行**，不图省事开全网。

### 2.3 `frame-ios-usb-helper.exe` —— iPhone USB 隧道（最有技术含量的一块）

它是 **Apple usbmuxd 客户端**，把"PC 的码流"送进"iPhone 上监听的端口"。

命令行（原文 usage）：

```
frame-ios-usb-helper --list | --bridge --udid ID --source-port PORT [--device-port 28766]
```

- `--list`：向 Apple Mobile Device 服务（usbmuxd，本机 TCP 27015）发 `ListDevices`，
  输出 `{"devices":[{"udid":"…","connection":"USB"}…]}`
- `--bridge`：对指定 UDID 发 `Connect`，`PortNumber = 28766`（默认设备端口），
  然后用 `--source-port` 连本机插件自己的媒体服务，把数据转发进隧道。

usbmuxd 请求体是 **plist XML**，字符串里能看到模板：

```xml
<key>ProgName</key><string>frame-ios-usb-helper</string>
<key>kLibUSBMuxVersion</key><integer>3</integer>
<key>BundleID</key><string>app.zhenxiang.livebridge.windows</string>
<key>ClientVersionString</key><string>FrameXiang 1.0</string>
<key>MessageType</key><string>Connect</string>
<key>DeviceID</key><integer>…</integer>
<key>PortNumber</key><integer>28766</integer>
<key>ConnectionType</key><string>USB</string>
```

隧道建立后的**应用层协议**（字符串直接暴露）：

```
iPhone connection failed
failed to send iPhone media handshake          ← 先发一个 JSON 握手（含 "channel"）
iPhone USB media tunnel stopped accepting data
CSU1                                            ← 媒体包魔数
USB packet too large
```

配合手机端 dylib 里的解析错误串，可以确定帧格式有三层：

```
CSU1  —— 会话/媒体通道头（"unsupported CSU1 version"、"invalid CSU1 channel"）
CSC2  —— 控制消息（"invalid CSC2 message type"）
media packet —— 媒体包（"unsupported media packet version"、
                "reserved media header bits are non-zero"、
                "media payload length is invalid"、
                "media PTS exceeds signed clock range"）
```

即：**自定义二进制封装**，视频是 H.264 Annex-B 访问单元 + PTS，音频是 AAC 帧 + PTS，
带版本号、通道号、长度校验。这不是 RTMP —— RTMP 只在"局域网 / 外部推流"模式用。

错误处理也印证了常见现场问题：
`Apple Mobile Device service is unavailable; install Apple Devices or iTunes`、
`selected USB iPhone is not connected or trusted`（手机没点"信任"）、
`iPhone port is not accepting the FrameXiang connection (result N)`（手机端插件没起监听）。

### 2.4 `zj-network-helper.exe` —— 提权助手

参数 `--configure` / `--remove` / `--public` / `--bridge` / `--udid`，
`GetExtendedTcpTable` 查占用、`CreatePipe/PeekNamedPipe` 读命令行（用 PowerShell
`Get-CimInstance Win32_Process` 校验 `frame-ios-usb-helper.exe` 是不是自己在跑，
防"同款程序"冲突）。核心作用：**UAC 提权做防火墙/端口相关操作**，避免整个 OBS 提权。

### 2.5 Android 分支（附带支持）

插件里还有 `platform-tools/adb.exe` 与 `localabstract:camswap_usb`：
对 Android 走 `adb forward` 到设备上的抽象命名空间 socket `camswap_usb`，
配对的是另一套 Android App（本次没提供，不在分析范围）。

### 2.6 可追溯线索（供判断版本/来源）

- 日志横幅：`[ZJ Phone] Plugin 0.1.8 loaded (Windows x64 / OBS 32)` —— 按 OBS 32.x API 编译
- PDB 路径：`\obschajian\build\native\frame-ios-usb-helper.pdb` —— 工程代号 `obschajian`（"OBS 插件"拼音）
- 编译器：MSVC v14.3x（`VCRUNTIME140_1` + C++20 `std::basic_string` 布局 + PPL `<future>`）
- 性能埋点：`render_avg_ms / render_lagged / video_drops / audio_drops / slow_sends /
  max_send_ms / session_resets / send_timeouts / video_recoveries`、`USB_REPAIR elapsed_ms`
  —— 作者很清楚 USB 链路会卡、会断、要重连修复

---

## 3. 端到端数据流

```
┌──────────────────────── 电脑 ────────────────────────┐        ┌──────── 手机 (iPhone) ────────┐
│ OBS 32.x                                            │        │ 直播 App（宿主）               │
│  ├ obs_video() ─┐                                   │        │  └ AVCaptureSession            │
│  └ raw audio ───┤（多音轨混合）                      │        │      ├ AVCaptureVideoDataOutput│
│                 ▼                                    │        │      └ AVCaptureAudioDataOutput│
│  zj-phone-output.dll：x264/NVENC + AAC               │        │             │ (delegate)       │
│   AVCC→AnnexB, AVCDecoderConfigurationRecord         │        │             ▼                  │
│         │                                            │        │   FrameXiang.dylib（注入）      │
│   ┌─────┴──────────────┬─────────────────────┐       │        │    FXCaptureDelegateProxy      │
│   ▼                    ▼                     ▼       │        │    ├ USB: TCP :28766 收流       │
│ USB 模式           局域网 RTMP          外部推流      │        │    ├ RTMP: ffmpeg 拉流          │
│   │                (mediamtx 1935)     (rtmp(s)://)  │        │    └ 本地视频: AVAssetReader    │
│   ▼                    │                     │       │        │             │                  │
│ frame-ios-usb-helper   └──── 手机 WiFi 拉 ───┘       │        │   VideoToolbox 硬解 → 像素缓冲  │
│   │  (usbmuxd plist)                                 │        │   + 时间轴对齐（Timing）        │
│   │  127.0.0.1:27015                                 │        │             ▼                  │
│   ▼                                                  │        │   替换 CMSampleBuffer          │
│ iPhone:28766  ◄── CSU1/CSC2/media 包 ────────────────┼───────►│             ▼                  │
│  (USB 线, Apple Mobile Device 服务)                   │        │   宿主 App 收到"摄像头"画面     │
└──────────────────────────────────────────────────────┘        └────────────────────────────────┘
```

要点：

1. **PC 端只负责编码 + 传**，画面替换 100% 在手机端完成；
2. **USB 方向是 PC → 手机**（PC 作为 usbmuxd 客户端 `Connect` 到手机监听端口），
   所以手机端必须有端口在 listen —— 这就是 `28766` 的由来；
3. 局域网模式最"省事"：手机端只要会拉 RTMP 就行，**不需要注入插件也能用**
   （但那样就没有"替换摄像头"的能力，只能录屏/推流）。

---

## 4. 复刻设计（本项目「兜鱼 / DOUY」的实现）

> 注意：本节起「复刻版」= 本项目 **兜鱼 DOUY**；上文 §0–§3 描述的是原版（保留原版命名，便于对照）。

### 4.1 复刻范围

| 原版 | 复刻版 | 说明 |
|---|---|---|
| OBS 输出插件（C++） | `pc/DOUY.Pc`（C# .NET 7 WinForms） | 不依赖 OBS SDK，**内置 RTMP 服务**接管 OBS 的"推流"输出，等价达成"OBS→手机" |
| MediaMTX 53 MB | 自研 RTMP 服务（约 1.2k 行 C#） | 免第三方二进制，行为对齐：发布仅本机、播放任意 IP、路径 `live/reecho` |
| `frame-ios-usb-helper.exe` | 同功能 `UsbMuxClient` + `UsbBridge`（C#） | 直连 Apple Mobile Device 服务，plist `Connect`，默认端口 28766 |
| 自定义 CSU1/CSC2 帧 | 自研 **FXP/2** 帧（magic `DYM2`，握手 `DYH2/2`，见 `PROTOCOL-zh.md`） | 原版字节布局无法静态复原，且两端都由我们重写，协议重新设计更干净 |
| iPhone 注入插件（Swift+ObjC+FFmpeg） | `ios/DOUYTweak`（纯 ObjC++，无 FFmpeg） | 自写 RTMP 客户端 + FLV demux，只支持 H.264/AAC，体积小、依赖为零 |
| 账号/卡密/计费/强制更新 | **已实现**（`server/`，PHP+MySQL，自有密钥） | 原版服务端闭源，按客户端字符串反推契约后同构重写；根私钥自持，互不通用 |
| 防火墙/UAC 提权助手 | 保留简化版（`netsh advfirewall` 一行） | 仅放行指定端口 |

### 4.2 为什么 PC 端不用写 OBS 插件

原版靠 `obs_register_output_s` 注册自定义输出，需要 OBS 源码/SDK 与 MSVC 工具链。
本机无编译器、无 OBS SDK，且复刻的核心价值是**协议与链路**，不是那 300 行注册代码。
改用等价路线：

- OBS 设置 → 输出 → 推流 → 服务器 `rtmp://127.0.0.1:1935/live`，串流密钥 `reecho`
  （即 OBS 原生 RTMP 输出，用户零学习成本）；
- 插件自带的 RTMP 服务收流、转发给手机（USB 隧道或局域网）。

这样连"外部推流"模式也顺带实现了（服务端把收到的流转推出去）。

### 4.3 手机端可以不重写 RTMP 解码器吗

可以，但会引入 40 MB FFmpeg。复刻版选择**自实现最小 RTMP 客户端 + FLV demux**
（handshake C0/C1/C2、AMF0 connect/createStream/play、chunk 解析、AVC/AAC tag 拆分），
约 700 行 ObjC++，换来的是：零第三方依赖、dylib 约 200 KB、CI 上 30 秒编译完。

### 4.4 构建/验证策略

- **PC 端**：本机 `dotnet build` 直接编译；用 ffmpeg 当"OBS 替身"做端到端验证
  （推流 → 服务 → 拉流落盘，比对帧数与时长）。
- **手机端**：本机无 Xcode，走 **GitHub Actions `macos-14` runner**（见
  `.github/workflows/build-ios.yml`）：runner 自带 Xcode 15/16 与 iPhoneOS SDK，
  直接 `clang++ -arch arm64 -miphoneos-version-min=14.0` 出 `DOUY.dylib`，
  再用 `codesign -s -` 做 ad-hoc 签名，产物可下载。
  注入目标 App 需要目标 IPA（自备），文档给了 `insert_dylib` 做法。

### 4.5 与"破解/绕过"的界线

复刻版的 USB 隧道、帧协议、浮窗、替换逻辑都是**从零实现**，
不复制原版二进制、不复用其密钥、不绕过其授权校验；
原版的 `frame-ios-proof-v1` / Ed25519 / Secure Enclave / `module_text_sha256`
防篡改体系只做分析记录，未做也不建议做绕过。原版 App 仍会自行校验它的计费状态。

### 4.6 已知与原版的差异

| 项 | 原版 | 复刻 |
|---|---|---|
| 手机端注入 | 需"注入器"（TrollFools/Sideloadly 等） | 同（产物是 dylib，注入工具自选） |
| 音轨 | 插件内多轨混音 | 单轨（OBS 混音后送一路），多轨混音在 OBS 侧完成 |
| 编码器 | x264/NVENC 直连（OBS encoder API） | 用 OBS 自身编码器（等价），服务端可另设转推 |
| 本地视频 | AVAssetReader + 硬解 | 同 |
| RTMP 兼容 | FFmpeg 全功能 | H.264/AAC 拉流（够用，且是唯一被允许的编码） |
| 授权 | 卡密计时（厂商私钥签发） | 卡密计时（自有私钥签发，`douy-ios-proof-v1`） |

### 4.7 命名说明

- 原版分析部分（§0–§3）**保留原版命名**：`帧相` / `FrameXiang.dylib` / `fx_framexiang_*` / `CSU1`…
  这样才能与二进制里的字符串一一对应。
- 本项目（§4 起）统一为 **兜鱼 / DOUY**：`DOUY.dylib`、`DOUY.Pc.exe`、`douy-*` 协议标识、
  `douy_*` 数据表、`DOUY-XXXX-XXXX-XXXX` 卡密。完整映射见 `NAMING-zh.md`。
