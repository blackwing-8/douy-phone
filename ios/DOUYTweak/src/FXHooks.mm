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

/// 按**指定像素格式**建 buffer（必须与摄像头原始帧一致，否则宿主编码器会崩）
static CVPixelBufferRef FXCreateBufferWithFormat(size_t width, size_t height, OSType format)
{
    if (width == 0 || height == 0)
    {
        return NULL;
    }
    if (format == 0)
    {
        format = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }

    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                          (__bridge CFDictionaryRef)attributes, &buffer);
    return status == kCVReturnSuccess ? buffer : NULL;
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

/// 把目标像素 (x,y) 反算回源像素坐标（含旋转/镜像），全部整数运算。
static inline void FXMapPixel(size_t x, size_t y, size_t outW, size_t outH,
                              size_t srcW, size_t srcH, NSInteger rotation, BOOL mirror,
                              size_t *outX, size_t *outY)
{
    // 归一化坐标（像素中心）
    double u = ((double)x + 0.5) / (double)outW;
    double v = ((double)y + 0.5) / (double)outH;

    // 逆旋转
    switch (((rotation % 360) + 360) % 360)
    {
        case 90:  { double t = u; u = v;     v = 1.0 - t; break; }
        case 180: { u = 1.0 - u; v = 1.0 - v; break; }
        case 270: { double t = u; u = 1.0 - v; v = t;     break; }
        default:  break;
    }

    if (mirror)
    {
        u = 1.0 - u;
    }

    if (u < 0.0) u = 0.0;
    if (u > 1.0) u = 1.0;
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;

    size_t sx = (size_t)(u * (double)(srcW - 1));
    size_t sy = (size_t)(v * (double)(srcH - 1));
    *outX = sx;
    *outY = sy;
}

/*
 * 缩放 + 旋转 + 镜像。
 *
 * 性能要点：映射在四个旋转角下都是**可分离的**（sx 只依赖 x 或 y，sy 只依赖另一个），
 * 所以每帧只算 dstW + dstH 次，内层循环是纯整数查表。
 * 之前每像素一次浮点除法 + 分支，1080p@60 会把采集线程拖到主线程超时（看门狗杀进程）。
 */
static void FXConvertPlane(const uint8_t *src, size_t srcStride, size_t srcW, size_t srcH,
                           uint8_t *dst, size_t dstStride, size_t dstW, size_t dstH,
                           size_t bytesPerPixel, NSInteger rotation, BOOL mirror)
{
    if (srcW == 0 || srcH == 0 || dstW == 0 || dstH == 0)
    {
        return;
    }

    int rot = (int)(((rotation % 360) + 360) % 360);

    // px[i]：第 i 列映射到的源列；py[j]：第 j 行映射到的源行
    size_t *px = (size_t *)malloc(sizeof(size_t) * dstW);
    size_t *py = (size_t *)malloc(sizeof(size_t) * dstH);
    if (px == NULL || py == NULL)
    {
        free(px);
        free(py);
        return;
    }

    for (size_t x = 0; x < dstW; x++)
    {
        double u = ((double)x + 0.5) / (double)dstW;
        double su = u;
        if (rot == 90)
        {
            su = 1.0 - u;          // r=90 时源 X 来自 (1-u)
        }
        else if (rot == 180)
        {
            su = 1.0 - u;
        }
        else if (rot == 270)
        {
            su = u;
        }
        if (mirror)
        {
            su = 1.0 - su;
        }
        if (su < 0.0) su = 0.0;
        if (su > 1.0) su = 1.0;
        px[x] = (size_t)(su * (double)(srcW - 1));
    }

    for (size_t y = 0; y < dstH; y++)
    {
        double v = ((double)y + 0.5) / (double)dstH;
        double sv = v;
        if (rot == 90)
        {
            sv = v;
        }
        else if (rot == 180)
        {
            sv = 1.0 - v;
        }
        else if (rot == 270)
        {
            sv = 1.0 - v;
        }
        if (sv < 0.0) sv = 0.0;
        if (sv > 1.0) sv = 1.0;
        py[y] = (size_t)(sv * (double)(srcH - 1));
    }

    // 90/270 时行列表互换
    BOOL swap = (rot == 90 || rot == 270);

    for (size_t y = 0; y < dstH; y++)
    {
        const uint8_t *srcRow = swap ? (src + px[y] * srcStride) : (src + py[y] * srcStride);
        uint8_t *dstRow = dst + y * dstStride;

        if (bytesPerPixel == 1)
        {
            for (size_t x = 0; x < dstW; x++)
            {
                dstRow[x] = srcRow[swap ? py[x] : px[x]];
            }
        }
        else if (bytesPerPixel == 2)
        {
            uint16_t *d = (uint16_t *)dstRow;
            const uint16_t *s = (const uint16_t *)srcRow;
            for (size_t x = 0; x < dstW; x++)
            {
                d[x] = s[swap ? py[x] : px[x]];
            }
        }
        else
        {
            uint32_t *d = (uint32_t *)dstRow;
            const uint32_t *s = (const uint32_t *)srcRow;
            for (size_t x = 0; x < dstW; x++)
            {
                d[x] = s[swap ? py[x] : px[x]];
            }
        }
    }

    free(px);
    free(py);
}

/*
 * 旋转 / 镜像 / 缩放到目标尺寸。
 *
 * 注意：这里**故意不用 CoreImage**。CIContext 的同步渲染会和主线程的 CoreAnimation
 * 转场争图形栈的锁，抖音打开摄像头时会导致主线程阻塞 10 秒被看门狗杀掉（0x8BADF00D）。
 * 全部改成纯 CPU 最近邻采样，不碰任何 ObjC 图形对象。
 */
static CVPixelBufferRef FXTransformBuffer(CVPixelBufferRef source, size_t outWidth, size_t outHeight,
                                          OSType outFormat, NSInteger rotation, BOOL mirror)
{
    if (source == NULL || outWidth == 0 || outHeight == 0)
    {
        return NULL;
    }

    CVPixelBufferRef destination = FXCreateBufferWithFormat(outWidth, outHeight, outFormat);
    if (destination == NULL)
    {
        return NULL;
    }

    if (CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
    {
        CVPixelBufferRelease(destination);
        return NULL;
    }

    if (CVPixelBufferLockBaseAddress(destination, 0) != kCVReturnSuccess)
    {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(destination);
        return NULL;
    }

    BOOL ok = NO;
    size_t planeCount = CVPixelBufferGetPlaneCount(source);

    if (planeCount >= 2)
    {
        // NV12 / 420f / 420v：Y 平面 + 交错的 UV 平面
        const uint8_t *srcY = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, 0);
        uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(destination, 0);
        const uint8_t *srcUV = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, 1);
        uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(destination, 1);

        if (srcY && dstY && srcUV && dstUV)
        {
            size_t srcW = CVPixelBufferGetWidthOfPlane(source, 0);
            size_t srcH = CVPixelBufferGetHeightOfPlane(source, 0);
            size_t srcYStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0);
            size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0);

            FXConvertPlane(srcY, srcYStride, srcW, srcH,
                           dstY, dstYStride, outWidth, outHeight,
                           1, rotation, mirror);

            size_t srcUvW = CVPixelBufferGetWidthOfPlane(source, 1);
            size_t srcUvH = CVPixelBufferGetHeightOfPlane(source, 1);
            size_t srcUvStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1);
            size_t dstUvStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1);

            FXConvertPlane(srcUV, srcUvStride, srcUvW, srcUvH,
                           dstUV, dstUvStride, outWidth / 2, outHeight / 2,
                           2, rotation, mirror);
            ok = YES;
        }
    }
    else if (planeCount == 0)
    {
        // BGRA / 其它 packed 格式
        const uint8_t *srcP = (const uint8_t *)CVPixelBufferGetBaseAddress(source);
        uint8_t *dstP = (uint8_t *)CVPixelBufferGetBaseAddress(destination);
        if (srcP && dstP)
        {
            size_t bpp = outFormat == kCVPixelFormatType_32BGRA ? 4 : 4;
            FXConvertPlane(srcP, CVPixelBufferGetBytesPerRow(source),
                           CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                           dstP, CVPixelBufferGetBytesPerRow(destination),
                           outWidth, outHeight, bpp, rotation, mirror);
            ok = YES;
        }
    }

    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);

    if (!ok)
    {
        CVPixelBufferRelease(destination);
        return NULL;
    }

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

    // 关键：输出帧的像素格式必须和摄像头原始帧完全一致（420f/420v/BGRA 混用会让宿主编码器崩溃）
    OSType targetFormat = originalImage ? CVPixelBufferGetPixelFormatType(originalImage) : 0;
    OSType decodedFormat = CVPixelBufferGetPixelFormatType(decoded);
    if (targetFormat == 0)
    {
        targetFormat = decodedFormat;
    }

    NSInteger rotation = store.rotation;
    BOOL mirror = store.mirror;
    BOOL needsTransform = (rotation % 360) != 0 || mirror || decodedWidth != targetWidth ||
                          decodedHeight != targetHeight || decodedFormat != targetFormat;

    CVPixelBufferRef finalBuffer = NULL;
    if (needsTransform)
    {
        finalBuffer = FXTransformBuffer(decoded, targetWidth, targetHeight, targetFormat, rotation, mirror);
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

    // 兜底：格式仍然不一致就放弃替换，让真实画面过去（宁可没效果，也不能让宿主崩）
    if (CVPixelBufferGetPixelFormatType(finalBuffer) != targetFormat)
    {
        NSLog(@"[DOUY] 替换帧格式不匹配（%u != %u），放弃替换",
              (unsigned)CVPixelBufferGetPixelFormatType(finalBuffer), (unsigned)targetFormat);
        CVPixelBufferRelease(finalBuffer);
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

/*
 * 就地改写摄像头自己的像素缓冲区。
 *
 * 为什么这样做（血泪教训）：
 *  1) 旧做法是新建一个 CMSampleBuffer 交给宿主 → 宿主按它自己的所有权规则 CFRelease，
 *     结果释放到非法对象，EXC_BREAKPOINT(SIGTRAP) 直接崩；
 *  2) 新建 buffer 还要对齐像素格式/尺寸/时间戳，任何一处不一致都会让宿主编码器崩或黑屏。
 * 改为「覆盖摄像头原始缓冲区、原样转发原始 sample buffer」后：
 *  不新建任何 CF 对象、不改时间戳、不动格式描述，宿主看到的永远是"它自己的帧"。
 *
 * 返回 YES 表示已经写入；NO 表示放弃替换（调用方仍然转发原帧）。
 */
static BOOL FXBlitIntoCameraBuffer(CMSampleBufferRef sampleBuffer)
{
    FXMediaStore *store = [FXMediaStore shared];
    if (![store isReplacingVideo])
    {
        return NO;
    }

    CVImageBufferRef camera = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (camera == NULL)
    {
        return NO;
    }

    int64_t sourcePts = 0;
    CVPixelBufferRef decoded = [store copyLatestVideoBufferWithPts:&sourcePts];
    if (decoded == NULL)
    {
        return NO;
    }

    BOOL done = NO;

    size_t camPlanes = CVPixelBufferGetPlaneCount(camera);
    size_t srcPlanes = CVPixelBufferGetPlaneCount(decoded);

    if (camPlanes >= 2 && srcPlanes >= 2)
    {
        // 摄像头与解码帧都是 NV12 家族（420f/420v 布局一致，只有色彩范围标记不同）
        if (CVPixelBufferLockBaseAddress(camera, 0) != kCVReturnSuccess)
        {
            CVPixelBufferRelease(decoded);
            return NO;
        }

        if (CVPixelBufferLockBaseAddress(decoded, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess)
        {
            const uint8_t *srcY = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(decoded, 0);
            const uint8_t *srcUV = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(decoded, 1);
            uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(camera, 0);
            uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(camera, 1);

            if (srcY && srcUV && dstY && dstUV)
            {
                size_t srcW = CVPixelBufferGetWidthOfPlane(decoded, 0);
                size_t srcH = CVPixelBufferGetHeightOfPlane(decoded, 0);
                size_t dstW = CVPixelBufferGetWidthOfPlane(camera, 0);
                size_t dstH = CVPixelBufferGetHeightOfPlane(camera, 0);

                NSInteger rotation = store.rotation;
                BOOL mirror = store.mirror;

                FXConvertPlane(srcY, CVPixelBufferGetBytesPerRowOfPlane(decoded, 0), srcW, srcH,
                               dstY, CVPixelBufferGetBytesPerRowOfPlane(camera, 0), dstW, dstH,
                               1, rotation, mirror);

                FXConvertPlane(srcUV, CVPixelBufferGetBytesPerRowOfPlane(decoded, 1),
                               CVPixelBufferGetWidthOfPlane(decoded, 1),
                               CVPixelBufferGetHeightOfPlane(decoded, 1),
                               dstUV, CVPixelBufferGetBytesPerRowOfPlane(camera, 1),
                               CVPixelBufferGetWidthOfPlane(camera, 1),
                               CVPixelBufferGetHeightOfPlane(camera, 1),
                               2, rotation, mirror);
                done = YES;
            }

            CVPixelBufferUnlockBaseAddress(decoded, kCVPixelBufferLock_ReadOnly);
        }

        CVPixelBufferUnlockBaseAddress(camera, 0);
    }

    CVPixelBufferRelease(decoded);
    return done;
}


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

    // 安全模式或连续失败 5 次后：完全不动画面，只转发原帧
    if (!FXSafeModeEnabled() && FXVideoReplaceFailures < 5)
    {
        @try
        {
            // 就地覆盖摄像头缓冲区；随后把**原始 sample buffer** 原样交给宿主，
            // 全程不新建/不释放任何 CMSampleBuffer 或 CVPixelBuffer。
            FXBlitIntoCameraBuffer(sampleBuffer);
        }
        @catch (NSException *exception)
        {
            __sync_add_and_fetch(&FXVideoReplaceFailures, 1);
            NSLog(@"[DOUY] 画面覆盖异常，本次跳过: %@", exception);
        }
    }

    [target captureOutput:output
        didOutputSampleBuffer:sampleBuffer
               fromConnection:connection];
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

    // 音频替换默认关闭：它同样是「新建 CMSampleBuffer 交给宿主」的模式，
    // 宿主的 CFRelease 所有权语义不同就会 SIGTRAP。需要时用 defaults 打开。
    BOOL audioReplaceEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"FXEnableAudioReplace"];

    if (audioReplaceEnabled && !FXSafeModeEnabled() && FXAudioReplaceFailures < 5)
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
