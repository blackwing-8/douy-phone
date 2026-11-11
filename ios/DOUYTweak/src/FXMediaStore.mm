#import "FXCommon.h"

NSString *const FXStatusDidChangeNotification = @"FXStatusDidChangeNotification";

/// 音频环形缓冲上限（±4 秒 @48k/2ch/int16 = 384000 B/秒）
static const NSUInteger kMaxAudioBytes = 4 * 48000 * 2 * 2;

@implementation FXMediaStore
{
    NSLock *_lock;
    CVPixelBufferRef _videoBuffer;
    int64_t _videoPtsMs;
    NSMutableData *_audio;
    int64_t _audioPtsMs;
    NSString *_statusText;
}

+ (instancetype)shared
{
    static FXMediaStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[FXMediaStore alloc] init];
    });
    return store;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _lock = [[NSLock alloc] init];
        _audio = [[NSMutableData alloc] initWithCapacity:64 * 1024];
        _mode = FXSourceModeRealCamera;
        _statusText = @"兜鱼 · 真实摄像头";
        _rotation = 0;
    }
    return self;
}

- (void)dealloc
{
    if (_videoBuffer)
    {
        CVPixelBufferRelease(_videoBuffer);
        _videoBuffer = NULL;
    }
}

- (BOOL)isReplacingVideo
{
    return self.mode != FXSourceModeRealCamera;
}

- (BOOL)isReplacingAudio
{
    return self.mode != FXSourceModeRealCamera && self.audioReplaceEnabled;
}

- (void)setVideoBuffer:(CVPixelBufferRef)buffer ptsMs:(int64_t)ptsMs
{
    if (buffer == NULL)
    {
        return;
    }

    CVPixelBufferRef copy = (CVPixelBufferRef)CFRetain(buffer);
    [_lock lock];
    CVPixelBufferRef old = _videoBuffer;
    _videoBuffer = copy;
    _videoPtsMs = ptsMs;
    [_lock unlock];

    if (old)
    {
        CVPixelBufferRelease(old);
    }
}

- (CVPixelBufferRef)copyLatestVideoBufferWithPts:(int64_t *)outPtsMs
{
    [_lock lock];
    CVPixelBufferRef buffer = _videoBuffer;
    if (buffer)
    {
        CFRetain(buffer);
    }
    if (outPtsMs)
    {
        *outPtsMs = _videoPtsMs;
    }
    [_lock unlock];
    return buffer;
}

- (void)invalidateVideo
{
    [_lock lock];
    CVPixelBufferRef old = _videoBuffer;
    _videoBuffer = NULL;
    [_lock unlock];
    if (old)
    {
        CVPixelBufferRelease(old);
    }
}

- (void)appendAudio:(NSData *)pcm ptsMs:(int64_t)ptsMs
{
    if (pcm.length == 0)
    {
        return;
    }

    [_lock lock];
    if (_audio.length == 0)
    {
        _audioPtsMs = ptsMs;
    }
    [_audio appendData:pcm];
    if (_audio.length > kMaxAudioBytes)
    {
        NSUInteger drop = _audio.length - kMaxAudioBytes / 2;
        drop -= (drop % 4);
        [_audio replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
        _audioPtsMs += (int64_t)(drop / 4) * 1000 / 48000;
    }
    [_lock unlock];
}

- (NSData *)dequeueAudioBytes:(NSUInteger)maxBytes
{
    if (maxBytes == 0)
    {
        return nil;
    }

    [_lock lock];
    NSData *result = nil;
    if (_audio.length >= maxBytes)
    {
        result = [_audio subdataWithRange:NSMakeRange(0, maxBytes)];
        [_audio replaceBytesInRange:NSMakeRange(0, maxBytes) withBytes:NULL length:0];
        _audioPtsMs += (int64_t)(maxBytes / 4) * 1000 / 48000;
    }
    [_lock unlock];
    return result;
}

- (void)resetAudio
{
    [_lock lock];
    [_audio setLength:0];
    [_lock unlock];
}

- (void)setStatus:(NSString *)text
{
    if (text.length == 0)
    {
        return;
    }

    @synchronized (self)
    {
        _statusText = [text copy];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FXStatusDidChangeNotification
                                                            object:nil
                                                          userInfo:@{@"text": text}];
    });
}

- (NSString *)statusText
{
    @synchronized (self)
    {
        return _statusText ?: @"";
    }
}

@end
