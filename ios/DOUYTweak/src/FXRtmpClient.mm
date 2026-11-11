//
//  FXRtmpClient.mm
//  极简 RTMP 拉流客户端（自包含、零第三方依赖、仅 Foundation + POSIX socket）
//
//  支持的协议子集：
//   * URL       : rtmp://host[:port]/app[/...]/stream，默认端口 1935；仅 rtmp://
//                 （rtmps:// / rtmpt:// 直接 state=failed 提示不支持）
//   * 握手      : C0+C1 -> S0+S1+S2 -> C2（简单握手；S2 只吃够字节，不校验内容）
//   * 消息层    : basic header 的 1/2/3 字节形式、fmt 0..3、扩展时间戳、
//                 SetChunkSize(1) / Abort(2) / Acknowledgement(3) / UserControl(4) /
//                 WindowAckSize(5) / SetPeerBandwidth(6) / Audio(8) / Video(9) /
//                 Data(18) / Command(20) / Aggregate(22)
//   * AMF0      : 编码 connect / createStream / play / deleteStream；
//                 解码 _result / _error / onStatus / onMetaData
//   * 媒体      : FLV H.264（AVC sequence header 缓存回调；NALU 由 AVCC 长度前缀
//                 转成 Annex-B 起始码；关键帧前自动插入缓存的 SPS/PPS）
//                 FLV AAC（AudioSpecificConfig 回调；裸 AAC 回调，不带 ADTS）
//
//  已知限制：
//   * 只做播放，不做推流；不支持 rtmps/tls；不支持加密（E-RTMP）与 seek/pause 等命令
//   * 只支持 H.264 + AAC；其它编码直接判定为致命错误
//   * 时间戳直接使用 RTMP 32 位消息时间戳（未做回绕重映射），直播场景足够
//   * 不支持 chunk stream id 复用之外的流控（没有发送 SetChunkSize，出向固定 128 字节）
//

#import "FXRtmpClient.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

static const int kIoTimeoutMs = 5000;                            // 读/写/连接超时
static const uint32_t kDefaultChunkSize = 128;                   // RTMP 默认 chunk 大小
static const uint32_t kDefaultAckWindow = 2500000;               // 默认确认窗口
static const uint32_t kMaxMessageSize = 16u * 1024u * 1024u;     // 单条 RTMP 消息上限
static const uint32_t kMaxChunkSize = 4u * 1024u * 1024u;        // 对端声明的 chunk 上限
static const uint32_t kOutChunkSize = 128;                       // 我们出向的 chunk 大小

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

static int64_t fxNowMs(void) {
    return (int64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

static NSString *fxStr(const std::string &s) {
    const char *c = s.empty() ? "" : s.c_str();
    NSString *r = [NSString stringWithUTF8String:c];
    if (r == nil) {
        r = [NSString stringWithUTF8String:"(非 UTF-8 文本)"];
    }
    return r;
}

/** 可被 cancel 打断的 sleep，用于重连退避等待 */
static void fxSleepInterruptible(const std::atomic<bool> &cancel, int ms) {
    int elapsed = 0;
    while (elapsed < ms && !cancel.load()) {
        int step = ms - elapsed;
        if (step > 50) {
            step = 50;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(step));
        elapsed += step;
    }
}

static inline uint32_t fxBe24(const uint8_t *p) {
    return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
}

static inline uint32_t fxBe32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) |
           (uint32_t)p[3];
}

static inline uint32_t fxLe32(const uint8_t *p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) |
           (uint32_t)p[0];
}

static inline void fxPutBe32(std::vector<uint8_t> &v, uint32_t x) {
    v.push_back((uint8_t)((x >> 24) & 0xFF));
    v.push_back((uint8_t)((x >> 16) & 0xFF));
    v.push_back((uint8_t)((x >> 8) & 0xFF));
    v.push_back((uint8_t)(x & 0xFF));
}

static inline bool fxHasStartCode(const std::vector<uint8_t> &v) {
    return v.size() >= 4 && v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 1;
}

// ---------------------------------------------------------------------------
// TCP 连接（非阻塞 socket + poll 超时）
// ---------------------------------------------------------------------------

class Conn {
  public:
    Conn() : _fd(-1), _bytesIn(0) {}
    ~Conn() { closeSock(); }

    bool connectTo(const std::string &host, int port, std::string &err) {
        closeSock();
        if (host.empty()) {
            err = "URL 缺少主机名";
            return false;
        }
        if (port <= 0 || port > 65535) {
            err = "URL 端口非法";
            return false;
        }

        struct addrinfo hints;
        std::memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_protocol = IPPROTO_TCP;

        char portStr[16];
        std::snprintf(portStr, sizeof(portStr), "%d", port);

        struct addrinfo *res = NULL;
        int gai = ::getaddrinfo(host.c_str(), portStr, &hints, &res);
        if (gai != 0 || res == NULL) {
            err = "域名解析失败: " + host;
            return false;
        }

        int lastErr = 0;
        bool connected = false;
        for (struct addrinfo *ai = res; ai != NULL && !connected; ai = ai->ai_next) {
            int fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
            if (fd < 0) {
                lastErr = errno;
                continue;
            }
            int flags = ::fcntl(fd, F_GETFL, 0);
            if (flags >= 0) {
                ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            }
            int one = 1;
            // 绝不因写已关闭的 socket 触发 SIGPIPE
            ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, (socklen_t)sizeof(one));
            ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, (socklen_t)sizeof(one));

            int rc = ::connect(fd, ai->ai_addr, ai->ai_addrlen);
            if (rc == 0) {
                connected = true;
            } else if (errno == EINPROGRESS) {
                struct pollfd pfd;
                pfd.fd = fd;
                pfd.events = POLLOUT;
                pfd.revents = 0;
                int pr = ::poll(&pfd, 1, kIoTimeoutMs);
                if (pr > 0) {
                    int soErr = 0;
                    socklen_t sl = (socklen_t)sizeof(soErr);
                    if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &sl) == 0 && soErr == 0) {
                        connected = true;
                    } else {
                        lastErr = (soErr != 0) ? soErr : errno;
                    }
                } else if (pr == 0) {
                    lastErr = ETIMEDOUT;
                } else {
                    lastErr = errno;
                }
            } else {
                lastErr = errno;
            }

            if (connected) {
                _fd = fd;
                _bytesIn = 0;
                break;
            }
            ::close(fd);
        }
        ::freeaddrinfo(res);

        if (!connected) {
            char buf[128];
            std::snprintf(buf, sizeof(buf), "TCP 连接失败 (errno=%d)", lastErr);
            err = buf;
            return false;
        }
        return true;
    }

    void closeSock(void) {
        if (_fd >= 0) {
            ::close(_fd);
            _fd = -1;
        }
    }

    int fd(void) const { return _fd; }

    uint64_t bytesIn(void) const { return _bytesIn; }

    bool readExact(void *buf, size_t len, std::string &err) {
        uint8_t *p = (uint8_t *)buf;
        size_t got = 0;
        while (got < len) {
            if (_fd < 0) {
                err = "socket 已关闭";
                return false;
            }
            struct pollfd pfd;
            pfd.fd = _fd;
            pfd.events = POLLIN;
            pfd.revents = 0;
            int pr = ::poll(&pfd, 1, kIoTimeoutMs);
            if (pr == 0) {
                err = "读取超时（5 秒内无数据）";
                return false;
            }
            if (pr < 0) {
                if (errno == EINTR) {
                    continue;
                }
                err = "poll 等待读取失败";
                return false;
            }
            ssize_t n = ::recv(_fd, p + got, len - got, 0);
            if (n > 0) {
                got += (size_t)n;
                _bytesIn += (uint64_t)n;
                continue;
            }
            if (n == 0) {
                err = "对端已关闭连接";
                return false;
            }
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            char buf2[96];
            std::snprintf(buf2, sizeof(buf2), "recv 失败 (errno=%d)", errno);
            err = buf2;
            return false;
        }
        return true;
    }

    bool writeAll(const void *buf, size_t len, std::string &err) {
        if (_fd < 0) {
            err = "socket 已关闭";
            return false;
        }
        const uint8_t *p = (const uint8_t *)buf;
        size_t sent = 0;
        while (sent < len) {
            ssize_t n = ::send(_fd, p + sent, len - sent, 0);
            if (n > 0) {
                sent += (size_t)n;
                continue;
            }
            if (n == 0) {
                err = "send 返回 0";
                return false;
            }
            if (errno == EINTR) {
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd;
                pfd.fd = _fd;
                pfd.events = POLLOUT;
                pfd.revents = 0;
                int pr = ::poll(&pfd, 1, kIoTimeoutMs);
                if (pr <= 0) {
                    err = "发送超时";
                    return false;
                }
                continue;
            }
            char buf2[96];
            std::snprintf(buf2, sizeof(buf2), "send 失败 (errno=%d)", errno);
            err = buf2;
            return false;
        }
        return true;
    }

  private:
    int _fd;
    uint64_t _bytesIn;
};

// ---------------------------------------------------------------------------
// AMF0 解码
// ---------------------------------------------------------------------------

struct AmfValue {
    uint8_t marker;
    double num;
    bool boolean;
    std::string str;
    std::map<std::string, AmfValue> obj;
    std::vector<AmfValue> arr;

    AmfValue() : marker(0xFF), num(0.0), boolean(false) {}

    const AmfValue *prop(const std::string &key) const {
        std::map<std::string, AmfValue>::const_iterator it = obj.find(key);
        if (it == obj.end()) {
            return NULL;
        }
        return &it->second;
    }

    std::string strProp(const std::string &key) const {
        const AmfValue *v = prop(key);
        if (v == NULL) {
            return std::string();
        }
        if (v->marker == 0x02 || v->marker == 0x0C) {
            return v->str;
        }
        return std::string();
    }
};

class AmfDec {
  public:
    AmfDec(const uint8_t *p, size_t n) : _p(p), _n(n), _off(0) {}

    bool eof(void) const { return _off >= _n; }

    bool readValue(AmfValue &out) { return readValueDepth(out, 0); }

  private:
    bool take(size_t k) const { return (_off <= _n) && ((_n - _off) >= k); }

    bool readU8(uint8_t &v) {
        if (!take(1)) {
            return false;
        }
        v = _p[_off++];
        return true;
    }

    bool readU16(uint16_t &v) {
        if (!take(2)) {
            return false;
        }
        v = (uint16_t)(((uint16_t)_p[_off] << 8) | (uint16_t)_p[_off + 1]);
        _off += 2;
        return true;
    }

    bool readU32(uint32_t &v) {
        if (!take(4)) {
            return false;
        }
        v = fxBe32(_p + _off);
        _off += 4;
        return true;
    }

    bool readF64(double &v) {
        if (!take(8)) {
            return false;
        }
        uint64_t bits = 0;
        for (int i = 0; i < 8; ++i) {
            bits = (bits << 8) | (uint64_t)_p[_off + (size_t)i];
        }
        _off += 8;
        std::memcpy(&v, &bits, sizeof(v));
        return true;
    }

    bool readBytes(std::string &out, size_t len) {
        if (!take(len)) {
            return false;
        }
        out.assign((const char *)(_p + _off), len);
        _off += len;
        return true;
    }

    bool readShortStr(std::string &out) {
        uint16_t len = 0;
        if (!readU16(len)) {
            return false;
        }
        return readBytes(out, (size_t)len);
    }

    bool readObjectBody(AmfValue &out, int depth) {
        for (;;) {
            if (eof()) {
                return true;  // 容忍被截断的对象
            }
            std::string key;
            if (!readShortStr(key)) {
                return false;
            }
            if (key.empty()) {
                uint8_t m = 0;
                if (!readU8(m)) {
                    return true;
                }
                if (m == 0x09) {
                    return true;  // object end
                }
                _off -= 1;  // 空 key + 正常值，回退一个字节继续解析
                AmfValue v;
                if (!readValueDepth(v, depth + 1)) {
                    return false;
                }
                continue;
            }
            AmfValue v;
            if (!readValueDepth(v, depth + 1)) {
                return false;
            }
            out.obj[key] = v;
        }
    }

    bool readValueDepth(AmfValue &out, int depth) {
        if (depth > 8) {
            return false;
        }
        uint8_t m = 0;
        if (!readU8(m)) {
            return false;
        }
        out.marker = m;
        switch (m) {
            case 0x00: {  // number
                double d = 0;
                if (!readF64(d)) {
                    return false;
                }
                out.num = d;
                return true;
            }
            case 0x01: {  // boolean
                uint8_t b = 0;
                if (!readU8(b)) {
                    return false;
                }
                out.boolean = (b != 0);
                out.num = out.boolean ? 1.0 : 0.0;
                return true;
            }
            case 0x02: {  // string
                return readShortStr(out.str);
            }
            case 0x03: {  // object
                return readObjectBody(out, depth);
            }
            case 0x05: {  // null
                return true;
            }
            case 0x06: {  // undefined
                return true;
            }
            case 0x07: {  // reference
                uint16_t r = 0;
                return readU16(r);
            }
            case 0x08: {  // ECMA array
                uint32_t cnt = 0;
                if (!readU32(cnt)) {
                    return false;
                }
                return readObjectBody(out, depth);
            }
            case 0x09: {  // object end（单独出现时忽略）
                return true;
            }
            case 0x0A: {  // strict array
                uint32_t cnt = 0;
                if (!readU32(cnt)) {
                    return false;
                }
                if (cnt > 4096u) {
                    return false;
                }
                for (uint32_t i = 0; i < cnt; ++i) {
                    AmfValue v;
                    if (!readValueDepth(v, depth + 1)) {
                        return false;
                    }
                    out.arr.push_back(v);
                }
                return true;
            }
            case 0x0B: {  // date
                double d = 0;
                uint16_t tz = 0;
                if (!readF64(d)) {
                    return false;
                }
                if (!readU16(tz)) {
                    return false;
                }
                out.num = d;
                return true;
            }
            case 0x0C: {  // long string
                uint32_t len = 0;
                if (!readU32(len)) {
                    return false;
                }
                return readBytes(out.str, (size_t)len);
            }
            case 0x0F: {  // xml document
                uint32_t len = 0;
                if (!readU32(len)) {
                    return false;
                }
                return readBytes(out.str, (size_t)len);
            }
            case 0x10: {  // typed object
                std::string cls;
                if (!readShortStr(cls)) {
                    return false;
                }
                return readObjectBody(out, depth);
            }
            default: {
                return false;  // AMF3 / 不认识的类型：放弃本条消息
            }
        }
    }

    const uint8_t *_p;
    size_t _n;
    size_t _off;
};

// ---------------------------------------------------------------------------
// AMF0 编码
// ---------------------------------------------------------------------------

static void amfPutNumber(std::vector<uint8_t> &v, double d) {
    v.push_back(0x00);
    uint64_t bits = 0;
    std::memcpy(&bits, &d, sizeof(bits));
    for (int i = 7; i >= 0; --i) {
        v.push_back((uint8_t)((bits >> (i * 8)) & 0xFF));
    }
}

static void amfPutNull(std::vector<uint8_t> &v) { v.push_back(0x05); }

static void amfPutString(std::vector<uint8_t> &v, const std::string &s) {
    v.push_back(0x02);
    uint32_t len = (uint32_t)s.size();
    v.push_back((uint8_t)((len >> 8) & 0xFF));
    v.push_back((uint8_t)(len & 0xFF));
    v.insert(v.end(), s.begin(), s.end());
}

static void amfPutKey(std::vector<uint8_t> &v, const std::string &k) {
    uint32_t len = (uint32_t)k.size();
    v.push_back((uint8_t)((len >> 8) & 0xFF));
    v.push_back((uint8_t)(len & 0xFF));
    v.insert(v.end(), k.begin(), k.end());
}

static void amfPutObjectEnd(std::vector<uint8_t> &v) {
    v.push_back(0x00);
    v.push_back(0x00);
    v.push_back(0x09);
}

// ---------------------------------------------------------------------------
// AVCDecoderConfigurationRecord 解析
// ---------------------------------------------------------------------------

static bool fxParseAvcC(const std::vector<uint8_t> &c, int &lengthSize,
                        std::vector<std::vector<uint8_t> > &sps,
                        std::vector<std::vector<uint8_t> > &pps) {
    sps.clear();
    pps.clear();
    if (c.size() < 7) {
        return false;
    }
    lengthSize = (int)(c[4] & 0x03) + 1;
    if (lengthSize < 1 || lengthSize > 4) {
        lengthSize = 4;
    }

    size_t off = 5;
    int numSps = (int)(c[5] & 0x1F);
    for (int i = 0; i < numSps; ++i) {
        if (off + 2 > c.size()) {
            return false;
        }
        size_t l = ((size_t)c[off] << 8) | (size_t)c[off + 1];
        off += 2;
        if (l == 0 || off + l > c.size()) {
            return false;
        }
        sps.push_back(std::vector<uint8_t>(c.begin() + (ptrdiff_t)off,
                                           c.begin() + (ptrdiff_t)(off + l)));
        off += l;
    }
    if (off + 1 > c.size()) {
        return false;
    }
    int numPps = (int)c[off];
    off += 1;
    for (int i = 0; i < numPps; ++i) {
        if (off + 2 > c.size()) {
            return false;
        }
        size_t l = ((size_t)c[off] << 8) | (size_t)c[off + 1];
        off += 2;
        if (l == 0 || off + l > c.size()) {
            return false;
        }
        pps.push_back(std::vector<uint8_t>(c.begin() + (ptrdiff_t)off,
                                           c.begin() + (ptrdiff_t)(off + l)));
        off += l;
    }
    return (!sps.empty() && !pps.empty());
}

// ---------------------------------------------------------------------------
// RTMP chunk 流读取 / 消息聚合
// ---------------------------------------------------------------------------

struct ChunkStreamState {
    uint32_t timestamp;
    uint32_t delta;
    uint32_t msgLen;
    uint8_t msgType;
    uint32_t msgStreamId;
    uint32_t bytesRead;
    bool hasExtTs;
    std::vector<uint8_t> payload;

    ChunkStreamState()
        : timestamp(0), delta(0), msgLen(0), msgType(0), msgStreamId(0), bytesRead(0),
          hasExtTs(false) {}
};

class ChunkReader {
  public:
    ChunkReader() : _chunkSize(kDefaultChunkSize) {}

    void reset(void) {
        _chunkSize = kDefaultChunkSize;
        _states.clear();
    }

    void setChunkSize(uint32_t s) {
        if (s == 0 || s > kMaxChunkSize) {
            return;
        }
        _chunkSize = s;
    }

    void abortStream(uint32_t csid) {
        std::map<uint32_t, ChunkStreamState>::iterator it = _states.find(csid);
        if (it == _states.end()) {
            return;
        }
        it->second.bytesRead = 0;
        it->second.payload.clear();
    }

    bool readMessage(Conn &conn, uint32_t &outType, uint32_t &outStreamId,
                     uint32_t &outTimestamp, std::vector<uint8_t> &outPayload,
                     std::string &err) {
        for (;;) {
            // ---- basic header ----
            uint8_t b0 = 0;
            if (!conn.readExact(&b0, 1, err)) {
                return false;
            }
            const int fmt = (int)(b0 >> 6);
            uint32_t csid = (uint32_t)(b0 & 0x3F);
            if (csid == 0) {
                uint8_t b1 = 0;
                if (!conn.readExact(&b1, 1, err)) {
                    return false;
                }
                csid = 64u + (uint32_t)b1;
            } else if (csid == 1) {
                uint8_t b[2];
                b[0] = 0;
                b[1] = 0;
                if (!conn.readExact(b, 2, err)) {
                    return false;
                }
                csid = 64u + (uint32_t)b[0] + (uint32_t)b[1] * 256u;
            }

            ChunkStreamState &st = _states[csid];
            const bool isContinuation = (fmt == 3) && (st.bytesRead > 0);

            // fmt 0/1/2 一定开启新消息；若之前有残留半包则丢弃
            if (fmt != 3 && st.bytesRead > 0) {
                st.bytesRead = 0;
                st.payload.clear();
            }

            // ---- message header ----
            uint8_t hdr[11];
            std::memset(hdr, 0, sizeof(hdr));
            size_t hlen = 0;
            if (fmt == 0) {
                hlen = 11;
            } else if (fmt == 1) {
                hlen = 7;
            } else if (fmt == 2) {
                hlen = 3;
            }
            if (hlen > 0 && !conn.readExact(hdr, hlen, err)) {
                return false;
            }

            if (fmt == 0) {
                uint32_t t = fxBe24(hdr);
                bool ext = (t == 0xFFFFFFu);
                st.msgLen = fxBe24(hdr + 3);
                st.msgType = hdr[6];
                st.msgStreamId = fxLe32(hdr + 7);
                st.delta = 0;
                if (ext) {
                    uint8_t eb[4];
                    if (!conn.readExact(eb, 4, err)) {
                        return false;
                    }
                    st.timestamp = fxBe32(eb);
                } else {
                    st.timestamp = t;
                }
                st.hasExtTs = ext;
            } else if (fmt == 1) {
                uint32_t d = fxBe24(hdr);
                bool ext = (d == 0xFFFFFFu);
                st.msgLen = fxBe24(hdr + 3);
                st.msgType = hdr[6];
                if (ext) {
                    uint8_t eb[4];
                    if (!conn.readExact(eb, 4, err)) {
                        return false;
                    }
                    d = fxBe32(eb);
                }
                st.delta = d;
                st.timestamp += d;
                st.hasExtTs = ext;
            } else if (fmt == 2) {
                uint32_t d = fxBe24(hdr);
                bool ext = (d == 0xFFFFFFu);
                if (ext) {
                    uint8_t eb[4];
                    if (!conn.readExact(eb, 4, err)) {
                        return false;
                    }
                    d = fxBe32(eb);
                }
                st.delta = d;
                st.timestamp += d;
                st.hasExtTs = ext;
            } else {
                // fmt 3：延续包或复用上一次 delta 的新消息
                if (st.hasExtTs) {
                    uint8_t eb[4];
                    if (!conn.readExact(eb, 4, err)) {
                        return false;
                    }
                }
                if (!isContinuation) {
                    st.timestamp += st.delta;
                }
            }

            if (st.msgLen > kMaxMessageSize) {
                err = "RTMP 消息长度超出限制";
                return false;
            }

            // ---- payload ----
            if (st.bytesRead == 0) {
                st.payload.clear();
            }
            uint32_t remaining = st.msgLen - st.bytesRead;
            uint32_t want = (remaining < _chunkSize) ? remaining : _chunkSize;
            if (want > 0) {
                size_t old = st.payload.size();
                st.payload.resize(old + (size_t)want);
                if (!conn.readExact(&st.payload[old], (size_t)want, err)) {
                    return false;
                }
                st.bytesRead += want;
            }

            if (st.bytesRead >= st.msgLen) {
                outType = (uint32_t)st.msgType;
                outStreamId = st.msgStreamId;
                outTimestamp = st.timestamp;
                outPayload.clear();
                outPayload.swap(st.payload);
                st.payload.clear();
                st.bytesRead = 0;
                return true;
            }
        }
    }

  private:
    uint32_t _chunkSize;
    std::map<uint32_t, ChunkStreamState> _states;
};

// ---------------------------------------------------------------------------
// URL 配置
// ---------------------------------------------------------------------------

struct UrlConfig {
    std::string host;
    int port;
    std::string app;
    std::string stream;
    std::string tcUrl;
    std::string fatalError;

    UrlConfig() : port(1935) {}
};

// ---------------------------------------------------------------------------
// 核心实现
// ---------------------------------------------------------------------------

class Core {
  public:
    Core(FXRtmpClient *o, id<FXRtmpClientDelegate> d);
    ~Core();

    void setConfig(const UrlConfig &c) { _cfg = c; }

    void start(void);
    void requestStop(void);
    void joinIfNeeded(void);
    void markSelfDelete(void) { _selfDelete.store(true); }

    bool running(void) const { return _running.load(); }
    bool isOnNetworkThread(void);

    // 由 FXRtmpClient 在 init/dealloc 中赋值（弱引用，避免循环持有）
    __weak FXRtmpClient *owner;
    __weak id<FXRtmpClientDelegate> delegate;

  private:
    enum Stage {
        StageIdle = 0,
        StageAwaitConnect,
        StageAwaitStreamId,
        StagePlaySent,
        StagePlaying
    };

    void threadMain(void);
    void threadBody(void);

    bool runSession(std::string &err, bool &played, bool &fatal);
    bool handshake(std::string &err);

    bool sendConnect(std::string &err);
    bool sendCreateStream(std::string &err);
    bool sendPlay(std::string &err);
    bool sendDeleteStream(std::string &err);
    bool sendAck(uint64_t total, std::string &err);
    bool sendWindowAckSize(uint32_t size, std::string &err);
    bool sendUserControl(uint16_t event, const uint8_t *data, size_t n, std::string &err);
    bool sendMessage(uint32_t csid, uint8_t type, uint32_t msgStreamId,
                     const std::vector<uint8_t> &payload, std::string &err);

    bool handleMessage(uint32_t type, uint32_t msgStreamId, uint32_t ts,
                       const std::vector<uint8_t> &payload, int depth, std::string &err,
                       bool &fatal, bool &played);
    void handleCommand(uint32_t ts, const uint8_t *p, size_t n, std::string &err, bool &fatal,
                       bool &played);
    void handleData(const uint8_t *p, size_t n);
    void handleVideo(uint32_t ts, const uint8_t *p, size_t n, std::string &err, bool &fatal);
    void handleAudio(uint32_t ts, const uint8_t *p, size_t n, std::string &err, bool &fatal);
    void notePlaying(bool &played);

    void resetSessionState(void);
    void registerActiveFd(int fd);
    void clearActiveFd(void);

    void emitState(const std::string &state, const std::string &message);
    void emitAvcConfig(const std::vector<uint8_t> &cfg);
    void emitAacConfig(const std::vector<uint8_t> &cfg);
    void emitVideo(const std::vector<uint8_t> &annexB, int64_t ptsMs, bool keyframe);
    void emitAudio(const std::vector<uint8_t> &rawAac, int64_t ptsMs);

    UrlConfig _cfg;
    Conn _conn;
    ChunkReader _reader;

    std::atomic<bool> _running;
    std::atomic<bool> _stopRequested;
    std::atomic<bool> _threadFinished;
    std::atomic<bool> _everStarted;
    std::atomic<bool> _detachOnExit;
    std::atomic<bool> _selfDelete;

    std::thread _th;
    std::mutex _metaMutex;

    std::mutex _sockMutex;
    int _activeFd;

    // 会话状态
    Stage _stage;
    uint32_t _streamId;
    bool _playing;
    uint32_t _ackWindow;
    uint64_t _lastAckBytes;

    // 媒体缓存
    bool _hasAvcC;
    bool _hasAacC;
    bool _seenKeyframe;
    int _nalLengthSize;
    std::vector<uint8_t> _avcC;
    std::vector<uint8_t> _aacC;
    std::vector<std::vector<uint8_t> > _sps;
    std::vector<std::vector<uint8_t> > _pps;
};

Core::Core(FXRtmpClient *o, id<FXRtmpClientDelegate> d)
    : _running(false), _stopRequested(false), _threadFinished(false), _everStarted(false),
      _detachOnExit(false), _selfDelete(false), _activeFd(-1), _stage(StageIdle),
      _streamId(0), _playing(false), _ackWindow(kDefaultAckWindow), _lastAckBytes(0),
      _hasAvcC(false), _hasAacC(false), _seenKeyframe(false), _nalLengthSize(4) {
    owner = o;
    delegate = d;
}

Core::~Core() {
    _conn.closeSock();
    if (_th.joinable()) {
        _th.detach();
    }
}

void Core::start(void) {
    if (isOnNetworkThread()) {
        // 在网络线程里（例如回调中）调用 start 不支持：避免自我 join / 双线程共用 socket
        return;
    }
    bool expected = false;
    if (!_running.compare_exchange_strong(expected, true)) {
        return;  // 已在运行，start 幂等
    }
    joinIfNeeded();  // 回收上一轮的线程（若有）
    {
        std::lock_guard<std::mutex> lk(_metaMutex);
        if (_th.joinable()) {
            // 上一轮线程仍在收尾，不能覆盖 std::thread 对象（否则 std::terminate）
            _running.store(false);
            return;
        }
    }
    _stopRequested.store(false);
    _threadFinished.store(false);
    _everStarted.store(true);
    _th = std::thread([this]() { this->threadMain(); });
}

bool Core::isOnNetworkThread(void) {
    std::lock_guard<std::mutex> lk(_metaMutex);
    if (!_th.joinable()) {
        return false;
    }
    return _th.get_id() == std::this_thread::get_id();
}

void Core::joinIfNeeded(void) {
    if (isOnNetworkThread()) {
        // 从网络线程里调用 stop（例如在回调中停止）：不能 join 自己，
        // 让线程在退出时自行 detach。
        _detachOnExit.store(true);
        return;
    }
    std::thread local;
    {
        std::lock_guard<std::mutex> lk(_metaMutex);
        if (_th.joinable()) {
            local = std::move(_th);
        }
    }
    if (local.joinable()) {
        local.join();
        return;
    }
    // 线程已被 detach（例如 stop 是在网络线程里调用的），等它自己收尾
    if (_everStarted.load() && !_threadFinished.load()) {
        const int64_t deadline = fxNowMs() + 3000;
        while (!_threadFinished.load() && fxNowMs() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
}

void Core::requestStop(void) {
    _stopRequested.store(true);
    _running.store(false);
    std::lock_guard<std::mutex> lk(_sockMutex);
    if (_activeFd >= 0) {
        // 唤醒阻塞在 poll/recv 上的网络线程
        ::shutdown(_activeFd, SHUT_RDWR);
    }
}

void Core::registerActiveFd(int fd) {
    std::lock_guard<std::mutex> lk(_sockMutex);
    _activeFd = fd;
}

void Core::clearActiveFd(void) {
    std::lock_guard<std::mutex> lk(_sockMutex);
    _activeFd = -1;
}

void Core::threadMain(void) {
    @autoreleasepool {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
        try {
            threadBody();
        } catch (...) {
            // 任何 C++ 异常都不允许逃出线程（否则 std::terminate 会 crash）
            @autoreleasepool {
                emitState("failed", "内部异常，拉流线程已退出");
            }
        }
#else
        threadBody();
#endif
        _conn.closeSock();
        clearActiveFd();
        _running.store(false);
        {
            std::lock_guard<std::mutex> lk(_metaMutex);
            if (_detachOnExit.load() && _th.joinable()) {
                _th.detach();
            }
        }
        // 注意：此后不得再访问任何成员变量，_threadFinished 必须是最后一次写
        _threadFinished.store(true);
        if (_selfDelete.load()) {
            // 对象在网络线程上被 dealloc（极端情况），故意泄漏 Core 以避免
            // 跨线程 delete 造成的竞态；socket 已在上面关闭。
        }
    }
}

void Core::threadBody(void) {
    if (!_cfg.fatalError.empty()) {
        emitState("failed", _cfg.fatalError);
        return;
    }

    int attempt = 0;
    bool firstRound = true;
    while (!_stopRequested.load()) {
        if (firstRound) {
            emitState("connecting", "正在连接 RTMP 服务器");
            firstRound = false;
        } else {
            emitState("reconnecting", "连接已断开，正在重新连接");
        }

        const int64_t sessionStart = fxNowMs();
        bool played = false;
        bool fatal = false;
        std::string err;
        runSession(err, played, fatal);

        _conn.closeSock();
        clearActiveFd();
        resetSessionState();

        if (_stopRequested.load()) {
            break;
        }
        if (err.empty()) {
            err = "连接已结束";
        }
        emitState("failed", err);
        if (fatal) {
            break;  // 编码不支持之类的错误不再重连
        }

        // 播放稳定 8 秒以上，重连退避重新从 1 秒开始
        if (played && (fxNowMs() - sessionStart) >= 8000) {
            attempt = 0;
        }
        int shift = attempt;
        if (shift > 2) {
            shift = 2;
        }
        const int delayMs = 1000 << shift;  // 1s / 2s / 4s，上限 4s
        if (attempt < 3) {
            attempt++;
        }
        char buf[96];
        std::snprintf(buf, sizeof(buf), "将在 %d 秒后重连（第 %d 次）", delayMs / 1000, attempt);
        emitState("reconnecting", std::string(buf));
        fxSleepInterruptible(_stopRequested, delayMs);
    }
    emitState("stopped", "已停止");
}

void Core::resetSessionState(void) {
    _stage = StageIdle;
    _streamId = 0;
    _playing = false;
    _seenKeyframe = false;
    _ackWindow = kDefaultAckWindow;
    _lastAckBytes = 0;
}

// ---------------------------------------------------------------------------
// 单次会话（连接 -> 握手 -> connect -> createStream -> play -> 收流）
// ---------------------------------------------------------------------------

bool Core::handshake(std::string &err) {
    // C0 + C1
    uint8_t c0c1[1 + 1536];
    std::memset(c0c1, 0, sizeof(c0c1));
    c0c1[0] = 0x03;  // 版本
    // c0c1[1..4] = time = 0, c0c1[5..8] = zero = 0
    ::arc4random_buf(c0c1 + 9, 1528);
    if (!_conn.writeAll(c0c1, sizeof(c0c1), err)) {
        return false;
    }

    // S0
    uint8_t s0 = 0;
    if (!_conn.readExact(&s0, 1, err)) {
        return false;
    }
    if (s0 != 0x03) {
        char buf[96];
        std::snprintf(buf, sizeof(buf), "握手失败：服务器 RTMP 版本为 %u（期望 3）", (unsigned)s0);
        err = buf;
        return false;
    }

    // S1 + S2（S2 内容不校验，只吃够字节）
    uint8_t s1[1536];
    uint8_t s2[1536];
    if (!_conn.readExact(s1, sizeof(s1), err)) {
        return false;
    }
    if (!_conn.readExact(s2, sizeof(s2), err)) {
        return false;
    }

    // C2：回显 S1（标准做法，服务器不校验）
    if (!_conn.writeAll(s1, sizeof(s1), err)) {
        return false;
    }
    return true;
}

bool Core::sendMessage(uint32_t csid, uint8_t type, uint32_t msgStreamId,
                       const std::vector<uint8_t> &payload, std::string &err) {
    if (_conn.fd() < 0) {
        err = "socket 未连接";
        return false;
    }
    std::vector<uint8_t> out;
    out.reserve(payload.size() + 32);

    // basic header：fmt 0，1 字节形式（csid 1..63）
    out.push_back((uint8_t)(csid & 0x3F));
    // message header：timestamp=0
    out.push_back(0x00);
    out.push_back(0x00);
    out.push_back(0x00);
    const uint32_t len = (uint32_t)payload.size();
    out.push_back((uint8_t)((len >> 16) & 0xFF));
    out.push_back((uint8_t)((len >> 8) & 0xFF));
    out.push_back((uint8_t)(len & 0xFF));
    out.push_back(type);
    // message stream id 小端
    out.push_back((uint8_t)(msgStreamId & 0xFF));
    out.push_back((uint8_t)((msgStreamId >> 8) & 0xFF));
    out.push_back((uint8_t)((msgStreamId >> 16) & 0xFF));
    out.push_back((uint8_t)((msgStreamId >> 24) & 0xFF));

    size_t off = 0;
    while (off < payload.size()) {
        uint32_t n = (uint32_t)(payload.size() - off);
        if (n > kOutChunkSize) {
            n = kOutChunkSize;
        }
        out.insert(out.end(), payload.begin() + (ptrdiff_t)off,
                   payload.begin() + (ptrdiff_t)(off + n));
        off += n;
        if (off < payload.size()) {
            out.push_back((uint8_t)(0xC0 | (csid & 0x3F)));  // fmt 3 延续块
        }
    }
    return _conn.writeAll(out.data(), out.size(), err);
}

bool Core::sendConnect(std::string &err) {
    std::vector<uint8_t> p;
    amfPutString(p, "connect");
    amfPutNumber(p, 1.0);
    p.push_back(0x03);  // command object
    amfPutKey(p, "app");
    amfPutString(p, _cfg.app);
    amfPutKey(p, "type");
    amfPutString(p, "nonprivate");
    amfPutKey(p, "flashVer");
    amfPutString(p, "FMLE/3.0 (compatible; FMSc/1.0)");
    amfPutKey(p, "tcUrl");
    amfPutString(p, _cfg.tcUrl);
    amfPutObjectEnd(p);
    return sendMessage(3, 20, 0, p, err);
}

bool Core::sendCreateStream(std::string &err) {
    std::vector<uint8_t> p;
    amfPutString(p, "createStream");
    amfPutNumber(p, 2.0);
    amfPutNull(p);
    return sendMessage(3, 20, 0, p, err);
}

bool Core::sendPlay(std::string &err) {
    std::vector<uint8_t> p;
    amfPutString(p, "play");
    amfPutNumber(p, 0.0);
    amfPutNull(p);
    amfPutString(p, _cfg.stream);
    amfPutNumber(p, -2.0);  // start = -2（带 FLV 头）/ -1（纯数据）
    return sendMessage(8, 20, _streamId, p, err);
}

bool Core::sendDeleteStream(std::string &err) {
    std::vector<uint8_t> p;
    amfPutString(p, "deleteStream");
    amfPutNumber(p, 3.0);
    amfPutNull(p);
    amfPutNumber(p, (double)_streamId);
    return sendMessage(8, 20, 0, p, err);
}

bool Core::sendAck(uint64_t total, std::string &err) {
    std::vector<uint8_t> p;
    fxPutBe32(p, (uint32_t)(total & 0xFFFFFFFFu));
    return sendMessage(2, 3, 0, p, err);
}

bool Core::sendWindowAckSize(uint32_t size, std::string &err) {
    std::vector<uint8_t> p;
    fxPutBe32(p, size);
    return sendMessage(2, 5, 0, p, err);
}

bool Core::sendUserControl(uint16_t event, const uint8_t *data, size_t n, std::string &err) {
    std::vector<uint8_t> p;
    p.push_back((uint8_t)((event >> 8) & 0xFF));
    p.push_back((uint8_t)(event & 0xFF));
    if (data != NULL && n > 0) {
        p.insert(p.end(), data, data + n);
    }
    return sendMessage(2, 4, 0, p, err);
}

bool Core::runSession(std::string &err, bool &played, bool &fatal) {
    played = false;
    fatal = false;

    if (!_conn.connectTo(_cfg.host, _cfg.port, err)) {
        return false;
    }
    registerActiveFd(_conn.fd());

    if (!handshake(err)) {
        return false;
    }
    if (_stopRequested.load()) {
        err = "已停止";
        return false;
    }

    _reader.reset();
    _stage = StageAwaitConnect;
    _ackWindow = kDefaultAckWindow;
    _lastAckBytes = _conn.bytesIn();
    if (!sendConnect(err)) {
        return false;
    }
    const int64_t connectSentAt = fxNowMs();

    while (!_stopRequested.load()) {
        uint32_t type = 0;
        uint32_t msgStreamId = 0;
        uint32_t ts = 0;
        std::vector<uint8_t> payload;
        if (!_reader.readMessage(_conn, type, msgStreamId, ts, payload, err)) {
            return false;
        }
        if (!handleMessage(type, msgStreamId, ts, payload, 0, err, fatal, played)) {
            return false;
        }
        if (!err.empty()) {
            return false;
        }

        // 收到的字节数达到确认窗口 -> 回 Acknowledgement
        const uint64_t in = _conn.bytesIn();
        if (_ackWindow > 0 && (in - _lastAckBytes) >= (uint64_t)_ackWindow) {
            std::string werr;
            if (!sendAck(in, werr)) {
                err = werr;
                return false;
            }
            _lastAckBytes = in;
        }

        if (_stage == StageAwaitConnect && (fxNowMs() - connectSentAt) > 15000) {
            err = "等待 connect 响应超时";
            return false;
        }
    }

    // 优雅退出：尽力通知服务器关流（失败无所谓）
    if (_streamId != 0) {
        std::string derr;
        (void)sendDeleteStream(derr);
    }
    err = "已停止";
    return false;
}

// ---------------------------------------------------------------------------
// 消息分发
// ---------------------------------------------------------------------------

void Core::notePlaying(bool &played) {
    if (_stage == StagePlaying || _playing) {
        return;
    }
    _stage = StagePlaying;
    _playing = true;
    played = true;
    emitState("playing", "开始播放");
}

bool Core::handleMessage(uint32_t type, uint32_t msgStreamId, uint32_t ts,
                         const std::vector<uint8_t> &payload, int depth, std::string &err,
                         bool &fatal, bool &played) {
    (void)msgStreamId;
    const uint8_t *p = payload.empty() ? NULL : payload.data();
    const size_t n = payload.size();

    switch (type) {
        case 1: {  // Set Chunk Size
            if (p == NULL || n < 4) {
                return true;
            }
            uint32_t sz = fxBe32(p) & 0x7FFFFFFFu;
            if (sz == 0 || sz > kMaxChunkSize) {
                err = "服务器下发了非法的 SetChunkSize";
                return false;
            }
            _reader.setChunkSize(sz);
            return true;
        }
        case 2: {  // Abort
            if (p == NULL || n < 4) {
                return true;
            }
            _reader.abortStream(fxBe32(p));
            return true;
        }
        case 3: {  // Acknowledgement（服务器回报自己收到多少字节）
            return true;
        }
        case 4: {  // User Control
            if (p == NULL || n < 2) {
                return true;
            }
            const uint16_t ev = (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
            if (ev == 6) {  // PingRequest -> PingResponse
                std::string werr;
                const uint8_t *extra = (n >= 6) ? (p + 2) : NULL;
                size_t extraLen = (n >= 6) ? 4 : 0;
                if (!sendUserControl(7, extra, extraLen, werr)) {
                    err = werr;
                    return false;
                }
            } else if (ev == 0) {  // StreamBegin，记录 streamId（不影响播放）
                if (n >= 8) {
                    uint32_t sid = fxBe32(p + 4);
                    if (sid != 0) {
                        _streamId = sid;
                    }
                }
            }
            return true;
        }
        case 5: {  // Window Acknowledgement Size
            if (p == NULL || n < 4) {
                return true;
            }
            uint32_t w = fxBe32(p);
            _ackWindow = (w == 0) ? kDefaultAckWindow : w;
            return true;
        }
        case 6: {  // Set Peer Bandwidth
            if (p == NULL || n < 4) {
                return true;
            }
            uint32_t w = fxBe32(p);
            if (w > 0) {
                _ackWindow = w;
            }
            std::string werr;
            if (!sendWindowAckSize(_ackWindow, werr)) {
                err = werr;
                return false;
            }
            return true;
        }
        case 8: {  // Audio
            handleAudio(ts, p, n, err, fatal);
            if (!err.empty()) {
                return false;
            }
            if (_stage != StagePlaying) {
                notePlaying(played);
            }
            return true;
        }
        case 9: {  // Video
            handleVideo(ts, p, n, err, fatal);
            if (!err.empty()) {
                return false;
            }
            if (_stage != StagePlaying) {
                notePlaying(played);
            }
            return true;
        }
        case 15: {  // AMF3 Data（前面会有一个 0x00 字节）
            if (p != NULL && n > 1 && p[0] == 0x00) {
                handleData(p + 1, n - 1);
            }
            return true;
        }
        case 18: {  // AMF0 Data（onMetaData / @setDataFrame）
            handleData(p, n);
            return true;
        }
        case 17: {  // AMF3 Command
            if (p != NULL && n > 1 && p[0] == 0x00) {
                handleCommand(ts, p + 1, n - 1, err, fatal, played);
            }
            return err.empty();
        }
        case 20: {  // AMF0 Command
            handleCommand(ts, p, n, err, fatal, played);
            return err.empty();
        }
        case 22: {  // Aggregate（多个 FLV tag 打包）
            if (depth > 3 || p == NULL) {
                return true;
            }
            size_t off = 0;
            while (off + 11 <= n) {
                const uint8_t tagType = p[off];
                const uint32_t dataSize = fxBe24(p + off + 1);
                const uint32_t tagTs = fxBe24(p + off + 4);
                if (off + 11 + (size_t)dataSize > n) {
                    break;  // 截断，丢弃剩余部分
                }
                const uint8_t *sub = p + off + 11;
                off += 11 + (size_t)dataSize;
                // 聚合包内每个 tag 后面跟一个 4 字节 PreviousTagSize
                if (off + 4 <= n) {
                    off += 4;
                }
                if (tagType == 8 || tagType == 9 || tagType == 18 || tagType == 20) {
                    std::vector<uint8_t> tmp(sub, sub + dataSize);
                    std::string serr;
                    bool sfatal = false;
                    bool splayed = false;
                    if (!handleMessage((uint32_t)tagType, 0, tagTs, tmp, depth + 1, serr, sfatal,
                                       splayed)) {
                        err = serr;
                        return false;
                    }
                    if (sfatal) {
                        fatal = true;
                    }
                    if (splayed) {
                        played = true;
                    }
                    if (!serr.empty()) {
                        err = serr;
                        return false;
                    }
                }
            }
            return true;
        }
        default: {
            return true;  // 其它类型忽略
        }
    }
}

void Core::handleData(const uint8_t *p, size_t n) {
    // onMetaData / @setDataFrame 只记录不转发；这里仅做轻量解析以便排查问题。
    if (p == NULL || n < 4) {
        return;
    }
    AmfDec dec(p, n);
    AmfValue first;
    if (!dec.readValue(first)) {
        return;
    }
    if (first.marker != 0x02) {
        return;
    }
    // 首值为 "@setDataFrame" 时后面还有 onMetaData + 对象，忽略即可
}

void Core::handleVideo(uint32_t ts, const uint8_t *p, size_t n, std::string &err, bool &fatal) {
    if (p == NULL || n < 1) {
        return;
    }
    const int frameType = (int)((p[0] >> 4) & 0x0F);
    const int codecId = (int)(p[0] & 0x0F);

    if (frameType == 5) {
        return;  // video info / command frame，忽略
    }
    if (codecId != 7) {
        char buf[128];
        std::snprintf(buf, sizeof(buf),
                      "视频编码不是 H.264/AVC（codecId=%d），本客户端仅支持 H.264 + AAC", codecId);
        err = buf;
        fatal = true;
        return;
    }
    if (n < 5) {
        return;
    }

    const int pktType = (int)p[1];
    // compositionTime：有符号 24 位（ms）
    int32_t cts = (int32_t)(((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 8) | (uint32_t)p[4]);
    if (cts & 0x00800000) {
        cts -= 0x01000000;
    }

    if (pktType == 0) {  // AVC sequence header（AVCDecoderConfigurationRecord）
        std::vector<uint8_t> cfg(p + 5, p + n);
        if (cfg.empty()) {
            return;
        }
        int ls = 4;
        std::vector<std::vector<uint8_t> > sps;
        std::vector<std::vector<uint8_t> > pps;
        if (fxParseAvcC(cfg, ls, sps, pps)) {
            _nalLengthSize = ls;
            _sps = sps;
            _pps = pps;
        }
        const bool changed = (cfg != _avcC);
        _avcC = cfg;
        _hasAvcC = true;
        if (changed) {
            emitAvcConfig(_avcC);
        }
        return;
    }
    if (pktType == 2) {
        return;  // end of sequence
    }
    if (pktType != 1) {
        return;
    }
    if (!_hasAvcC) {
        return;  // 还没有配置，丢弃
    }

    const bool keyframe = (frameType == 1);
    if (!_seenKeyframe && !keyframe) {
        return;  // 首个 IDR 之前的非关键帧直接丢弃，避免解码器报错
    }

    static const uint8_t kStartCode[4] = {0x00, 0x00, 0x00, 0x01};
    std::vector<uint8_t> au;
    au.reserve(n + 64);
    if (keyframe) {
        // 关键帧前插入缓存 SPS/PPS
        for (size_t i = 0; i < _sps.size(); ++i) {
            au.insert(au.end(), kStartCode, kStartCode + 4);
            au.insert(au.end(), _sps[i].begin(), _sps[i].end());
        }
        for (size_t i = 0; i < _pps.size(); ++i) {
            au.insert(au.end(), kStartCode, kStartCode + 4);
            au.insert(au.end(), _pps[i].begin(), _pps[i].end());
        }
    }

    const int ls = (_nalLengthSize >= 1 && _nalLengthSize <= 4) ? _nalLengthSize : 4;
    size_t off = 5;
    while (off + (size_t)ls <= n) {
        uint32_t nalLen = 0;
        for (int i = 0; i < ls; ++i) {
            nalLen = (nalLen << 8) | (uint32_t)p[off + (size_t)i];
        }
        off += (size_t)ls;
        if (nalLen == 0) {
            continue;
        }
        if (off + (size_t)nalLen > n) {
            break;  // 截断的 AU，丢掉尾巴
        }
        // 顺手缓存内联的 SPS/PPS（部分编码器不单独发 sequence header）
        const uint8_t nalHeader = p[off];
        const int nalType = (int)(nalHeader & 0x1F);
        if (nalType == 7 && _sps.empty() && nalLen <= 1024) {
            _sps.push_back(std::vector<uint8_t>(p + off, p + off + nalLen));
        } else if (nalType == 8 && _pps.empty() && nalLen <= 1024) {
            _pps.push_back(std::vector<uint8_t>(p + off, p + off + nalLen));
        }
        au.insert(au.end(), kStartCode, kStartCode + 4);
        au.insert(au.end(), p + off, p + off + nalLen);
        off += (size_t)nalLen;
    }

    if (au.empty() || fxHasStartCode(au) == false) {
        return;
    }
    if (keyframe) {
        _seenKeyframe = true;
    }
    emitVideo(au, (int64_t)ts + (int64_t)cts, keyframe);
}

void Core::handleAudio(uint32_t ts, const uint8_t *p, size_t n, std::string &err, bool &fatal) {
    if (p == NULL || n < 2) {
        return;
    }
    const int soundFormat = (int)((p[0] >> 4) & 0x0F);
    if (soundFormat != 10) {
        char buf[128];
        std::snprintf(buf, sizeof(buf),
                      "音频编码不是 AAC（soundFormat=%d），本客户端仅支持 H.264 + AAC",
                      soundFormat);
        err = buf;
        fatal = true;
        return;
    }
    const int pktType = (int)p[1];
    if (pktType == 0) {  // AAC sequence header（AudioSpecificConfig）
        std::vector<uint8_t> cfg(p + 2, p + n);
        if (cfg.empty()) {
            return;
        }
        const bool changed = (cfg != _aacC);
        _aacC = cfg;
        _hasAacC = true;
        if (changed) {
            emitAacConfig(_aacC);
        }
        return;
    }
    if (pktType != 1) {
        return;
    }
    if (!_hasAacC) {
        return;  // 没有 AudioSpecificConfig 之前不回调裸 AAC
    }
    if (n <= 2) {
        return;
    }
    std::vector<uint8_t> raw(p + 2, p + n);
    emitAudio(raw, (int64_t)ts);
}

// ---------------------------------------------------------------------------
// AMF0 命令处理
// ---------------------------------------------------------------------------

void Core::handleCommand(uint32_t ts, const uint8_t *p, size_t n, std::string &err, bool &fatal,
                         bool &played) {
    (void)ts;
    (void)fatal;
    if (p == NULL || n < 2) {
        return;
    }
    AmfDec dec(p, n);
    AmfValue nameVal;
    if (!dec.readValue(nameVal)) {
        return;
    }
    if (nameVal.marker != 0x02) {
        return;
    }
    const std::string name = nameVal.str;

    double txn = 0.0;
    if (!dec.eof()) {
        AmfValue txnVal;
        if (dec.readValue(txnVal) && txnVal.marker == 0x00) {
            txn = txnVal.num;
        }
    }

    std::vector<AmfValue> args;
    for (int i = 0; i < 8 && !dec.eof(); ++i) {
        AmfValue v;
        if (!dec.readValue(v)) {
            break;
        }
        args.push_back(v);
    }

    if (name == "_result") {
        if (_stage == StageAwaitConnect && (int)(txn + 0.5) == 1) {
            // 检查 connect 结果码（有的服务器在 _result 里直接给 NetConnection.Connect.Success）
            for (size_t i = 0; i < args.size(); ++i) {
                const std::string code = args[i].strProp("code");
                if (code == "NetConnection.Connect.Rejected" ||
                    code == "NetConnection.Connect.Failed") {
                    err = "服务器拒绝连接: " + code;
                    return;
                }
            }
            if (!sendCreateStream(err)) {
                return;
            }
            _stage = StageAwaitStreamId;
            return;
        }
        if (_stage == StageAwaitStreamId && (int)(txn + 0.5) == 2) {
            uint32_t sid = 1;
            for (size_t i = 0; i < args.size(); ++i) {
                if (args[i].marker == 0x00) {
                    const double d = args[i].num;
                    if (d > 0 && d < 4294967295.0) {
                        sid = (uint32_t)d;
                    }
                    break;
                }
            }
            _streamId = sid;
            if (!sendPlay(err)) {
                return;
            }
            _stage = StagePlaySent;
            return;
        }
        return;
    }

    if (name == "_error") {
        std::string code;
        std::string desc;
        for (size_t i = 0; i < args.size(); ++i) {
            if (code.empty()) {
                code = args[i].strProp("code");
            }
            if (desc.empty()) {
                desc = args[i].strProp("description");
            }
        }
        if (!desc.empty()) {
            err = "服务器返回错误: " + desc;
        } else if (!code.empty()) {
            err = "服务器返回错误: " + code;
        } else {
            err = "服务器返回错误（_error）";
        }
        return;
    }

    if (name == "onStatus") {
        std::string code;
        std::string desc;
        std::string level;
        for (size_t i = 0; i < args.size(); ++i) {
            if (code.empty()) {
                code = args[i].strProp("code");
            }
            if (desc.empty()) {
                desc = args[i].strProp("description");
            }
            if (level.empty()) {
                level = args[i].strProp("level");
            }
        }
        if (code == "NetStream.Play.Start") {
            notePlaying(played);
            return;
        }
        if (code == "NetStream.Play.Reset") {
            return;  // 服务器在 Start 之前会先发 Reset，忽略
        }
        if (code == "NetStream.Play.StreamNotFound") {
            err = "服务器上不存在该流（NetStream.Play.StreamNotFound）";
            return;
        }
        if (code == "NetStream.Play.Stop" || code == "NetStream.Play.UnpublishNotify" ||
            code == "NetStream.Play.Failed") {
            err = desc.empty() ? ("播放结束: " + code) : ("播放结束: " + desc);
            return;
        }
        if (code == "NetConnection.Connect.Rejected" || code == "NetConnection.Connect.Failed") {
            err = desc.empty() ? ("连接被拒绝: " + code) : ("连接被拒绝: " + desc);
            return;
        }
        // 其它 onStatus（onBWDone / onFCPublish 等）忽略
        return;
    }

    // onMetaData / onBWDone / onFCPublish / releaseStream 等一律忽略
}

// ---------------------------------------------------------------------------
// 回调（全部在网络线程上发出）
// ---------------------------------------------------------------------------

void Core::emitState(const std::string &state, const std::string &message) {
    FXRtmpClient *o = owner;
    if (o == nil) {
        return;
    }
    id<FXRtmpClientDelegate> d = delegate;
    if (d == nil) {
        return;
    }
    @autoreleasepool {
        [d rtmpClient:o didChangeState:fxStr(state) message:fxStr(message)];
    }
}

void Core::emitAvcConfig(const std::vector<uint8_t> &cfg) {
    if (cfg.empty()) {
        return;
    }
    FXRtmpClient *o = owner;
    if (o == nil) {
        return;
    }
    id<FXRtmpClientDelegate> d = delegate;
    if (d == nil) {
        return;
    }
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:(const void *)cfg.data()
                                      length:(NSUInteger)cfg.size()];
        [d rtmpClient:o didReceiveAvcConfig:data];
    }
}

void Core::emitAacConfig(const std::vector<uint8_t> &cfg) {
    if (cfg.empty()) {
        return;
    }
    FXRtmpClient *o = owner;
    if (o == nil) {
        return;
    }
    id<FXRtmpClientDelegate> d = delegate;
    if (d == nil) {
        return;
    }
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:(const void *)cfg.data()
                                      length:(NSUInteger)cfg.size()];
        [d rtmpClient:o didReceiveAacConfig:data];
    }
}

void Core::emitVideo(const std::vector<uint8_t> &annexB, int64_t ptsMs, bool keyframe) {
    if (annexB.empty()) {
        return;
    }
    FXRtmpClient *o = owner;
    if (o == nil) {
        return;
    }
    id<FXRtmpClientDelegate> d = delegate;
    if (d == nil) {
        return;
    }
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:(const void *)annexB.data()
                                      length:(NSUInteger)annexB.size()];
        [d rtmpClient:o
            didReceiveVideoAnnexB:data
                           ptsMs:ptsMs
                         keyframe:(keyframe ? YES : NO)];
    }
}

void Core::emitAudio(const std::vector<uint8_t> &rawAac, int64_t ptsMs) {
    if (rawAac.empty()) {
        return;
    }
    FXRtmpClient *o = owner;
    if (o == nil) {
        return;
    }
    id<FXRtmpClientDelegate> d = delegate;
    if (d == nil) {
        return;
    }
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:(const void *)rawAac.data()
                                      length:(NSUInteger)rawAac.size()];
        [d rtmpClient:o didReceiveAudioAac:data ptsMs:ptsMs];
    }
}

// ---------------------------------------------------------------------------
// URL 解析：rtmp://host[:port]/app[/...]/stream
// ---------------------------------------------------------------------------

static bool fxParseUrl(NSURL *url, UrlConfig &cfg, std::string &errText) {
    NSString *abs = (url != nil) ? [url absoluteString] : nil;
    if (abs == nil || abs.length == 0) {
        errText = "URL 为空";
        return false;
    }

    NSRange schemeRange = [abs rangeOfString:@"://"];
    if (schemeRange.location == NSNotFound) {
        errText = "URL 缺少协议头（需要 rtmp://）";
        return false;
    }
    NSString *scheme = [[abs substringToIndex:schemeRange.location] lowercaseString];
    if (![scheme isEqualToString:@"rtmp"]) {
        if ([scheme isEqualToString:@"rtmps"]) {
            errText = "暂不支持 rtmps://（加密 RTMP），请改用 rtmp://";
        } else if ([scheme isEqualToString:@"rtmpt"] || [scheme isEqualToString:@"rtmpte"]) {
            errText = "暂不支持 rtmpt://（隧道 RTMP），请改用 rtmp://";
        } else {
            errText = "不支持的协议：" + std::string(scheme.UTF8String ? scheme.UTF8String : "");
        }
        return false;
    }

    NSString *rest = [abs substringFromIndex:NSMaxRange(schemeRange)];
    if (rest.length == 0) {
        errText = "URL 缺少主机名";
        return false;
    }

    NSString *authority = rest;
    NSString *path = @"";
    NSRange slashRange = [rest rangeOfString:@"/"];
    if (slashRange.location != NSNotFound) {
        authority = [rest substringToIndex:slashRange.location];
        path = [rest substringFromIndex:slashRange.location];
    }
    // 去掉 query / fragment
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        path = [path substringToIndex:q.location];
    }
    q = [path rangeOfString:@"#"];
    if (q.location != NSNotFound) {
        path = [path substringToIndex:q.location];
    }

    // 去掉 user:pass@
    NSRange atRange = [authority rangeOfString:@"@" options:NSBackwardsSearch];
    if (atRange.location != NSNotFound) {
        authority = [authority substringFromIndex:NSMaxRange(atRange)];
    }

    NSString *host = authority;
    int port = 1935;
    NSRange colon = [authority rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location != NSNotFound) {
        NSString *portStr = [authority substringFromIndex:NSMaxRange(colon)];
        host = [authority substringToIndex:colon.location];
        if (portStr.length > 0) {
            port = (int)[portStr integerValue];
            if (port <= 0 || port > 65535) {
                errText = "URL 端口非法";
                return false;
            }
        }
    }
    if (host.length == 0) {
        errText = "URL 缺少主机名";
        return false;
    }

    // 拆分 app / stream
    NSString *trimmed = path;
    while (trimmed.length > 0 && [trimmed hasPrefix:@"/"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    while (trimmed.length > 0 && [trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:trimmed.length - 1];
    }
    if (trimmed.length == 0) {
        errText = "URL 中缺少 app/stream（形如 rtmp://host/app/stream）";
        return false;
    }
    NSArray *parts = [trimmed componentsSeparatedByString:@"/"];
    NSMutableArray *segs = [NSMutableArray array];
    for (NSUInteger i = 0; i < parts.count; ++i) {
        NSString *one = [parts objectAtIndex:i];
        if (one.length > 0) {
            [segs addObject:one];
        }
    }
    if (segs.count < 2) {
        errText = "URL 中缺少 stream 名（形如 rtmp://host/app/stream）";
        return false;
    }
    NSString *stream = [segs lastObject];
    NSMutableArray *appSegs = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < segs.count; ++i) {
        [appSegs addObject:[segs objectAtIndex:i]];
    }
    NSString *app = [appSegs componentsJoinedByString:@"/"];
    if (app.length == 0 || stream.length == 0) {
        errText = "URL 中缺少 app/stream（形如 rtmp://host/app/stream）";
        return false;
    }

    char tcUrl[1024];
    std::snprintf(tcUrl, sizeof(tcUrl), "rtmp://%s:%d/%s", host.UTF8String ? host.UTF8String : "",
                  port, app.UTF8String ? app.UTF8String : "");

    cfg.host = host.UTF8String ? host.UTF8String : "";
    cfg.port = port;
    cfg.app = app.UTF8String ? app.UTF8String : "";
    cfg.stream = stream.UTF8String ? stream.UTF8String : "";
    cfg.tcUrl = tcUrl;
    cfg.fatalError = "";
    return true;
}

}  // namespace

// ---------------------------------------------------------------------------
// FXRtmpClient
// ---------------------------------------------------------------------------

@implementation FXRtmpClient {
    void *_impl;  // Core *
}

- (instancetype)initWithURL:(NSURL *)url delegate:(id<FXRtmpClientDelegate>)delegate {
    self = [super init];
    if (self) {
        UrlConfig cfg;
        std::string errText;
        if (!fxParseUrl(url, cfg, errText)) {
            cfg.fatalError = errText;
        }
        Core *core = new Core(self, delegate);
        core->setConfig(cfg);
        _impl = (void *)core;
    }
    return self;
}

- (void)dealloc {
    Core *core = (Core *)_impl;
    _impl = NULL;
    if (core == NULL) {
        return;
    }
    core->owner = nil;
    core->delegate = nil;
    core->requestStop();
    if (core->isOnNetworkThread()) {
        // 极端情况：在网络线程的回调里被释放，交给线程自己收尾，避免跨线程 delete
        core->markSelfDelete();
    } else {
        core->joinIfNeeded();
        delete core;
    }
}

- (void)start {
    Core *core = (Core *)_impl;
    if (core == NULL) {
        return;
    }
    core->start();
}

- (void)stop {
    Core *core = (Core *)_impl;
    if (core == NULL) {
        return;
    }
    core->requestStop();
    core->joinIfNeeded();
}

- (BOOL)isRunning {
    Core *core = (Core *)_impl;
    if (core == NULL) {
        return NO;
    }
    return core->running() ? YES : NO;
}

@end
