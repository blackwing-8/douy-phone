using System.Buffers;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using DOUY.Pc.Media;

namespace DOUY.Pc.Usb;

public enum UsbBridgeState
{
    Idle,
    WaitingPhone,
    Handshaking,
    Streaming,
    Error,
}

/// <summary>
/// USB 隧道守护：把 <see cref="MediaHub"/> 出来的 FXP/2 帧送进 iPhone。
///
/// 两条路径：
///   1) usbmuxd（真机）：Apple Mobile Device 服务 → Connect(devicePort=28767)
///   2) 直连（调试/自测）：直接连接 <c>--phone host:port</c>，用于没有真机时验证协议
///
/// 行为对齐原版：断线自动重连（退避）、积压时丢非关键帧、连接后立刻补发最近关键帧。
/// </summary>
public sealed class UsbBridge : IDisposable
{
    private readonly MediaHub _hub;
    private readonly string? _udid;
    private readonly int _devicePort;
    private readonly string? _directHost;
    private readonly int _directPort;

    private readonly object _gate = new();
    private readonly Queue<MediaFrame> _queue = new();
    private Thread? _worker;
    private Thread? _pump;
    private volatile bool _running;
    private TcpClient? _client;
    private NetworkStream? _stream;
    private Action? _unsubscribe;
    private long _framesSent;
    private long _bytesSent;
    private long _dropped;
    private long _sessions;
    private int _lastWidth;
    private int _lastHeight;

    public UsbBridge(MediaHub hub, string? udid = null, int devicePort = 28767, string? directEndpoint = null)
    {
        _hub = hub;
        _udid = udid;
        _devicePort = devicePort;
        if (!string.IsNullOrWhiteSpace(directEndpoint))
        {
            var parts = directEndpoint.Split(':', 2);
            _directHost = parts[0];
            _directPort = parts.Length > 1 && int.TryParse(parts[1], out var p) ? p : 28767;
        }
    }

    public event Action<UsbBridgeState, string>? StateChanged;

    public UsbBridgeState State { get; private set; } = UsbBridgeState.Idle;
    public long FramesSent => Interlocked.Read(ref _framesSent);
    public long BytesSent => Interlocked.Read(ref _bytesSent);
    public long Dropped => Interlocked.Read(ref _dropped);
    public long Sessions => Interlocked.Read(ref _sessions);
    public int Backlog
    {
        get { lock (_gate) { return _queue.Count; } }
    }

    public void Start()
    {
        if (_running)
        {
            return;
        }

        _running = true;
        _unsubscribe = _hub.Subscribe(Enqueue);

        _worker = new Thread(WorkerLoop) { IsBackground = true, Name = "fxp-bridge" };
        _worker.Start();

        _pump = new Thread(PumpLoop) { IsBackground = true, Name = "fxp-send" };
        _pump.Start();

        SetState(UsbBridgeState.WaitingPhone, "等待手机连接");
    }

    public void Stop()
    {
        if (!_running)
        {
            return;
        }

        _running = false;
        _unsubscribe?.Invoke();
        _unsubscribe = null;

        try
        {
            _client?.Close();
        }
        catch
        {
            // ignore
        }

        _worker?.Join(1500);
        _pump?.Join(1500);
        SetState(UsbBridgeState.Idle, "USB 输出已关闭");
    }

    private void SetState(UsbBridgeState state, string message)
    {
        State = state;
        try
        {
            StateChanged?.Invoke(state, message);
        }
        catch
        {
            // ignore
        }

        AppLog.Info($"[USB] {message}");
    }

    private void Enqueue(MediaFrame frame)
    {
        lock (_gate)
        {
            // 队列上限：视频 240 帧（约 8 秒@30fps）
            while (_queue.Count >= 240)
            {
                var dropped = false;
                var kept = new List<MediaFrame>(_queue.Count);
                foreach (var f in _queue)
                {
                    if (!dropped && f.Kind == MediaKind.Video && !f.Keyframe)
                    {
                        dropped = true;
                        continue;
                    }

                    kept.Add(f);
                }

                if (!dropped)
                {
                    break; // 全是关键帧，等消费
                }

                _queue.Clear();
                foreach (var f in kept)
                {
                    _queue.Enqueue(f);
                }

                Interlocked.Increment(ref _dropped);
            }

            _queue.Enqueue(frame);
        }
    }

    private void WorkerLoop()
    {
        var backoffMs = 500;
        while (_running)
        {
            UsbMuxClient? mux = null;
            try
            {
                TcpClient client;
                if (_directHost != null)
                {
                    client = new TcpClient { NoDelay = true };
                    var connect = client.ConnectAsync(_directHost, _directPort);
                    if (!connect.Wait(3000) || !client.Connected)
                    {
                        throw new IOException($"连接 {_directHost}:{_directPort} 超时");
                    }
                }
                else
                {
                    mux = UsbMuxClient.ConnectToService();
                    var devices = mux.ListDevices();
                    if (devices.Count == 0)
                    {
                        mux.Dispose();
                        SetState(UsbBridgeState.WaitingPhone, "未发现 iPhone（请解锁并信任此电脑）");
                        Thread.Sleep(Math.Min(backoffMs, 4000));
                        backoffMs = Math.Min(backoffMs * 2, 4000);
                        continue;
                    }

                    var device = _udid == null
                        ? devices[0]
                        : devices.FirstOrDefault(d => d.Udid == _udid) ?? devices[0];

                    mux.ConnectToDevice(device.DeviceId, _devicePort);
                    client = mux.Client;
                    AppLog.Info($"USB 隧道已建立 · {device.Udid[..Math.Min(8, device.Udid.Length)]}… → :{_devicePort}");
                    mux = null; // 所有权转移给连接
                }

                _client = client;
                _stream = client.GetStream();
                SetState(UsbBridgeState.Handshaking, "正在与手机握手…");

                if (!Handshake())
                {
                    throw new IOException("握手失败");
                }

                Interlocked.Increment(ref _sessions);
                backoffMs = 500;
                SetState(UsbBridgeState.Streaming, "USB 已连接 · 正在传输");

                // 立刻补发最近关键帧，避免手机等下一个 IDR
                var key = _hub.LastKeyframe;
                if (key != null)
                {
                    SendFrame(key);
                }

                // 等断开：pump 线程负责写；这里只监视
                while (_running && _client != null && _client.Connected)
                {
                    Thread.Sleep(200);
                    if (_stream == null)
                    {
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                AppLog.Warn($"[USB] {ex.Message}");
                SetState(UsbBridgeState.WaitingPhone, "等待手机重连…");
            }
            finally
            {
                mux?.Dispose();
                try
                {
                    _stream?.Dispose();
                }
                catch
                {
                    // ignore
                }

                _stream = null;
                try
                {
                    _client?.Close();
                }
                catch
                {
                    // ignore
                }

                _client = null;
            }

            if (!_running)
            {
                break;
            }

            var wait = Math.Min(backoffMs, 4000);
            backoffMs = Math.Min(backoffMs * 2, 4000);
            Thread.Sleep(wait);
        }
    }

    private bool Handshake()
    {
        var (w, h) = _hub.Resolution;
        var nonce = Guid.NewGuid().ToString("N")[..16];
        var request = Fxp.HandshakeRequest("DOUY PC", w, h, 30, nonce);
        _stream!.Write(request);
        _stream.Flush();

        var buffer = new MemoryStream();
        var scratch = new byte[512];
        var deadline = Environment.TickCount64 + 3000;
        _client!.ReceiveTimeout = 300;

        while (Environment.TickCount64 < deadline && buffer.Length < 8192)
        {
            int n;
            try
            {
                n = _stream.Read(scratch, 0, scratch.Length);
            }
            catch (IOException)
            {
                // ReceiveTimeout 到期：已收满两行就收工，否则继续等
                if (CountNewlines(buffer.ToArray()) >= 2)
                {
                    break;
                }

                continue;
            }

            if (n <= 0)
            {
                break;
            }

            buffer.Write(scratch, 0, n);
            if (CountNewlines(buffer.ToArray()) >= 2)
            {
                break;
            }
        }

        var data = buffer.ToArray();
        var all = Encoding.UTF8.GetString(data);
        if (!Fxp.TryParseHandshakeAck(data, out var status, out _))
        {
            AppLog.Warn($"[USB] 握手响应异常: {Truncate(all.Replace('\n', ' '), 120)}");
            return false;
        }

        if (status != "ok")
        {
            AppLog.Warn($"[USB] 手机端拒绝: {status}");
            return false;
        }

        AppLog.Info($"[USB] 手机握手完成 · {Truncate(all.Replace('\n', ' '), 120)}");
        return true;
    }

    private static int CountNewlines(byte[] data)
    {
        var count = 0;
        foreach (var b in data)
        {
            if (b == (byte)'\n')
            {
                count++;
            }
        }

        return count;
    }

    private static string Truncate(string text, int max) => text.Length <= max ? text : text[..max] + "…";

    private void PumpLoop()
    {
        var lastPing = Environment.TickCount64;
        while (_running)
        {
            MediaFrame? frame = null;
            lock (_gate)
            {
                if (_queue.Count > 0)
                {
                    frame = _queue.Dequeue();
                }
            }

            if (frame == null)
            {
                if (Environment.TickCount64 - lastPing >= 1000)
                {
                    lastPing = Environment.TickCount64;
                    var ping = Fxp.BuildFrame(Fxp.FrameType.Ping, Fxp.FrameFlags.None, 0, 0, 0, ReadOnlySpan<byte>.Empty);
                    if (_stream != null && !TryWrite(ping))
                    {
                        CloseConnection("心跳写入失败");
                    }
                }

                Thread.Sleep(2);
                continue;
            }

            SendFrame(frame);
        }
    }

    private void SendFrame(MediaFrame frame)
    {
        var stream = _stream;
        if (stream == null)
        {
            return;
        }

        var bytes = Fxp.BuildMediaFrame(frame);
        var sw = Stopwatch.StartNew();
        if (!TryWrite(bytes))
        {
            CloseConnection("发送失败");
            return;
        }

        Interlocked.Increment(ref _framesSent);
        Interlocked.Add(ref _bytesSent, bytes.Length);
        if (sw.ElapsedMilliseconds > 50)
        {
            AppLog.Warn($"[USB] 慢发送 {sw.ElapsedMilliseconds}ms ({bytes.Length}B)");
        }

        if (frame.Kind == MediaKind.Video && _lastWidth == 0)
        {
            var (w, h) = _hub.Resolution;
            _lastWidth = w;
            _lastHeight = h;
            if (w > 0)
            {
                AppLog.Info($"[USB] 开始传输 {w}x{h}");
            }
        }
    }

    private bool TryWrite(byte[] data)
    {
        var stream = _stream;
        if (stream == null)
        {
            return false;
        }

        try
        {
            stream.Write(data, 0, data.Length);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void CloseConnection(string reason)
    {
        AppLog.Warn($"[USB] {reason}，准备重连");
        try
        {
            _client?.Close();
        }
        catch
        {
            // ignore
        }
    }

    public void Dispose() => Stop();
}
