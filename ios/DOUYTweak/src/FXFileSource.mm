#import "FXCommon.h"

@interface FXFileSource ()
- (void)runLoop2;
@end

@implementation FXFileSource
{
    NSURL *_url;
    NSThread *_thread;
    volatile BOOL _running;
}

+ (instancetype)shared
{
    static FXFileSource *source = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = [[FXFileSource alloc] init];
    });
    return source;
}

- (NSURL *)currentURL
{
    return _url;
}

- (BOOL)openURL:(NSURL *)url error:(NSError **)error
{
    if (url == nil)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"DOUY"
                                         code:1
                                     userInfo:@{ NSLocalizedDescriptionKey : @"未选择视频文件" }];
        }
        return NO;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0)
    {
        if (error)
        {
            *error = [NSError errorWithDomain:@"DOUY"
                                         code:2
                                     userInfo:@{ NSLocalizedDescriptionKey : @"视频无法解码，请选择 MP4 / MOV" }];
        }
        return NO;
    }

    _url = [url copy];
    return YES;
}

- (void)start
{
    if (_running || _url == nil)
    {
        return;
    }

    _running = YES;
    [[FXMediaStore shared] setMode:FXSourceModeLocalFile];
    [[FXMediaStore shared] setStatus:@"本地视频 · 循环播放"];

    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(runLoop2) object:nil];
    _thread.name = @"fx-file-source";
    _thread.qualityOfService = NSQualityOfServiceUtility;
    [_thread start];
}

- (void)stop
{
    _running = NO;
    [[FXMediaStore shared] invalidateVideo];
    [[FXMediaStore shared] resetAudio];
}

- (void)runLoop2
{
    while (_running)
    {
        @autoreleasepool
        {
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:_url options:nil];
            NSError *error = nil;
            AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
            if (reader == nil)
            {
                [[FXMediaStore shared] setStatus:@"本地视频读取失败"];
                return;
            }

            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            if (videoTrack == nil)
            {
                [[FXMediaStore shared] setStatus:@"视频无法解码，请选择 MP4 / MOV"];
                return;
            }

            NSDictionary *videoSettings = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
            };
            AVAssetReaderTrackOutput *videoOutput =
                [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:videoSettings];
            videoOutput.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:videoOutput])
            {
                [reader addOutput:videoOutput];
            }

            AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            AVAssetReaderTrackOutput *audioOutput = nil;
            if (audioTrack != nil)
            {
                NSDictionary *audioSettings = @{
                    AVFormatIDKey : @(kAudioFormatLinearPCM),
                    AVLinearPCMBitDepthKey : @16,
                    AVLinearPCMIsFloatKey : @NO,
                    AVLinearPCMIsBigEndianKey : @NO,
                    AVLinearPCMIsNonInterleaved : @NO,
                    AVSampleRateKey : @48000,
                    AVNumberOfChannelsKey : @2,
                };
                audioOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:audioSettings];
                audioOutput.alwaysCopiesSampleData = NO;
                if ([reader canAddOutput:audioOutput])
                {
                    [reader addOutput:audioOutput];
                }
            }

            if (![reader startReading])
            {
                [[FXMediaStore shared] setStatus:@"本地视频无法开始读取"];
                return;
            }

            double startTime = -1;
            double startWall = 0;
            [[FXMediaStore shared] resetAudio];

            while (_running && reader.status == AVAssetReaderStatusReading)
            {
                @autoreleasepool
                {
                    CMSampleBufferRef videoSample = [videoOutput copyNextSampleBuffer];
                    if (videoSample != NULL)
                    {
                        CMTime pts = CMSampleBufferGetPresentationTimeStamp(videoSample);
                        double seconds = CMTimeGetSeconds(pts);
                        if (startTime < 0)
                        {
                            startTime = seconds;
                            startWall = CFAbsoluteTimeGetCurrent();
                        }
                        else
                        {
                            double due = startWall + (seconds - startTime);
                            double wait = due - CFAbsoluteTimeGetCurrent();
                            if (wait > 0.002 && wait < 1.0)
                            {
                                [NSThread sleepForTimeInterval:wait];
                            }
                        }

                        CVImageBufferRef image = CMSampleBufferGetImageBuffer(videoSample);
                        if (image != NULL)
                        {
                            [[FXMediaStore shared] setVideoBuffer:image ptsMs:(int64_t)(seconds * 1000.0)];
                        }
                        CFRelease(videoSample);
                    }
                    else if (reader.status != AVAssetReaderStatusReading)
                    {
                        break;
                    }

                    if (audioOutput != nil)
                    {
                        CMSampleBufferRef audioSample = [audioOutput copyNextSampleBuffer];
                        if (audioSample != NULL)
                        {
                            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(audioSample);
                            if (block != NULL)
                            {
                                size_t totalLength = CMBlockBufferGetDataLength(block);
                                if (totalLength > 0)
                                {
                                    NSMutableData *pcm = [NSMutableData dataWithLength:totalLength];
                                    if (CMBlockBufferCopyDataBytes(block, 0, totalLength, pcm.mutableBytes) == kCMBlockBufferNoErr)
                                    {
                                        [[FXMediaStore shared] appendAudio:pcm ptsMs:0];
                                    }
                                }
                            }
                            CFRelease(audioSample);
                        }
                    }
                }
            }

            [reader cancelReading];
            [[FXMediaStore shared] resetAudio];
        }

        if (_running)
        {
            [NSThread sleepForTimeInterval:0.05]; // 循环播放
        }
    }
}

@end
