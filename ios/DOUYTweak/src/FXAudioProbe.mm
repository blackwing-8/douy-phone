//
//  FXAudioProbe.mm —— 音频路径探针 v3（__interpose 版）
//
//  为什么不内联钩子：上一次改写 AudioUnitSetProperty 的机器码，直接让抖音卡死。
//  内联钩子有三个致命点——指令撕裂、PC 相对跳转、并发 patch；任何一点出错都是崩溃。
//
//  __interpose 是 Mach-O 的原生机制：把替换函数写进 __DATA,__interpose 段，
//  由 dyld 在符号绑定时完成替换，不改任何指令，失败也只是"没生效"。
//
//  实时安全：热路径（AudioUnitRender）只做原子自增，不加锁、不分配、不打日志。
//

#import "FXCommon.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <dlfcn.h>

// ---------------- 计数（全部原子，热路径只碰这些） ----------------

static volatile int gCaptureHookCalls = 0;
static volatile int gEngineStarts = 0;
static volatile int gInstallTapCalls = 0;
static volatile int gSetCategoryCalls = 0;

static volatile int gAuSetPropertyCalls = 0;
static volatile int gAuRenderCalls = 0;
static volatile int gAuCreateCalls = 0;
static volatile int gAuRenderCallbackSets = 0;
static volatile int gAuInputCallbackSets = 0;
static volatile int gAuEnableIOSets = 0;
static volatile int gAuStreamFormatSets = 0;

// 最近一次 SetRenderCallback 的回调指针 / 上下文（原子保存，供报告读取）
static volatile uintptr_t gLastRenderCb = 0;
static volatile uintptr_t gLastRenderCtx = 0;
static volatile uint32_t gLastRenderScope = 0;
static volatile uint32_t gLastRenderElement = 0;

// 最近一次 AudioUnitRender 的 bus / 帧数
static volatile uint32_t gLastRenderBus = 0;
static volatile uint32_t gLastRenderFrames = 0;

// 最近一次 StreamFormat 的格式摘要（用整数打包，避免字符串）
static volatile uint32_t gLastFmtID = 0;
static volatile uint32_t gLastFmtChannels = 0;
static volatile uint32_t gLastFmtBits = 0;
static volatile uint32_t gLastFmtRate = 0;
static volatile uint32_t gLastFmtFlags = 0;

// 手机侧解码链路
static volatile int gUsbAudioFrames = 0;
static volatile int64_t gUsbAudioBytes = 0;
static volatile int gAdtsAttempts = 0;
static volatile int64_t gPcmBytes = 0;

// 字符串类信息（只在冷路径写，用弱锁保护）
static NSString *gCategoryText = nil;
static NSString *gTapFormatText = nil;
static NSString *gHostASBDText = nil;
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

void FXAudioProbeNoteCaptureHook(void) { __sync_add_and_fetch(&gCaptureHookCalls, 1); }

void FXAudioProbeNoteHostASBD(NSString *text)
{
    if (text.length == 0) return;
    FXProbeLock(^{ gHostASBDText = [text copy]; });
}

void FXAudioProbeNoteUsbAudioFrame(NSUInteger length)
{
    __sync_add_and_fetch(&gUsbAudioFrames, 1);
    __sync_add_and_fetch(&gUsbAudioBytes, (int64_t)length);
}

void FXAudioProbeNoteAdtsAttempt(void) { __sync_add_and_fetch(&gAdtsAttempts, 1); }
void FXAudioProbeNotePcmBytes(NSUInteger length) { __sync_add_and_fetch(&gPcmBytes, (int64_t)length); }

static NSString *FXDescribeFormat(AVAudioFormat *format)
{
    if (format == nil) return @"(nil)";

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
}

// ---------------------------------------------------------------- ObjC 侧（冷路径）

@implementation AVAudioEngine (DOUYProbe)
- (BOOL)douy_probe_startAndReturnError:(NSError **)error
{
    __sync_add_and_fetch(&gEngineStarts, 1);
    return [self douy_probe_startAndReturnError:error];
}
@end

@implementation AVAudioNode (DOUYProbe)
- (void)douy_probe_installTapOnBus:(AVAudioNodeBus)bus
                        bufferSize:(AVAudioFrameCount)bufferSize
                            format:(AVAudioFormat *)format
                            block:(AVAudioNodeTapBlock)tapBlock
{
    __sync_add_and_fetch(&gInstallTapCalls, 1);
    FXProbeLock(^{ gTapFormatText = [FXDescribeFormat(format) copy]; });
    [self douy_probe_installTapOnBus:bus bufferSize:bufferSize format:format block:tapBlock];
}
@end

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
@end

// ---------------------------------------------------------------- AudioUnit：__interpose
//
// 只记录，不修改任何参数；热路径（Render）只做原子自增。

static OSStatus (*gOrigSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                    AudioUnitElement, const void *, UInt32) = NULL;
static OSStatus (*gOrigRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                               UInt32, UInt32, AudioBufferList *) = NULL;
static OSStatus (*gOrigInstanceNew)(AudioComponent, AudioComponentInstance *) = NULL;

static OSStatus FXProbeAU_SetProperty(AudioUnit unit, AudioUnitPropertyID property,
                                      AudioUnitScope scope, AudioUnitElement element,
                                      const void *data, UInt32 size)
{
    __sync_add_and_fetch(&gAuSetPropertyCalls, 1);

    switch (property)
    {
        case kAudioUnitProperty_SetRenderCallback:
            __sync_add_and_fetch(&gAuRenderCallbackSets, 1);
            if (data != NULL && size >= sizeof(AURenderCallbackStruct))
            {
                const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)data;
                gLastRenderCb = (uintptr_t)cb->inputProc;
                gLastRenderCtx = (uintptr_t)cb->inputProcRefCon;
                gLastRenderScope = (uint32_t)scope;
                gLastRenderElement = (uint32_t)element;
            }
            break;

        case kAudioOutputUnitProperty_SetInputCallback:
            __sync_add_and_fetch(&gAuInputCallbackSets, 1);
            break;

        case kAudioOutputUnitProperty_EnableIO:
            __sync_add_and_fetch(&gAuEnableIOSets, 1);
            break;

        case kAudioUnitProperty_StreamFormat:
            __sync_add_and_fetch(&gAuStreamFormatSets, 1);
            if (data != NULL && size >= sizeof(AudioStreamBasicDescription))
            {
                const AudioStreamBasicDescription *asbd = (const AudioStreamBasicDescription *)data;
                gLastFmtID = (uint32_t)asbd->mFormatID;
                gLastFmtChannels = (uint32_t)asbd->mChannelsPerFrame;
                gLastFmtBits = (uint32_t)asbd->mBitsPerChannel;
                gLastFmtRate = (uint32_t)asbd->mSampleRate;
                gLastFmtFlags = (uint32_t)asbd->mFormatFlags;
            }
            break;

        default:
            break;
    }

    if (gOrigSetProperty != NULL)
    {
        return gOrigSetProperty(unit, property, scope, element, data, size);
    }

    // 解析失败：绝不能用 noErr 糊弄过去（上一版就是这样让音频静默失效的）
    return kAudioUnitErr_InvalidProperty;
}

static OSStatus FXProbeAU_Render(AudioUnit unit, AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp, UInt32 inOutputBusNumber,
                                 UInt32 inNumberFrames, AudioBufferList *ioData)
{
    __sync_add_and_fetch(&gAuRenderCalls, 1);
    gLastRenderBus = inOutputBusNumber;
    gLastRenderFrames = inNumberFrames;

    if (gOrigRender != NULL)
    {
        return gOrigRender(unit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    }
    return noErr;
}

static OSStatus FXProbeAU_InstanceNew(AudioComponent component, AudioComponentInstance *outInstance)
{
    __sync_add_and_fetch(&gAuCreateCalls, 1);
    if (gOrigInstanceNew != NULL)
    {
        return gOrigInstanceNew(component, outInstance);
    }
    return noErr;
}

// 把替换函数登记到 __DATA,__interpose，由 dyld 在绑定时替换
#define FX_INTERPOSE(replacement, replacee)                                    \
    __attribute__((used, section("__DATA,__interpose"))) static const struct {  \
        const void *replacement;                                                \
        const void *replacee;                                                   \
    } _fx_interpose_##replacee = {                                              \
        (const void *)(uintptr_t)&replacement,                                  \
        (const void *)(uintptr_t)&replacee                                      \
    }

FX_INTERPOSE(FXProbeAU_SetProperty, AudioUnitSetProperty);

// ---------------------------------------------------------------- 安装与报告

void FXAudioProbeInstall(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ⚠️ 必须用 RTLD_NEXT，不能用 RTLD_DEFAULT：
        //    interpose 已把该符号指向我们自己，RTLD_DEFAULT 会拿回本函数 → 无限递归。
        //    这是上一版把抖音音频搞瘫的直接原因。
        void *orig = dlsym(RTLD_NEXT, "AudioUnitSetProperty");

        // 兜底：显式从 AudioToolbox 镜像里取，并确认不是我们自己
        if (orig == NULL || orig == (void *)FXProbeAU_SetProperty)
        {
            void *handle = dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                                  RTLD_LAZY | RTLD_NOLOAD);
            if (handle != NULL)
            {
                void *candidate = dlsym(handle, "AudioUnitSetProperty");
                if (candidate != NULL && candidate != (void *)FXProbeAU_SetProperty)
                {
                    orig = candidate;
                }
                dlclose(handle);
            }
        }

        if (orig != NULL && orig != (void *)FXProbeAU_SetProperty)
        {
            gOrigSetProperty = (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                             AudioUnitElement, const void *, UInt32))orig;
        }
        else
        {
            gOrigSetProperty = NULL;
            NSLog(@"[DOUY-probe] 原函数解析失败，钩子将退化为直通（不做任何修改）");
        }

        Class engine = NSClassFromString(@"AVAudioEngine");
        Class node = NSClassFromString(@"AVAudioNode");
        Class session = NSClassFromString(@"AVAudioSession");

        if (engine != Nil)
        {
            FXProbeSwizzle(engine, @selector(startAndReturnError:), @selector(douy_probe_startAndReturnError:));
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
        }

        NSLog(@"[DOUY-probe] interpose 已登记 setProperty=%p render=%p new=%p",
              (void *)AudioUnitSetProperty, (void *)AudioUnitRender, (void *)AudioComponentInstanceNew);
    });
}

NSString *FXAudioProbeReport(void)
{
    NSMutableString *text = [NSMutableString string];

    [text appendString:@"=== 音频诊断 v3（interpose）===\n"];
    [text appendFormat:@"AVCaptureAudioDataOutput 钩子: %d 次\n", gCaptureHookCalls];
    [text appendFormat:@"AVAudioEngine: %d 次 / installTap: %d 次\n\n", gEngineStarts, gInstallTapCalls];

    [text appendString:@"—— AudioUnit ——\n"];
    [text appendFormat:@"钩子接上: %@\n", gOrigSetProperty != NULL ? @"是" : @"否（原函数未解析到）"];
    [text appendFormat:@"实例创建: %d 次\n", gAuCreateCalls];
    [text appendFormat:@"SetProperty: %d 次\n", gAuSetPropertyCalls];
    [text appendFormat:@"  RenderCallback: %d 次\n", gAuRenderCallbackSets];
    [text appendFormat:@"  InputCallback : %d 次\n", gAuInputCallbackSets];
    [text appendFormat:@"  EnableIO      : %d 次\n", gAuEnableIOSets];
    [text appendFormat:@"  StreamFormat  : %d 次\n", gAuStreamFormatSets];
    [text appendString:@"Render 未挂钩（本轮只观察 SetProperty，缩小爆炸半径）\n"];

    if (gLastRenderCb != 0)
    {
        [text appendFormat:@"  回调指针: 0x%lx  上下文: 0x%lx  scope=%u elem=%u\n",
         (unsigned long)gLastRenderCb, (unsigned long)gLastRenderCtx,
         gLastRenderScope, gLastRenderElement];
    }
    if (gLastFmtID != 0)
    {
        [text appendFormat:@"  最近格式: fmt=%u flags=0x%x ch=%u bits=%u rate=%u\n",
         gLastFmtID, gLastFmtFlags, gLastFmtChannels, gLastFmtBits, gLastFmtRate];
    }
    [text appendString:@"\n"];

    [text appendString:@"—— 手机音频解码 ——\n"];
    [text appendFormat:@"USB 音频帧: %d / %lld 字节\n", gUsbAudioFrames, gUsbAudioBytes];
    if (gAdtsAttempts > 0 && gPcmBytes == 0)
    {
        [text appendFormat:@"ADTS 尝试 %d 次，但 PCM 仍为 0（解码器没起来）\n", gAdtsAttempts];
    }
    else
    {
        [text appendFormat:@"ADTS 尝试 %d 次 · 累计 PCM %lld 字节\n", gAdtsAttempts, gPcmBytes];
    }

    FXMediaStore *store = [FXMediaStore shared];
    [text appendFormat:@"当前缓冲 %lu 字节 · 替换开关:%@\n",
     (unsigned long)[store audioBufferedBytes], store.audioReplaceEnabled ? @"开" : @"关"];
    FXProbeLock(^{
        [text appendFormat:@"宿主麦克风格式: %@\n", gHostASBDText.length > 0 ? gHostASBDText : @"(未经过替换入口)"];
    });
    [text appendString:@"\n"];

    [text appendString:@"—— 结论 ——\n"];
    if (gAuRenderCallbackSets > 0)
    {
        [text appendString:@"有 RenderCallback → 可以包这个回调注入（方案明确）\n"];
    }
    else if (gAuInputCallbackSets > 0)
    {
        [text appendString:@"有 InputCallback → 需要通过 Render 改写（方案明确，但更复杂）\n"];
    }
    else if (gAuSetPropertyCalls == 0 && gAuRenderCalls == 0)
    {
        [text appendString:@"interpose 未生效（音频可能在被拦截的镜像里，或走私有 API）\n"];
    }
    else
    {
        [text appendString:@"有 AudioUnit 活动但没看到回调设置，看上面的次数分布\n"];
    }

    return text;
}
