//
//  FXHooks.mm —— 注入核心
//
//  手法与原型一致：method_exchangeImplementations 换掉
//    -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
//    -[AVCaptureAudioDataOutput setSampleBufferDelegate:queue:]
//  把宿主传入的 delegate 包进一个代理，代理在回调里把 CMSampleBuffer
//  换成"来自 USB / RTMP / 本地视频"的帧，再转发给真正的 delegate。
//
//  时间戳沿用宿主原始 sample buffer 的 PTS，因此不需要额外的时钟对齐。
//

#import "FXCommon.h"
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>

// ---------------------------------------------------------------- 视频替换

static CIContext *FXSharedCIContext(void)
{
    static CIContext *context = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{ kCIContextCacheIntermediates : @NO }];
    });
    return context;
}

static CVPixelBufferRef FXCreateBufferLike(CVPixelBufferRef like, size_t width, size_t height)
{
    OSType format = CVPixelBufferGetPixelFormatType(like);
    if (format == 0)
    {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }

    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          format,
                                          (__bridge CFDictionaryRef)attributes,
                                          &buffer);
    return status == kCVReturnSuccess ? buffer : NULL;
}

/// 旋转 / 镜像 / 缩放到目标尺寸（只在需要时调用）。
static CVPixelBufferRef FXTransformBuffer(CVPixelBufferRef source, size_t outWidth, size_t outHeight,
                                          NSInteger rotation, BOOL mirror)
{
    if (source == NULL || outWidth == 0 || outHeight == 0)
    {
        return NULL;
    }

    CVPixelBufferRef destination = FXCreateBufferLike(source, outWidth, outHeight);
    if (destination == NULL)
    {
        return NULL;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    CGFloat width = CVPixelBufferGetWidth(source);
    CGFloat height = CVPixelBufferGetHeight(source);

    CGAffineTransform transform = CGAffineTransformMakeTranslation(-width / 2.0, -height / 2.0);
    if (mirror)
    {
        transform = CGAffineTransformScale(transform, -1.0, 1.0);
    }
    if (rotation != 0)
    {
        transform = CGAffineTransformRotate(transform, (CGFloat)rotation * (CGFloat)M_PI / 180.0);
    }

    CGRect box = CGRectApplyAffineTransform(CGRectMake(0, 0, width, height), transform);
    CGFloat boxWidth = MAX(CGRectGetWidth(box), 1.0);
    CGFloat boxHeight = MAX(CGRectGetHeight(box), 1.0);
    CGFloat scale = MIN((CGFloat)outWidth / boxWidth, (CGFloat)outHeight / boxHeight);

    CGAffineTransform finalTransform = CGAffineTransformConcat(transform,
                                                               CGAffineTransformMakeScale(scale, scale));
    finalTransform = CGAffineTransformConcat(finalTransform,
                                             CGAffineTransformMakeTranslation(outWidth / 2.0, outHeight / 2.0));
    CIImage *transformed = [image imageByApplyingTransform:finalTransform];

    [FXSharedCIContext() render:transformed toCVPixelBuffer:destination];
    return destination;
}

static CMSampleBufferRef FXCreateVideoSampleBuffer(CVPixelBufferRef pixelBuffer, CMTime pts, CMTime duration)
{
    if (pixelBuffer == NULL)
    {
        return NULL;
    }

    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format) != noErr || format == NULL)
    {
        return NULL;
    }

    if (!CMTIME_IS_VALID(duration) || CMTIME_IS_INDEFINITE(duration) ||
        CMTIME_COMPARE_INLINE(duration, <=, kCMTimeZero))
    {
        duration = CMTimeMake(1, 30);   // 时长缺失时给个合理值，避免 VT 侧异常
    }

    CMSampleTimingInfo timing = { duration, pts, kCMTimeInvalid };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                               pixelBuffer,
                                                               format,
                                                               &timing,
                                                               &sample);
    CFRelease(format);
    return status == noErr ? sample : NULL;
}

/// 生成"替换用"视频 sample buffer；返回 NULL 表示本帧不替换。
static CMSampleBufferRef FXMakeReplacementVideoSample(CMSampleBufferRef original, AVCaptureOutput *output)
{
    FXMediaStore *store = [FXMediaStore shared];
    if (![store isReplacingVideo])
    {
        return NULL;
    }

    int64_t sourcePts = 0;
    CVPixelBufferRef decoded = [store copyLatestVideoBufferWithPts:&sourcePts];
    if (decoded == NULL)
    {
        return NULL; // 还没有可用帧：先让真实画面过去
    }

    CVImageBufferRef originalImage = CMSampleBufferGetImageBuffer(original);
    size_t targetWidth = originalImage ? CVPixelBufferGetWidth(originalImage) : CVPixelBufferGetWidth(decoded);
    size_t targetHeight = originalImage ? CVPixelBufferGetHeight(originalImage) : CVPixelBufferGetHeight(decoded);
    size_t decodedWidth = CVPixelBufferGetWidth(decoded);
    size_t decodedHeight = CVPixelBufferGetHeight(decoded);

    NSInteger rotation = store.rotation;
    BOOL mirror = store.mirror;
    BOOL needsTransform = (rotation % 360) != 0 || mirror || decodedWidth != targetWidth ||
                          decodedHeight != targetHeight;

    CVPixelBufferRef finalBuffer = NULL;
    if (needsTransform)
    {
        finalBuffer = FXTransformBuffer(decoded, targetWidth, targetHeight, rotation, mirror);
    }
    else
    {
        finalBuffer = (CVPixelBufferRef)CFRetain(decoded);
    }

    CVPixelBufferRelease(decoded);
    if (finalBuffer == NULL)
    {
        return NULL;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(original);
    CMTime duration = CMSampleBufferGetDuration(original);
    if (!CMTIME_IS_VALID(pts))
    {
        pts = CMTimeMake(sourcePts, 1000);
    }

    CMSampleBufferRef replacement = FXCreateVideoSampleBuffer(finalBuffer, pts, duration);
    CVPixelBufferRelease(finalBuffer);
    return replacement;
}

// ---------------------------------------------------------------- 音频替换

static const int kFXInputRate = 48000;
static const int kFXInputChannels = 2;

static AudioConverterRef FXAudioConverterForASBD(const AudioStreamBasicDescription *target)
{
    static AudioConverterRef converter = NULL;
    static AudioStreamBasicDescription cached = {0};
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
    });

    [lock lock];
    if (converter != NULL &&
        cached.mSampleRate == target->mSampleRate &&
        cached.mFormatID == target->mFormatID &&
        cached.mChannelsPerFrame == target->mChannelsPerFrame &&
        cached.mBitsPerChannel == target->mBitsPerChannel &&
        cached.mFormatFlags == target->mFormatFlags)
    {
        [lock unlock];
        return converter;
    }

    if (converter != NULL)
    {
        AudioConverterDispose(converter);
        converter = NULL;
    }

    AudioStreamBasicDescription source = {0};
    source.mSampleRate = kFXInputRate;
    source.mFormatID = kAudioFormatLinearPCM;
    source.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    source.mChannelsPerFrame = kFXInputChannels;
    source.mFramesPerPacket = 1;
    source.mBitsPerChannel = 16;
    source.mBytesPerFrame = kFXInputChannels * 2;
    source.mBytesPerPacket = source.mBytesPerFrame;

    if (AudioConverterNew(&source, target, &converter) != noErr)
    {
        converter = NULL;
    }
    else
    {
        cached = *target;
    }

    [lock unlock];
    return converter;
}

static BOOL FXSameAsCanonical(const AudioStreamBasicDescription *asbd)
{
    return asbd != NULL &&
           asbd->mFormatID == kAudioFormatLinearPCM &&
           asbd->mSampleRate == kFXInputRate &&
           asbd->mChannelsPerFrame == kFXInputChannels &&
           asbd->mBitsPerChannel == 16 &&
           (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
           (asbd->mFormatFlags & kAudioFormatFlagIsFloat) == 0;
}

typedef struct
{
    const void *data;
    UInt32 length;
} FXConvertFeed;

static OSStatus FXConvertInputProc(AudioConverterRef converter,
                                   UInt32 *ioNumberDataPackets,
                                   AudioBufferList *ioData,
                                   AudioStreamPacketDescription **outDataPacketDescription,
                                   void *inUserData)
{
    FXConvertFeed *feed = (FXConvertFeed *)inUserData;
    if (feed == NULL || feed->length == 0)
    {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = kFXInputChannels;
    ioData->mBuffers[0].mData = (void *)feed->data;
    ioData->mBuffers[0].mDataByteSize = feed->length;
    *ioNumberDataPackets = feed->length / (kFXInputChannels * 2);
    feed->length = 0;

    if (outDataPacketDescription)
    {
        *outDataPacketDescription = NULL;
    }
    return noErr;
}

static NSData *FXConvertPCM(NSData *input, const AudioStreamBasicDescription *target)
{
    if (input.length == 0 || target == NULL)
    {
        return nil;
    }

    AudioConverterRef converter = FXAudioConverterForASBD(target);
    if (converter == NULL)
    {
        return nil;
    }

    const UInt32 inputFrames = (UInt32)(input.length / (kFXInputChannels * 2));
    if (inputFrames == 0)
    {
        return nil;
    }

    UInt32 outputCapacity = (UInt32)((double)inputFrames * target->mSampleRate / (double)kFXInputRate) + 64;
    UInt32 outputSize = outputCapacity * (target->mBytesPerFrame > 0 ? target->mBytesPerFrame : 4);
    NSMutableData *output = [NSMutableData dataWithLength:outputSize];

    AudioBufferList outputList = {0};
    outputList.mNumberBuffers = 1;
    outputList.mBuffers[0].mNumberChannels = target->mChannelsPerFrame;
    outputList.mBuffers[0].mDataByteSize = outputSize;
    outputList.mBuffers[0].mData = output.mutableBytes;

    FXConvertFeed feed = { input.bytes, (UInt32)input.length };
    UInt32 packets = outputCapacity;
    OSStatus status = AudioConverterFillComplexBuffer(converter,
                                                      FXConvertInputProc,
                                                      &feed,
                                                      &packets,
                                                      &outputList,
                                                      NULL);
    if (status != noErr)
    {
        return nil;
    }

    UInt32 produced = outputList.mBuffers[0].mDataByteSize;
    if (produced == 0)
    {
        return nil;
    }

    return [output subdataWithRange:NSMakeRange(0, produced)];
}

static CMSampleBufferRef FXCreateAudioSampleBuffer(NSData *pcm, CMFormatDescriptionRef format, CMTime pts, CMItemCount frames)
{
    if (pcm.length == 0 || format == NULL)
    {
        return NULL;
    }

    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, pcm.length, kCFAllocatorDefault, NULL,
                                           0, pcm.length, kCMBlockBufferAssureMemoryNowFlag, &block) != noErr ||
        block == NULL)
    {
        return NULL;
    }

    if (CMBlockBufferReplaceDataBytes(pcm.bytes, block, 0, pcm.length) != kCMBlockBufferNoErr)
    {
        CFRelease(block);
        return NULL;
    }

    CMSampleBufferRef sample = NULL;
    OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault,
                                                                          block,
                                                                          format,
                                                                          frames,
                                                                          pts,
                                                                          NULL,
                                                                          &sample);
    CFRelease(block);
    return status == noErr ? sample : NULL;
}

static CMSampleBufferRef FXMakeReplacementAudioSample(CMSampleBufferRef original)
{
    FXMediaStore *store = [FXMediaStore shared];
    if (![store isReplacingAudio])
    {
        return NULL;
    }

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(original);
    if (format == NULL || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio)
    {
        return NULL;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    if (asbd == NULL || asbd->mSampleRate <= 0 || asbd->mChannelsPerFrame == 0)
    {
        return NULL;
    }

    CMItemCount wantedFrames = CMSampleBufferGetNumSamples(original);
    if (wantedFrames <= 0)
    {
        wantedFrames = 1024;
    }

    UInt32 inputFrames = (UInt32)llround((double)wantedFrames * (double)kFXInputRate / asbd->mSampleRate);
    NSUInteger neededBytes = (NSUInteger)inputFrames * kFXInputChannels * 2;
    NSData *pcm = [store dequeueAudioBytes:neededBytes];
    if (pcm.length < neededBytes)
    {
        return NULL; // 音频还没攒够，先让真实麦克风过去
    }

    NSData *payload = nil;
    if (FXSameAsCanonical(asbd))
    {
        payload = pcm;
    }
    else
    {
        payload = FXConvertPCM(pcm, asbd);
    }

    if (payload.length == 0)
    {
        return NULL;
    }

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(original);
    CMItemCount frames = (CMItemCount)(payload.length / (asbd->mBytesPerFrame > 0 ? asbd->mBytesPerFrame : 4));
    return FXCreateAudioSampleBuffer(payload, format, pts, frames);
}

// ---------------------------------------------------------------- 代理

@interface FXVideoDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> original;
@end

@interface FXAudioDelegateProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> original;
@end

static char kFXVideoProxyKey;
static char kFXAudioProxyKey;

// ─────────────── 崩溃防御 ───────────────
// 替换链路里任何一步不可靠时，都必须把「原始样本」原样交给宿主，绝不能让宿主崩。

static volatile int FXVideoReplaceFailures = 0;
static volatile int FXAudioReplaceFailures = 0;

/// 安全模式：在 App 里执行 defaults write <bundle> FXSafeMode -bool YES 即可完全关闭替换（只做转发）
static BOOL FXSafeModeEnabled(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"FXSafeMode"];
}

/// 把替换帧交给宿主前的最后一道校验：尺寸/格式/时间戳任何一项对不上就放弃替换
static BOOL FXVideoSampleLooksValid(CMSampleBufferRef sample)
{
    if (sample == NULL || !CMSampleBufferIsValid(sample))
    {
        return NO;
    }
    if (CMSampleBufferGetNumSamples(sample) < 1)
    {
        return NO;
    }
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (image == NULL)
    {
        return NO;
    }
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (format == NULL)
    {
        return NO;
    }
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(format);
    if (dim.width <= 0 || dim.height <= 0)
    {
        return NO;
    }
    if ((size_t)dim.width != CVPixelBufferGetWidth(image) ||
        (size_t)dim.height != CVPixelBufferGetHeight(image))
    {
        return NO;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!CMTIME_IS_VALID(pts))
    {
        return NO;
    }
    return YES;
}

static BOOL FXAudioSampleLooksValid(CMSampleBufferRef sample)
{
    if (sample == NULL || !CMSampleBufferIsValid(sample))
    {
        return NO;
    }
    if (CMSampleBufferGetNumSamples(sample) < 1)
    {
        return NO;
    }
    if (CMSampleBufferGetFormatDescription(sample) == NULL)
    {
        return NO;
    }
    return YES;
}

@implementation FXVideoDelegateProxy

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.original;
    if (target == nil)
    {
        return;
    }

    CMSampleBufferRef replacement = NULL;

    // 安全模式或连续失败 5 次后：只转发原帧，绝不再碰替换链路
    if (!FXSafeModeEnabled() && FXVideoReplaceFailures < 5)
    {
        @try
        {
            replacement = FXMakeReplacementVideoSample(sampleBuffer, output);
        }
        @catch (NSException *exception)
        {
            __sync_add_and_fetch(&FXVideoReplaceFailures, 1);
            NSLog(@"[DOUY] 视频替换抛异常，回退原帧: %@", exception);
            replacement = NULL;
        }

        if (replacement != NULL && !FXVideoSampleLooksValid(replacement))
        {
            __sync_add_and_fetch(&FXVideoReplaceFailures, 1);
            NSLog(@"[DOUY] 替换帧校验未通过，回退原帧（第 %d 次）", FXVideoReplaceFailures);
            CFRelease(replacement);
            replacement = NULL;
        }
    }

    [target captureOutput:output
        didOutputSampleBuffer:(replacement ?: sampleBuffer)
               fromConnection:connection];
    if (replacement)
    {
        CFRelease(replacement);
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    id target = self.original;
    if ([target respondsToSelector:_cmd])
    {
        [target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)selector
{
    if ([super respondsToSelector:selector])
    {
        return YES;
    }
    return [self.original respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector
{
    id target = self.original;
    if ([target respondsToSelector:selector])
    {
        return target;
    }
    return nil;
}

@end

@implementation FXAudioDelegateProxy

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
    id<AVCaptureAudioDataOutputSampleBufferDelegate> target = self.original;
    if (target == nil)
    {
        return;
    }

    CMSampleBufferRef replacement = NULL;
    if (!FXSafeModeEnabled() && FXAudioReplaceFailures < 5)
    {
        @try
        {
            replacement = FXMakeReplacementAudioSample(sampleBuffer);
        }
        @catch (NSException *exception)
        {
            __sync_add_and_fetch(&FXAudioReplaceFailures, 1);
            NSLog(@"[DOUY] 音频替换抛异常，回退原帧: %@", exception);
            replacement = NULL;
        }

        if (replacement != NULL && !FXAudioSampleLooksValid(replacement))
        {
            __sync_add_and_fetch(&FXAudioReplaceFailures, 1);
            CFRelease(replacement);
            replacement = NULL;
        }
    }

    [target captureOutput:output
        didOutputSampleBuffer:(replacement ?: sampleBuffer)
               fromConnection:connection];
    if (replacement)
    {
        CFRelease(replacement);
    }
}

- (BOOL)respondsToSelector:(SEL)selector
{
    if ([super respondsToSelector:selector])
    {
        return YES;
    }
    return [self.original respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector
{
    id target = self.original;
    if ([target respondsToSelector:selector])
    {
        return target;
    }
    return nil;
}

@end

// ---------------------------------------------------------------- swizzling

static void FXSwizzle(Class cls, SEL originalSelector, SEL replacementSelector)
{
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original != NULL && replacement != NULL)
    {
        method_exchangeImplementations(original, replacement);
    }
}

@implementation AVCaptureVideoDataOutput (DOUY)

- (void)douy_douy_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                                        queue:(dispatch_queue_t)sampleBufferCallbackQueue
{
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = sampleBufferDelegate;
    if (target != nil && ![target isKindOfClass:[FXVideoDelegateProxy class]])
    {
        FXVideoDelegateProxy *proxy = [[FXVideoDelegateProxy alloc] init];
        proxy.original = target;
        objc_setAssociatedObject(self, &kFXVideoProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        target = (id<AVCaptureVideoDataOutputSampleBufferDelegate>)proxy;
    }

    [self douy_douy_setSampleBufferDelegate:target queue:sampleBufferCallbackQueue];
}

- (id<AVCaptureVideoDataOutputSampleBufferDelegate>)douy_douy_sampleBufferDelegate
{
    id delegate = [self douy_douy_sampleBufferDelegate];
    if ([delegate isKindOfClass:[FXVideoDelegateProxy class]])
    {
        return ((FXVideoDelegateProxy *)delegate).original;
    }
    return delegate;
}

@end

@implementation AVCaptureAudioDataOutput (DOUY)

- (void)douy_douy_audio_setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate
                                              queue:(dispatch_queue_t)sampleBufferCallbackQueue
{
    id<AVCaptureAudioDataOutputSampleBufferDelegate> target = sampleBufferDelegate;
    if (target != nil && ![target isKindOfClass:[FXAudioDelegateProxy class]])
    {
        FXAudioDelegateProxy *proxy = [[FXAudioDelegateProxy alloc] init];
        proxy.original = target;
        objc_setAssociatedObject(self, &kFXAudioProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        target = (id<AVCaptureAudioDataOutputSampleBufferDelegate>)proxy;
    }

    [self douy_douy_audio_setSampleBufferDelegate:target queue:sampleBufferCallbackQueue];
}

- (id<AVCaptureAudioDataOutputSampleBufferDelegate>)douy_douy_audio_sampleBufferDelegate
{
    id delegate = [self douy_douy_audio_sampleBufferDelegate];
    if ([delegate isKindOfClass:[FXAudioDelegateProxy class]])
    {
        return ((FXAudioDelegateProxy *)delegate).original;
    }
    return delegate;
}

@end

void FXInstallHooks(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FXSwizzle([AVCaptureVideoDataOutput class],
                  @selector(setSampleBufferDelegate:queue:),
                  @selector(douy_douy_setSampleBufferDelegate:queue:));
        FXSwizzle([AVCaptureVideoDataOutput class],
                  @selector(sampleBufferDelegate),
                  @selector(douy_douy_sampleBufferDelegate));

        FXSwizzle([AVCaptureAudioDataOutput class],
                  @selector(setSampleBufferDelegate:queue:),
                  @selector(douy_douy_audio_setSampleBufferDelegate:queue:));
        FXSwizzle([AVCaptureAudioDataOutput class],
                  @selector(sampleBufferDelegate),
                  @selector(douy_douy_audio_sampleBufferDelegate));
    });
}
