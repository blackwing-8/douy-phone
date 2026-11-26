#import "FXCommon.h"

NSString *const FXStatusDidChangeNotification = @"FXStatusDidChangeNotification";

/// 音频环形缓冲上限（±4 秒 @48k/2ch/int16 = 384000 B/秒）
static const NSUInteger kMaxAudioBytes = 4 * 48000 * 2 * 2;


// ---------------------------------------------------------------------------
// 无锁 PCM 环：解码线程写（生产者），音频渲染线程读（消费者）。
// 音频线程绝不能加锁/分配内存，所以这里只用原子下标。
// 格式固定：48kHz / 2ch / int16（与解码器输出一致）。
// ---------------------------------------------------------------------------
#define FX_RING_FRAMES (48000 * 2)          // 2 秒
static int16_t gRing[FX_RING_FRAMES * 2];
static volatile uint32_t gRingWrite = 0;    // 已写入帧数
static volatile uint32_t gRingRead = 0;     // 已读取帧数

static void FXRingWrite(const int16_t *src, uint32_t frames)
{
    for (uint32_t i = 0; i < frames; i++)
    {
        uint32_t w = gRingWrite;
        if (w - gRingRead >= FX_RING_FRAMES)     // 满了就丢新数据，绝不覆盖未读
        {
            return;
        }
        gRing[(w % FX_RING_FRAMES) * 2 + 0] = src[i * 2 + 0];
        gRing[(w % FX_RING_FRAMES) * 2 + 1] = src[i * 2 + 1];
        gRingWrite = w + 1;
    }
}

/// 音频线程调用：读最多 frames 帧，返回实际写入帧数
uint32_t FXAudioRingRead(int16_t *dst, uint32_t frames)
{
    if (dst == NULL || frames == 0)
    {
        return 0;
    }
    uint32_t r = gRingRead;
    uint32_t available = gRingWrite - r;
    if (available < frames)
    {
        return 0;                                 // 不够就整段不给，避免断续杂音
    }
    for (uint32_t i = 0; i < frames; i++)
    {
        dst[i * 2 + 0] = gRing[((r + i) % FX_RING_FRAMES) * 2 + 0];
        dst[i * 2 + 1] = gRing[((r + i) % FX_RING_FRAMES) * 2 + 1];
    }
    gRingRead = r + frames;
    return frames;
}

uint32_t FXAudioRingAvailable(void)
{
    return gRingWrite - gRingRead;
}

@implementation FXMediaStore
{
    NSLock *_lock;
    CVPixelBufferRef _videoBuffer;
    CVPixelBufferRef _videoQueue[4];
    int64_t _videoSeqQueue[4];
    int64_t _videoSeqCounter;   // FIFO 环形缓冲：每帧只呈现一次（纯 C，避免 CF 对象走 ARC 桥接）
    int _videoQueueCount;
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
    // 不再排除「真实摄像头」：原版支持「画面用手机后置摄像头、声音用电脑的」。
    // 缓冲区没数据时会自动放行原始麦克风（FXBlitIntoAudioBuffer 里判断），
    // 所以放开这个条件不会把真实麦克风弄哑。
    FXAudioInjectSetReplaceFlag(self.audioReplaceEnabled ? 1 : 0);
    return self.audioReplaceEnabled;
}

- (void)setVideoBuffer:(CVPixelBufferRef)buffer ptsMs:(int64_t)ptsMs
{
    if (buffer == NULL)
    {
        return;
    }

    CVPixelBufferRef dropped = NULL;
    CVPixelBufferRef oldLatest = NULL;

    [_lock lock];

    // 队列满：丢掉最旧的一帧，保证延迟有上限（≈100ms）
    if (_videoQueueCount >= 4)
    {
        dropped = _videoQueue[0];
        for (int i = 1; i < _videoQueueCount; i++)
        {
            _videoQueue[i - 1] = _videoQueue[i];
            _videoSeqQueue[i - 1] = _videoSeqQueue[i];
        }
        _videoQueueCount -= 1;
    }

    _videoQueue[_videoQueueCount] = (CVPixelBufferRef)CFRetain(buffer);
    _videoSeqCounter += 1;
    _videoSeqQueue[_videoQueueCount] = _videoSeqCounter;
    _videoQueueCount += 1;

    oldLatest = _videoBuffer;
    _videoBuffer = (CVPixelBufferRef)CFRetain(buffer);
    _videoPtsMs = ptsMs;

    [_lock unlock];

    if (oldLatest)
    {
        CVPixelBufferRelease(oldLatest);
    }
    if (dropped)
    {
        CVPixelBufferRelease(dropped);
    }
}

- (CVPixelBufferRef)copyNextVideoBufferWithSequence:(int64_t *)outSeq
{
    CVPixelBufferRef result = NULL;
    int64_t poppedSeq = 0;

    [_lock lock];
    if (_videoQueueCount > 0)
    {
        result = _videoQueue[0];
        poppedSeq = _videoSeqQueue[0];
        for (int i = 1; i < _videoQueueCount; i++)
        {
            _videoQueue[i - 1] = _videoQueue[i];
            _videoSeqQueue[i - 1] = _videoSeqQueue[i];
        }
        _videoQueueCount -= 1;
        _videoQueue[_videoQueueCount] = NULL;
    }
    [_lock unlock];

    if (outSeq)
    {
        *outSeq = poppedSeq;
    }
    return result;
}

- (CVPixelBufferRef)copyNextVideoBufferWithPts:(int64_t *)outPtsMs
{
    CVPixelBufferRef result = NULL;
    int64_t poppedSeq = 0;

    [_lock lock];
    if (_videoQueueCount > 0)
    {
        result = _videoQueue[0];          // 队列里已持有 +1，直接转移所有权
        poppedSeq = _videoSeqQueue[0];
        for (int i = 1; i < _videoQueueCount; i++)
        {
            _videoQueue[i - 1] = _videoQueue[i];
            _videoSeqQueue[i - 1] = _videoSeqQueue[i];
        }
        _videoQueueCount -= 1;
        _videoQueue[_videoQueueCount] = NULL;
    }
    if (outPtsMs)
    {
        *outPtsMs = _videoPtsMs;
    }
    [_lock unlock];

    return result;
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
    CVPixelBufferRef buffered[4] = {NULL, NULL, NULL, NULL};
    int bufferedCount = 0;
    CVPixelBufferRef oldLatest = NULL;

    [_lock lock];
    for (int i = 0; i < _videoQueueCount && i < 4; i++)
    {
        buffered[bufferedCount++] = _videoQueue[i];
        _videoQueue[i] = NULL;
    }
    _videoQueueCount = 0;

    oldLatest = _videoBuffer;
    _videoBuffer = NULL;
    [_lock unlock];

    for (int i = 0; i < bufferedCount; i++)
    {
        if (buffered[i])
        {
            CVPixelBufferRelease(buffered[i]);
        }
    }
    if (oldLatest)
    {
        CVPixelBufferRelease(oldLatest);
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
    FXRingWrite((const int16_t *)pcm.bytes, (uint32_t)(pcm.length / 4));
    if (_audio.length > kMaxAudioBytes)
    {
        NSUInteger drop = _audio.length - kMaxAudioBytes / 2;
        drop -= (drop % 4);
        [_audio replaceBytesInRange:NSMakeRange(0, drop) withBytes:NULL length:0];
        _audioPtsMs += (int64_t)(drop / 4) * 1000 / 48000;
    }
    [_lock unlock];
}

- (NSUInteger)audioBufferedBytes
{
    NSUInteger n = 0;
    [_lock lock];
    n = _audio.length;
    [_lock unlock];
    return n;
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
