using System.Buffers.Binary;
using System.Text;
using DOUY.Pc.Media;

namespace DOUY.Pc.Usb;

/// <summary>
/// FXP/2 线格式（见 docs/PROTOCOL-zh.md）。
/// 24 字节小端头 + 载荷。
/// </summary>
public static class Fxp
{
    public const uint Magic = 0x324D5944; // 'F''X''M''2'
    public const int HeaderSize = 28;
    public const int MaxPayload = 8 * 1024 * 1024;
    public const string HandshakeMagic = "DYH2/2";
    public const string HandshakeAck = "DYA2/2";

    public enum FrameType : byte
    {
        Config = 0x01,
        Ping = 0x02,
        Pong = 0x03,
        Stop = 0x04,
        RequestIdr = 0x05,
        Video = 0x10,
        Audio = 0x11,
        Meta = 0x12,
    }

    [Flags]
    public enum FrameFlags : byte
    {
        None = 0,
        Keyframe = 1 << 0,
        Config = 1 << 1,
        Discontinuity = 1 << 2,
        Silent = 1 << 3,
    }

    public static byte[] BuildFrame(FrameType type, FrameFlags flags, ushort channel, long ptsUs, long dtsUs, ReadOnlySpan<byte> payload)
    {
        var buffer = new byte[HeaderSize + payload.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(0), Magic);
        buffer[4] = (byte)type;
        buffer[5] = (byte)flags;
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(6), channel);
        BinaryPrimitives.WriteInt64LittleEndian(buffer.AsSpan(8), ptsUs);
        BinaryPrimitives.WriteInt64LittleEndian(buffer.AsSpan(16), dtsUs);
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(24), (uint)payload.Length);
        payload.CopyTo(buffer.AsSpan(HeaderSize));
        return buffer;
    }

    public static byte[] BuildMediaFrame(MediaFrame frame, ushort channel = 0)
    {
        var type = frame.Kind switch
        {
            MediaKind.Video => FrameType.Video,
            MediaKind.Audio => FrameType.Audio,
            _ => FrameType.Meta,
        };

        var flags = FrameFlags.None;
        if (frame.Keyframe)
        {
            flags |= FrameFlags.Keyframe;
        }

        return BuildFrame(type, flags, channel, frame.PtsUs, frame.DtsUs, frame.Payload);
    }

    public static byte[] HandshakeRequest(string appName, int width, int height, int fps, string nonceHex)
    {
        var json = $"{{\"app\":\"{appName}\",\"version\":\"{Version}\",\"video\":\"h264\",\"audio\":\"aac\"," +
                   $"\"width\":{width},\"height\":{height},\"fps\":{fps},\"nonce\":\"{nonceHex}\"}}";
        return Encoding.UTF8.GetBytes($"{HandshakeMagic}\n{json}\n");
    }

    public const string Version = "1.0.0";

    /// <summary>解析对端握手的文本行（最多 8 KiB）。</summary>
    public static bool TryParseHandshakeAck(byte[] data, out string status, out string raw)
    {
        status = "unknown";
        raw = Encoding.UTF8.GetString(data);
        if (!raw.StartsWith(HandshakeAck, StringComparison.Ordinal))
        {
            return false;
        }

        var nl = raw.IndexOf('\n');
        if (nl < 0)
        {
            return false;
        }

        var json = raw[(nl + 1)..].Trim();
        var idx = json.IndexOf("\"status\"", StringComparison.Ordinal);
        if (idx >= 0)
        {
            var colon = json.IndexOf(':', idx);
            if (colon > 0)
            {
                var q1 = json.IndexOf('"', colon);
                var q2 = q1 >= 0 ? json.IndexOf('"', q1 + 1) : -1;
                if (q1 > 0 && q2 > q1)
                {
                    status = json[(q1 + 1)..q2];
                }
            }
        }

        return true;
    }
}
