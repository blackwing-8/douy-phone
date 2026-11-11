using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;

namespace DOUY.Pc.Rtmp;

/// <summary>
/// 极简 RTMP 服务端：本机 OBS 推流（H.264 + AAC），任意播放器拉流。
///
/// 线程模型：
///   * accept 线程只负责接连接，每条连接一个独立线程跑 chunk 循环；
///   * 每个播放器一个发送队列（BlockingCollection）+ 一个写线程，
///     广播时只做非阻塞入队，绝不在锁内做网络写；
///   * 任何连接上的异常都只影响该连接。
/// </summary>
public sealed class RtmpServer : IRtmpServer
{
    private const int OutChunkSize = 4096;
    private const uint WindowAckSize = 2_500_000;
    private const int ViewerQueueCapacity = 512;
    private const int ViewerQueueLimit = 300;
    private const int GopFrameLimit = 120;
    private const long GopByteLimit = 8L * 1024 * 1024;
    private const int AudioCacheLimit = 200;
    private const int SocketTimeoutMs = 30_000;

    private const int CsidProtocolControl = 2;
    private const int CsidCommand = 3;
    private const int CsidAudio = 4;
    private const int CsidData = 5;
    private const int CsidVideo = 6;

    private readonly object _sync = new();
    private readonly List<Viewer> _viewers = new();
    private readonly List<CachedPacket> _gop = new();
    private readonly Queue<CachedPacket> _audioCache = new();

    private TcpListener? _listener;
    private Thread? _acceptThread;
    private Connection? _publisher;
    private RtmpServerState _state = RtmpServerState.Idle;
    private string _path = "live/douy";
    private int _port;
    private int _viewerCount;
    private long _bytesReceived;
    private long _gopBytes;
    private volatile bool _running;
    private bool _disposed;

    private CachedPacket? _avcSeqMessage;
    private CachedPacket? _aacSeqMessage;
    private byte[]? _metadata;

    public RtmpServer()
    {
    }

    // ------------------------------------------------------------ 公开状态

    public RtmpServerState State
    {
        get
        {
            lock (_sync)
            {
                return _state;
            }
        }
    }

    public int Port
    {
        get
        {
            lock (_sync)
            {
                return _port;
            }
        }
    }

    public string Path
    {
        get
        {
            lock (_sync)
            {
                return _path;
            }
        }
    }

    public int ViewerCount
    {
        get
        {
            lock (_sync)
            {
                return _viewerCount;
            }
        }
    }

    public long BytesReceived => Interlocked.Read(ref _bytesReceived);

    public event Action? PublisherConnected;
    public event Action? PublisherDisconnected;
    public event Action<int>? ViewerCountChanged;
    public event Action<byte[]>? AvcSequenceHeader;
    public event Action<byte[]>? AacSequenceHeader;
    public event Action<RtmpVideoPacketEventArgs>? VideoPacket;
    public event Action<RtmpAudioPacketEventArgs>? AudioPacket;
    public event Action<RtmpMetadataEventArgs>? Metadata;

    // ------------------------------------------------------------ 生命周期

    public void Start(int port, string path = "live/douy")
    {
        if (port is <= 0 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(port), "端口必须在 1..65535 之间");
        }

        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(RtmpServer));
        }

        Stop();

        string normalized = NormalizePath(path);
        var listener = new TcpListener(IPAddress.Any, port);
        try
        {
            listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            listener.Start(64);
        }
        catch (Exception ex)
        {
            AppLog.Error($"RTMP 监听端口 {port} 失败", ex);
            AppLog.Warn($"端口 {port} 可能被占用：原版「帧相」插件的 mediamtx 默认也监听 1935，" +
                        "其它推流软件、或已有一个本程序实例在跑；请在面板里换一个端口再试");
            try
            {
                listener.Stop();
            }
            catch
            {
                // 忽略
            }

            throw;
        }

        lock (_sync)
        {
            _listener = listener;
            _port = port;
            _path = normalized;
            _state = RtmpServerState.Listening;
            _running = true;
        }

        _acceptThread = new Thread(() => AcceptLoop(listener))
        {
            IsBackground = true,
            Name = "rtmp-accept",
        };
        _acceptThread.Start();

        AppLog.Info($"RTMP 服务已启动 · 端口 {port} · 路径 {normalized}");
    }

    public void Stop()
    {
        TcpListener? listener;
        Connection? publisher;
        Viewer[] viewers;

        lock (_sync)
        {
            listener = _listener;
            _listener = null;
            publisher = _publisher;
            _publisher = null;
            viewers = _viewers.ToArray();
            _viewers.Clear();
            _viewerCount = 0;
            _running = false;
            _state = RtmpServerState.Idle;
            _gop.Clear();
            _gopBytes = 0;
            _audioCache.Clear();
            _avcSeqMessage = null;
            _aacSeqMessage = null;
            _metadata = null;
        }

        try
        {
            listener?.Stop();
        }
        catch (Exception ex)
        {
            AppLog.Warn($"关闭 RTMP 监听失败: {ex.Message}");
        }

        foreach (Viewer viewer in viewers)
        {
            viewer.Shutdown();
        }

        publisher?.Close();

        Thread? acceptThread = _acceptThread;
        _acceptThread = null;
        if (acceptThread != null && acceptThread != Thread.CurrentThread)
        {
            try
            {
                acceptThread.Join(2000);
            }
            catch
            {
                // 忽略
            }
        }

        if (listener != null)
        {
            AppLog.Info("RTMP 服务已停止");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Stop();
        GC.SuppressFinalize(this);
    }

    // ------------------------------------------------------------ 接入

    private void AcceptLoop(TcpListener listener)
    {
        while (_running)
        {
            TcpClient client;
            try
            {
                client = listener.AcceptTcpClient();
            }
            catch (SocketException ex)
            {
                if (!_running)
                {
                    break;
                }

                AppLog.Warn($"RTMP 接受连接失败: {ex.Message}");
                continue;
            }
            catch (ObjectDisposedException)
            {
                break;
            }
            catch (InvalidOperationException)
            {
                break;
            }
            catch (Exception ex)
            {
                if (!_running)
                {
                    break;
                }

                AppLog.Warn($"RTMP 接受连接异常: {ex.Message}");
                break;
            }

            if (!_running)
            {
                try
                {
                    client.Close();
                }
                catch
                {
                    // 忽略
                }

                break;
            }

            try
            {
                var thread = new Thread(() => RunSession(client))
                {
                    IsBackground = true,
                    Name = "rtmp-conn",
                };
                thread.Start();
            }
            catch (Exception ex)
            {
                AppLog.Error("RTMP 连接线程启动失败", ex);
                try
                {
                    client.Close();
                }
                catch
                {
                    // 忽略
                }
            }
        }
    }

    private void RunSession(TcpClient client)
    {
        Connection? connection = null;
        try
        {
            client.NoDelay = true;
            client.ReceiveTimeout = SocketTimeoutMs;
            client.SendTimeout = SocketTimeoutMs;

            IPAddress address = (client.Client.RemoteEndPoint as IPEndPoint)?.Address ?? IPAddress.Loopback;

            // 注意：这里不能包 BufferedStream —— RTMP 在同一连接上读写交替，
            // BufferedStream 对不可寻址流在“读缓冲非空”时禁止写入。
            Stream stream = client.GetStream();

            long handshakeBytes = RtmpHandshake.ServerHandshake(stream);
            Interlocked.Add(ref _bytesReceived, handshakeBytes);

            connection = new Connection
            {
                Client = client,
                Stream = stream,
                Reader = new RtmpChunkReader(stream),
                Writer = new RtmpChunkWriter(stream),
                Address = address,
            };

            while (_running && !connection.Closed)
            {
                RtmpMessage? message = connection.Reader.ReadMessage();
                if (message == null)
                {
                    break;
                }

                ReportProgress(connection);
                HandleMessage(connection, message);
            }
        }
        catch (EndOfStreamException)
        {
            // 对端正常关闭
        }
        catch (SocketException ex)
        {
            AppLog.Warn($"RTMP 连接中断: {ex.Message}");
        }
        catch (IOException)
        {
            // 网络中断 / 超时
        }
        catch (ObjectDisposedException)
        {
            // Stop() 关掉了 socket
        }
        catch (InvalidDataException ex)
        {
            AppLog.Warn($"RTMP 数据异常: {ex.Message}");
        }
        catch (Exception ex)
        {
            AppLog.Error("RTMP 连接处理异常", ex);
        }
        finally
        {
            if (connection != null)
            {
                connection.Closed = true;
                try
                {
                    connection.Close();
                }
                catch
                {
                    // 忽略
                }

                HandlePublisherGone(connection, "连接关闭");

                Viewer? viewer = connection.Viewer;
                connection.Viewer = null;
                connection.IsPlaying = false;
                RemoveViewer(viewer);
            }
            else
            {
                try
                {
                    client.Close();
                }
                catch
                {
                    // 忽略
                }
            }
        }
    }

    private void ReportProgress(Connection connection)
    {
        long total = connection.Reader.BytesRead;
        long delta = total - connection.ReportedBytes;
        if (delta > 0)
        {
            connection.ReportedBytes = total;
            Interlocked.Add(ref _bytesReceived, delta);
        }

        if (total - connection.LastAckBytes >= WindowAckSize)
        {
            connection.LastAckBytes = total;
            try
            {
                connection.Writer.WriteUInt32Message(CsidProtocolControl, 3, (uint)total);
            }
            catch (Exception)
            {
                connection.Closed = true;
            }
        }
    }

    // ------------------------------------------------------------ 消息分发

    private void HandleMessage(Connection connection, RtmpMessage message)
    {
        switch (message.TypeId)
        {
            case 1: // Set Chunk Size
                HandleSetChunkSize(connection, message);
                break;

            case 2: // Abort Message
                if (message.Payload.Length >= 4)
                {
                    uint csid = BinaryPrimitives.ReadUInt32BigEndian(message.Payload);
                    connection.Reader.AbortChunk((int)(csid & 0xFFFF));
                }

                break;

            case 3: // Acknowledgement（对端对我们发的数据的确认，忽略）
            case 5: // Window Acknowledgement Size
            case 6: // Set Peer Bandwidth
                break;

            case 4: // User Control（PingResponse 等，无状态处理）
                break;

            case 8:
                HandleAudio(connection, message);
                break;

            case 9:
                HandleVideo(connection, message);
                break;

            case 18:
                HandleData(connection, message);
                break;

            case 17: // AMF3 命令：首字节是 0x00，随后是 AMF0
                if (message.Payload.Length > 0)
                {
                    HandleCommand(connection, message.Payload, 1);
                }

                break;

            case 20:
                HandleCommand(connection, message.Payload, 0);
                break;

            default:
                break;
        }
    }

    private static void HandleSetChunkSize(Connection connection, RtmpMessage message)
    {
        if (message.Payload.Length < 4)
        {
            return;
        }

        uint size = BinaryPrimitives.ReadUInt32BigEndian(message.Payload) & 0x7FFFFFFF;
        if (size == 0)
        {
            return;
        }

        connection.Reader.ChunkSize = (int)Math.Min(size, 0x7FFFFF);
    }

    // ------------------------------------------------------------ 命令

    private void HandleCommand(Connection connection, byte[] payload, int offset)
    {
        List<object?> values = Amf0.DecodeValues(payload, offset);
        if (values.Count == 0)
        {
            return;
        }

        string name = Amf0.AsString(values[0]) ?? string.Empty;
        double transactionId = values.Count > 1 ? Amf0.AsNumber(values[1]) : 0;

        switch (name)
        {
            case "connect":
                HandleConnect(connection, transactionId);
                break;

            case "releaseStream":
            case "FCPublish":
            case "_checkbw":
                // 客户端只是探路，回一个 _result 免得它卡住
                SendResult(connection, transactionId, (object?)null);
                break;

            case "createStream":
                // 注意：_result 的附加参数必须只有 streamId（ffmpeg 会按
                // "_result"/txn/null/number 四个值严格解析）
                SendResult(connection, transactionId, 1.0);
                break;

            case "publish":
                HandlePublish(connection, transactionId, GetName(values));
                break;

            case "play":
                HandlePlay(connection, transactionId, GetName(values));
                break;

            case "deleteStream":
            case "closeStream":
            case "FCUnpublish":
                HandleTeardown(connection);
                connection.Close();
                break;

            case "getStreamLength":
                SendResult(connection, transactionId, 0.0);
                break;

            default:
                AppLog.Warn($"忽略未知 RTMP 命令: {name}");
                break;
        }
    }

    private static string? GetName(List<object?> values)
    {
        // publish / play 的第 4 个值（index 3）是流名
        return values.Count > 3 ? Amf0.AsString(values[3]) : null;
    }

    private void HandleConnect(Connection connection, double transactionId)
    {
        // 窗口 / 带宽 / chunk 大小
        SendWindowAckSize(connection, WindowAckSize);
        SendSetPeerBandwidth(connection, WindowAckSize, 2);
        SendSetChunkSize(connection, OutChunkSize);

        var properties = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["fmsVer"] = "FMS/3,0,1,123",
            ["capabilities"] = 31.0,
        };

        var information = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["level"] = "status",
            ["code"] = "NetConnection.Connect.Success",
            ["description"] = "Connection succeeded.",
            ["objectEncoding"] = 0.0,
        };

        var buffer = new List<byte>(64);
        Amf0.WriteString(buffer, "_result");
        Amf0.WriteNumber(buffer, transactionId);
        Amf0.WriteObject(buffer, properties);
        Amf0.WriteObject(buffer, information);
        connection.Writer.WriteMessage(CsidCommand, 20, 0, 0, buffer.ToArray());

        // 注意：不发 onBWDone —— 那是 FMS 的遗留命令，ffmpeg 会把它当成
        // "Unexpected reply on connect()"。OBS/ffmpeg 都不需要它。
    }

    private void HandlePublish(Connection connection, double transactionId, string? streamName)
    {
        if (!IsLocalPublisher(connection))
        {
            AppLog.Warn($"拒绝非本机发布: {connection.RemoteIp}");
            SendStatus(connection, 1, "error", "NetStream.Publish.Denied", $"拒绝非本机发布: {connection.RemoteIp}");
            connection.Close();
            return;
        }

        if (!IsPathMatch(streamName))
        {
            AppLog.Warn($"发布路径不匹配: {streamName} · 期望 {Path}");
            SendStatus(connection, 1, "error", "NetStream.Publish.BadName", $"流名不匹配: {streamName}");
            connection.Close();
            return;
        }

        bool busy;
        lock (_sync)
        {
            busy = _publisher != null && !ReferenceEquals(_publisher, connection);
            if (!busy)
            {
                _publisher = connection;
                connection.IsPublisher = true;
                if (_running)
                {
                    _state = RtmpServerState.Publishing;
                }
            }
        }

        if (busy)
        {
            AppLog.Warn("已有发布者在线，拒绝新的 publish");
            SendStatus(connection, 1, "error", "NetStream.Publish.BadName", "已有发布者在线");
            connection.Close();
            return;
        }

        SendStatus(connection, 1, "status", "NetStream.Publish.Start", "Start publishing.");
        AppLog.Info($"OBS 已发布 · {Path}");
        Fire(PublisherConnected);
    }

    private void HandlePlay(Connection connection, double transactionId, string? streamName)
    {
        _ = transactionId;

        if (connection.IsPublisher)
        {
            SendStatus(connection, 1, "error", "NetStream.Play.Failed", "该连接正在发布");
            return;
        }

        if (!IsPathMatch(streamName))
        {
            AppLog.Warn($"播放路径不匹配: {streamName} · 期望 {Path}");
            SendStatus(connection, 1, "error", "NetStream.Play.StreamNotFound", $"找不到流: {streamName}");
            connection.Close();
            return;
        }

        if (connection.IsPlaying)
        {
            return;
        }

        // 没有发布者时立刻拒绝：否则播放器（ffmpeg/手机）会一直挂着等流，
        // 表现成"拉流卡死"。有发布者但还没有关键帧时仍然放行，等 IDR 到达。
        bool hasPublisher;
        lock (_sync)
        {
            hasPublisher = _publisher != null;
        }

        if (!hasPublisher)
        {
            AppLog.Warn($"拒绝播放（无人推流）: {connection.RemoteIp}");
            SendStatus(connection, 1, "error", "NetStream.Play.StreamNotFound", "还没有推流，请先开始输出");
            connection.Close();
            return;
        }

        SendSetChunkSize(connection, OutChunkSize);
        SendStatus(connection, 1, "status", "NetStream.Play.Reset", "Playing and resetting stream.");
        SendStatus(connection, 1, "status", "NetStream.Play.Start", "Started playing stream.");
        SendUserControl(connection, 0, 1); // StreamBegin

        var viewer = new Viewer(this, connection);
        connection.IsPlaying = true;
        connection.Viewer = viewer;

        int count;
        lock (_sync)
        {
            // 缓存补发：metadata -> AVC/AAC sequence header -> 最近一个 GOP -> 最近音频
            if (_metadata != null)
            {
                viewer.EnqueueInitial(new CachedPacket(18, 0, 1, _metadata));
            }

            if (_avcSeqMessage != null)
            {
                viewer.EnqueueInitial(_avcSeqMessage);
            }

            if (_aacSeqMessage != null)
            {
                viewer.EnqueueInitial(_aacSeqMessage);
            }

            foreach (CachedPacket packet in _gop)
            {
                viewer.EnqueueInitial(packet);
            }

            foreach (CachedPacket packet in _audioCache)
            {
                viewer.EnqueueInitial(packet);
            }

            _viewers.Add(viewer);
            _viewerCount = _viewers.Count;
            count = _viewerCount;
        }

        viewer.StartPump();
        AppLog.Info($"新播放器接入 ({count})");
        Fire(ViewerCountChanged, count);
    }

    private void HandleTeardown(Connection connection)
    {
        HandlePublisherGone(connection, "客户端请求停止");

        Viewer? viewer = connection.Viewer;
        connection.Viewer = null;
        connection.IsPlaying = false;
        RemoveViewer(viewer);
    }

    private void HandlePublisherGone(Connection connection, string reason)
    {
        bool wasPublisher;
        lock (_sync)
        {
            wasPublisher = ReferenceEquals(_publisher, connection);
            if (wasPublisher)
            {
                _publisher = null;
                connection.IsPublisher = false;
                if (_running)
                {
                    _state = RtmpServerState.Listening;
                }
            }
        }

        if (!wasPublisher)
        {
            return;
        }

        AppLog.Info($"发布者断开（{reason}）");

        // 通知所有播放器停止，但保留缓存：重新推流后无需重连
        var status = new CachedPacket(
            20,
            0,
            1,
            BuildStatus("status", "NetStream.Unpublish.Success", "Stream is now unpublished."));
        Broadcast(status);

        Fire(PublisherDisconnected);
    }

    // ------------------------------------------------------------ 媒体

    private void HandleVideo(Connection connection, RtmpMessage message)
    {
        if (!connection.IsPublisher)
        {
            return;
        }

        byte[] payload = message.Payload;
        if (payload.Length < 5)
        {
            AppLog.Warn("收到过短的视频消息，已忽略");
            return;
        }

        // FLV VideoTagBody（RTMP/FLV 规范）：
        //   [0]      frameType(高 4 位) | codecId(低 4 位)
        //   [1]      AVCPacketType（0=sequence header, 1=NALU, 2=end of sequence）
        //   [2..4]   composition time（有符号 24 位，ms）
        //   [5..]    数据（sequence header 时是 AVCDecoderConfigurationRecord）
        int frameType = payload[0] >> 4;
        int codecId = payload[0] & 0x0F;
        if (codecId != 7)
        {
            AppLog.Warn($"不支持的视频编码 (codecId={codecId})，仅支持 H.264，断开发布者");
            connection.Close();
            return;
        }

        byte packetType = payload[1];
        int compositionTime = ReadInt24Signed(payload, 2);
        uint timestamp = message.Timestamp;

        if (packetType == 0)
        {
            // AVC sequence header（AVCDecoderConfigurationRecord）
            var record = new byte[Math.Max(payload.Length - 5, 0)];
            if (record.Length > 0)
            {
                Buffer.BlockCopy(payload, 5, record, 0, record.Length);
            }

            var cached = new CachedPacket(9, timestamp, 1, payload);
            lock (_sync)
            {
                _avcSeqMessage = cached;
            }

            Broadcast(cached);
            Fire(AvcSequenceHeader, record);
            AppLog.Info($"收到 AVC sequence header ({record.Length} 字节)");
            return;
        }

        if (packetType != 1)
        {
            // 2 = end of sequence，忽略
            return;
        }

        // 媒体负载 = 5 字节 FLV 视频头之后，保留 AVCC 的 4 字节长度前缀
        var avcc = new byte[payload.Length - 5];
        Buffer.BlockCopy(payload, 5, avcc, 0, avcc.Length);

        bool keyframe = frameType == 1;
        var packet = new CachedPacket(9, timestamp, 1, payload);
        lock (_sync)
        {
            UpdateGop(packet, keyframe);
        }

        Broadcast(packet);

        Fire(VideoPacket, new RtmpVideoPacketEventArgs
        {
            AvccData = avcc,
            DtsUs = (long)timestamp * 1000L,
            PtsUs = (long)(timestamp + compositionTime) * 1000L,
            Keyframe = keyframe,
        });
    }

    private void HandleAudio(Connection connection, RtmpMessage message)
    {
        if (!connection.IsPublisher)
        {
            return;
        }

        byte[] payload = message.Payload;
        if (payload.Length < 2)
        {
            return;
        }

        int soundFormat = payload[0] >> 4;
        if (soundFormat != 10)
        {
            AppLog.Warn($"不支持的音频编码 (soundFormat={soundFormat})，仅支持 AAC，断开发布者");
            connection.Close();
            return;
        }

        byte packetType = payload[1];
        uint timestamp = message.Timestamp;

        if (packetType == 0)
        {
            // AAC sequence header（AudioSpecificConfig）
            var config = new byte[payload.Length - 2];
            Buffer.BlockCopy(payload, 2, config, 0, config.Length);

            var cached = new CachedPacket(8, timestamp, 1, payload);
            lock (_sync)
            {
                _aacSeqMessage = cached;
            }

            Broadcast(cached);
            Fire(AacSequenceHeader, config);
            AppLog.Info($"收到 AAC sequence header ({config.Length} 字节)");
            return;
        }

        if (packetType != 1)
        {
            return;
        }

        var raw = new byte[payload.Length - 2];
        Buffer.BlockCopy(payload, 2, raw, 0, raw.Length);

        var packet = new CachedPacket(8, timestamp, 1, payload);
        lock (_sync)
        {
            _audioCache.Enqueue(packet);
            while (_audioCache.Count > AudioCacheLimit)
            {
                _audioCache.Dequeue();
            }
        }

        Broadcast(packet);

        Fire(AudioPacket, new RtmpAudioPacketEventArgs
        {
            RawAac = raw,
            PtsUs = (long)timestamp * 1000L,
        });
    }

    private void HandleData(Connection connection, RtmpMessage message)
    {
        byte[] payload = message.Payload;
        if (payload.Length == 0)
        {
            return;
        }

        int pos = 0;
        object? first = Amf0.ReadValue(payload, ref pos);
        string? name = Amf0.AsString(first);

        if (string.Equals(name, "@setDataFrame", StringComparison.Ordinal))
        {
            if (pos >= payload.Length)
            {
                return;
            }

            var rest = new byte[payload.Length - pos];
            Buffer.BlockCopy(payload, pos, rest, 0, rest.Length);
            StoreMetadata(connection, rest, message.Timestamp);
            return;
        }

        if (string.Equals(name, "onMetaData", StringComparison.Ordinal))
        {
            StoreMetadata(connection, payload, message.Timestamp);
        }
    }

    private void StoreMetadata(Connection connection, byte[] amf0Payload, uint timestamp)
    {
        if (!connection.IsPublisher)
        {
            return;
        }

        var packet = new CachedPacket(18, timestamp, 1, amf0Payload);
        lock (_sync)
        {
            _metadata = amf0Payload;
        }

        Broadcast(packet);

        Fire(Metadata, new RtmpMetadataEventArgs
        {
            Amf0Payload = amf0Payload,
            PtsUs = (long)timestamp * 1000L,
        });

        AppLog.Info("收到 onMetaData");
    }

    // ------------------------------------------------------------ 缓存

    /// <summary>从最近一个关键帧开始缓存视频帧（上限 120 帧 / 8 MiB）。</summary>
    private void UpdateGop(CachedPacket packet, bool keyframe)
    {
        if (keyframe)
        {
            _gop.Clear();
            _gopBytes = 0;
        }
        else if (_gop.Count == 0)
        {
            return; // 还没遇到过关键帧，先不缓存
        }

        if (_gop.Count >= GopFrameLimit)
        {
            return;
        }

        if (_gopBytes + packet.Payload.Length > GopByteLimit)
        {
            return;
        }

        _gop.Add(packet);
        _gopBytes += packet.Payload.Length;
    }

    // ------------------------------------------------------------ 分发

    private void Broadcast(CachedPacket packet)
    {
        Viewer[] snapshot;
        lock (_sync)
        {
            if (_viewers.Count == 0)
            {
                return;
            }

            snapshot = _viewers.ToArray();
        }

        foreach (Viewer viewer in snapshot)
        {
            if (!viewer.EnqueueLive(packet))
            {
                if (viewer.LivePending >= ViewerQueueLimit)
                {
                    AppLog.Warn("播放器发送队列积压超限，断开该播放器");
                }

                RemoveViewer(viewer);
            }
        }
    }

    private void RemoveViewer(Viewer? viewer)
    {
        if (viewer == null)
        {
            return;
        }

        bool removed;
        int count;
        lock (_sync)
        {
            removed = _viewers.Remove(viewer);
            _viewerCount = _viewers.Count;
            count = _viewerCount;
        }

        viewer.Closed = true;
        viewer.CloseSession();
        viewer.Complete();

        if (!removed)
        {
            return;
        }

        AppLog.Info($"播放器断开，当前 {count}");
        Fire(ViewerCountChanged, count);
    }

    // ------------------------------------------------------------ 协议输出

    private static void SendWindowAckSize(Connection connection, uint size) =>
        connection.Writer.WriteUInt32Message(CsidProtocolControl, 5, size);

    private static void SendSetChunkSize(Connection connection, int size)
    {
        connection.Writer.WriteUInt32Message(CsidProtocolControl, 1, (uint)size);
        connection.Writer.ChunkSize = size;
    }

    private static void SendSetPeerBandwidth(Connection connection, uint size, byte limitType)
    {
        var payload = new byte[5];
        BinaryPrimitives.WriteUInt32BigEndian(payload, size);
        payload[4] = limitType;
        connection.Writer.WriteMessage(CsidProtocolControl, 6, 0, 0, payload);
    }

    private static void SendUserControl(Connection connection, ushort eventType, uint data)
    {
        var payload = new byte[6];
        BinaryPrimitives.WriteUInt16BigEndian(payload, eventType);
        BinaryPrimitives.WriteUInt32BigEndian(payload.AsSpan(2), data);
        connection.Writer.WriteMessage(CsidProtocolControl, 4, 0, 0, payload);
    }

    private static byte[] BuildStatus(string level, string code, string description)
    {
        var info = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["level"] = level,
            ["code"] = code,
            ["description"] = description,
            ["clientid"] = "1",
        };

        var buffer = new List<byte>(96);
        Amf0.WriteString(buffer, "onStatus");
        Amf0.WriteNumber(buffer, 0);
        Amf0.WriteNull(buffer);
        Amf0.WriteObject(buffer, info);
        return buffer.ToArray();
    }

    private static void SendStatus(Connection connection, uint streamId, string level, string code, string description)
    {
        connection.Writer.WriteMessage(CsidData, 20, 0, streamId, BuildStatus(level, code, description));
    }

    private static void SendResult(Connection connection, double transactionId, params object?[]? values)
    {
        var buffer = new List<byte>(64);
        Amf0.WriteString(buffer, "_result");
        Amf0.WriteNumber(buffer, transactionId);
        Amf0.WriteNull(buffer);
        if (values != null)
        {
            foreach (object? value in values)
            {
                Amf0.WriteValue(buffer, value);
            }
        }

        connection.Writer.WriteMessage(CsidCommand, 20, 0, 0, buffer.ToArray());
    }

    // ------------------------------------------------------------ 小工具

    private static bool IsLocalPublisher(Connection connection) => IPAddress.IsLoopback(connection.Address);

    private bool IsPathMatch(string? streamName)
    {
        if (string.IsNullOrWhiteSpace(streamName))
        {
            return false;
        }

        string actual = NormalizePath(streamName);
        string expected = Path;
        if (string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // OBS 里「服务器」填 rtmp://ip/live，「串流密钥」只填 reecho 也接受
        int slash = expected.LastIndexOf('/');
        string leaf = slash >= 0 ? expected[(slash + 1)..] : expected;
        return string.Equals(actual, leaf, StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizePath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return "live/douy";
        }

        string text = path.Trim().Replace('\\', '/');
        int cut = text.IndexOfAny(new[] { '?', '#' });
        if (cut >= 0)
        {
            text = text[..cut];
        }

        while (text.Contains("//", StringComparison.Ordinal))
        {
            text = text.Replace("//", "/", StringComparison.Ordinal);
        }

        text = text.Trim('/');
        return text.Length == 0 ? "live/douy" : text;
    }

    private static int ReadInt24Signed(byte[] data, int offset)
    {
        int value = (data[offset] << 16) | (data[offset + 1] << 8) | data[offset + 2];
        if ((value & 0x800000) != 0)
        {
            value |= unchecked((int)0xFF000000);
        }

        return value;
    }

    private static int CsidFor(byte typeId)
    {
        return typeId switch
        {
            8 => CsidAudio,
            9 => CsidVideo,
            18 => CsidData,
            20 => CsidCommand,
            _ => CsidProtocolControl,
        };
    }

    private static void Fire(Action? handler)
    {
        if (handler == null)
        {
            return;
        }

        try
        {
            handler();
        }
        catch (Exception ex)
        {
            AppLog.Error("RTMP 事件处理异常", ex);
        }
    }

    private static void Fire<T>(Action<T>? handler, T argument)
    {
        if (handler == null)
        {
            return;
        }

        try
        {
            handler(argument);
        }
        catch (Exception ex)
        {
            AppLog.Error("RTMP 事件处理异常", ex);
        }
    }

    // ------------------------------------------------------------ 内部类型

    private sealed class CachedPacket
    {
        public CachedPacket(byte typeId, uint timestamp, uint streamId, byte[] payload)
        {
            TypeId = typeId;
            Timestamp = timestamp;
            StreamId = streamId;
            Payload = payload;
        }

        public byte TypeId { get; }

        public uint Timestamp { get; }

        public uint StreamId { get; }

        public byte[] Payload { get; }
    }

    private sealed class Connection
    {
        public TcpClient Client { get; init; } = null!;
        public Stream Stream { get; init; } = null!;
        public RtmpChunkReader Reader { get; init; } = null!;
        public RtmpChunkWriter Writer { get; init; } = null!;
        public IPAddress Address { get; init; } = IPAddress.Loopback;

        public string RemoteIp => Address.ToString();
        public bool IsPublisher { get; set; }
        public bool IsPlaying { get; set; }
        public Viewer? Viewer { get; set; }
        public long ReportedBytes { get; set; }
        public long LastAckBytes { get; set; }
        public volatile bool Closed;

        public void Close()
        {
            Closed = true;
            try
            {
                Client.Client?.Shutdown(SocketShutdown.Both);
            }
            catch
            {
                // 忽略
            }

            try
            {
                Client.Close();
            }
            catch
            {
                // 忽略
            }
        }
    }

    /// <summary>播放器队列里的一项：包 + 是否属于实时广播（补发的缓存不计入积压上限）。</summary>
    private readonly struct OutItem
    {
        public OutItem(CachedPacket packet, bool live)
        {
            Packet = packet;
            Live = live;
        }

        public CachedPacket Packet { get; }

        public bool Live { get; }
    }

    private sealed class Viewer
    {
        private readonly RtmpServer _server;
        private readonly BlockingCollection<OutItem> _queue =
            new(new ConcurrentQueue<OutItem>(), ViewerQueueCapacity);

        private int _livePending;

        public Viewer(RtmpServer server, Connection connection)
        {
            _server = server;
            Connection = connection;
        }

        public Connection Connection { get; }

        public int Pending => _queue.Count;

        /// <summary>当前还没写出去的实时帧数（用于判断积压）。</summary>
        public int LivePending => Volatile.Read(ref _livePending);

        public volatile bool Closed;

        /// <summary>补发缓存用：直接入队（缓存总量有限，不受实时队列上限约束）。</summary>
        public void EnqueueInitial(CachedPacket packet)
        {
            if (Closed)
            {
                return;
            }

            _queue.TryAdd(new OutItem(packet, false));
        }

        /// <summary>实时广播用：积压超过上限时返回 false，由调用方断开。</summary>
        public bool EnqueueLive(CachedPacket packet)
        {
            if (Closed)
            {
                return false;
            }

            if (Interlocked.Increment(ref _livePending) > ViewerQueueLimit)
            {
                Interlocked.Decrement(ref _livePending);
                return false;
            }

            if (_queue.TryAdd(new OutItem(packet, true)))
            {
                return true;
            }

            Interlocked.Decrement(ref _livePending);
            return false;
        }

        public void StartPump()
        {
            var thread = new Thread(Pump)
            {
                IsBackground = true,
                Name = "rtmp-viewer",
            };
            thread.Start();
        }

        public void Complete()
        {
            try
            {
                _queue.CompleteAdding();
            }
            catch (Exception)
            {
                // 忽略
            }
        }

        public void Shutdown()
        {
            Closed = true;
            Complete();
            try
            {
                Connection.Close();
            }
            catch
            {
                // 忽略
            }
        }

        public void CloseSession()
        {
            try
            {
                Connection.Close();
            }
            catch
            {
                // 忽略
            }
        }

        private void Pump()
        {
            try
            {
                foreach (OutItem item in _queue.GetConsumingEnumerable())
                {
                    if (item.Live)
                    {
                        Interlocked.Decrement(ref _livePending);
                    }

                    if (Closed)
                    {
                        break;
                    }

                    CachedPacket packet = item.Packet;
                    Connection.Writer.WriteMessage(
                        CsidFor(packet.TypeId),
                        packet.TypeId,
                        packet.Timestamp,
                        packet.StreamId,
                        packet.Payload);
                }
            }
            catch (ObjectDisposedException)
            {
                // 连接已关闭
            }
            catch (IOException)
            {
                // 网络断开
            }
            catch (Exception ex)
            {
                if (!Closed)
                {
                    AppLog.Warn($"播放器发送失败: {ex.Message}");
                }
            }
            finally
            {
                _server.RemoveViewer(this);
            }
        }
    }
}
