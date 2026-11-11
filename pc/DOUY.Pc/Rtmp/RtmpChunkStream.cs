using System.Buffers.Binary;

namespace DOUY.Pc.Rtmp;

/// <summary>一条完整的 RTMP 消息（已经把 chunk 重新拼装好）。</summary>
public sealed class RtmpMessage
{
    public int Csid { get; init; }
    public byte TypeId { get; init; }
    public uint Timestamp { get; init; }
    public uint StreamId { get; init; }
    public byte[] Payload { get; init; } = Array.Empty<byte>();

    public override string ToString() =>
        $"type={TypeId} csid={Csid} ts={Timestamp} stream={StreamId} len={Payload.Length}";
}

/// <summary>RTMP 服务端简单握手（C0/C1 -> S0/S1/S2 -> C2）。</summary>
public static class RtmpHandshake
{
    public const int HandshakeSize = 1536;

    /// <summary>
    /// 执行服务端握手。返回本次握手读到的字节数（用于统计）。
    /// 只校验长度，不校验 C1/C2 的内容（纯 RTMP，不支持加密握手）。
    /// </summary>
    public static long ServerHandshake(Stream stream)
    {
        // C0(1) + C1(1536)
        var c0c1 = new byte[1 + HandshakeSize];
        ReadExactly(stream, c0c1);

        // S0 + S1 + S2
        var s0s1s2 = new byte[1 + HandshakeSize * 2];
        s0s1s2[0] = 3; // 版本

        // S1: 4 字节时间 + 4 字节零 + 1528 字节随机数
        s0s1s2[1] = 0;
        s0s1s2[2] = 0;
        s0s1s2[3] = 0;
        s0s1s2[4] = 0;
        // s0s1s2[5..9] 保持 0
        Random.Shared.NextBytes(s0s1s2.AsSpan(9, HandshakeSize - 8));

        // S2: 原样回 C1
        Buffer.BlockCopy(c0c1, 1, s0s1s2, 1 + HandshakeSize, HandshakeSize);

        stream.Write(s0s1s2, 0, s0s1s2.Length);
        stream.Flush();

        // C2 (1536) —— 只校验长度
        var c2 = new byte[HandshakeSize];
        ReadExactly(stream, c2);

        return c0c1.Length + c2.Length;
    }

    internal static void ReadExactly(Stream stream, byte[] buffer)
    {
        int read = 0;
        while (read < buffer.Length)
        {
            int n = stream.Read(buffer, read, buffer.Length - read);
            if (n <= 0)
            {
                throw new EndOfStreamException("RTMP 握手期间连接被关闭");
            }

            read += n;
        }
    }
}

/// <summary>
/// RTMP chunk 读取器：把 chunk 流还原成一条条完整消息。
/// 支持 fmt0..fmt3、扩展时间戳、SetChunkSize 生效、type 22 聚合消息拆包。
/// 非线程安全：只允许同一个连接线程调用。
/// </summary>
public sealed class RtmpChunkReader
{
    private const int MaxMessageLength = 16 * 1024 * 1024;

    private sealed class ChunkState
    {
        public uint Timestamp;
        public uint Delta;
        public int Length;
        public byte TypeId;
        public uint StreamId;
        public byte[]? Buffer;
        public int Received;
        public bool UseExtendedTimestamp;
        public bool HasHeader;
    }

    private readonly Stream _stream;
    private readonly Dictionary<int, ChunkState> _states = new();
    private readonly Queue<RtmpMessage> _queue = new();

    /// <summary>复用的小缓冲区，避免在 chunk 循环里反复 stackalloc（会累积栈空间）。</summary>
    private readonly byte[] _scratch = new byte[18];
    private int _chunkSize = 128;

    public RtmpChunkReader(Stream stream)
    {
        _stream = stream ?? throw new ArgumentNullException(nameof(stream));
    }

    /// <summary>本连接的 chunk 大小（对端可通过 SetChunkSize 修改）。</summary>
    public int ChunkSize
    {
        get => _chunkSize;
        set => _chunkSize = Math.Clamp(value, 1, 0x7FFFFF);
    }

    /// <summary>累计读到的字节数（含 chunk 头）。</summary>
    public long BytesRead { get; private set; }

    /// <summary>
    /// 读一条完整消息；连接正常关闭时返回 null。
    /// </summary>
    public RtmpMessage? ReadMessage()
    {
        while (true)
        {
            if (_queue.Count > 0)
            {
                return _queue.Dequeue();
            }

            RtmpMessage? message = ReadOneMessage();
            if (message == null)
            {
                return null;
            }

            if (message.TypeId != 22)
            {
                return message;
            }

            // 聚合消息：拆成若干条普通消息登记到队列里
            List<RtmpMessage> parts = SplitAggregate(message);
            if (parts.Count == 0)
            {
                continue;
            }

            for (int i = 1; i < parts.Count; i++)
            {
                _queue.Enqueue(parts[i]);
            }

            return parts[0];
        }
    }

    /// <summary>Abort 消息：丢弃该 csid 上未收完的消息。</summary>
    public void AbortChunk(int csid)
    {
        if (_states.TryGetValue(csid, out ChunkState? state))
        {
            state.Buffer = null;
            state.Received = 0;
        }
    }

    private RtmpMessage? ReadOneMessage()
    {
        while (true)
        {
            // ---- basic header
            if (!TryReadByte(out byte basicHeader))
            {
                return null;
            }

            int fmt = (basicHeader >> 6) & 0x03;
            int csid = basicHeader & 0x3F;
            if (csid == 0)
            {
                Span<byte> one = _scratch.AsSpan(0, 1);
                ReadExact(one);
                csid = 64 + one[0];
            }
            else if (csid == 1)
            {
                Span<byte> two = _scratch.AsSpan(0, 2);
                ReadExact(two);
                csid = 64 + BinaryPrimitives.ReadUInt16LittleEndian(two);
            }

            ChunkState state = GetState(csid);

            // ---- message header
            switch (fmt)
            {
                case 0:
                {
                    Span<byte> head = _scratch.AsSpan(0, 11);
                    ReadExact(head);
                    uint timestamp = ReadUInt24(head);
                    int length = (int)ReadUInt24(head[3..]);
                    byte typeId = head[6];
                    uint streamId = BinaryPrimitives.ReadUInt32LittleEndian(head[7..]);

                    bool extended = timestamp == 0xFFFFFF;
                    if (extended)
                    {
                        timestamp = ReadUInt32BigEndian();
                    }

                    state.Timestamp = timestamp;
                    state.Delta = 0;
                    state.Length = ValidateLength(length);
                    state.TypeId = typeId;
                    state.StreamId = streamId;
                    state.UseExtendedTimestamp = extended;
                    state.HasHeader = true;
                    StartMessage(state);
                    break;
                }

                case 1:
                {
                    Span<byte> head = _scratch.AsSpan(0, 7);
                    ReadExact(head);
                    uint delta = ReadUInt24(head);
                    int length = (int)ReadUInt24(head[3..]);
                    byte typeId = head[6];

                    bool extended = delta == 0xFFFFFF;
                    if (extended)
                    {
                        delta = ReadUInt32BigEndian();
                    }

                    state.Timestamp += delta;
                    state.Delta = delta;
                    state.Length = ValidateLength(length);
                    state.TypeId = typeId;
                    state.UseExtendedTimestamp = extended;
                    state.HasHeader = true;
                    StartMessage(state);
                    break;
                }

                case 2:
                {
                    uint delta = ReadUInt24Exact();

                    bool extended = delta == 0xFFFFFF;
                    if (extended)
                    {
                        delta = ReadUInt32BigEndian();
                    }

                    state.Timestamp += delta;
                    state.Delta = delta;
                    state.UseExtendedTimestamp = extended;
                    state.HasHeader = true;
                    StartMessage(state);
                    break;
                }

                default: // fmt 3：沿用上一个头；可能是续块，也可能是一条新消息
                {
                    if (state.UseExtendedTimestamp)
                    {
                        ReadUInt32BigEndian(); // fmt3 续块同样带扩展时间戳，必须读掉
                    }

                    if (state.Buffer == null)
                    {
                        if (!state.HasHeader)
                        {
                            throw new InvalidDataException("RTMP fmt3 分块没有可沿用的消息头");
                        }

                        state.Timestamp += state.Delta;
                        StartMessage(state);
                    }

                    break;
                }
            }

            // ---- payload（本 chunk 最多 chunkSize 字节）
            byte[]? buffer = state.Buffer;
            if (buffer == null)
            {
                throw new InvalidDataException("RTMP chunk 状态异常：缺少消息缓冲区");
            }

            int remaining = state.Length - state.Received;
            int toRead = Math.Min(remaining, _chunkSize);
            if (toRead > 0)
            {
                ReadExact(buffer.AsSpan(state.Received, toRead));
                state.Received += toRead;
            }

            if (state.Received < state.Length)
            {
                continue; // 后面还有续块
            }

            state.Buffer = null;
            state.Received = 0;

            return new RtmpMessage
            {
                Csid = csid,
                TypeId = state.TypeId,
                Timestamp = state.Timestamp,
                StreamId = state.StreamId,
                Payload = buffer,
            };
        }
    }

    private static void StartMessage(ChunkState state)
    {
        state.Buffer = state.Length > 0 ? new byte[state.Length] : Array.Empty<byte>();
        state.Received = 0;
    }

    private static int ValidateLength(int length)
    {
        if (length < 0 || length > MaxMessageLength)
        {
            throw new InvalidDataException($"RTMP 消息长度异常: {length}");
        }

        return length;
    }

    private ChunkState GetState(int csid)
    {
        if (!_states.TryGetValue(csid, out ChunkState? state))
        {
            state = new ChunkState();
            _states[csid] = state;
        }

        return state;
    }

    /// <summary>把 type 22 聚合消息拆成 FLV tag 对应的普通消息。</summary>
    private static List<RtmpMessage> SplitAggregate(RtmpMessage message)
    {
        var result = new List<RtmpMessage>(4);
        byte[] data = message.Payload;
        int pos = 0;
        while (pos + 11 <= data.Length)
        {
            byte typeId = data[pos];
            int length = (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
            uint timestamp = (uint)((data[pos + 4] << 24) | (data[pos + 5] << 16) | (data[pos + 6] << 8) | data[pos + 7]);
            // data[pos + 8..11] 是 3 字节 stream id（对 FLV tag 无意义）

            pos += 11;
            if (length < 0 || pos + length > data.Length)
            {
                break;
            }

            var payload = new byte[length];
            if (length > 0)
            {
                Buffer.BlockCopy(data, pos, payload, 0, length);
            }

            pos += length;
            pos += 4; // PreviousTagSize

            if (timestamp == 0xFFFFFFFF)
            {
                timestamp = message.Timestamp;
            }

            result.Add(new RtmpMessage
            {
                Csid = message.Csid,
                TypeId = typeId,
                Timestamp = timestamp,
                StreamId = message.StreamId,
                Payload = payload,
            });
        }

        return result;
    }

    // ------------------------------------------------------------ 底层读取

    private bool TryReadByte(out byte value)
    {
        int b = _stream.ReadByte();
        if (b < 0)
        {
            value = 0;
            return false;
        }

        value = (byte)b;
        BytesRead++;
        return true;
    }

    private void ReadExact(Span<byte> buffer)
    {
        int read = 0;
        while (read < buffer.Length)
        {
            int n = _stream.Read(buffer[read..]);
            if (n <= 0)
            {
                throw new EndOfStreamException("RTMP 连接已关闭");
            }

            read += n;
            BytesRead += n;
        }
    }

    private uint ReadUInt32BigEndian()
    {
        Span<byte> buffer = _scratch.AsSpan(0, 4);
        ReadExact(buffer);
        return BinaryPrimitives.ReadUInt32BigEndian(buffer);
    }

    private uint ReadUInt24Exact()
    {
        Span<byte> buffer = _scratch.AsSpan(0, 3);
        ReadExact(buffer);
        return ReadUInt24(buffer);
    }

    private static uint ReadUInt24(ReadOnlySpan<byte> data) =>
        (uint)((data[0] << 16) | (data[1] << 8) | data[2]);
}

/// <summary>
/// RTMP chunk 写入器：一条消息按 fmt0 头 + fmt3 续块输出，遵守对端 chunk size。
/// 内部有自己的锁，多个线程写同一个连接也不会把字节写串。
/// </summary>
public sealed class RtmpChunkWriter
{
    private readonly Stream _stream;
    private readonly object _gate = new();
    private readonly MemoryStream _buffer = new(8192);
    private int _chunkSize = 128;

    public RtmpChunkWriter(Stream stream)
    {
        _stream = stream ?? throw new ArgumentNullException(nameof(stream));
    }

    /// <summary>本端输出使用的 chunk 大小（发过 SetChunkSize 之后要同步修改）。</summary>
    public int ChunkSize
    {
        get => _chunkSize;
        set => _chunkSize = Math.Clamp(value, 1, 0x7FFFFF);
    }

    public void WriteMessage(int csid, byte typeId, uint timestamp, uint streamId, byte[]? payload)
    {
        payload ??= Array.Empty<byte>();
        int chunkSize = _chunkSize;

        lock (_gate)
        {
            _buffer.SetLength(0);

            bool extended = timestamp >= 0xFFFFFF;
            WriteBasicHeader(0, csid);
            WriteUInt24(extended ? 0xFFFFFFu : timestamp);
            WriteUInt24((uint)payload.Length);
            _buffer.WriteByte(typeId);
            Span<byte> streamBytes = stackalloc byte[4];
            BinaryPrimitives.WriteUInt32LittleEndian(streamBytes, streamId);
            _buffer.Write(streamBytes);
            if (extended)
            {
                WriteUInt32(timestamp);
            }

            int offset = 0;
            int first = Math.Min(chunkSize, payload.Length);
            if (first > 0)
            {
                _buffer.Write(payload, 0, first);
                offset = first;
            }

            while (offset < payload.Length)
            {
                WriteBasicHeader(3, csid);
                if (extended)
                {
                    WriteUInt32(timestamp);
                }

                int count = Math.Min(chunkSize, payload.Length - offset);
                _buffer.Write(payload, offset, count);
                offset += count;
            }

            _stream.Write(_buffer.GetBuffer(), 0, (int)_buffer.Length);
            _stream.Flush();
        }
    }

    /// <summary>写一条只有 4 字节负载的控制消息。</summary>
    public void WriteUInt32Message(int csid, byte typeId, uint value)
    {
        var payload = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(payload, value);
        WriteMessage(csid, typeId, 0, 0, payload);
    }

    private void WriteBasicHeader(int fmt, int csid)
    {
        if (csid < 64)
        {
            _buffer.WriteByte((byte)((fmt << 6) | csid));
            return;
        }

        if (csid < 320)
        {
            _buffer.WriteByte((byte)(fmt << 6));
            _buffer.WriteByte((byte)(csid - 64));
            return;
        }

        int value = csid - 64;
        _buffer.WriteByte((byte)((fmt << 6) | 1));
        _buffer.WriteByte((byte)(value & 0xFF));
        _buffer.WriteByte((byte)((value >> 8) & 0xFF));
    }

    private void WriteUInt24(uint value)
    {
        _buffer.WriteByte((byte)(value >> 16));
        _buffer.WriteByte((byte)(value >> 8));
        _buffer.WriteByte((byte)value);
    }

    private void WriteUInt32(uint value)
    {
        _buffer.WriteByte((byte)(value >> 24));
        _buffer.WriteByte((byte)(value >> 16));
        _buffer.WriteByte((byte)(value >> 8));
        _buffer.WriteByte((byte)value);
    }
}
