#import "FXCommon.h"
#import "FXRtmpClient.h"

@interface FXRTMPSource () <FXRtmpClientDelegate>
@end

@implementation FXRTMPSource
{
    FXRtmpClient *_client;
    FXVideoDecoder *_video;
    FXAudioDecoder *_audio;
    NSString *_currentURLString;
}

+ (instancetype)shared
{
    static FXRTMPSource *source = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = [[FXRTMPSource alloc] init];
    });
    return source;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _video = [[FXVideoDecoder alloc] init];
        _audio = [[FXAudioDecoder alloc] init];
    }
    return self;
}

- (NSString *)currentURLString
{
    return _currentURLString;
}

- (void)connectURL:(NSURL *)url
{
    if (url == nil)
    {
        return;
    }

    [self stop];

    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"rtmp"])
    {
        [[FXMediaStore shared] setStatus:@"请输入有效的 rtmp:// 地址（暂不支持 rtmps）"];
        return;
    }

    _currentURLString = url.absoluteString;
    [[FXMediaStore shared] setMode:FXSourceModeRTMP];
    [[FXMediaStore shared] setStatus:@"RTMP 连接中…"];

    _video = [[FXVideoDecoder alloc] init];
    _audio = [[FXAudioDecoder alloc] init];

    _client = [[FXRtmpClient alloc] initWithURL:url delegate:self];
    [_client start];
}

- (void)stop
{
    [_client stop];
    _client = nil;
    _currentURLString = nil;
    [[FXMediaStore shared] invalidateVideo];
    [[FXMediaStore shared] resetAudio];
}

#pragma mark - FXRtmpClientDelegate

- (void)rtmpClient:(FXRtmpClient *)client didReceiveAvcConfig:(NSData *)avcConfig
{
    [_video configureWithAVCConfig:avcConfig];
}

- (void)rtmpClient:(FXRtmpClient *)client didReceiveVideoAnnexB:(NSData *)annexB ptsMs:(int64_t)ptsMs keyframe:(BOOL)keyframe
{
    [_video decodeAnnexB:annexB ptsMs:ptsMs keyframe:keyframe];
}

- (void)rtmpClient:(FXRtmpClient *)client didReceiveAacConfig:(NSData *)audioSpecificConfig
{
    [_audio configureWithAudioSpecificConfig:audioSpecificConfig];
}

- (void)rtmpClient:(FXRtmpClient *)client didReceiveAudioAac:(NSData *)rawAac ptsMs:(int64_t)ptsMs
{
    [_audio decodeRawAAC:rawAac];
}

- (void)rtmpClient:(FXRtmpClient *)client didChangeState:(NSString *)state message:(NSString *)message
{
    NSString *text = nil;
    if ([state isEqualToString:@"playing"])
    {
        text = @"RTMP 接收中";
    }
    else if ([state isEqualToString:@"connecting"])
    {
        text = @"RTMP 连接中…";
    }
    else if ([state isEqualToString:@"reconnecting"])
    {
        text = @"RTMP 断开，正在重连…";
    }
    else if ([state isEqualToString:@"failed"])
    {
        text = message.length > 0 ? message : @"RTMP 接收失败，请重新连接";
    }
    else if ([state isEqualToString:@"stopped"])
    {
        text = @"RTMP 已停止";
    }

    if (text.length > 0)
    {
        [[FXMediaStore shared] setStatus:text];
    }
}

@end
