//
//  FXLanSource.mm —— 局域网取图（PC 端「兜鱼选图」提供 HTTP 服务）
//
//  为什么不用 NSURLSession：
//    高德自己的 Info.plist 有 ATS 策略，明文 http:// 会被拦（-1022）。
//    这里直接用 BSD socket 手写最小 HTTP 客户端，完全绕开 ATS。
//
//  协议（与 PC 端 PhotoServer 对应）：
//    GET /info   → {"version":N,"name":"...","size":N,"md5":"..."}
//    GET /photo  → 图片字节
//

#import "FXCommon.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <errno.h>

static NSString *gHost = nil;
static int gPort = 0;
static int gLastVersion = -1;
static dispatch_source_t gTimer = nil;
static volatile int gFailCount = 0;
static volatile int gFetchCount = 0;
static volatile int gApplyCount = 0;

static NSString *FXLastError = nil;

/// 发一个最简单的 HTTP GET，返回响应体（失败返回 nil）
static NSData *FXHttpGet(NSString *host, int port, const char *path, int timeoutSec)
{
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    char portStr[8];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo *res = NULL;
    if (getaddrinfo([host UTF8String], portStr, &hints, &res) != 0 || res == NULL)
    {
        FXLastError = @"域名解析失败";
        return nil;
    }

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0)
    {
        freeaddrinfo(res);
        FXLastError = @"创建 socket 失败";
        return nil;
    }

    struct timeval tv = { timeoutSec, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0)
    {
        close(fd);
        freeaddrinfo(res);
        FXLastError = @"连接电脑失败（检查 IP / 端口 / 防火墙）";
        return nil;
    }
    freeaddrinfo(res);

    char req[512];
    int n = snprintf(req, sizeof(req),
                     "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n",
                     path, [host UTF8String]);
    if (send(fd, req, (size_t)n, 0) != n)
    {
        close(fd);
        FXLastError = @"发送请求失败";
        return nil;
    }

    NSMutableData *raw = [NSMutableData data];
    uint8_t buf[16 * 1024];
    while (YES)
    {
        ssize_t got = recv(fd, buf, sizeof(buf), 0);
        if (got <= 0)
        {
            break;
        }
        [raw appendBytes:buf length:(NSUInteger)got];
        if (raw.length > 24 * 1024 * 1024)          // 单张图上限 24MB
        {
            break;
        }
    }
    close(fd);

    if (raw.length == 0)
    {
        FXLastError = @"没有收到数据";
        return nil;
    }

    // 找 header/body 分隔
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange r = [raw rangeOfData:sep options:0 range:NSMakeRange(0, raw.length)];
    if (r.location == NSNotFound)
    {
        FXLastError = @"响应格式异常";
        return nil;
    }

    NSData *head = [raw subdataWithRange:NSMakeRange(0, r.location)];
    NSString *headStr = [[NSString alloc] initWithData:head encoding:NSASCIIStringEncoding];
    if (![headStr containsString:@" 200 "])
    {
        FXLastError = ([headStr containsString:@"404"] ? @"电脑端还没有选图" : @"电脑返回错误");
        return nil;
    }

    return [raw subdataWithRange:NSMakeRange(r.location + r.length,
                                             raw.length - r.location - r.length)];
}

static void FXParseAndApply(NSString *baseHost, int port)
{
    NSData *info = FXHttpGet(baseHost, port, "/info", 3);
    if (info == nil)
    {
        __sync_add_and_fetch(&gFailCount, 1);
        return;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:info options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]])
    {
        FXLastError = @"/info 解析失败";
        return;
    }

    int version = [json[@"version"] intValue];
    if (version == gLastVersion)
    {
        return;                                  // 没变化，不重复下载
    }

    NSData *photo = FXHttpGet(baseHost, port, "/photo", 8);
    if (photo.length == 0)
    {
        return;
    }

    NSString *name = json[@"name"];
    if (name.length == 0)
    {
        name = @"电脑图片";
    }

    [[FXPhotoStore shared] setPhotoData:photo name:name source:FXPhotoSourceLAN];
    gLastVersion = version;
    [[FXPhotoStore shared] setStatus:[NSString stringWithFormat:
                                      @"已从电脑取图 %@ · %.0f KB",
                                      name, photo.length / 1024.0]];
    __sync_add_and_fetch(&gApplyCount, 1);
}

void FXLanStart(NSString *host, int port)
{
    FXLanStop();

    if (host.length == 0 || port <= 0)
    {
        return;
    }
    gHost = [host copy];
    gPort = port;
    gLastVersion = -1;
    gFailCount = 0;

    // 记住地址，下次打开 App 自动连
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    [def setObject:host forKey:@"fx.lan.host"];
    [def setInteger:port forKey:@"fx.lan.port"];
    [def synchronize];

    dispatch_queue_t q = dispatch_queue_create("douy.lan.photo", DISPATCH_QUEUE_SERIAL);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              2ull * NSEC_PER_SEC,
                              200ull * NSEC_PER_MSEC);

    dispatch_source_set_event_handler(gTimer, ^{
        __sync_add_and_fetch(&gFetchCount, 1);
        @autoreleasepool
        {
            FXParseAndApply(gHost, gPort);
        }
    });
    dispatch_resume(gTimer);

    [[FXPhotoStore shared] setStatus:[NSString stringWithFormat:@"局域网：%@@%d 每 2 秒同步", host, port]];
    NSLog(@"[原相机替换] 局域网取图启动 %@:%d", host, port);
}

void FXLanStop(void)
{
    if (gTimer != nil)
    {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
    gHost = nil;
    gPort = 0;
}

BOOL FXLanRunning(void)
{
    return gTimer != nil;
}

/// 上次用过的地址（形如 "192.168.1.5:28900"），没有返回 nil
NSString *FXLanSavedAddress(void)
{
    NSUserDefaults *def = [NSUserDefaults standardUserDefaults];
    NSString *host = [def stringForKey:@"fx.lan.host"];
    NSInteger port = [def integerForKey:@"fx.lan.port"];
    if (host.length == 0 || port <= 0)
    {
        return nil;
    }
    return [NSString stringWithFormat:@"%@:%ld", host, (long)port];
}

NSString *FXLanStatus(void)
{
    if (gTimer == nil)
    {
        return @"局域网：未启用";
    }
    return [NSString stringWithFormat:@"局域网 %@:%d · 拉取 %d 次 / 应用 %d 次 / 失败 %d 次%@",
            gHost, gPort, gFetchCount, gApplyCount, gFailCount,
            FXLastError.length > 0 ? [@" · " stringByAppendingString:FXLastError] : @""];
}
