using System.Buffers.Binary;
using System.Collections;
using System.Text;

namespace DOUY.Pc.Rtmp;

/// <summary>
/// AMF0 编解码（RTMP 命令 / onMetaData 够用的一个子集）。
///
/// 解码支持：number、boolean、string、object、null、undefined、ecma array、
/// strict array、date、long string；
/// 编码支持：number、boolean、string、object、null、ecma array（另带 date / strict array 便于调试）。
/// 所有写入方法都直接追加到 <see cref="List{T}"/>（byte），方便拼装命令负载。
/// </summary>
public static class Amf0
{
    public const byte TypeNumber = 0x00;
    public const byte TypeBoolean = 0x01;
    public const byte TypeString = 0x02;
    public const byte TypeObject = 0x03;
    public const byte TypeMovieClip = 0x04;
    public const byte TypeNull = 0x05;
    public const byte TypeUndefined = 0x06;
    public const byte TypeReference = 0x07;
    public const byte TypeEcmaArray = 0x08;
    public const byte TypeObjectEnd = 0x09;
    public const byte TypeStrictArray = 0x0A;
    public const byte TypeDate = 0x0B;
    public const byte TypeLongString = 0x0C;

    private const int MaxStringLength = 1 << 24;

    // ---------------------------------------------------------------- 解码

    /// <summary>从 <paramref name="pos"/> 读一个 AMF0 值，读完把 pos 移到下一个值的起点。</summary>
    public static object? ReadValue(byte[] data, ref int pos)
    {
        if (data == null || pos < 0 || pos >= data.Length)
        {
            return null;
        }

        byte marker = data[pos++];
        switch (marker)
        {
            case TypeNumber:
            {
                if (pos + 8 > data.Length)
                {
                    pos = data.Length;
                    return null;
                }

                double value = BinaryPrimitives.ReadDoubleBigEndian(data.AsSpan(pos, 8));
                pos += 8;
                return value;
            }

            case TypeBoolean:
            {
                if (pos >= data.Length)
                {
                    return null;
                }

                return data[pos++] != 0;
            }

            case TypeString:
            {
                if (pos + 2 > data.Length)
                {
                    pos = data.Length;
                    return null;
                }

                int length = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(pos, 2));
                pos += 2;
                return ReadUtf8(data, ref pos, length);
            }

            case TypeLongString:
            {
                if (pos + 4 > data.Length)
                {
                    pos = data.Length;
                    return null;
                }

                int length = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(pos, 4));
                pos += 4;
                return ReadUtf8(data, ref pos, length);
            }

            case TypeObject:
            {
                // 对象标记后面还有 4 字节的属性数量（通常为 0），忽略之。
                pos += 4;
                if (pos > data.Length)
                {
                    pos = data.Length;
                    return new Dictionary<string, object?>(StringComparer.Ordinal);
                }

                return ReadObjectBody(data, ref pos, null);
            }

            case TypeEcmaArray:
            {
                if (pos + 4 > data.Length)
                {
                    pos = data.Length;
                    return new Dictionary<string, object?>(StringComparer.Ordinal);
                }

                int count = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(pos, 4));
                pos += 4;
                return ReadObjectBody(data, ref pos, count);
            }

            case TypeNull:
            case TypeUndefined:
            case TypeMovieClip:
            case TypeReference:
                return null;

            case TypeStrictArray:
            {
                if (pos + 4 > data.Length)
                {
                    pos = data.Length;
                    return Array.Empty<object?>();
                }

                int count = BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(pos, 4));
                pos += 4;
                if (count < 0 || count > 1 << 20)
                {
                    count = 0;
                }

                var items = new object?[count];
                for (int i = 0; i < count && pos < data.Length; i++)
                {
                    int before = pos;
                    items[i] = ReadValue(data, ref pos);
                    if (pos <= before)
                    {
                        break;
                    }
                }

                return items;
            }

            case TypeDate:
            {
                if (pos + 10 > data.Length)
                {
                    pos = data.Length;
                    return null;
                }

                double milliseconds = BinaryPrimitives.ReadDoubleBigEndian(data.AsSpan(pos, 8));
                pos += 8;
                pos += 2; // 2 字节时区，忽略
                try
                {
                    return DateTime.UnixEpoch.AddMilliseconds(milliseconds);
                }
                catch (ArgumentOutOfRangeException)
                {
                    return milliseconds;
                }
            }

            default:
                // 不认识的类型：无法推断长度，只能放弃后续内容。
                pos = data.Length;
                return null;
        }
    }

    /// <summary>把整段负载按 AMF0 依次解成列表（命令消息用）。</summary>
    public static List<object?> DecodeValues(byte[] payload, int offset = 0)
    {
        var values = new List<object?>(8);
        if (payload == null || payload.Length == 0)
        {
            return values;
        }

        int pos = Math.Clamp(offset, 0, payload.Length);
        while (pos < payload.Length)
        {
            int before = pos;
            object? value = ReadValue(payload, ref pos);
            if (pos <= before)
            {
                break;
            }

            values.Add(value);
        }

        return values;
    }

    private static Dictionary<string, object?> ReadObjectBody(byte[] data, ref int pos, int? declaredCount)
    {
        int capacity = declaredCount.GetValueOrDefault();
        var result = new Dictionary<string, object?>(capacity > 0 ? capacity : 0, StringComparer.Ordinal);

        while (pos + 2 <= data.Length)
        {
            int nameLength = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(pos, 2));
            pos += 2;

            if (nameLength == 0 && pos < data.Length && data[pos] == TypeObjectEnd)
            {
                pos++; // 对象结束标记
                return result;
            }

            if (nameLength < 0 || pos + nameLength > data.Length)
            {
                pos = data.Length;
                return result;
            }

            string name = Encoding.UTF8.GetString(data, pos, nameLength);
            pos += nameLength;

            if (pos >= data.Length)
            {
                result[name] = null;
                return result;
            }

            result[name] = ReadValue(data, ref pos);
        }

        return result;
    }

    private static string ReadUtf8(byte[] data, ref int pos, int length)
    {
        if (length < 0 || length > MaxStringLength || pos + length > data.Length)
        {
            pos = data.Length;
            return string.Empty;
        }

        string text = Encoding.UTF8.GetString(data, pos, length);
        pos += length;
        return text;
    }

    // ---------------------------------------------------------------- 编码

    public static void WriteNumber(List<byte> buffer, double value)
    {
        buffer.Add(TypeNumber);
        Span<byte> tmp = stackalloc byte[8];
        BinaryPrimitives.WriteDoubleBigEndian(tmp, value);
        Append(buffer, tmp);
    }

    public static void WriteBool(List<byte> buffer, bool value)
    {
        buffer.Add(TypeBoolean);
        buffer.Add(value ? (byte)1 : (byte)0);
    }

    public static void WriteString(List<byte> buffer, string? value)
    {
        value ??= string.Empty;
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        if (bytes.Length <= ushort.MaxValue)
        {
            buffer.Add(TypeString);
            buffer.Add((byte)(bytes.Length >> 8));
            buffer.Add((byte)(bytes.Length & 0xFF));
        }
        else
        {
            buffer.Add(TypeLongString);
            buffer.Add((byte)(bytes.Length >> 24));
            buffer.Add((byte)(bytes.Length >> 16));
            buffer.Add((byte)(bytes.Length >> 8));
            buffer.Add((byte)(bytes.Length & 0xFF));
        }

        Append(buffer, bytes);
    }

    public static void WriteNull(List<byte> buffer)
    {
        buffer.Add(TypeNull);
    }

    public static void WriteUndefined(List<byte> buffer)
    {
        buffer.Add(TypeUndefined);
    }

    /// <summary>
    /// 对象头：只有 0x03 一个字节。
    /// 注意：AMF0 的 object(0x03) **没有** 4 字节属性计数——那是 ecma-array(0x08) 才有的。
    /// 早期版本多写了 4 字节计数，导致 ffmpeg 解析 "level"/"code" 失败（publish 之后直接 EIO）。
    /// </summary>
    public static void WriteObjectHeader(List<byte> buffer, int propertyCount = 0)
    {
        _ = propertyCount; // 仅为兼容调用方签名保留
        buffer.Add(TypeObject);
    }

    /// <summary>ECMA 数组头：0x08 + 4 字节元素数量。</summary>
    public static void WriteEcmaArrayHeader(List<byte> buffer, int count = 0)
    {
        buffer.Add(TypeEcmaArray);
        WriteUInt32(buffer, (uint)Math.Max(count, 0));
    }

    /// <summary>对象 / ECMA 数组的结束标记 00 00 09。</summary>
    public static void WriteObjectEnd(List<byte> buffer)
    {
        buffer.Add(0x00);
        buffer.Add(0x00);
        buffer.Add(TypeObjectEnd);
    }

    public static void WriteDate(List<byte> buffer, DateTime value)
    {
        buffer.Add(TypeDate);
        Span<byte> tmp = stackalloc byte[8];
        double milliseconds = (value.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds;
        BinaryPrimitives.WriteDoubleBigEndian(tmp, milliseconds);
        Append(buffer, tmp);
        buffer.Add(0x00);
        buffer.Add(0x00);
    }

    /// <summary>写属性名：2 字节长度 + UTF8（对象/ECMA 数组内部不带类型标记）。</summary>
    public static void WritePropertyName(List<byte> buffer, string name)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(name ?? string.Empty);
        if (bytes.Length > ushort.MaxValue)
        {
            bytes = bytes[..ushort.MaxValue];
        }

        buffer.Add((byte)(bytes.Length >> 8));
        buffer.Add((byte)(bytes.Length & 0xFF));
        Append(buffer, bytes);
    }

    /// <summary>写一个「属性名 + 值」（不含对象头 / 结束标记）。</summary>
    public static void WriteProperty(List<byte> buffer, string name, object? value)
    {
        WritePropertyName(buffer, name);
        WriteValue(buffer, value);
    }

    /// <summary>写一个完整对象：对象头 + 所有属性 + 结束标记。</summary>
    public static void WriteObject(List<byte> buffer, IEnumerable<KeyValuePair<string, object?>>? properties)
    {
        int count = 0;
        if (properties != null)
        {
            foreach (var _ in properties)
            {
                count++;
            }
        }

        WriteObjectHeader(buffer, count);
        if (properties != null)
        {
            foreach (var pair in properties)
            {
                WriteProperty(buffer, pair.Key, pair.Value);
            }
        }

        WriteObjectEnd(buffer);
    }

    /// <summary>写一个完整 ECMA 数组（onMetaData 用）。</summary>
    public static void WriteEcmaArray(List<byte> buffer, IEnumerable<KeyValuePair<string, object?>>? properties)
    {
        int count = 0;
        if (properties != null)
        {
            foreach (var _ in properties)
            {
                count++;
            }
        }

        WriteEcmaArrayHeader(buffer, count);
        if (properties != null)
        {
            foreach (var pair in properties)
            {
                WriteProperty(buffer, pair.Key, pair.Value);
            }
        }

        WriteObjectEnd(buffer);
    }

    /// <summary>按 CLR 类型自动选择一个 AMF0 编码。</summary>
    public static void WriteValue(List<byte> buffer, object? value)
    {
        switch (value)
        {
            case null:
            case DBNull:
                WriteNull(buffer);
                return;

            case bool b:
                WriteBool(buffer, b);
                return;

            case string s:
                WriteString(buffer, s);
                return;

            case double d:
                WriteNumber(buffer, d);
                return;

            case float f:
                WriteNumber(buffer, f);
                return;

            case decimal m:
                WriteNumber(buffer, (double)m);
                return;

            case byte by:
                WriteNumber(buffer, by);
                return;

            case sbyte sb:
                WriteNumber(buffer, sb);
                return;

            case short sh:
                WriteNumber(buffer, sh);
                return;

            case ushort us:
                WriteNumber(buffer, us);
                return;

            case int i:
                WriteNumber(buffer, i);
                return;

            case uint ui:
                WriteNumber(buffer, ui);
                return;

            case long l:
                WriteNumber(buffer, l);
                return;

            case ulong ul:
                WriteNumber(buffer, ul);
                return;

            case DateTime dt:
                WriteDate(buffer, dt);
                return;

            case byte[] raw:
            {
                buffer.Add(TypeStrictArray);
                WriteUInt32(buffer, (uint)raw.Length);
                foreach (byte item in raw)
                {
                    WriteNumber(buffer, item);
                }

                return;
            }

            case IDictionary<string, object?> map:
                WriteObject(buffer, map);
                return;

            case IDictionary dictionary:
            {
                var pairs = new List<KeyValuePair<string, object?>>(dictionary.Count);
                foreach (DictionaryEntry entry in dictionary)
                {
                    pairs.Add(new KeyValuePair<string, object?>(
                        entry.Key?.ToString() ?? string.Empty,
                        entry.Value));
                }

                WriteObject(buffer, pairs);
                return;
            }

            case IEnumerable<(string, object?)> tuples:
            {
                var pairs = new List<KeyValuePair<string, object?>>();
                foreach (var (key, item) in tuples)
                {
                    pairs.Add(new KeyValuePair<string, object?>(key, item));
                }

                WriteObject(buffer, pairs);
                return;
            }

            case IEnumerable enumerable:
            {
                var items = new List<object?>();
                foreach (object? item in enumerable)
                {
                    items.Add(item);
                }

                buffer.Add(TypeStrictArray);
                WriteUInt32(buffer, (uint)items.Count);
                foreach (object? item in items)
                {
                    WriteValue(buffer, item);
                }

                return;
            }

            default:
                WriteString(buffer, value.ToString());
                return;
        }
    }

    /// <summary>按顺序编码若干个值，返回可直接作为命令消息负载的字节数组。</summary>
    public static byte[] EncodeValues(params object?[] values)
    {
        var buffer = new List<byte>(64);
        if (values != null)
        {
            foreach (object? value in values)
            {
                WriteValue(buffer, value);
            }
        }

        return buffer.ToArray();
    }

    // ---------------------------------------------------------------- 小工具

    public static string? AsString(object? value) => value as string;

    public static double AsNumber(object? value, double fallback = 0)
    {
        return value switch
        {
            double d => d,
            float f => f,
            decimal m => (double)m,
            byte b => b,
            sbyte sb => sb,
            short s => s,
            ushort us => us,
            int i => i,
            uint ui => ui,
            long l => l,
            ulong ul => ul,
            bool flag => flag ? 1 : 0,
            string text when double.TryParse(text, out double parsed) => parsed,
            _ => fallback,
        };
    }

    public static bool AsBool(object? value, bool fallback = false)
    {
        return value switch
        {
            bool b => b,
            double d => d != 0,
            string s when bool.TryParse(s, out bool parsed) => parsed,
            _ => fallback,
        };
    }

    private static void WriteUInt32(List<byte> buffer, uint value)
    {
        buffer.Add((byte)(value >> 24));
        buffer.Add((byte)(value >> 16));
        buffer.Add((byte)(value >> 8));
        buffer.Add((byte)value);
    }

    private static void Append(List<byte> buffer, ReadOnlySpan<byte> data)
    {
        for (int i = 0; i < data.Length; i++)
        {
            buffer.Add(data[i]);
        }
    }
}
