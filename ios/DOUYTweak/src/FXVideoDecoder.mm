#import "FXCommon.h"
#import <VideoToolbox/VideoToolbox.h>

/// Annex-B → AVCC（VideoToolbox 需要 4 字节长度前缀的 NALU 序列）
static NSData *FXAnnexBToAVCC(NSData *annexB)
{
    const uint8_t *bytes = (const uint8_t *)annexB.bytes;
    const NSUInteger length = annexB.length;
    NSMutableData *output = [NSMutableData dataWithCapacity:length + 16];

    NSUInteger index = 0;
    NSUInteger nalStart = NSNotFound;

    while (index + 2 < length)
    {
        NSUInteger startCodeLength = 0;
        if (bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1)
        {
            startCodeLength = 3;
        }
        else if (index + 3 < length && bytes[index] == 0 && bytes[index + 1] == 0 &&
                 bytes[index + 2] == 0 && bytes[index + 3] == 1)
        {
            startCodeLength = 4;
        }

        if (startCodeLength > 0)
        {
            if (nalStart != NSNotFound && index > nalStart)
            {
                uint32_t nalLength = (uint32_t)(index - nalStart);
                uint8_t header[4] = {
                    (uint8_t)((nalLength >> 24) & 0xFF), (uint8_t)((nalLength >> 16) & 0xFF),
                    (uint8_t)((nalLength >> 8) & 0xFF), (uint8_t)(nalLength & 0xFF),
                };
                [output appendBytes:header length:4];
                [output appendBytes:bytes + nalStart length:nalLength];
            }
            index += startCodeLength;
            nalStart = index;
            continue;
        }

        index++;
    }

    if (nalStart != NSNotFound && length > nalStart)
    {
        uint32_t nalLength = (uint32_t)(length - nalStart);
        uint8_t header[4] = {
            (uint8_t)((nalLength >> 24) & 0xFF), (uint8_t)((nalLength >> 16) & 0xFF),
            (uint8_t)((nalLength >> 8) & 0xFF), (uint8_t)(nalLength & 0xFF),
        };
        [output appendBytes:header length:4];
        [output appendBytes:bytes + nalStart length:nalLength];
    }

    return output;
}

@interface FXVideoDecoder ()
- (void)noteDecodedBuffer:(CVImageBufferRef)buffer;
@end

static void FXDecodeCallback(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTimeStamp,
                             CMTime presentationDuration)
{
    if (status != noErr || imageBuffer == NULL)
    {
        return;
    }

    FXVideoDecoder *decoder = (__bridge FXVideoDecoder *)decompressionOutputRefCon;
    if (decoder == nil)
    {
        return;
    }

    int64_t ptsMs = (int64_t)llround(CMTimeGetSeconds(presentationTimeStamp) * 1000.0);
    [[FXMediaStore shared] setVideoBuffer:imageBuffer ptsMs:ptsMs];
    [decoder noteDecodedBuffer:imageBuffer];
}

@implementation FXVideoDecoder
{
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _format;
    int _consecutiveErrors;
    int _lastWidth;
    int _lastHeight;
}

- (void)dealloc
{
    [self reset];
}

- (int)lastWidth
{
    return _lastWidth;
}

- (int)lastHeight
{
    return _lastHeight;
}

- (void)noteDecodedBuffer:(CVImageBufferRef)buffer
{
    int width = (int)CVPixelBufferGetWidth(buffer);
    int height = (int)CVPixelBufferGetHeight(buffer);
    if (width > 0 && height > 0 && (width != _lastWidth || height != _lastHeight))
    {
        _lastWidth = width;
        _lastHeight = height;
        [[FXMediaStore shared] setVideoMeta:@{ @"width": @(width), @"height": @(height) }];
    }
}

- (void)reset
{
    if (_session)
    {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }

    if (_format)
    {
        CFRelease(_format);
        _format = NULL;
    }

    _consecutiveErrors = 0;
}

- (BOOL)configureWithAVCConfig:(NSData *)avcConfig
{
    if (avcConfig.length < 8)
    {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)avcConfig.bytes;
    NSUInteger index = 5;
    NSUInteger spsCount = (NSUInteger)(bytes[index++] & 0x1F);
    NSData *sps = nil;
    NSData *pps = nil;

    for (NSUInteger i = 0; i < spsCount; i++)
    {
        if (index + 2 > avcConfig.length)
        {
            return NO;
        }
        NSUInteger size = (NSUInteger)(((uint32_t)bytes[index] << 8) | bytes[index + 1]);
        index += 2;
        if (index + size > avcConfig.length)
        {
            return NO;
        }
        if (sps == nil && size > 0)
        {
            sps = [avcConfig subdataWithRange:NSMakeRange(index, size)];
        }
        index += size;
    }

    if (index >= avcConfig.length)
    {
        return NO;
    }

    NSUInteger ppsCount = (NSUInteger)bytes[index++];
    for (NSUInteger i = 0; i < ppsCount; i++)
    {
        if (index + 2 > avcConfig.length)
        {
            return NO;
        }
        NSUInteger size = (NSUInteger)(((uint32_t)bytes[index] << 8) | bytes[index + 1]);
        index += 2;
        if (index + size > avcConfig.length)
        {
            return NO;
        }
        if (pps == nil && size > 0)
        {
            pps = [avcConfig subdataWithRange:NSMakeRange(index, size)];
        }
        index += size;
    }

    if (sps == nil || pps == nil)
    {
        return NO;
    }

    return [self configureWithSPS:sps pps:pps];
}

- (BOOL)configureWithSPS:(NSData *)sps pps:(NSData *)pps
{
    if (sps.length == 0 || pps.length == 0)
    {
        return NO;
    }

    [self reset];

    const uint8_t *parameterSets[2] = { (const uint8_t *)sps.bytes, (const uint8_t *)pps.bytes };
    const size_t sizes[2] = { sps.length, pps.length };

    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         2,
                                                                         parameterSets,
                                                                         sizes,
                                                                         4,
                                                                         &_format);
    if (status != noErr || _format == NULL)
    {
        return NO;
    }

    NSDictionary *extensions = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };

    VTDecompressionOutputCallbackRecord callback = { FXDecodeCallback, (__bridge void *)self };
    status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                          _format,
                                          NULL,
                                          (__bridge CFDictionaryRef)extensions,
                                          &callback,
                                          &_session);
    if (status != noErr || _session == NULL)
    {
        return NO;
    }

    VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    self.needsKeyframe = YES;
    return YES;
}

- (void)decodeAnnexB:(NSData *)annexB ptsMs:(int64_t)ptsMs keyframe:(BOOL)keyframe
{
    if (_session == NULL || _format == NULL || annexB.length == 0)
    {
        return;
    }

    if (self.needsKeyframe && !keyframe)
    {
        return;
    }

    NSData *avcc = FXAnnexBToAVCC(annexB);
    if (avcc.length < 5)
    {
        return;
    }

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         NULL,
                                                         avcc.length,
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         avcc.length,
                                                         kCMBlockBufferAssureMemoryNowFlag,
                                                         &block);
    if (status != noErr || block == NULL)
    {
        return;
    }

    status = CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);
    if (status != noErr)
    {
        CFRelease(block);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake(ptsMs, 1000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t sampleSize = avcc.length;
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreate(kCFAllocatorDefault,
                                  block,
                                  true,
                                  NULL,
                                  NULL,
                                  _format,
                                  1,
                                  1,
                                  &timing,
                                  1,
                                  &sampleSize,
                                  &sample);
    CFRelease(block);

    if (status != noErr || sample == NULL)
    {
        return;
    }

    VTDecodeInfoFlags infoFlags = 0;
    status = VTDecompressionSessionDecodeFrame(_session, sample, 0, NULL, &infoFlags);
    CFRelease(sample);

    if (status != noErr)
    {
        _consecutiveErrors++;
        if (_consecutiveErrors >= 30)
        {
            _consecutiveErrors = 0;
            self.needsKeyframe = YES;
        }
    }
    else
    {
        _consecutiveErrors = 0;
        if (keyframe)
        {
            self.needsKeyframe = NO;
        }
    }
}

@end
