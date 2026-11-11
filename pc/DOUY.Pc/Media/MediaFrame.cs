namespace DOUY.Pc.Media;

public enum MediaKind
{
    Video,
    Audio,
    Meta,
}

/// <summary>
/// 一帧待发送的媒体数据（已完成 Annex-B / ADTS 封装，可直接进 FXP/2 载荷）。
/// </summary>
public sealed class MediaFrame
{
    public MediaKind Kind { get; init; }
    public byte[] Payload { get; init; } = Array.Empty<byte>();
    public long PtsUs { get; init; }
    public long DtsUs { get; init; }
    public bool Keyframe { get; init; }

    public int Length => Payload.Length;

    public override string ToString() =>
        $"{Kind} {Payload.Length}B pts={PtsUs / 1000.0:F1}ms dts={DtsUs / 1000.0:F1}ms{(Keyframe ? " KEY" : string.Empty)}";
}
