namespace DOUY.Pc.Rtmp;

public enum RtmpServerState
{
    Idle,
    Listening,
    Publishing,
}

/// <summary>RTMP 视频包（AVCC 长度前缀，尚未转 Annex-B）。</summary>
public sealed class RtmpVideoPacketEventArgs : EventArgs
{
    /// <summary>FLV AVC packet body 去掉前 5 字节（frametype/codecid/compositiontime）后的数据：
    /// 4 字节大端长度 + NAL，可重复。</summary>
    public byte[] AvccData { get; init; } = Array.Empty<byte>();

    public long DtsUs { get; init; }
    public long PtsUs { get; init; }
    public bool Keyframe { get; init; }
}

/// <summary>RTMP 音频包（裸 AAC 访问单元，尚未加 ADTS）。</summary>
public sealed class RtmpAudioPacketEventArgs : EventArgs
{
    public byte[] RawAac { get; init; } = Array.Empty<byte>();
    public long PtsUs { get; init; }
}

/// <summary>RTMP 元数据（onMetaData 的 AMF0 负载，原样）。</summary>
public sealed class RtmpMetadataEventArgs : EventArgs
{
    public byte[] Amf0Payload { get; init; } = Array.Empty<byte>();
    public long PtsUs { get; init; }
}

/// <summary>
/// 极简 RTMP 服务端：接收 OBS / ffmpeg 推流，并向任意 RTMP 播放器分发。
///
/// 契约（由 Rtmp/RtmpServer.cs 实现）：
///   * 仅允许本机发布（127.0.0.1 / ::1），任意 IP 播放；
///   * 只接受 H.264 + AAC，其它编码直接断开；
///   * 内部缓存 AVC/AAC sequence header 与最近一个 GOP，
///     新播放器接入后立即补发（先 seq header，再 GOP 内各帧）；
///   * 时间戳统一换成微秒（毫秒 * 1000）后抛事件。
/// </summary>
public interface IRtmpServer : IDisposable
{
    RtmpServerState State { get; }
    int Port { get; }
    string Path { get; }
    int ViewerCount { get; }
    long BytesReceived { get; }

    event Action? PublisherConnected;
    event Action? PublisherDisconnected;
    event Action<int>? ViewerCountChanged;
    event Action<byte[]>? AvcSequenceHeader;
    event Action<byte[]>? AacSequenceHeader;
    event Action<RtmpVideoPacketEventArgs>? VideoPacket;
    event Action<RtmpAudioPacketEventArgs>? AudioPacket;
    event Action<RtmpMetadataEventArgs>? Metadata;

    void Start(int port, string path = "live/douy");
    void Stop();
}
