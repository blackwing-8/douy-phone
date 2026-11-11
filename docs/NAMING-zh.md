# 命名规范（兜鱼 / DOUY）

> 这是**唯一权威**的命名表。改名前请先看这里，避免出现"一半兜鱼一半帧相"。

---

## 1. 品牌

| 项 | 值 |
|---|---|
| 中文名 | **兜鱼** |
| 英文名 | **DOUY**（全大写，不写 Douy / douy，除非是标识符/路径） |
| 产品全称 | 兜鱼 DOUY · OBS 手机输出 |
| Slogan（可选） | 让电脑画面成为手机摄像头 |
| Logo | `assets/logo.png`（1254²）· `logo-1024/512/256/128/64.png` · `app.ico`（16–256 多尺寸） |
| 主色 | 品牌蓝 `#1E7BFF` → 渐变 `#2AA8FF`；深色界面沿用 `#1E1F22 / #2B2D31` |

---

## 2. 代码与产物

| 项 | 旧（帧相） | 新（兜鱼 DOUY） |
|---|---|---|
| 仓库目录 | `FrameXiang-Replica` | `DOUY` |
| PC 项目 | `pc/FrameXiang.Pc/FrameXiang.Pc.csproj` | `pc/DOUY.Pc/DOUY.Pc.csproj` |
| PC 程序集 / 进程 | `FrameXiang.Pc.exe` | **`DOUY.Pc.exe`** |
| PC 命名空间 | `FrameXiang.Pc` | `DOUY.Pc` |
| PC 窗口标题 | 帧相手机输出 · FrameXiang | **兜鱼手机输出 · DOUY** |
| iOS 工程目录 | `ios/FrameXiangTweak` | `ios/DOUYTweak` |
| iOS 产物 | `FrameXiang.dylib` | **`DOUY.dylib`** |
| iOS install_name | `@executable_path/Frameworks/FrameXiang.dylib` | `@executable_path/Frameworks/DOUY.dylib` |
| 日志前缀 | `[FrameXiang]` | `[DOUY]` |
| iOS Bundle 标识 | `app.framexiang.*` | `app.douy.*` |
| usbmuxd ProgName | `FrameXiang.Pc` | `DOUY.Pc` |
| usbmuxd BundleID | `app.zhenxiang.livebridge.windows` | `app.douy.livebridge.windows` |
| usbmuxd ClientVersion | `FrameXiang 1.0` | `DOUY 1.0` |
| Keychain service | `app.framexiang.plugin-auth` | `app.douy.plugin-auth` |
| Keychain 设备密钥 tag | `app.framexiang.plugin.device-key.v1` | `app.douy.plugin.device-key.v1` |

---

## 3. 协议标识（两端必须一起改）

| 项 | 旧 | 新 |
|---|---|---|
| 请求证明方案 | `frame-ios-proof-v1` | **`douy-ios-proof-v1`** |
| 授权凭证 audience | `frame-ios-hook` | **`douy-ios-hook`** |
| 更新清单 audience | `frame-ios-plugin-update` | **`douy-ios-plugin-update`** |
| 登录挑战协议 | `frame-ios-challenge-v1` | **`douy-ios-challenge-v1`** |
| 请求头 | `X-Frame-IOS-Proof / Role / Time / Nonce / Key / Signature / Device` | **`X-DOUY-IOS-*`**（同名后缀） |
| USB 帧魔数 | `FXM2`（`0x324D5846`） | **`DYM2`**（`0x324D5944`） |
| USB 握手魔数 | `FXH2/2` / `FXA2/2` | **`DYH2/2`** / **`DYA2/2`** |
| USB 帧头 | 28 字节（不变） | 28 字节（不变） |

> 这几个是**我们自己定的**线格式；改了就两端一起改（PC `Usb/Fxp.cs`、iOS `FXUSBSource.mm`、
> 服务端 `Proof.php` + `config.php`、测试工具 `tools/test-phone.py`、冒烟脚本）。

---

## 4. 服务端

| 项 | 旧 | 新 |
|---|---|---|
| 数据库 | `fx_license` | **`douy_license`** |
| 表前缀 | `fx_*` | **`douy_*`**（18 张表） |
| 管理 CLI | `bin/fxctl.php` | **`bin/douyctl.php`** |
| PHP 辅助函数 | `fx_db()` / `fx_log()` / `fx_handle_exception()` | `douy_db()` / `douy_log()` / `douy_handle_exception()` |
| 健康检查文案 | FrameXiang license server | **DOUY license server** |
| 商品标识 | `ios_injection` | **`douy_ios_injection`** |
| 商品名 | 帧相 iOS 注入插件 | **兜鱼 iOS 注入插件** |
| RTMP 默认端口 | 1935（与原版相同） | **19350**（错开，避免抢占 1935） |
| USB 设备端口 | 28766 | **28767**（错开，两套插件可共存） |
| 流路径 | `live/reecho` | **`live/douy`** |
| 卡密格式 | `FX-IOS-XXXX-XXXX-XXXX`（掩码 `FX-IOS-****-9F2A`） | **`DOUY-XXXX-XXXX-XXXX`**（掩码 `DOUY-****-9F2A`） |
| 默认套餐标题 | 30 天 / 90 天 | 同（价格/收款码由你改） |

---

## 5. 刻意**没有**改的

| 项 | 现状 | 原因 |
|---|---|---|
| ObjC 类前缀 `FX*` | `FXLicense`、`FXHooks`、`FXOverlay`… | 编译期才能验证；本机无 clang，改名风险大于收益。**CI 编译通过后可一次性机械改名**（见 §6） |
| 文件 `FX*.mm` / `FX*.h` | 同上 | 同上（改名要同步改 `#import`） |
| 常量前缀 `kFX*` | 同上 | 同上 |
| `tools/` 下的诊断脚本 | 保留 | 只给开发用，不影响产品 |
| 原版分析文档（`ANALYSIS-zh.md` §0–§3） | **保留原版命名**（帧相 / FrameXiang / `fx_framexiang_*` / `CSU1`） | 那份文档是对**原版**的逆向记录，必须与二进制字符串一一对应，改成兜鱼会变成错误描述 |

---

## 6. 遗留的机械改名（建议在 iOS CI 跑通后做）

一旦 `build-ios.yml` 第一次编译通过，就可以安全地做这一步（有 CI 兜底）：

```bash
cd ios/DOUYTweak/src
# 1) 类/常量/文件名：FX* -> DY*
for f in FX*.mm FX*.h; do git mv "$f" "DY${f#FX}"; done
# 2) 全仓库同步：FX -> DY（注意只改标识符，别动字符串常量）
#    建议用 IDE 的 Rename 或 Perl 的 \bFX 边界匹配，改完立刻 push 让 CI 编一次
```

改完需要同步：`FXCommon.h` 里的 `FXCreateAccountPanel` / `FXLogoImage`、
`FXStatusDidChangeNotification`、以及 `FXOverlay.mm` 里 `extern` 引用。

> 在此之前，`FX` 前缀只出现在**符号层**（崩溃日志、`nm` 输出），用户完全看不到。

---

## 7. 还需要你确认的命名点

| 问题 | 选项 | 我的建议 |
|---|---|---|
| 域名 | `douy.example.com` / `license.douy.cn` / 其它 | 用独立子域，方便以后上 CDN / 换机 |
| 卡密前缀 | `DOUY-XXXX-XXXX-XXXX`（现在） | 保持；比原版少一组，手感更顺 |
| 是否保留"复刻版"字样 | 是 / 否 | 用户可见界面**去掉**（现在已去掉）；内部文档保留，便于对照原版 |
| Logo 是否要横版文字标 | 需要 / 不需要 | PC 标题旁用方形图 + 文字「兜鱼 DOUY」即可，暂不做横版 |
