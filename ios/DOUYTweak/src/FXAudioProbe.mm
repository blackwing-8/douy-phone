//
//  FXAudioProbe.mm —— 音频路径探针（只记录，不修改任何音频行为）
//
//  目的：确认抖音到底用哪条音频采集路径。
//    路径 A：AVAudioEngine + installTapOnBus  → 可以 swizzle block，改动小
//    路径 B：直接用 AudioUnit（AURemoteIO）   → 需要拦 C 函数，改动大
//
//  为什么必须先测：上次凭猜测改线程模型，直接让抖音 0x8BADF00D 崩了。
//
//  读数方式：浮窗 →「音频诊断」按钮，弹窗里显示统计。
//

#import "FXCommon.h"
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include <string.h>
#include <libkern/OSCacheControl.h>

static volatile int gCaptureHookCalls = 0;   // AVCaptureAudioDataOutput 钩子被调用次数
static volatile int gEngineStarts = 0;       // AVAudioEngine startAndReturnError
static volatile int gInputNodeCalls = 0;     // AVAudioEngine inputNode 取用
static volatile int gInstallTapCalls = 0;    // AVAudioInputNode installTapOnBus
static volatile int gSetCategoryCalls = 0;   // AVAudioSession setCategory
static volatile int gSetActiveCalls = 0;     // AVAudioSession setActive

// AudioUnit（路径 B）观察量
static volatile int gAuSetPropertyCalls = 0;
static volatile int gAuRenderCallbackSets = 0;
static volatile int gAuInputCallbackSets = 0;
static volatile int gAuEnableIOSets = 0;
static volatile int gAuHookInstalled = 0;

// 手机侧音频解码链路（回答"音频到底到没到 / 解没解出来"）
static volatile int gUsbAudioFrames = 0;
static volatile int64_t gUsbAudioBytes = 0;
static volatile int gAdtsAttempts = 0;
static volatile int gConverterFails = 0;
static volatile int64_t gPcmBytes = 0;

static NSString *gCategoryText = nil;
static NSString *gTapFormatText = nil;
static NSString *gHostASBDText = nil;
static NSString *gLastTapBus = nil;
static NSString *gAuPropertyText = nil;
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

void FXAudioProbeNoteCaptureHook(void)
{
    __sync_add_and_fetch(&gCaptureHookCalls, 1);
}

void FXAudioProbeNoteHostASBD(NSString *text)
{
    if (text.length == 0)
    {
        return;
    }
    FXProbeLock(^{ gHostASBDText = [text copy]; });
}

void FXAudioProbeNoteUsbAudioFrame(NSUInteger length)
{
    __sync_add_and_fetch(&gUsbAudioFrames, 1);
    __sync_add_and_fetch(&gUsbAudioBytes, (int64_t)length);
}

void FXAudioProbeNoteAdtsAttempt(void)
{
    __sync_add_and_fetch(&gAdtsAttempts, 1);
}

void FXAudioProbeNoteConverterFail(void)
{
    __sync_add_and_fetch(&gConverterFails, 1);
}

void FXAudioProbeNotePcmBytes(NSUInteger length)
{
    __sync_add_and_fetch(&gPcmBytes, (int64_t)length);
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

// ---------------------------------------------------------------- ARM64 内联钩子
//
// 为什么不用 fishhook：抖音是 chained fixups 二进制，鱼钩找不到 __la_symbol_ptr，
// 大概率钩不上。内联钩子直接改目标函数入口，与调用方的链接方式无关。
//
// 兜底原则：任何一步不符合预期就放弃安装，只打日志，绝不半途 patch。

typedef OSStatus (*FXAudioUnitSetPropertyFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                             AudioUnitElement, const void *, UInt32);

static FXAudioUnitSetPropertyFn gOriginalSetProperty = NULL;
static void *gSetPropertyTarget = NULL;

static void FXMakeWritable(void *addr, size_t size, bool *ok)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    size_t len = ((vm_address_t)addr + size) - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, len, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *ok = (kr == KERN_SUCCESS);
}

static void FXMakeExecutable(void *addr, size_t size)
{
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(vm_page_size - 1);
    size_t len = ((vm_address_t)addr + size) - page;
    vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate(addr, size);
}


/// 判断一条 ARM64 指令是否依赖自身地址（PC 相对）。
/// 这类指令搬到跳板里会算出错误地址，必须拒绝安装钩子。
static bool FXInstructionIsPCRelative(uint32_t insn)
{
    if ((insn & 0x1F000000) == 0x10000000) return true;   // ADR / ADRP
    if ((insn & 0x7C000000) == 0x14000000) return true;   // B / BL
    if ((insn & 0xFF000010) == 0x54000000) return true;   // B.cond
    if ((insn & 0x7E000000) == 0x34000000) return true;   // CBZ / CBNZ
    if ((insn & 0x3B000000) == 0x18000000) return true;   // LDR (literal)
    if ((insn & 0x7E000000) == 0x36000000) return true;   // TBZ / TBNZ
    return false;
}

/// 把 target 的前 16 字节改成跳转到 replacement，并把原指令搬到一段可执行内存里。
static void *FXInstallInlineHook(void *target, void *replacement)
{
    if (target == NULL || replacement == NULL)
    {
        return NULL;
    }

    const size_t patchSize = 16;                       // ldr + br + 8 字节地址

    // 安全检查：前 16 字节里只要有 PC 相对指令就放弃，避免把错误指令搬进跳板
    const uint32_t *prologue = (const uint32_t *)target;
    for (int i = 0; i < 4; i++)
    {
        if (FXInstructionIsPCRelative(prologue[i]))
        {
            NSLog(@"[DOUY-probe] 目标函数开头含 PC 相对指令(第 %d 条)，放弃内联钩子", i + 1);
            return NULL;
        }
    }
    uint8_t *trampoline = (uint8_t *)mmap(NULL, vm_page_size,
                                          PROT_READ | PROT_WRITE,
                                          MAP_ANON | MAP_PRIVATE, -1, 0);
    if (trampoline == MAP_FAILED || trampoline == NULL)
    {
        NSLog(@"[DOUY-probe] 分配跳板内存失败");
        return NULL;
    }

    memcpy(trampoline, target, patchSize);

    // 跳板尾部：跳回 target + 16
    uint32_t ldr = 0x58000050;   // ldr x16, #8
    uint32_t br  = 0xD61F0200;   // br  x16
    uint64_t back = (uint64_t)((uint8_t *)target + patchSize);
    memcpy(trampoline + patchSize, &ldr, 4);
    memcpy(trampoline + patchSize + 4, &br, 4);
    memcpy(trampoline + patchSize + 8, &back, 8);

    mprotect(trampoline, vm_page_size, PROT_READ | PROT_EXEC);
    sys_icache_invalidate(trampoline, vm_page_size);

    bool ok = false;
    FXMakeWritable(target, patchSize, &ok);
    if (!ok)
    {
        NSLog(@"[DOUY-probe] 目标页不可写，放弃内联钩子");
        munmap(trampoline, vm_page_size);
        return NULL;
    }

    uint8_t patch[patchSize];
    memcpy(patch, &ldr, 4);
    memcpy(patch + 4, &br, 4);
    uint64_t rep = (uint64_t)replacement;
    memcpy(patch + 8, &rep, 8);
    memcpy(target, patch, patchSize);

    FXMakeExecutable(target, patchSize);
    return trampoline;
}

static void FXAudioProbeInstallAudioUnitHook(void)
{
    if (gAuHookInstalled)
    {
        return;
    }

    void *target = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    if (target == NULL)
    {
        NSLog(@"[DOUY-probe] 找不到 AudioUnitSetProperty 符号");
        return;
    }

    extern OSStatus FXProbeAudioUnitSetProperty(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                                AudioUnitElement, const void *, UInt32);

    void *trampoline = FXInstallInlineHook(target, (void *)FXProbeAudioUnitSetProperty);
    if (trampoline == NULL)
    {
        return;
    }

    gOriginalSetProperty = (FXAudioUnitSetPropertyFn)trampoline;
    gSetPropertyTarget = target;
    gAuHookInstalled = 1;
    NSLog(@"[DOUY-probe] AudioUnitSetProperty 内联钩子已安装");
}

/// 真实调用：记录后原样转发（不修改任何参数）
OSStatus FXProbeAudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property,
                                     AudioUnitScope scope, AudioUnitElement element,
                                     const void *data, UInt32 size)
{
    __sync_add_and_fetch(&gAuSetPropertyCalls, 1);

    switch (property)
    {
        case kAudioUnitProperty_SetRenderCallback:
            __sync_add_and_fetch(&gAuRenderCallbackSets, 1);
            break;
        case kAudioOutputUnitProperty_SetInputCallback:
            __sync_add_and_fetch(&gAuInputCallbackSets, 1);
            break;
        case kAudioOutputUnitProperty_EnableIO:
            __sync_add_and_fetch(&gAuEnableIOSets, 1);
            break;
        default:
            break;
    }

    FXProbeLock(^{
        NSString *extra = @"";
        if (property == kAudioUnitProperty_SetRenderCallback && data != NULL &&
            size >= sizeof(AURenderCallbackStruct))
        {
            const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)data;
            extra = [NSString stringWithFormat:@" cb=%p ctx=%p", cb->inputProc, cb->inputProcRefCon];
        }
        else if (property == kAudioUnitProperty_StreamFormat && data != NULL &&
                 size >= sizeof(AudioStreamBasicDescription))
        {
            const AudioStreamBasicDescription *asbd = (const AudioStreamBasicDescription *)data;
            extra = [NSString stringWithFormat:@" fmt=%u flags=0x%x ch=%u bits=%u rate=%.0f",
                     (unsigned)asbd->mFormatID, (unsigned)asbd->mFormatFlags,
                     (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mBitsPerChannel,
                     asbd->mSampleRate];
        }

        gAuPropertyText = [NSString stringWithFormat:@"prop=%u scope=%u elem=%u size=%u%@",
                           (unsigned)property, (unsigned)scope, (unsigned)element, (unsigned)size, extra];
    });

    if (gOriginalSetProperty != NULL)
    {
        return gOriginalSetProperty(unit, property, scope, element, data, size);
    }
    return noErr;
}

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

        FXAudioProbeInstallAudioUnitHook();

        NSLog(@"[DOUY-probe] 音频探针已安装");
    });
}

NSString *FXAudioProbeReport(void)
{
    NSMutableString *text = [NSMutableString string];

    [text appendString:@"=== 音频路径诊断 v2 ===\n"];

    [text appendFormat:@"AVCaptureAudioDataOutput 钩子: %d 次\n", gCaptureHookCalls];
    [text appendFormat:@"AVAudioEngine 启动: %d 次 / inputNode: %d 次 / installTap: %d 次\n",
     gEngineStarts, gInputNodeCalls, gInstallTapCalls];

    FXProbeLock(^{
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
    [text appendFormat:@"AudioSession setActive: %d 次\n\n", gSetActiveCalls];

    [text appendString:@"—— AudioUnit（路径 B）——\n"];
    [text appendFormat:@"钩子安装: %@\n", gAuHookInstalled ? @"成功" : @"失败"];
    [text appendFormat:@"SetProperty 调用: %d 次\n", gAuSetPropertyCalls];
    [text appendFormat:@"  SetRenderCallback: %d 次\n", gAuRenderCallbackSets];
    [text appendFormat:@"  SetInputCallback : %d 次\n", gAuInputCallbackSets];
    [text appendFormat:@"  EnableIO         : %d 次\n", gAuEnableIOSets];
    FXProbeLock(^{
        if (gAuPropertyText.length > 0)
        {
            [text appendFormat:@"  最近一次: %@\n", gAuPropertyText];
        }
    });
    [text appendString:@"\n"];

    [text appendString:@"—— 手机音频解码——\n"];
    [text appendFormat:@"USB 音频帧: %d 个 / %lld 字节\n", gUsbAudioFrames, gUsbAudioBytes];
    if (gAdtsAttempts > 0 && gPcmBytes == 0)
    {
        [text appendFormat:@"ADTS 解码尝试 %d 次，但一帧 PCM 都没解出来\n（AudioConverter 初始化失败，问题在手机解码而不是传输）\n",
         gAdtsAttempts];
    }
    else
    {
        [text appendFormat:@"ADTS 解码尝试 %d 次 · 累计 PCM %lld 字节\n", gAdtsAttempts, gPcmBytes];
    }

    FXMediaStore *store = [FXMediaStore shared];
    [text appendFormat:@"当前缓冲: %lu 字节 · 替换开关:%@\n",
     (unsigned long)[store audioBufferedBytes], store.audioReplaceEnabled ? @"开" : @"关"];
    FXProbeLock(^{
        [text appendFormat:@"宿主麦克风格式: %@\n",
            gHostASBDText.length > 0 ? gHostASBDText : @"(从未经过替换入口)"];
    });
    [text appendString:@"\n"];

    [text appendString:@"—— 结论 ——\n"];
    if (gAuRenderCallbackSets > 0)
    {
        [text appendString:@"路径 B-1：抖音给输入 bus 设了 RenderCallback\n可以包住这个回调来注入音频。\n"];
    }
    else if (gAuInputCallbackSets > 0)
    {
        [text appendString:@"路径 B-2：抖音用 InputCallback + AudioUnitRender\n需要拦 AudioUnitRender 改写输出。\n"];
    }
    else if (gAuSetPropertyCalls > 0)
    {
        [text appendString:@"有 AudioUnit 活动，但没看到回调设置\n把上面「最近一次」发我，我再判断。\n"];
    }
    else if (gAuHookInstalled)
    {
        [text appendString:@"钩子装上了但一次都没被调用\n音频可能在更早的时机初始化，需要调整安装时机。\n"];
    }
    else
    {
        [text appendString:@"AudioUnit 钩子没装上，音频路径仍未知。\n"];
    }

    return text;
}
