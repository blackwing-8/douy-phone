//
//  FXAudioInject.mm —— 音频注入（观察阶段，全部由用户手动触发）
//
//  ⚠️ 上一版在 dylib 加载时就扫描并改桩，出错 = 启动即崩。
//     这一版绝不自动执行：只有在浮窗点「音频注入诊断」时才跑，
//     第一次点只统计（dryRun），第二次点才真正改写。
//

#import "FXCommon.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>

static volatile int gStartCalls = 0;
static volatile int gRemoteIOHits = 0;
static volatile int gOtherUnits = 0;
static volatile uintptr_t gLastUnit = 0;
static volatile uintptr_t gLastCallback = 0;
static volatile uintptr_t gLastCallbackCtx = 0;
static volatile uint32_t gLastScope = 0;
static volatile uint32_t gLastElement = 0;
static volatile uint32_t gLastFmtID = 0;
static volatile uint32_t gLastFmtChannels = 0;
static volatile uint32_t gLastFmtBits = 0;
static volatile uint32_t gLastFmtRate = 0;
static volatile uint32_t gLastFmtFlags = 0;
static volatile int gPatched = 0;
static volatile int gScanCount = 0;
static NSString *gScanNote = nil;

typedef OSStatus (*FXStartFn)(AudioUnit);
static FXStartFn gOrigStart = NULL;

static BOOL FXReadProperty(AudioUnit unit, AudioUnitPropertyID prop, AudioUnitScope scope,
                           AudioUnitElement elem, void *out, UInt32 outSize)
{
    UInt32 size = outSize;
    OSStatus st = AudioUnitGetProperty(unit, prop, scope, elem, out, &size);
    return st == noErr && size <= outSize;
}

static void FXRecordUnit(AudioUnit unit)
{
    if (unit == NULL)
    {
        return;
    }
    gLastUnit = (uintptr_t)unit;

    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    BOOL isRemoteIO = NO;

    if (comp != NULL && AudioComponentGetDescription(comp, &desc) == noErr)
    {
        isRemoteIO = (desc.componentType == kAudioUnitType_Output &&
                      desc.componentSubType == kAudioUnitSubType_RemoteIO);
    }

    if (!isRemoteIO)
    {
        __sync_add_and_fetch(&gOtherUnits, 1);
        return;
    }

    __sync_add_and_fetch(&gRemoteIOHits, 1);

    AURenderCallbackStruct cb;
    memset(&cb, 0, sizeof(cb));
    if (FXReadProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 1,
                       &cb, sizeof(cb)))
    {
        gLastCallback = (uintptr_t)cb.inputProc;
        gLastCallbackCtx = (uintptr_t)cb.inputProcRefCon;
        gLastScope = (uint32_t)kAudioUnitScope_Input;
        gLastElement = 1;
    }

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    if (FXReadProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                       &asbd, sizeof(asbd)))
    {
        gLastFmtID = (uint32_t)asbd.mFormatID;
        gLastFmtFlags = (uint32_t)asbd.mFormatFlags;
        gLastFmtChannels = (uint32_t)asbd.mChannelsPerFrame;
        gLastFmtBits = (uint32_t)asbd.mBitsPerChannel;
        gLastFmtRate = (uint32_t)asbd.mSampleRate;
    }
}

static OSStatus FXStartHook(AudioUnit unit)
{
    __sync_add_and_fetch(&gStartCalls, 1);
    FXRecordUnit(unit);
    if (gOrigStart != NULL)
    {
        return gOrigStart(unit);
    }
    return noErr;
}

/// apply=NO 只统计；apply=YES 才改桩
void FXAudioInjectScan(BOOL apply)
{
    __sync_add_and_fetch(&gScanCount, 1);

    if (gOrigStart == NULL)
    {
        gOrigStart = (FXStartFn)dlsym(RTLD_DEFAULT, "AudioOutputUnitStart");
    }
    if (gOrigStart == NULL)
    {
        gScanNote = @"找不到 AudioOutputUnitStart";
        return;
    }

    FXStubHookResult r = FXStubHookInstall("AudioOutputUnitStart", (void *)FXStartHook, !apply);
    gPatched = r.stubsPatched;

    NSMutableString *n = [NSMutableString string];
    [n appendFormat:@"%@ · 镜像 %d / 桩 %d / 命中 %d / 改写 %d",
     apply ? @"已尝试改写" : @"仅统计", r.imagesScanned, r.stubsTotal, r.stubsMatched, r.stubsPatched];
    if (r.note.length > 0)
    {
        [n appendFormat:@" · %@", r.note];
    }
    gScanNote = n;

    NSLog(@"[DOUY] 音频注入扫描 %@", n);
}

NSString *FXAudioInjectReport(void)
{
    NSMutableString *t = [NSMutableString string];
    [t appendString:@"=== 音频注入诊断 ===\n"];
    [t appendFormat:@"扫描: %@\n", gScanNote ?: @"还没扫描过"];
    [t appendFormat:@"Start 调用: %d 次\n", gStartCalls];
    [t appendFormat:@"RemoteIO 命中: %d（其它 unit %d）\n", gRemoteIOHits, gOtherUnits];

    if (gLastUnit != 0)
    {
        [t appendFormat:@"unit: 0x%lx\n", (unsigned long)gLastUnit];
    }
    if (gLastCallback != 0)
    {
        [t appendFormat:@"麦克风回调: 0x%lx ctx=0x%lx scope=%u elem=%u\n",
         (unsigned long)gLastCallback, (unsigned long)gLastCallbackCtx, gLastScope, gLastElement];
    }
    else if (gRemoteIOHits > 0)
    {
        [t appendString:@"麦克风回调: 未读到（可能是 InputCallback 拉模式）\n"];
    }
    if (gLastFmtID != 0)
    {
        [t appendFormat:@"麦克风格式: fmt=%u flags=0x%x ch=%u bits=%u rate=%u\n",
         gLastFmtID, gLastFmtFlags, gLastFmtChannels, gLastFmtBits, gLastFmtRate];
    }

    FXMediaStore *store = [FXMediaStore shared];
    [t appendFormat:@"OBS 音频缓存: %lu 字节\n", (unsigned long)[store audioBufferedBytes]];
    [t appendFormat:@"%@\n", FXAudioStatsReport()];

    [t appendString:@"—— 下一步 ——\n"];
    if (gScanCount <= 1 && gPatched == 0)
    {
        [t appendString:@"再点一次按钮才会真正改写桩\n"];
    }
    else if (gPatched > 0 && gStartCalls == 0)
    {
        [t appendString:@"桩已改写，等抖音启动音频后就会看到 Start 调用\n"];
    }
    else if (gStartCalls > 0 && gRemoteIOHits > 0)
    {
        [t appendString:@"已拿到 RemoteIO → 可以进入下一步（换回调注入）\n"];
    }
    else if (gPatched == 0)
    {
        [t appendString:@"还没命中：抖音可能还没绑定该符号，开播后再点\n"];
    }
    return t;
}
