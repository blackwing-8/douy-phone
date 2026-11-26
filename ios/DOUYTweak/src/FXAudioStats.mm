//
//  FXAudioStats.mm —— 音频链路计数器（纯计数，无副作用）
//
//  目的：把「音频从哪一步断掉」变成可读数字，替代反复猜测。
//  只在现有「音频注入诊断」弹窗里展示，不改任何音频行为。
//

#import "FXCommon.h"

static volatile int gCfgCalls = 0;        // 收到 AAC 配置次数
static volatile int gCfgOK = 0;           // 配置成功次数
static volatile int gRtmpAudioFrames = 0; // RTMP 收到的音频帧
static volatile int gUsbAudioFrames = 0;  // USB 收到的音频帧
static volatile int64_t gRtmpAudioBytes = 0;
static volatile int gDecodeCalls = 0;     // 进入解码次数
static volatile int gDecodeOK = 0;        // 解码出样本次数
static volatile int64_t gPcmBytes = 0;    // 累计 PCM 字节
static volatile int32_t gLastStatus = 0;  // 最近一次 OSStatus
static volatile int32_t gLastConfigStatus = 0;

void FXStatsConfigCall(void) { __sync_add_and_fetch(&gCfgCalls, 1); }
void FXStatsConfigResult(BOOL ok, int32_t status)
{
    if (ok) __sync_add_and_fetch(&gCfgOK, 1);
    gLastConfigStatus = status;
}
void FXStatsRtmpAudio(NSUInteger len)
{
    __sync_add_and_fetch(&gRtmpAudioFrames, 1);
    __sync_add_and_fetch(&gRtmpAudioBytes, (int64_t)len);
}
void FXStatsUsbAudio(NSUInteger len)
{
    __sync_add_and_fetch(&gUsbAudioFrames, 1);
}
void FXStatsDecodeResult(BOOL ok, int32_t status, NSUInteger pcmLen)
{
    __sync_add_and_fetch(&gDecodeCalls, 1);
    if (ok)
    {
        __sync_add_and_fetch(&gDecodeOK, 1);
        __sync_add_and_fetch(&gPcmBytes, (int64_t)pcmLen);
    }
    gLastStatus = status;
}

NSString *FXAudioStatsReport(void)
{
    NSMutableString *t = [NSMutableString string];
    [t appendString:@"—— 音频链路计数 ——\n"];
    [t appendFormat:@"AAC 配置: 收到 %d 次 / 成功 %d 次 (status=%d)\n",
     gCfgCalls, gCfgOK, gLastConfigStatus];
    [t appendFormat:@"RTMP 音频帧: %d 个 / %lld 字节\n", gRtmpAudioFrames, gRtmpAudioBytes];
    [t appendFormat:@"USB 音频帧: %d 个\n", gUsbAudioFrames];
    [t appendFormat:@"解码: 调用 %d / 成功 %d (status=%d)\n", gDecodeCalls, gDecodeOK, gLastStatus];
    [t appendFormat:@"累计 PCM: %lld 字节\n", gPcmBytes];
    return t;
}
