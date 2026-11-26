//
//  FXAudioInject.mm —— 音频注入（钩 AudioUnitRender，在宿主取麦的那一刻覆盖样本）
//
//  为什么是 AudioUnitRender：
//    抖音的麦克风走 AURemoteIO，它通过 AudioUnitRender(bus=1) 把麦克风数据拉进自己的
//    AudioBufferList。AudioOutputUnitStart 只是启动，抓不到数据（实测 0 次命中）。
//
//  安全性：
//    · 通过数据槽改写（不改代码页，不撤 EXEC），原函数地址取自槽里原本的值
//    · 钩子里不加锁、不分配内存，只从无锁环里 memcpy
//    · 只有「音频替换」开着、且缓冲看起来是 48k/2ch/int16 时才写入
//    · 任何异常都不改宿主数据，原样返回
//

#import "FXCommon.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>

static volatile int gRenderCalls = 0;
static volatile int gRenderBus1 = 0;
static volatile int gInjectFrames = 0;
static volatile int gInjectAttempts = 0;
static volatile int gPatched = 0;
static volatile int gScanCount = 0;
static NSString *gScanNote = nil;

typedef OSStatus (*FXRenderFn)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                               UInt32, UInt32, AudioBufferList *);
static FXRenderFn gOrigRender = NULL;

/// 音频替换开关的 C 镜像（音频线程只读这个，避免 objc_msgSend）
static volatile int gReplaceMirror = 0;
void FXAudioInjectSetReplaceFlag(int on) { gReplaceMirror = on; }

static OSStatus FXRenderHook(AudioUnit unit, AudioUnitRenderActionFlags *ioActionFlags,
                             const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
                             UInt32 inNumberFrames, AudioBufferList *ioData)
{
    __sync_add_and_fetch(&gRenderCalls, 1);

    OSStatus status = noErr;
    if (gOrigRender != NULL)
    {
        status = gOrigRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }

    if (inBusNumber != 1)
    {
        return status;
    }
    __sync_add_and_fetch(&gRenderBus1, 1);

    if (status != noErr || ioData == NULL || ioData->mNumberBuffers != 1 || gReplaceMirror == 0)
    {
        return status;
    }

    AudioBuffer *buf = &ioData->mBuffers[0];
    if (buf->mData == NULL)
    {
        return status;
    }

    // 只处理 48k/2ch/int16：一帧 4 字节
    if (buf->mDataByteSize != inNumberFrames * 4)
    {
        return status;
    }

    __sync_add_and_fetch(&gInjectAttempts, 1);
    if (FXAudioRingRead((int16_t *)buf->mData, inNumberFrames) == inNumberFrames)
    {
        __sync_add_and_fetch(&gInjectFrames, (int)inNumberFrames);
    }
    return status;
}

void FXAudioInjectScan(BOOL apply)
{
    __sync_add_and_fetch(&gScanCount, 1);

    FXStubHookResult r = FXStubHookInstall("AudioUnitRender", (void *)FXRenderHook, !apply);
    gPatched = r.stubsPatched;
    if (r.original != NULL)
    {
        gOrigRender = (FXRenderFn)r.original;
    }

    NSMutableString *n = [NSMutableString string];
    [n appendFormat:@"%@ · 镜像 %d / 桩 %d / 命中 %d / 改写 %d",
     apply ? @"已改写" : @"仅统计", r.imagesScanned, r.stubsTotal, r.stubsMatched, r.stubsPatched];
    if (r.note.length > 0)
    {
        [n appendFormat:@" · %@", r.note];
    }
    gScanNote = n;
    NSLog(@"[DOUY] AudioUnitRender 注入扫描: %@", n);
}

NSString *FXAudioInjectReport(void)
{
    NSMutableString *t = [NSMutableString string];
    [t appendString:@"=== 音频注入诊断 ===\n"];
    [t appendFormat:@"扫描: %@\n", gScanNote ?: @"还没扫描过"];
    [t appendFormat:@"原函数: %s\n", gOrigRender ? "已取得" : "未取得"];
    [t appendFormat:@"Render 调用: %d（bus1 %d）\n", gRenderCalls, gRenderBus1];
    [t appendFormat:@"注入尝试: %d · 成功写入 %d 帧\n", gInjectAttempts, gInjectFrames];
    [t appendFormat:@"替换开关: %s · 环内可读 %u 帧\n",
     gReplaceMirror ? "开" : "关", FXAudioRingAvailable()];

    FXMediaStore *store = [FXMediaStore shared];
    [t appendFormat:@"OBS 音频缓存: %lu 字节\n", (unsigned long)[store audioBufferedBytes]];
    [t appendFormat:@"%@\n", FXAudioStatsReport()];

    [t appendString:@"—— 下一步 ——\n"];
    if (gPatched == 0 && gScanCount <= 1)
    {
        [t appendString:@"再点一次才会真正改写\n"];
    }
    else if (gRenderBus1 == 0)
    {
        [t appendString:@"还没看到宿主拉麦（bus1）→ 开播后音频线程才会跑\n"];
    }
    else if (gInjectFrames == 0)
    {
        [t appendString:@"已在拉麦但没写入：看替换开关和环内帧数\n"];
    }
    else
    {
        [t appendString:@"已把 OBS 音频写进宿主麦克风缓冲\n"];
    }
    return t;
}
