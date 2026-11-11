using System.Net;
using System.Net.Sockets;
using DOUY.Pc.Media;
using DOUY.Pc.Rtmp;
using DOUY.Pc.Usb;

namespace DOUY.Pc;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // 日志统一 UTF-8，避免重定向到文件/CI 里中文变问号
        try
        {
            Console.OutputEncoding = System.Text.Encoding.UTF8;
        }
        catch
        {
            // WinExe 双击（无控制台）时设置会抛，忽略即可
        }

        var command = args.Length > 0 ? args[0].ToLowerInvariant() : "gui";
        try
        {
            switch (command)
            {
                case "serve":
                case "headless":
                    return Headless(args);
                case "list":
                    return ListDevices();
                case "gui":
                case "":
                    ApplicationConfiguration.Initialize();
                    Application.Run(new MainForm());
                    return 0;
                default:
                    Console.Error.WriteLine("用法: DOUY.Pc [gui | list | serve ...]");
                    return 2;
            }
        }
        catch (Exception ex)
        {
            AppLog.Error("致命错误", ex);
            return 1;
        }
    }

    private static string? Arg(string[] args, string name)
    {
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return null;
    }

    private static bool HasFlag(string[] args, string name) =>
        args.Any(a => string.Equals(a, name, StringComparison.OrdinalIgnoreCase));

    private static int ListDevices()
    {
        try
        {
            using var mux = UsbMuxClient.ConnectToService();
            var devices = mux.ListDevices();
            Console.WriteLine($"{{\"devices\":[{string.Join(",", devices.Select(d => $"{{\"udid\":\"{d.Udid}\",\"connection\":\"{d.ConnectionType}\"}}"))}]}}");
            return 0;
        }
        catch (Exception ex)
        {
            AppLog.Error("无法连接 Apple Mobile Device 服务", ex);
            return 1;
        }
    }

    /// <summary>
    /// 无界面模式（自动化测试 / 服务器部署）：
    ///   serve --port 19350 [--path live/douy] [--phone 127.0.0.1:28767]
    ///         [--usb] [--device-port 28767] [--udid XXX] [--dump out_prefix]
    /// </summary>
    private static int Headless(string[] args)
    {
        var port = int.TryParse(Arg(args, "--port"), out var p) ? p : 19350;
        var path = Arg(args, "--path") ?? "live/douy";
        var phone = Arg(args, "--phone");
        var dump = Arg(args, "--dump");
        var useUsb = HasFlag(args, "--usb") || phone == null;
        var devicePort = int.TryParse(Arg(args, "--device-port"), out var dp) ? dp : 28767;
        var udid = Arg(args, "--udid");

        using var server = new RtmpServer();
        using var hub = new MediaHub();
        hub.Attach(server);
        server.Start(port, path);

        FileStream? videoDump = null;
        FileStream? audioDump = null;
        if (!string.IsNullOrEmpty(dump))
        {
            videoDump = File.Create($"{dump}.h264");
            audioDump = File.Create($"{dump}.aac");
            long videoBytes = 0;
            long audioBytes = 0;
            hub.Subscribe(frame =>
            {
                if (frame.Kind == MediaKind.Video && videoDump != null)
                {
                    videoDump.Write(frame.Payload);
                    videoDump.Flush();
                    videoBytes += frame.Payload.Length;
                    if (hub.VideoFrames % 60 == 0)
                    {
                        AppLog.Info($"已写出 {hub.VideoFrames} 帧视频 / {videoBytes / 1024} KiB");
                    }
                }
                else if (frame.Kind == MediaKind.Audio && audioDump != null)
                {
                    audioDump.Write(frame.Payload);
                    audioDump.Flush();
                    audioBytes += frame.Payload.Length;
                }
            });
        }

        UsbBridge? bridge = null;
        if (useUsb || phone != null)
        {
            bridge = new UsbBridge(hub, udid, devicePort, phone);
            bridge.StateChanged += (state, message) => AppLog.Info($"[状态] {state} · {message}");
            bridge.Start();
        }

        AppLog.Info("=== 兜鱼复刻版 · 无界面模式 ===");
        AppLog.Info($"RTMP: rtmp://127.0.0.1:{port}/{path}");
        foreach (var ip in LocalAddresses())
        {
            AppLog.Info($"局域网: rtmp://{ip}:{port}/{path}");
        }

        var stop = false;
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            stop = true;
        };

        // 无控制台（被重定向 / 服务方式）时 Console.KeyAvailable 会抛异常
        var canReadKeys = true;
        try
        {
            _ = Console.KeyAvailable;
        }
        catch (InvalidOperationException)
        {
            canReadKeys = false;
        }

        while (!stop && !(canReadKeys && Console.KeyAvailable))
        {
            Thread.Sleep(500);
        }

        AppLog.Info($"结束：视频 {hub.VideoFrames} 帧 / 音频 {hub.AudioFrames} 帧" +
                    (bridge != null ? $" / USB 发送 {bridge.FramesSent} 帧 {bridge.BytesSent / 1024} KiB" : string.Empty));
        bridge?.Stop();
        videoDump?.Dispose();
        audioDump?.Dispose();
        return 0;
    }

    public static IEnumerable<string> LocalAddresses()
    {
        var results = new List<string>();
        try
        {
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up)
                {
                    continue;
                }

                if (ni.NetworkInterfaceType is System.Net.NetworkInformation.NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                foreach (var addr in ni.GetIPProperties().UnicastAddresses)
                {
                    if (addr.Address.AddressFamily == AddressFamily.InterNetwork)
                    {
                        results.Add(addr.Address.ToString());
                    }
                }
            }
        }
        catch
        {
            // ignore
        }

        return results;
    }
}
