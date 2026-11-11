//
//  FXRtmpClient.h
//  极简 RTMP 拉流客户端（自包含 / 零第三方依赖 / 仅 Foundation）
//  支持：rtmp:// 简单握手 + AMF0 connect/createStream/play + FLV H.264(AVC) + AAC
//  不支持：rtmps/rtmpt、推流、加密、H.265/AV1/MP3 等其它编码
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FXRtmpClient;

@protocol FXRtmpClientDelegate <NSObject>
@required
/** AVCDecoderConfigurationRecord（FLV AVC sequence header 的负载，原样字节） */
- (void)rtmpClient:(FXRtmpClient *)client didReceiveAvcConfig:(NSData *)avcConfig;
/** H.264 Annex-B 访问单元（已由客户端把 AVCC 4 字节长度前缀转成 00 00 00 01 起始码） */
- (void)rtmpClient:(FXRtmpClient *)client didReceiveVideoAnnexB:(NSData *)annexB
             ptsMs:(int64_t)ptsMs
           keyframe:(BOOL)keyframe;
/** AudioSpecificConfig（FLV AAC sequence header 的负载，原样字节） */
- (void)rtmpClient:(FXRtmpClient *)client didReceiveAacConfig:(NSData *)audioSpecificConfig;
/** 裸 AAC 访问单元（不带 ADTS 头，不带 FLV 的 2 字节头） */
- (void)rtmpClient:(FXRtmpClient *)client didReceiveAudioAac:(NSData *)rawAac ptsMs:(int64_t)ptsMs;
/** 状态变化（用于 UI 显示），state 取值建议：connecting / playing / reconnecting / stopped / failed */
- (void)rtmpClient:(FXRtmpClient *)client didChangeState:(NSString *)state message:(NSString *)message;
@end

@interface FXRtmpClient : NSObject
- (instancetype)initWithURL:(NSURL *)url delegate:(id<FXRtmpClientDelegate>)delegate;
- (void)start;   // 异步：内部起线程；可重复调用（幂等）
- (void)stop;    // 异步：停止并重连取消；可重复调用
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@end

NS_ASSUME_NONNULL_END
