using System.Text;
using DOUY.Pc.Rtmp;

namespace DOUY.Pc.Media;

/// <summary>
/// 把 RTMP 发布者的数据统一成"可直接上 USB 隧道"的帧：
///   * 视频：AVCC → Annex-B，关键帧前置 SPS/PPS
///   * 音频：裸 AAC → ADTS
/// 并向所有订阅者（USB 会话）分发。
/// </summary>
public sealed class MediaHub : IDisposable
{
    private readonly object _gate = new();
    private readonly List<Action<MediaFrame>> _sinks = new();

    private IRtmpServer? _server;
    private MediaTranscoder.AvcConfig? _avc;
    private MediaTranscoder.AacConfig? _aac;
    private MediaFrame? _lastKeyframe;
    private long _videoFrames;
    private long _audioFrames;

    public MediaTranscoder.AvcConfig? AvcConfig
    {
        get { lock (_gate) { return _avc; } }
    }

    public MediaTranscoder.AacConfig? AacConfig
    {
        get { lock (_gate) { return _aac; } }
    }

    public MediaFrame? LastKeyframe
    {
        get { lock (_gate) { return _lastKeyframe; } }
    }

    public long VideoFrames => Interlocked.Read(ref _videoFrames);
    public long AudioFrames => Interlocked.Read(ref _audioFrames);

    public (int Width, int Height) Resolution
    {
        get
        {
            lock (_gate)
            {
                return _avc == null ? (0, 0) : (_avc.Width, _avc.Height);
            }
        }
    }

    public void Attach(IRtmpServer server)
    {
        lock (_gate)
        {
            _server = server;
        }

        server.AvcSequenceHeader += OnAvcConfig;
        server.AacSequenceHeader += OnAacConfig;
        server.VideoPacket += OnVideo;
        server.AudioPacket += OnAudio;
        server.Metadata += OnMetadata;
        server.PublisherConnected += () => AppLog.Info("收到发布者，开始转换媒体");
        server.PublisherDisconnected += () => AppLog.Warn("发布者已断开，保留缓存等待重连");
    }

    public void Detach()
    {
        IRtmpServer? server;
        lock (_gate)
        {
            server = _server;
            _server = null;
        }

        if (server == null)
        {
            return;
        }

        server.AvcSequenceHeader -= OnAvcConfig;
        server.AacSequenceHeader -= OnAacConfig;
        server.VideoPacket -= OnVideo;
        server.AudioPacket -= OnAudio;
        server.Metadata -= OnMetadata;
    }

    /// <summary>订阅转发出去的帧；返回取消函数。</summary>
    public Action Subscribe(Action<MediaFrame> sink)
    {
        lock (_gate)
        {
            _sinks.Add(sink);
        }

        return () =>
        {
            lock (_gate)
            {
                _sinks.Remove(sink);
            }
        };
    }

    public int SinkCount
    {
        get { lock (_gate) { return _sinks.Count; } }
    }

    private void Emit(MediaFrame frame)
    {
        Action<MediaFrame>[] sinks;
        lock (_gate)
        {
            sinks = _sinks.ToArray();
        }

        foreach (var sink in sinks)
        {
            try
            {
                sink(frame);
            }
            catch (Exception ex)
            {
                AppLog.Error("分发媒体帧失败", ex);
            }
        }
    }

    private void OnAvcConfig(byte[] record)
    {
        var config = MediaTranscoder.ParseAvcConfig(record);
        if (config == null)
        {
            AppLog.Warn($"AVC 配置无效（{record.Length} 字节），忽略");
            return;
        }

        lock (_gate)
        {
            _avc = config;
            _lastKeyframe = null;
        }

        AppLog.Info($"视频参数就绪 · {config.Width}x{config.Height} · SPS {config.Sps.Length}B / PPS {config.Pps.Length}B");

        var meta = Encoding.UTF8.GetBytes($"{{\"kind\":\"video\",\"codec\":\"h264\",\"width\":{config.Width},\"height\":{config.Height}}}");
        Emit(new MediaFrame
        {
            Kind = MediaKind.Meta,
            Payload = meta,
            PtsUs = 0,
            DtsUs = 0,
        });
    }

    private void OnAacConfig(byte[] asc)
    {
        var config = MediaTranscoder.ParseAacConfig(asc);
        if (config == null)
        {
            AppLog.Warn("AAC 配置无效，忽略");
            return;
        }

        lock (_gate)
        {
            _aac = config;
        }

        AppLog.Info($"音频参数就绪 · {config.SampleRate} Hz · {config.Channels} ch · profile {config.Profile}");
    }

    private void OnVideo(RtmpVideoPacketEventArgs e)
    {
        MediaTranscoder.AvcConfig? config;
        lock (_gate)
        {
            config = _avc;
        }

        if (config == null)
        {
            return; // 还没收到 SPS/PPS，先不发明智
        }

        var annexB = MediaTranscoder.AvccToAnnexB(e.AvccData, config, e.Keyframe);
        if (annexB.Length == 0)
        {
            return;
        }

        var frame = new MediaFrame
        {
            Kind = MediaKind.Video,
            Payload = annexB,
            PtsUs = e.PtsUs,
            DtsUs = e.DtsUs,
            Keyframe = e.Keyframe,
        };

        if (e.Keyframe)
        {
            lock (_gate)
            {
                _lastKeyframe = frame;
            }
        }

        Interlocked.Increment(ref _videoFrames);
        Emit(frame);
    }

    private void OnAudio(RtmpAudioPacketEventArgs e)
    {
        MediaTranscoder.AacConfig? config;
        lock (_gate)
        {
            config = _aac;
        }

        if (config == null || e.RawAac.Length == 0)
        {
            return;
        }

        var frame = new MediaFrame
        {
            Kind = MediaKind.Audio,
            Payload = MediaTranscoder.AddAdts(e.RawAac, config),
            PtsUs = e.PtsUs,
            DtsUs = e.PtsUs,
        };

        Interlocked.Increment(ref _audioFrames);
        Emit(frame);
    }

    private void OnMetadata(RtmpMetadataEventArgs e)
    {
        // 元数据（分辨率/帧率等）对 USB 隧道只作日志
        AppLog.Info($"onMetaData {e.Amf0Payload.Length} 字节");
    }

    public void Dispose() => Detach();
}
