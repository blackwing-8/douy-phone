//
//  FXAudioProbe.mm —— 音频路径探针（只记录，不修改任何音频行为）
//
//  目的：确认抖音到底用哪条音频采集路径。
//    路径 A：AVAudioEngine + installTapOnBus  → 可以 swizzle block，改动小
//    路径 B：直接用 AudioUnit（AURemoteIO）   → 需要 fishhook 拦 C 函数，改动大
//
//  为什么必须先测：上次凭猜测改线程模型，直接让抖音 0x8BADF00D 崩了。
//
//  读数方式：浮窗 →「音频诊断」按钮，弹窗里显示统计。
//

#import "FXCommon.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>

static volatile int gCaptureHookCalls = 0;   // AVCaptureAudioDataOutput 钩子被调用次数
static volatile int gEngineStarts = 0;       // AVAudioEngine startAndReturnError
static volatile int gInputNodeCalls = 0;     // AVAudioEngine inputNode 取用
static volatile int gInstallTapCalls = 0;    // AVAudioInputNode installTapOnBus
static volatile int gSetCategoryCalls = 0;   // AVAudioSession setCategory
static volatile int gSetActiveCalls = 0;     // AVAudioSession setActive

static NSString *gCategoryText = nil;
static NSString *gTapFormatText = nil;
static NSString *gHostASBDText = nil;
static NSString *gLastTapBus = nil;
static NSLock *gProbeLock = nil;

static void FXProbeLock(dispatch_block_t block)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gProbeLock = [[NSLock alloc] init];
    });
    [gProbeLock lock];
    block();
    [gProbeLock unlock];
}

/// AVCaptureAudioDataOutput 的 delegate 钩子命中（0 表示抖音根本不用这个采集口）
void FXAudioProbeNoteCaptureHook(void)
{
    __sync_add_and_fetch(&gCaptureHookCalls, 1);
}

/// 宿主麦克风的实际格式（如果能走到我们的替换入口才有值）
void FXAudioProbeNoteHostASBD(NSString *text)
{
    if (text.length == 0)
    {
        return;
    }
    FXProbeLock(^{ gHostASBDText = [text copy]; });
}

static NSString *FXDescribeFormat(AVAudioFormat *format)
{
    if (format == nil)
    {
        return @"(nil)";
    }

    NSString *common = @"其它";
    switch (format.commonFormat)
    {
        case AVAudioPCMFormatFloat32: common = @"float32"; break;
        case AVAudioPCMFormatFloat64: common = @"float64"; break;
        case AVAudioPCMFormatInt16:   common = @"int16";   break;
        case AVAudioPCMFormatInt32:   common = @"int32";   break;
        default: break;
    }

    return [NSString stringWithFormat:@"%.0fHz %uch %@ interleaved=%d",
            format.sampleRate, (unsigned)format.channelCount, common, format.isInterleaved ? 1 : 0];
}

static void FXProbeSwizzle(Class cls, SEL original, SEL replacement)
{
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a != NULL && b != NULL)
    {
        method_exchangeImplementations(a, b);
    }
    else
    {
        NSLog(@"[DOUY-probe] 无法挂钩 %@ -> %@", NSStringFromClass(cls), NSStringFromSelector(original));
    }
}

// ---------------------------------------------------------------- AVAudioEngine

@implementation AVAudioEngine (DOUYProbe)

- (BOOL)douy_probe_startAndReturnError:(NSError **)error
{
    __sync_add_and_fetch(&gEngineStarts, 1);
    return [self douy_probe_startAndReturnError:error];
}

- (AVAudioInputNode *)douy_probe_inputNode
{
    __sync_add_and_fetch(&gInputNodeCalls, 1);
    return [self douy_probe_inputNode];
}

@end

// ---------------------------------------------------------------- AVAudioNode（tap）

@implementation AVAudioNode (DOUYProbe)

- (void)douy_probe_installTapOnBus:(AVAudioNodeBus)bus
                        bufferSize:(AVAudioFrameCount)bufferSize
                            format:(AVAudioFormat *)format
                            block:(AVAudioNodeTapBlock)tapBlock
{
    __sync_add_and_fetch(&gInstallTapCalls, 1);
    FXProbeLock(^{
        gLastTapBus = [NSString stringWithFormat:@"bus=%u buffer=%u", (unsigned)bus, (unsigned)bufferSize];
        gTapFormatText = [FXDescribeFormat(format) copy];
    });
    [self douy_probe_installTapOnBus:bus bufferSize:bufferSize format:format block:tapBlock];
}

@end

// ---------------------------------------------------------------- AVAudioSession

@implementation AVAudioSession (DOUYProbe)

- (BOOL)douy_probe_setCategory:(AVAudioSessionCategory)category
                          mode:(AVAudioSessionMode)mode
                       options:(AVAudioSessionCategoryOptions)options
                         error:(NSError **)outError
{
    __sync_add_and_fetch(&gSetCategoryCalls, 1);
    FXProbeLock(^{
        gCategoryText = [NSString stringWithFormat:@"%@ / %@ / options=0x%lx",
                         category, mode, (unsigned long)options];
    });
    return [self douy_probe_setCategory:category mode:mode options:options error:outError];
}

- (BOOL)douy_probe_setActive:(BOOL)active error:(NSError **)outError
{
    __sync_add_and_fetch(&gSetActiveCalls, 1);
    return [self douy_probe_setActive:active error:outError];
}

@end

// ---------------------------------------------------------------- 安装与报告

void FXAudioProbeInstall(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class engine = NSClassFromString(@"AVAudioEngine");
        Class node = NSClassFromString(@"AVAudioNode");
        Class session = NSClassFromString(@"AVAudioSession");

        if (engine != Nil)
        {
            FXProbeSwizzle(engine, @selector(startAndReturnError:), @selector(douy_probe_startAndReturnError:));
            FXProbeSwizzle(engine, @selector(inputNode), @selector(douy_probe_inputNode));
        }

        if (node != Nil)
        {
            FXProbeSwizzle(node,
                           @selector(installTapOnBus:bufferSize:format:block:),
                           @selector(douy_probe_installTapOnBus:bufferSize:format:block:));
        }

        if (session != Nil)
        {
            FXProbeSwizzle(session,
                           @selector(setCategory:mode:options:error:),
                           @selector(douy_probe_setCategory:mode:options:error:));
            FXProbeSwizzle(session, @selector(setActive:error:), @selector(douy_probe_setActive:error:));
        }

        NSLog(@"[DOUY-probe] 音频探针已安装");
    });
}

NSString *FXAudioProbeReport(void)
{
    NSMutableString *text = [NSMutableString string];

    [text appendString:@"=== 音频路径诊断 ===\n"];

    [text appendFormat:@"AVCaptureAudioDataOutput 钩子: %d 次\n", gCaptureHookCalls];
    if (gCaptureHookCalls == 0)
    {
        [text appendString:@"  → 抖音不用这个采集口（旧音频替换方案必然无效）\n"];
    }
    [text appendString:@"\n"];

    [text appendFormat:@"AVAudioEngine 启动: %d 次\n", gEngineStarts];
    [text appendFormat:@"inputNode 取用: %d 次\n", gInputNodeCalls];
    [text appendFormat:@"installTapOnBus: %d 次\n", gInstallTapCalls];

    FXProbeLock(^{
        if (gLastTapBus.length > 0)
        {
            [text appendFormat:@"  最近一次: %@\n", gLastTapBus];
        }
        if (gTapFormatText.length > 0)
        {
            [text appendFormat:@"  tap 格式: %@\n", gTapFormatText];
        }
    });
    [text appendString:@"\n"];

    [text appendFormat:@"AudioSession setCategory: %d 次\n", gSetCategoryCalls];
    FXProbeLock(^{
        if (gCategoryText.length > 0)
        {
            [text appendFormat:@"  %@\n", gCategoryText];
        }
    });
    [text appendFormat:@"AudioSession setActive: %d 次\n", gSetActiveCalls];
    [text appendString:@"\n"];

    FXMediaStore *store = [FXMediaStore shared];
    [text appendFormat:@"音频替换开关: %@\n", store.audioReplaceEnabled ? @"开" : @"关"];
    [text appendFormat:@"已解码的 OBS 音频缓存: %lu 字节\n", (unsigned long)[store audioBufferedBytes]];
    FXProbeLock(^{
        [text appendFormat:@"宿主麦克风格式: %@\n",
            gHostASBDText.length > 0 ? gHostASBDText : @"(从未经过替换入口)"];
    });
    [text appendString:@"\n"];

    [text appendString:@"—— 结论 ——\n"];
    if (gInstallTapCalls > 0)
    {
        [text appendString:@"路径 A：抖音用 AVAudioEngine + tap\n可以替换 tap 的 block 来注入音频。\n"];
    }
    else if (gEngineStarts > 0 || gInputNodeCalls > 0)
    {
        [text appendString:@"路径 B 疑似：有 AVAudioEngine 但没有 tap\n大概率直接用 AudioUnit，需要 fishhook 拦 AudioUnitRender/SetProperty。\n"];
    }
    else
    {
        [text appendString:@"两条路都没看到\n可能音频完全走 AudioUnit（AURemoteIO），需要 fishhook 探 AudioUnitSetProperty。\n"];
    }

    return text;
}
