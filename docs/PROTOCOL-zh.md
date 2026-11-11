# FXP/2 —— 兜鱼复刻版端到端协议规范

> 本文定义 **复刻版** 自己的线格式 `FXP/2`（DOUY Protocol v2）。
> 原版手机端使用 `CSU1` / `CSC2` / `media packet` 三层二进制封装（见
> `ANALYSIS-zh.md` §2.3），其精确字节布局需要反汇编才能复原；且复刻版两端都由
> 本项目重写，重新设计一个更清晰、可调试的协议更合适。原版帧格式仅作对照。

---

## 1. 链路拓扑

```
模式 A（USB 直连）
  PC: RtmpServer(19350) ← OBS 推流
      UsbBridge ──TCP──► 127.0.0.1:27015 (Apple Mobile Device / usbmuxd)
                          │  plist <MessageType>Connect</MessageType><PortNumber>28767</PortNumber>
                          ▼
                        iPhone:28767  ← FXP/2 会话（本协议）→ DOUYTweak

模式 B（局域网 RTMP）
  PC: RtmpServer(19350) ← OBS 推流；手机直接 rtmp://<PC-IP>:19350/live/douy 拉流
      手机端不注入也能工作（任何 RTMP 播放器可拉），注入插件额外提供"替换摄像头"能力

模式 C（外部推流 / 中继）
  PC: RtmpServer(19350) ← OBS 推流；同时把收到的流 relaying 到 rtmp(s)://外部地址
```

端口约定（与原版一致）：

| 端口 | 用途 |
|---|---|
| `19350` | RTMP 服务（可配 1024–65535；**与原版 1935 错开**，避免两个插件同时开时抢占） |
| `27015` | Apple Mobile Device 服务（usbmuxd）的本地 TCP 端口，**由 Apple 组件监听** |
| `28767` | **iPhone 侧监听**的 FXP 端口（**刻意与原版 28766 错开**，两套插件可共存） |

流路径默认 `live/douy`（与原版 `live/reecho` 区分；可在 PC 面板里改）。

---

## 2. 会话建立（USB 模式）

手机端 `DOUYTweak` 在选定「USB 直连」时 `listen(28767)`；
PC 端通过 usbmuxd 连上手机端口后，立刻进行 **文本行握手**（可读、可用 `nc`/telnet 调试）。

### 2.1 握手

```
PC  → PHONE : "DYH2/2\n"
PC  → PHONE : {"app":"DOUY PC","version":"1.0.0","video":"h264","audio":"aac",
               "width":1280,"height":720,"fps":30,"nonce":"<hex16>"}\n
PHONE → PC  : "DYA2/2\n"
PHONE → PC  : {"status":"ok","app":"DOUY iOS","version":"1.0.0",
               "width":1280,"height":720,"fps":30}\n
```

- `DYH2/2` = 协议名/版本，必须有 `/2`，否则对端回 `status:"version_mismatch"` 并断开。
- `status`: `ok` | `busy`（已有会话） | `denied` | `version_mismatch` | `no_video`。
- 握手后所有报文为 **二进制帧**（§3）。JSON 行最大 8 KiB。
- 手机端若 3 秒内未收到 `DYH2/2` 则关闭连接（防端口探测堆积）。

### 2.2 心跳

- PC 每 1 s 发一个 `PING` 帧（§3.2），手机收到立刻回 `PONG`。
- 任一方 5 s 未收到对端帧 → 判定断链；PC 侧重连（退避 0.5/1/2/4 s，上限 4 s），
  手机侧回到 `等待连接` 状态并保留最后一帧画面（原版行为：`USB 等待连接 · 恢复相机请点下方按钮`）。
- 手机端积压超过 250 ms 时丢弃非关键帧（原版行为：`画面交付缓冲占满`）。

---

## 3. 二进制帧格式

所有帧共用 28 字节头（小端）：

```
 0  u32  magic      = 0x324D5944 ('F','X','M','2'，即字节流 46 58 4D 32)
 4  u8   type       帧类型，见 §3.1
 5  u8   flags      位标志，见 §3.1
 6  u16  channel     通道号（视频/音频各一路时固定 0；原版 CSU1 也有 channel 字段）
 8  i64  pts_us     显示时间戳（微秒，单调递增）
16  i64  dts_us     解码时间戳（微秒；无 B 帧时等于 pts_us）
24  u32  length     载荷长度（字节）
28  ...             payload 紧跟其后
```

校验规则（对应原版 `invalid media packet magic` / `reserved media header bits are non-zero` /
`media payload length is invalid` / `media PTS exceeds signed clock range`）：

| 检查 | 处理 |
|---|---|
| magic ≠ `DYM2` | 断开（`invalid magic`） |
| type 未知 | 跳过该帧（`unknown frame type`） |
| flags 保留位非 0 | 断开（`reserved flags set`） |
| length > 8 MiB | 断开（`payload too large`） |
| pts_us/dts_us 超出 ±(2^62) | 断开（`pts out of range`） |
| 视频帧非 Annex-B（首字节非 `0x00 0x00 0x01`/`0x00 0x00 0x00 0x01`） | 丢弃并请求关键帧 |

### 3.1 帧类型

| type | 名称 | 载荷 |
|---|---|---|
| `0x01` | `CONFIG` | JSON（UTF-8），键见 §3.3 |
| `0x02` | `PING` | 空 |
| `0x03` | `PONG` | 空 |
| `0x04` | `STOP` | 空（对端应释放解码器、恢复真实摄像头） |
| `0x05` | `REQUEST_IDR` | 空（手机请求关键帧） |
| `0x10` | `VIDEO` | H.264 **Annex-B** 访问单元（含 SPS/PPS 前置，关键帧必须带） |
| `0x11` | `AUDIO` | AAC **ADTS** 单帧 |
| `0x12` | `META` | JSON：分辨率/帧率/时间基变更等 |

`flags` 位定义（媒体帧）：

```
bit0 KEYFRAME   视频：IDR
bit1 CONFIG     视频：该载荷前附 SPS/PPS（AVCDecoderConfigurationRecord 前置）
bit2 DISCONT    时间轴不连续（收到后手机端应重置时钟，不等待）
bit3 SILENT     音频：静音帧（播放静音但保持时间轴）
```

### 3.2 media 之外的约束

- 视频必须 **Annex-B**（不是 AVCC）：PC 端在发送前把编码器的长度前缀转成起始码
  （原版同样做 AVCC→AnnexB：`Invalid AVC configuration`/`Truncated SPS/PPS` 即此模块）。
- 音频必须 **ADTS**：AAC 每帧加 7 字节 ADTS 头，便于手机端边收边解。
- 关键帧间隔建议 1–2 s；手机端解码器在 `REQUEST_IDR` 后等待下一个 `KEYFRAME` 才恢复正常出图。

### 3.3 `CONFIG` JSON

```json
{"video":{"codec":"h264","width":1280,"height":720,"fps":30,"profile":"high"},
 "audio":{"codec":"aac","sampleRate":48000,"channels":2,"bitrate":128000},
 "latency":{"targetMs":120}}
```

手机端只按需读取；缺字段沿用 OBS 输出设置（与原版一致：
`分辨率与帧率跟随 OBS 输出设置`）。

---

## 4. RTMP 模式（模式 B / C）

复刻版内置 RTMP 服务，兼容 OBS 原生推流与 ffmpeg/ffplay：

| 项 | 值 |
|---|---|
| URL | `rtmp://<host>:19350/live/douy`（OBS 里服务器 `rtmp://host:19350/live`，密钥 `douy`） |
| 编码 | H.264（AVC）+ AAC；**其他编码不转码，直接拒绝**（对齐原版 `仅支持 H.264 拉流，请调整发送端编码`） |
| 发布权限 | 仅 `127.0.0.1` / `::1`（对齐原版 `authInternalUsers` 只允许本机 publish） |
| 播放权限 | 任意 IP（局域网手机拉流） |
| 多客户端 | 支持；新播放器接入时立即补发 AVC/AAC sequence header + 最近 GOP 的 IDR |
| 元数据 | `@setDataFrame`/`onMetaData` 转发；服务端另发 `|RtmpSampleAccess` 允许录制 |

行为对齐点（原版靠 tail mediamtx.log 判断状态，复刻版直接内部状态机）：

| 原版日志 | 复刻版内部状态 |
|---|---|
| `RTMP 服务已启动 · 正在确认发布` | `Idle → Listening` |
| `is publishing to path 'live/douy'` | `Publishing` |
| `已发布音画 · 等待客户端拉流（未确认手机连通）` | `Publishing, viewers=0` |
| `N 个客户端正在拉流` | `viewers=N` |

断线：发布者 3 s 无数据 → 广播 `NetStream.Unpublish` 给所有播放器，但**保留**
sequence header/GOP 缓存，发布者重连后无缝继续（原版 MediaMTX 亦是如此）。

---

## 5. 与原版协议的对照

| 原版 | 复刻版 | 说明 |
|---|---|---|
| `CSU1` 会话头（4 字节魔数 + 版本 + channel） | `DYH2/2` 文本行 + JSON | 更易调试；版本/channel 语义保留 |
| `CSC2` 控制消息（消息类型） | type `0x01`–`0x05` 控制帧 | 语义对应 |
| `media packet`（版本/保留位/长度/PTS 校验） | `DYM2` 28 字节头 + 同样四类校验 | 校验项一一对应 |
| JSON 媒体握手（`"channel"` 字段） | JSON 握手行 | 对应 |
| 设备端口 `28766` | `28767`（可配） | 刻意错开 |
| usbmuxd plist `Connect` | 同（C# 实现） | 一致 |

**不做**：字节级兼容原版（原版 `CSU1` 布局无法静态复原，且两端均为本项目实现）。
