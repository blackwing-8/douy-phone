#import "FXCommon.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <poll.h>
#import <errno.h>

static const uint32_t kFXMagic = 0x324D5944; // 'F''X''M''2'
static const int kFXHeaderSize = 28;
static const int kFXMaxPayload = 8 * 1024 * 1024;
static const int kDefaultListenPort = 28767;

enum
{
    FXFrameConfig = 0x01,
    FXFramePing = 0x02,
    FXFramePong = 0x03,
    FXFrameStop = 0x04,
    FXFrameRequestIdr = 0x05,
    FXFrameVideo = 0x10,
    FXFrameAudio = 0x11,
    FXFrameMeta = 0x12,
};

static BOOL FXReadExact(int fd, void *buffer, size_t length, int timeoutMs)
{
    uint8_t *cursor = (uint8_t *)buffer;
    size_t remaining = length;
    const int64_t deadline = (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0) + timeoutMs;

    while (remaining > 0)
    {
        struct pollfd pfd = { fd, POLLIN, 0 };
        int64_t left = deadline - (int64_t)(CFAbsoluteTimeGetCurrent() * 1000.0);
        if (left <= 0)
        {
            return NO;
        }

        int ready = poll(&pfd, 1, (int)left);
        if (ready <= 0)
        {
            return NO;
        }

        ssize_t n = recv(fd, cursor, remaining, 0);
        if (n <= 0)
        {
            return NO;
        }

        cursor += n;
        remaining -= (size_t)n;
    }

    return YES;
}

static uint32_t FXReadU32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t FXReadU16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static int64_t FXReadI64(const uint8_t *p) { return (int64_t)((uint64_t)FXReadU32(p) | ((uint64_t)FXReadU32(p + 4) << 32)); }

@interface FXUSBSource ()
- (void)acceptLoop;
- (void)sessionLoop:(int)fd;
@end

@implementation FXUSBSource
{
    int _listenFd;
    int _port;
    BOOL _running;
    NSThread *_acceptThread;
    NSLock *_sessionLock;
    int _sessionFd;
}

+ (instancetype)shared
{
    static FXUSBSource *source = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        source = [[FXUSBSource alloc] init];
    });
    return source;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _listenFd = -1;
        _sessionFd = -1;
        _port = kDefaultListenPort;
        _sessionLock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)running
{
    return _running;
}

- (int)listenPort
{
    return _port;
}

- (void)setListenPort:(int)port
{
    if (port > 0 && port < 65536)
    {
        _port = port;
    }
}

- (void)start
{
    if (_running)
    {
        return;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
    {
        [[FXMediaStore shared] setStatus:@"USB 无法创建监听套接字"];
        return;
    }

    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 只接受本机（usbmuxd 在设备侧回环）

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 4) < 0)
    {
        close(fd);
        [[FXMediaStore shared] setStatus:@"USB 端口 28767 被占用"];
        return;
    }

    _listenFd = fd;
    _running = YES;
    [[FXMediaStore shared] setMode:FXSourceModeUSB];
    [[FXMediaStore shared] setStatus:@"USB 等待连接"];

    _acceptThread = [[NSThread alloc] initWithTarget:self selector:@selector(acceptLoop) object:nil];
    _acceptThread.name = @"fx-usb-accept";
    _acceptThread.qualityOfService = NSQualityOfServiceUtility;
    [_acceptThread start];
}

- (void)stop
{
    _running = NO;

    if (_listenFd >= 0)
    {
        close(_listenFd);
        _listenFd = -1;
    }

    [_sessionLock lock];
    if (_sessionFd >= 0)
    {
        close(_sessionFd);
        _sessionFd = -1;
    }
    [_sessionLock unlock];

    [[FXMediaStore shared] invalidateVideo];
    [[FXMediaStore shared] resetAudio];
    [[FXMediaStore shared] setStatus:@"USB 已关闭"];
}

- (void)acceptLoop
{
    while (_running)
    {
        struct pollfd pfd = { _listenFd, POLLIN, 0 };
        int ready = poll(&pfd, 1, 500);
        if (!_running)
        {
            break;
        }

        if (ready <= 0)
        {
            continue;
        }

        int fd = accept(_listenFd, NULL, NULL);
        if (fd < 0)
        {
            continue;
        }

        int nodelay = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
        int nosigpipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));

        [_sessionLock lock];
        if (_sessionFd >= 0)
        {
            close(_sessionFd); // 新会话顶掉旧会话
        }
        _sessionFd = fd;
        [_sessionLock unlock];

        [[FXMediaStore shared] setStatus:@"USB 已连接 · 等待画面"];
        [NSThread detachNewThreadWithBlock:^{
            [self sessionLoop:fd];
        }];
    }
}

- (void)sessionLoop:(int)fd
{
    // 1) 文本行握手：DYH2/2\n{"..."}\n
    NSMutableData *handshake = [NSMutableData data];
    uint8_t byte = 0;
    int newlines = 0;
    while (newlines < 2 && handshake.length < 8192)
    {
        if (!FXReadExact(fd, &byte, 1, 3000))
        {
            close(fd);
            return;
        }
        [handshake appendBytes:&byte length:1];
        if (byte == '\n')
        {
            newlines++;
        }
    }

    NSString *text = [[NSString alloc] initWithData:handshake encoding:NSUTF8StringEncoding];
    if (![text hasPrefix:@"DYH2/2"])
    {
        close(fd);
        return;
    }

    NSDictionary *meta = [FXMediaStore shared].videoMeta;
    NSString *ack = [NSString stringWithFormat:@"DYA2/2\n{\"status\":\"ok\",\"app\":\"DOUY iOS\",\"version\":\"1.0.0\",\"width\":%d,\"height\":%d}\n",
                                               [meta[@"width"] intValue], [meta[@"height"] intValue]];
    NSData *ackData = [ack dataUsingEncoding:NSUTF8StringEncoding];
    send(fd, ackData.bytes, ackData.length, 0);

    FXVideoDecoder *video = [[FXVideoDecoder alloc] init];
    FXAudioDecoder *audio = [[FXAudioDecoder alloc] init];
    [[FXMediaStore shared] resetAudio];
    [[FXMediaStore shared] setStatus:@"USB 已连接 · 等待视频参数"];

    uint8_t header[kFXHeaderSize];
    BOOL stopping = NO;
    while (_running && !stopping)
    {
        if (!FXReadExact(fd, header, kFXHeaderSize, 6000))
        {
            break;
        }

        uint32_t magic = FXReadU32(header);
        if (magic != kFXMagic)
        {
            break;
        }

        uint8_t type = header[4];
        uint8_t flags = header[5];
        uint16_t channel = FXReadU16(header + 6);
        int64_t ptsMs = FXReadI64(header + 8) / 1000;
        int64_t dtsMs = FXReadI64(header + 16) / 1000;
        uint32_t length = FXReadU32(header + 24);

        (void)channel;
        (void)dtsMs;

        if (length > (uint32_t)kFXMaxPayload)
        {
            break;
        }

        NSMutableData *payload = length > 0 ? [NSMutableData dataWithLength:length] : nil;
        if (length > 0 && !FXReadExact(fd, payload.mutableBytes, length, 6000))
        {
            break;
        }

        switch (type)
        {
            case FXFrameVideo:
            {
                BOOL keyframe = (flags & 0x01) != 0;
                [video decodeAnnexB:payload ptsMs:ptsMs keyframe:keyframe];
                break;
            }
            case FXFrameAudio:
            {
                [audio decodeADTS:payload];
                break;
            }
            case FXFrameConfig:
            case FXFrameMeta:
            {
                break;
            }
            case FXFramePing:
            {
                uint8_t pong[kFXHeaderSize] = {0};
                pong[0] = (uint8_t)(kFXMagic & 0xFF);
                pong[1] = (uint8_t)((kFXMagic >> 8) & 0xFF);
                pong[2] = (uint8_t)((kFXMagic >> 16) & 0xFF);
                pong[3] = (uint8_t)((kFXMagic >> 24) & 0xFF);
                pong[4] = FXFramePong;
                send(fd, pong, sizeof(pong), 0);
                break;
            }
            case FXFrameStop:
            {
                stopping = YES;
                break;
            }
            default:
                break;
        }
    }

    close(fd);
    [_sessionLock lock];
    if (_sessionFd == fd)
    {
        _sessionFd = -1;
    }
    [_sessionLock unlock];

    [[FXMediaStore shared] setStatus:@"USB 等待连接"];
}

@end
