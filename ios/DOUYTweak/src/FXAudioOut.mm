//
//  FXAudioOut.mm —— 把解码好的 OBS 声音从手机扬声器放出来
//
//  为什么走这条路：抖音的麦克风不走 AVFoundation（实测 0 次命中），
//  而直接注入它的 AudioUnit 会破坏其音频初始化（两次实测：卡死 / 直播上传异常）。
//  帧相的做法是「解码后本机播放，麦克风自然拾音」（它导入了 AudioOutputUnitStart），
//  这条路完全不碰宿主代码，最坏情况只是没声音，不会影响抖音本身。
//
//  实现：AVAudioEngine + AVAudioPlayerNode，定时从 FXMediaStore 的 PCM 缓冲取数据。
//  默认关闭，必须用户手动打开，避免在后台偷偷占音频资源。
//

#import "FXCommon.h"
#import <AVFoundation/AVFoundation.h>

static const NSUInteger kPumpBytes = 9600;   // 50ms @48k/2ch/int16

@implementation FXAudioOut
{
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_player;
    AVAudioFormat *_format;
    dispatch_source_t _timer;
    dispatch_queue_t _queue;
}

+ (instancetype)shared
{
    static FXAudioOut *out = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        out = [[FXAudioOut alloc] init];
    });
    return out;
}

- (BOOL)running
{
    return _timer != NULL;
}

- (BOOL)start
{
    if (_timer != NULL)
    {
        return YES;
    }

    @try
    {
        _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                   sampleRate:48000
                                                     channels:2
                                                  interleaved:YES];
        if (_format == nil)
        {
            NSLog(@"[DOUY] 声音外放：无法创建 48k/2ch/int16 格式");
            return NO;
        }

        _engine = [[AVAudioEngine alloc] init];
        _player = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:_player];
        [_engine connect:_player to:_engine.mainMixerNode format:_format];
        _player.volume = 1.0f;

        NSError *error = nil;
        if (![_engine startAndReturnError:&error])
        {
            NSLog(@"[DOUY] 声音外放：音频引擎启动失败 %@", error);
            [self stop];
            return NO;
        }

        [_player play];

        _queue = dispatch_queue_create("douy.audio.out", DISPATCH_QUEUE_SERIAL);
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)kPumpBytes * 0),
                                  50ull * NSEC_PER_MSEC,
                                  10ull * NSEC_PER_MSEC);

        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{
            [weakSelf pump];
        });
        dispatch_resume(_timer);

        NSLog(@"[DOUY] 声音外放已开启");
        return YES;
    }
    @catch (NSException *exception)
    {
        NSLog(@"[DOUY] 声音外放异常: %@", exception);
        [self stop];
        return NO;
    }
}

- (void)stop
{
    if (_timer != NULL)
    {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }

    @try
    {
        if (_player != nil)
        {
            [_player stop];
        }
        if (_engine != nil)
        {
            [_engine stop];
        }
    }
    @catch (NSException *exception)
    {
        NSLog(@"[DOUY] 声音外放停止异常: %@", exception);
    }

    _player = nil;
    _engine = nil;
    NSLog(@"[DOUY] 声音外放已关闭");
}

- (void)pump
{
    if (_player == nil || _format == nil)
    {
        return;
    }

    NSData *pcm = [[FXMediaStore shared] dequeueAudioBytes:kPumpBytes];
    if (pcm.length < 4)
    {
        return;
    }

    const NSUInteger frames = pcm.length / 4;   // 2ch × int16
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format
                                                             frameCapacity:(AVAudioFrameCount)frames];
    if (buffer == nil)
    {
        return;
    }

    buffer.frameLength = (AVAudioFrameCount)frames;
    if (buffer.int16ChannelData == NULL || buffer.int16ChannelData[0] == NULL)
    {
        return;
    }

    memcpy(buffer.int16ChannelData[0], pcm.bytes, frames * 4);
    [_player scheduleBuffer:buffer completionHandler:nil];
}

@end
