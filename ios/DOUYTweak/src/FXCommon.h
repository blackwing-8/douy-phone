//
//  FXCommon.h —— 兜鱼复刻版 iOS 注入插件 · 公共定义
//
//  设计要点：
//   * 本插件被注入到宿主（直播类）App，hook AVCaptureVideoDataOutput /
//     AVCaptureAudioDataOutput 的 delegate，实现"替换摄像头/麦克风"。
//   * 帧源（USB / RTMP / 本地视频）解码后的画面与 PCM 都放进 FXMediaStore，
//     hook 回调时从 store 取"最新一帧"，时间戳沿用宿主原始 sample buffer，
//     因此不需要额外的时钟对齐（比原版的 FXCaptureClockContext 简单）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FXSourceMode) {
    FXSourceModeRealCamera = 0, // 恢复真实摄像头/麦克风
    FXSourceModeUSB = 1,        // USB 直连（PC 通过 usbmuxd 推过来）
    FXSourceModeRTMP = 2,       // RTMP 拉流
    FXSourceModeLocalFile = 3,  // 本地视频
};

extern NSString *const FXStatusDidChangeNotification;

/// 全局媒体仓库：解码结果 → hook 消费。
@interface FXMediaStore : NSObject

+ (instancetype)shared;

@property (atomic, assign) FXSourceMode mode;
@property (atomic, assign) BOOL audioReplaceEnabled;
@property (atomic, assign) NSInteger rotation;   // 0 / 90 / 180 / 270
@property (atomic, assign) BOOL mirror;
@property (atomic, assign) BOOL paused;          // 本地视频暂停
@property (atomic, copy, nullable) NSDictionary *videoMeta; // width/height/fps

- (BOOL)isReplacingVideo;
- (BOOL)isReplacingAudio;

// ---- 视频 ----
- (void)setVideoBuffer:(CVPixelBufferRef)buffer ptsMs:(int64_t)ptsMs;
/// 取最新一帧（CFRetain 过，调用方负责 CFRelease）；无帧返回 NULL。
- (nullable CVPixelBufferRef)copyLatestVideoBufferWithPts:(int64_t *)outPtsMs;
- (void)invalidateVideo;

// ---- 音频（48kHz / 2ch / int16 交织）----
- (void)appendAudio:(NSData *)pcm ptsMs:(int64_t)ptsMs;
/// 取最多 maxBytes 字节的 PCM；不足时返回已积累的部分。
- (nullable NSData *)dequeueAudioBytes:(NSUInteger)maxBytes;
- (void)resetAudio;

// ---- 状态 ----
- (void)setStatus:(NSString *)text;
@property (atomic, copy, readonly) NSString *statusText;

@end

/// H.264 Annex-B → CVPixelBuffer（VideoToolbox 硬解）。
@interface FXVideoDecoder : NSObject

/// 用 AVCDecoderConfigurationRecord（FLV sequence header）配置。
- (BOOL)configureWithAVCConfig:(NSData *)avcConfig;
/// 用 SPS/PPS 原始字节配置。
- (BOOL)configureWithSPS:(NSData *)sps pps:(NSData *)pps;
/// 解码一个 Annex-B 访问单元。失败次数过多会自动要求关键帧。
- (void)decodeAnnexB:(NSData *)annexB ptsMs:(int64_t)ptsMs keyframe:(BOOL)keyframe;
- (void)reset;
@property (atomic, assign) BOOL needsKeyframe;
@property (atomic, readonly) int lastWidth;
@property (atomic, readonly) int lastHeight;

@end

/// AAC → PCM（48kHz / 2ch / int16 交织）。
@interface FXAudioDecoder : NSObject

/// AudioSpecificConfig（FLV AAC sequence header）。
- (BOOL)configureWithAudioSpecificConfig:(NSData *)asc;
/// 由 ADTS 头推导（USB 模式直接收 ADTS）。
- (BOOL)configureWithADTSHeader:(NSData *)adts;
/// 裸 AAC 访问单元（一个 AAC frame，1024 samples）。
- (void)decodeRawAAC:(NSData *)rawAac;
/// ADTS 帧（含 7/9 字节头）。
- (void)decodeADTS:(NSData *)adts;

@property (atomic, readonly) int sampleRate;
@property (atomic, readonly) int channels;

@end

/// USB 帧源：监听 28767，解析 FXP/2。
@interface FXUSBSource : NSObject

+ (instancetype)shared;
- (void)start;
- (void)stop;
@property (atomic, readonly) BOOL running;
@property (atomic, readonly) int listenPort;
- (void)setListenPort:(int)port;

@end

/// 本地视频源：AVAssetReader 循环播放。
@interface FXFileSource : NSObject

+ (instancetype)shared;
- (BOOL)openURL:(NSURL *)url error:(NSError **)error;
- (void)start;
- (void)stop;
@property (atomic, readonly, nullable) NSURL *currentURL;

@end

/// RTMP 源：转发到 FXRtmpClient（见 FXRtmpClient.h）。
@interface FXRTMPSource : NSObject

+ (instancetype)shared;
- (void)connectURL:(NSURL *)url;
- (void)stop;
@property (atomic, copy, readonly, nullable) NSString *currentURLString;

@end

/// 安装 hook（幂等）。
void FXInstallHooks(void);
/// 显示/隐藏浮窗。
void FXShowOverlay(BOOL show);
/// 把浮窗挂到指定 windowScene（主线程内部派发）。
void FXAttachOverlayToScene(UIWindowScene *scene);

/// 创建「账号与卡包」面板（由 FXAccountPanel.mm 实现，调用方负责 present）。
UIViewController *FXCreateAccountPanel(void);

/// 内置品牌 logo（由 FXLogoAsset.mm 提供；dylib 无资源包，PNG 以 base64 编入）。
UIImage *FXLogoImage(void);

NS_ASSUME_NONNULL_END
