//
//  FXAudioInject.mm —— 音频注入（第 2 步：只观察，不改音频）
//
//  现状：挂钩 AudioOutputUnitStart，拿到抖音创建的 RemoteIO unit，
//        读出它当前的麦克风回调和数据格式，全部记录到浮窗，不做任何修改。
//
//  下一步（确认拿到 unit 之后）才会换回调、写静音、再混入 OBS 音频。
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
static volatile int gHookStubs = 0;
static volatile int gHookPatched = 0;
static NSString *gInjectNote = nil;

typedef OSStatus (*FXStartFn)(AudioUnit);
static FXStartFn gOrigStart = NULL;

/// 读一段 AudioUnit 属性到内存，成功返回 YES
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
    AudioComponentDescription desc = {0};
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

    // 输入总线（bus 1）上的回调与格式——这是麦克风数据真正的来源
    AURenderCallbackStruct cb = {0};
    if (FXReadProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 1,
                       &cb, sizeof(cb)))
    {
        gLastCallback = (uintptr_t)cb.inputProc;
        gLastCallbackCtx = (uintptr_t)cb.inputProcRefCon;
        gLastScope = (uint32_t)kAudioUnitScope_Input;
        gLastElement = 1;
    }

    AudioStreamBasicDescription asbd = {0};
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

/// 我们的 AudioOutputUnitStart：记录后原样转发
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

/// 抖音的 GOT 槽是惰性绑定：App 第一次调用前槽里还不是真实地址，
/// 所以要在启动后持续重试，直到改写到桩为止。
void FXAudioInjectRetry(void)
{
    if (gHookPatched > 0 || gOrigStart == NULL)
    {
        return;
    }

    FXStubHookResult r = FXStubHookInstall("AudioOutputUnitStart", (void *)FXStartHook, NO);
    if (r.stubsPatched > 0)
    {
        gHookStubs = r.stubsMatched;
        gHookPatched = r.stubsPatched;
        gInjectNote = [NSString stringWithFormat:@"镜像 %d / 桩 %d / 命中 %d / 已改写 %d",
                       r.imagesScanned, r.stubsTotal, r.stubsMatched, r.stubsPatched];
        NSLog(@"[DOUY] 音频注入桩(重试成功): 命中 %d 已改写 %d", r.stubsMatched, r.stubsPatched);
    }
    else if (r.stubsMatched > 0 || r.stubsTotal > 0)
    {
        gInjectNote = [NSString stringWithFormat:@"镜像 %d / 桩 %d / 命中 0 / 已改写 0（等待绑定）",
                       r.imagesScanned, r.stubsTotal];
    }
}

void FXAudioInjectInstall(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *real = dlsym(RTLD_DEFAULT, "AudioOutputUnitStart");
        if (real == NULL)
        {
            gInjectNote = @"找不到 AudioOutputUnitStart 符号";
            return;
        }
        gOrigStart = (FXStartFn)real;

        FXStubHookResult r = FXStubHookInstall("AudioOutputUnitStart", (void *)FXStartHook, NO);
        gHookStubs = r.stubsMatched;
        gHookPatched = r.stubsPatched;

        NSLog(@"[DOUY] 音频注入桩: 扫描镜像 %d 个, 桩 %d 个, 命中 %d 个, 已改写 %d 个",
              r.imagesScanned, r.stubsTotal, r.stubsMatched, r.stubsPatched);

        gInjectNote = [NSString stringWithFormat:@"镜像 %d / 桩 %d / 命中 %d / 已改写 %d",
                       r.imagesScanned, r.stubsTotal, r.stubsMatched, r.stubsPatched];

        // 惰性绑定：每 2 秒重试一次，最多 40 次（约 80 秒）
        dispatch_queue_t q = dispatch_queue_create("douy.inject.retry", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC),
                                  2ull * NSEC_PER_SEC, NSEC_PER_SEC);
        __block int tries = 0;
        dispatch_source_set_event_handler(timer, ^{
            tries++;
            FXAudioInjectRetry();
            if (tries >= 40 || gHookPatched > 0)
            {
                dispatch_source_cancel(timer);
            }
        });
        dispatch_resume(timer);
    });
}

NSString *FXAudioInjectReport(void)
{
    NSMutableString *t = [NSMutableString string];
    [t appendString:@"=== 音频注入诊断（只观察）===\n"];
    [t appendFormat:@"挂钩: %@\n", gInjectNote ?: @"未安装"];

    [t appendFormat:@"Start 调用: %d 次\n", gStartCalls];
    [t appendFormat:@"RemoteIO 命中: %d 次（其它 unit %d 个）\n", gRemoteIOHits, gOtherUnits];

    if (gLastUnit != 0)
    {
        [t appendFormat:@"最近 unit: 0x%lx\n", (unsigned long)gLastUnit];
    }
    if (gLastCallback != 0)
    {
        [t appendFormat:@"麦克风回调: 0x%lx  ctx=0x%lx  scope=%u elem=%u\n",
         (unsigned long)gLastCallback, (unsigned long)gLastCallbackCtx, gLastScope, gLastElement];
    }
    else if (gRemoteIOHits > 0)
    {
        [t appendString:@"麦克风回调: 未安装（App 可能用 InputCallback 拉模式）\n"];
    }

    if (gLastFmtID != 0)
    {
        [t appendFormat:@"麦克风格式: fmt=%u flags=0x%x ch=%u bits=%u rate=%u\n",
         gLastFmtID, gLastFmtFlags, gLastFmtChannels, gLastFmtBits, gLastFmtRate];
    }

    FXMediaStore *store = [FXMediaStore shared];
    [t appendFormat:@"OBS 音频缓存: %lu 字节\n", (unsigned long)[store audioBufferedBytes]];
    [t appendString:@"\n—— 结论 ——\n"];
    if (gStartCalls == 0)
    {
        [t appendString:@"还没有捕捉到音频启动\n开播后（或抖音播放视频时）再点一次\n"];
    }
    else if (gRemoteIOHits == 0)
    {
        [t appendString:@"捕捉到启动，但没有 RemoteIO\n看 unit/描述是否正确\n"];
    }
    else if (gLastCallback != 0)
    {
        [t appendString:@"已拿到麦克风回调 → 下一步可以换回调注入\n"];
    }
    else
    {
        [t appendString:@"是 RemoteIO 但没读到回调 → 走 InputCallback/Render 路线\n"];
    }
    return t;
}
