# DOUYTweak（iOS 注入插件）

复刻「DOUY.dylib」的注入插件：hook 宿主 App 的采集回调，把摄像头/麦克风
换成来自电脑（USB / RTMP）或本地视频的画面与声音，并在宿主之上挂一个浮窗。

零第三方依赖（不用 FFmpeg / Theos / CocoaPods），只用 Xcode 自带 clang + iPhoneOS SDK。

## 文件

| 文件 | 作用 |
|---|---|
| `src/FXCommon.h` | 公共类型与各模块接口 |
| `src/FXMediaStore.mm` | 全局媒体仓库：最新视频帧 + PCM 环形缓冲 + 状态 |
| `src/FXVideoDecoder.mm` | H.264 Annex-B → CVPixelBuffer（VideoToolbox 硬解，AVCC 重打包） |
| `src/FXAudioDecoder.mm` | AAC（raw / ADTS）→ PCM 48k/2ch/int16（AudioConverter） |
| `src/FXUSBSource.mm` | 监听 28767，解析 FXP/2，喂解码器 |
| `src/FXRtmpClient.{h,mm}` | 自写 RTMP 客户端 + FLV demux（拉流路径） |
| `src/FXRTMPSource.mm` | 把 RTMP 客户端接到解码器 |
| `src/FXFileSource.mm` | 本地视频（AVAssetReader，循环播放，带音频） |
| `src/FXHooks.mm` | **核心**：swizzle 采集 delegate，替换 CMSampleBuffer |
| `src/FXOverlay.mm` | 浮窗控制面板（模式/旋转/镜像/音频替换/账号入口/拖拽） |
| `src/FXLicense.{h,mm}` | **授权**：设备身份（Secure Enclave ECDSA）、`douy-ios-proof-v1` 请求签名、登录挑战、卡密激活、90 秒租约续租、服务端签名验签、更新检查 |
| `src/FXAccountPanel.mm` | 「账号与卡包」面板 UI（登录/注册/激活/备用卡/退出/更新） |
| `src/FXPlugin.mm` | `__attribute__((constructor))` 入口（hook + 浮窗 + 授权核验） |
| `scripts/verify.sh` | 产物校验（arm64 / dylib / 无第三方依赖） |

## 工作原理

```
宿主 App                        DOUYTweak
────────                       ────────────────────────────────
[output setSampleBufferDelegate:hostDelegate queue:q]
        │
        ▼  (swizzle 换入)
   FXVideoDelegateProxy  ←── weak 指向 hostDelegate
        │
        │  每帧回调：
        │    FXMediaStore.latestVideoBuffer 有帧？
        │      有 → 用它的像素 + 宿主的 PTS 造一个新 CMSampleBuffer
        │      无 → 原样透传（避免黑屏）
        ▼
   [hostDelegate captureOutput:didOutputSampleBuffer:...]
```

- **时间戳直接沿用宿主原始 sample buffer 的 PTS**，所以不存在音画漂移问题，
  也不需要原版那套 `FXCaptureClockContext` 时钟对齐。
- 音频：默认把 PCM 转成宿主自己的 ASBD（`AudioConverter`）后替换，
  所以宿主拿到的格式与它预期一致，不会因为"音频格式突变"而爆音/静音。
- 视频：解码成 420f，若尺寸/旋转/镜像与宿主不同，走一次 CoreImage 变换再交给宿主。

## 授权（卡密 / 账号 / 更新）

`FXLicense` 在上线前需要两处配置：

1. **服务端公钥**（`FXLicense.mm` 的 `kFXServerPublicKeyECDSA`）
   —— 用 `php server/bin/douyctl.php key:gen` 生成后粘贴；
2. **服务地址**（`kFXDefaultBaseURL`，或运行时用 `NSUserDefaults` 的 `FXLicenseBaseURL` 覆盖）。

行为：

- 首次运行 `device/register` 上报 `device_id + ECDSA 公钥`（Secure Enclave 优先，失败回落 Keychain）；
- 每个请求按 `douy-ios-proof-v1` 签名（7 段原文，见 `docs/API-zh.md §2.3`）；
- 登录是"密码 → challenge → 设备签名 challenge_response → 会话令牌"两步；
- 激活后每 60 秒续租（服务端租约 90 秒），断线用本地缓存凭证；
- 授权失效/过期 → 自动切回真实摄像头并提示（不会带着未授权状态继续替换）。

## 编译

```bash
# macOS（需要 Xcode / Command Line Tools）
cd ios/DOUYTweak
make                 # → DOUY.dylib（arm64，iOS 14+，ad-hoc 签名）
make info            # 打印 Mach-O 信息
```

Windows 上无法编译，用 GitHub Actions：

- 工作流：`.github/workflows/build-ios.yml`（`macos-14` runner，自带 Xcode 16 / iPhoneOS SDK）
- 触发：push 到 main 或手动 `workflow_dispatch`
- 产物：Artifacts → `DOUY.dylib`

## 注入

生成的 dylib 需要在目标 App 的 Mach-O 里加一条 `LC_LOAD_DYLIB`：

```
@executable_path/Frameworks/DOUY.dylib
```

两种常见做法：

1. **现成注入器**（TrollFools / Sideloadly / Azule / ESign 等）：
   把 `DOUY.dylib` 交给它，选择目标 App 注入并安装。
2. **手动（自备已解密的 IPA）**：

```bash
unzip app.ipa -d work
# 1) 拷入 dylib
mkdir -p work/Payload/App.app/Frameworks
cp DOUY.dylib work/Payload/App.app/Frameworks/
# 2) 加 load command（insert_dylib 需自行编译：git clone Tyilo/insert_dylib && clang insert_dylib/main.c -o insert_dylib）
./insert_dylib --strip-codesig --in-place \
    @executable_path/Frameworks/DOUY.dylib work/Payload/App.app/App
# 3) 重签（TrollStore 用 fakesign，越狱机用 ldid，普通设备需要开发者证书 + 描述文件）
ldid -S work/Payload/App.app/App work/Payload/App.app/Frameworks/DOUY.dylib
# 4) 打包
cd work && zip -qry ../app-injected.ipa Payload
```

> 注：本项目只产出 dylib，不提供任何绕过签名/授权的工具；能不能装取决于你自己的证书或越狱环境。

## 使用

1. 打开目标 App，屏幕上出现「兜鱼」浮窗。
2. 浮窗里选来源：
   - **USB 直连**：手机用数据线连电脑，电脑端 `DOUY.Pc.exe` 选 USB 模式。
   - **RTMP**：填 `rtmp://<电脑IP>:19350/live/douy`（电脑端选局域网 RTMP 模式）。
   - **本地视频**：从"文件"里选 MP4/MOV，循环播放。
   - **真实摄像头**：一键恢复，什么都不替换。
3. 旋转 / 镜像 / 音频替换 三个开关即时生效。

## 已知限制（诚实清单）

- RTMP 只支持 **H.264 + AAC**（和原版一致："仅支持 H.264 拉流"），不支持 HEVC。
- RTMP 只支持 `rtmp://`，未实现 `rtmps://`（需要 TLS 握手）。
- USB 模式监听 `127.0.0.1:28767`（与 PC 端默认设备端口一致；**刻意避开原版的 28766**）；
  若目标 App 已被别的"USB 输出"软件占用，需要先停掉。
- 若宿主把采集 delegate 设成 nil 或频繁重建 AVCaptureSession，插件会跟着重建代理，
  但极端情况下（宿主自己 swizzle 了同一方法）可能互相覆盖 —— 原版也有同样的限制。
- 音频替换要求宿主开麦采集；宿主没开麦时不会凭空造音频轨。
- 首次编译需要在 CI/macOS 上过一遍；本仓库的 Windows 环境下无法做语法级验证。
