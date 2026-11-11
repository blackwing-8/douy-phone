using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace DOUY.Pc.Usb;

/// <summary>
/// Apple Mobile Device（usbmuxd）最小客户端。
///
/// usbmuxd 在 Windows 上由 Apple Mobile Device Support / Apple Devices 安装在
/// 127.0.0.1:27015（TCP）。协议：16 字节头（length/version/message/tag，均小端）+ plist XML 负载。
/// 这里只实现三件事：ListDevices、Connect（把 PC 的 TCP 隧道接到 iPhone 的某个端口）、Read。
///
/// 对照原版：douy-ios-usb-helper.exe 用同一套 plist（ProgName / BundleID /
/// kLibUSBMuxVersion=3 / MessageType / DeviceID / PortNumber）。
/// </summary>
public sealed class UsbMuxClient : IDisposable
{
    private const uint MessageResult = 1;
    private const uint MessageConnect = 2;
    private const uint MessagePlist = 8;

    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private uint _tag = 1;

    private UsbMuxClient(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
    }

    public static UsbMuxClient ConnectToService(string host = "127.0.0.1", int port = 27015, int timeoutMs = 3000)
    {
        var client = new TcpClient { NoDelay = true };
        var task = client.ConnectAsync(host, port);
        if (!task.Wait(timeoutMs))
        {
            client.Dispose();
            throw new TimeoutException($"连接 Apple Mobile Device 服务 {host}:{port} 超时。请安装 Apple Devices 或 iTunes。");
        }

        task.GetAwaiter().GetResult();
        return new UsbMuxClient(client);
    }

    public sealed record DeviceInfo(uint DeviceId, string Udid, string ConnectionType)
    {
        public override string ToString() => $"{Udid} ({ConnectionType})";
    }

    /// <summary>列出所有 iPhone（USB / 网络连接都算）。</summary>
    public List<DeviceInfo> ListDevices()
    {
        var tag = NextTag();
        SendPlist(tag,
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>ListDevices</string>" +
            "<key>ProgName</key><string>DOUY.Pc</string>" +
            "<key>kLibUSBMuxVersion</key><integer>3</integer>" +
            "</dict></plist>");

        var devices = new List<DeviceInfo>();
        var deadline = Environment.TickCount64 + 3000;
        while (Environment.TickCount64 < deadline)
        {
            if (!TryReadMessage(out var message, out var payload, 2000))
            {
                break;
            }

            if (message == MessagePlist)
            {
                var xml = Encoding.UTF8.GetString(payload);
                devices.AddRange(ParseDeviceList(xml));
                break;
            }
        }

        return devices;
    }

    /// <summary>
    /// 把当前连接变成到 iPhone 指定端口的字节隧道（成功后本对象即"管道"）。
    /// </summary>
    public void ConnectToDevice(uint deviceId, int devicePort, string progName = "DOUY.Pc")
    {
        var tag = NextTag();
        SendPlist(tag,
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>Connect</string>" +
            $"<key>DeviceID</key><integer>{deviceId}</integer>" +
            $"<key>PortNumber</key><integer>{devicePort}</integer>" +
            "<key>ProgName</key><string>" + progName + "</string>" +
            "<key>ClientVersionString</key><string>DOUY 1.0</string>" +
            $"<key>BundleID</key><string>app.zhenxiang.livebridge.windows</string>" +
            "<key>kLibUSBMuxVersion</key><integer>3</integer>" +
            "</dict></plist>");

        var deadline = Environment.TickCount64 + 5000;
        while (Environment.TickCount64 < deadline)
        {
            if (!TryReadMessage(out var message, out var payload, 3000))
            {
                throw new IOException("Apple Mobile Device 服务关闭了连接。");
            }

            if (message != MessageResult)
            {
                continue;
            }

            var result = ParseResultNumber(payload);
            if (result == 0)
            {
                return;
            }

            throw new IOException(result switch
            {
                2 => "iPhone 端口未在接受兜鱼连线（手机端插件未启动监听）。",
                3 => "设备未连接或未信任此电脑（请在手机上点“信任”）。",
                5 => "设备未连接或未信任此电脑（请在手机上点“信任”）。",
                _ => $"usbmuxd Connect 失败，result={result}",
            });
        }

        throw new TimeoutException("等待 usbmuxd Connect 结果超时。");
    }

    public NetworkStream Stream => _stream;
    public TcpClient Client => _client;

    private uint NextTag() => _tag++;

    private void SendPlist(uint tag, string xml)
    {
        var payload = Encoding.UTF8.GetBytes(xml);
        var header = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(0), (uint)(16 + payload.Length));
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8), MessagePlist);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(12), tag);
        _stream.Write(header);
        _stream.Write(payload);
        _stream.Flush();
    }

    private bool TryReadMessage(out uint message, out byte[] payload, int timeoutMs)
    {
        message = 0;
        payload = Array.Empty<byte>();
        try
        {
            _client.ReceiveTimeout = timeoutMs;
            var header = ReadExactly(16);
            if (header == null)
            {
                return false;
            }

            var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(0));
            message = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8));
            if (length < 16 || length > 8 * 1024 * 1024)
            {
                return false;
            }

            var body = ReadExactly((int)length - 16);
            payload = body ?? Array.Empty<byte>();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private byte[]? ReadExactly(int count)
    {
        if (count == 0)
        {
            return Array.Empty<byte>();
        }

        var buffer = new byte[count];
        var read = 0;
        while (read < count)
        {
            var n = _stream.Read(buffer, read, count - read);
            if (n <= 0)
            {
                return null;
            }

            read += n;
        }

        return buffer;
    }

    /// <summary>Result 消息负载：plist 里 &lt;key&gt;Number&lt;/key&gt;&lt;integer&gt;N&lt;/integer&gt;。</summary>
    private static int ParseResultNumber(byte[] payload)
    {
        if (payload.Length == 0)
        {
            return 0;
        }

        if (payload.Length >= 4 && payload[0] == (byte)'b' && payload[1] == (byte)'p')
        {
            return 0; // 二进制 plist，按成功处理
        }

        var xml = Encoding.UTF8.GetString(payload);
        var idx = xml.IndexOf("<key>Number</key>", StringComparison.Ordinal);
        if (idx < 0)
        {
            return 0;
        }

        var start = xml.IndexOf("<integer>", idx, StringComparison.Ordinal);
        var end = start >= 0 ? xml.IndexOf("</integer>", start, StringComparison.Ordinal) : -1;
        if (start < 0 || end < 0)
        {
            return 0;
        }

        start += "<integer>".Length;
        return int.TryParse(xml[start..end], out var value) ? value : 0;
    }

    private static IEnumerable<DeviceInfo> ParseDeviceList(string xml)
    {
        // 逐个 <dict> 抓 Properties/DeviceID/SerialNumber/ConnectionType
        var pos = 0;
        while (true)
        {
            var dictStart = xml.IndexOf("<dict>", pos, StringComparison.Ordinal);
            if (dictStart < 0)
            {
                yield break;
            }

            var dictEnd = xml.IndexOf("</dict>", dictStart, StringComparison.Ordinal);
            if (dictEnd < 0)
            {
                yield break;
            }

            var chunk = xml[dictStart..dictEnd];
            pos = dictEnd + 7;

            var deviceId = ReadInt(chunk, "DeviceID");
            var udid = ReadString(chunk, "SerialNumber");
            var connection = ReadString(chunk, "ConnectionType");
            if (deviceId > 0 && !string.IsNullOrEmpty(udid))
            {
                yield return new DeviceInfo((uint)deviceId, udid!, connection ?? "USB");
            }
        }
    }

    private static string? ReadString(string xml, string key)
    {
        var k = xml.IndexOf($"<key>{key}</key>", StringComparison.Ordinal);
        if (k < 0)
        {
            return null;
        }

        var s = xml.IndexOf("<string>", k, StringComparison.Ordinal);
        var e = s >= 0 ? xml.IndexOf("</string>", s, StringComparison.Ordinal) : -1;
        if (s < 0 || e < 0)
        {
            return null;
        }

        return xml[(s + "<string>".Length)..e];
    }

    private static int ReadInt(string xml, string key)
    {
        var k = xml.IndexOf($"<key>{key}</key>", StringComparison.Ordinal);
        if (k < 0)
        {
            return 0;
        }

        var s = xml.IndexOf("<integer>", k, StringComparison.Ordinal);
        var e = s >= 0 ? xml.IndexOf("</integer>", s, StringComparison.Ordinal) : -1;
        if (s < 0 || e < 0)
        {
            return 0;
        }

        return int.TryParse(xml[(s + "<integer>".Length)..e], out var value) ? value : 0;
    }

    public void Dispose()
    {
        try
        {
            _stream.Dispose();
        }
        catch
        {
            // ignore
        }

        _client.Dispose();
    }
}
