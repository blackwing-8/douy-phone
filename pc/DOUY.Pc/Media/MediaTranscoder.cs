using System.Buffers.Binary;

namespace DOUY.Pc.Media;

/// <summary>
/// RTMP/FLV 的 AVCC(AVC1) ↔ Annex-B 转换，以及 AAC 裸帧 → ADTS 封装。
///
/// 原版插件里同职责的模块会报 "Invalid AVC configuration" / "Truncated SPS/PPS" /
/// "Missing PPS" / "Invalid H264 NAL" 等错误，这里给出等价实现。
/// </summary>
public static class MediaTranscoder
{
    public sealed record AvcConfig(byte[] Sps, byte[] Pps, int Width, int Height)
    {
        /// <summary>Annex-B 形式的 SPS/PPS 前置（用于关键帧）。</summary>
        public byte[] AnnexBParameterSets()
        {
            var list = new List<byte>(Sps.Length + Pps.Length + 8);
            list.AddRange(new byte[] { 0, 0, 0, 1 });
            list.AddRange(Sps);
            list.AddRange(new byte[] { 0, 0, 0, 1 });
            list.AddRange(Pps);
            return list.ToArray();
        }
    }

    public sealed record AacConfig(int ObjectType, int SampleRate, int Channels, int SampleRateIndex)
    {
        public int Profile => ObjectType - 1; // ADTS profile = objectType - 1 (AAC-LC => 1)
    }

    public static readonly int[] AacSampleRates =
    {
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350, 0, 0, 0,
    };

    /// <summary>解析 AVCDecoderConfigurationRecord（FLV AVC sequence header 的负载）。</summary>
    public static AvcConfig? ParseAvcConfig(ReadOnlySpan<byte> record)
    {
        if (record.Length < 7 || record[0] != 1)
        {
            return null;
        }

        var numSps = record[5] & 0x1F;
        var offset = 6;
        byte[]? sps = null;
        for (var i = 0; i < numSps; i++)
        {
            if (offset + 2 > record.Length)
            {
                return null;
            }

            var len = BinaryPrimitives.ReadUInt16BigEndian(record[offset..]);
            offset += 2;
            if (offset + len > record.Length)
            {
                return null;
            }

            if (sps == null)
            {
                sps = record.Slice(offset, len).ToArray();
            }

            offset += len;
        }

        if (offset >= record.Length)
        {
            return null;
        }

        var numPps = record[offset++];
        byte[]? pps = null;
        for (var i = 0; i < numPps; i++)
        {
            if (offset + 2 > record.Length)
            {
                return null;
            }

            var len = BinaryPrimitives.ReadUInt16BigEndian(record[offset..]);
            offset += 2;
            if (offset + len > record.Length)
            {
                return null;
            }

            if (pps == null)
            {
                pps = record.Slice(offset, len).ToArray();
            }

            offset += len;
        }

        if (sps == null || pps == null)
        {
            return null;
        }

        var (w, h) = ParseSpsSize(sps);
        return new AvcConfig(sps, pps, w, h);
    }

    /// <summary>AVCC（4 字节大端长度前缀的 NAL 序列）→ Annex-B。</summary>
    public static byte[] AvccToAnnexB(ReadOnlySpan<byte> avcc, AvcConfig? config = null, bool keyframe = false)
    {
        var output = new List<byte>(avcc.Length + 64);
        if (keyframe && config != null)
        {
            output.AddRange(config.AnnexBParameterSets());
        }

        var offset = 0;
        while (offset + 4 <= avcc.Length)
        {
            var len = (int)BinaryPrimitives.ReadUInt32BigEndian(avcc[offset..]);
            offset += 4;
            if (len <= 0 || offset + len > avcc.Length)
            {
                break;
            }

            output.AddRange(new byte[] { 0, 0, 0, 1 });
            output.AddRange(avcc.Slice(offset, len).ToArray());
            offset += len;
        }

        return output.ToArray();
    }

    /// <summary>解析 AudioSpecificConfig（FLV AAC sequence header 的负载）。</summary>
    public static AacConfig? ParseAacConfig(ReadOnlySpan<byte> asc)
    {
        if (asc.Length < 2)
        {
            return null;
        }

        var bitReader = new BitReader(asc);
        var objectType = bitReader.Read(5);
        if (objectType == 31)
        {
            objectType = 32 + bitReader.Read(6);
        }

        var rateIndex = bitReader.Read(4);
        var sampleRate = rateIndex == 15 ? bitReader.Read(24) : (rateIndex < AacSampleRates.Length ? AacSampleRates[rateIndex] : 48000);
        var channels = bitReader.Read(4);
        if (channels == 0)
        {
            channels = 2;
        }

        if (sampleRate <= 0)
        {
            sampleRate = 48000;
        }

        return new AacConfig(objectType, sampleRate, channels, rateIndex);
    }

    /// <summary>裸 AAC 帧 → 带 7 字节 ADTS 头的帧。</summary>
    public static byte[] AddAdts(ReadOnlySpan<byte> rawAac, AacConfig config)
    {
        var frameLength = rawAac.Length + 7;
        var header = new byte[7];
        header[0] = 0xFF;
        header[1] = 0xF1; // MPEG-4, layer 0, protection absent
        header[2] = (byte)(((config.Profile & 0x03) << 6) | ((config.SampleRateIndex & 0x0F) << 2) | ((config.Channels >> 2) & 0x01));
        header[3] = (byte)(((config.Channels & 0x03) << 6) | ((frameLength >> 11) & 0x03));
        header[4] = (byte)((frameLength >> 3) & 0xFF);
        header[5] = (byte)(((frameLength & 0x07) << 5) | 0x1F);
        header[6] = 0xFC;

        var result = new byte[frameLength];
        Buffer.BlockCopy(header, 0, result, 0, 7);
        rawAac.CopyTo(result.AsSpan(7));
        return result;
    }

    /// <summary>从 SPS 里读分辨率（含 crop）。失败返回 0,0。</summary>
    public static (int Width, int Height) ParseSpsSize(ReadOnlySpan<byte> sps)
    {
        try
        {
            var rbsp = RemoveEmulationPrevention(sps);
            var reader = new BitReader(rbsp);
            var profileIdc = reader.Read(8);
            reader.Read(8);  // constraint flags + reserved
            reader.Read(8);  // level_idc
            reader.ReadUe(); // seq_parameter_set_id

            var chromaFormatIdc = 1;
            var separateColourPlane = 0;
            if (profileIdc is 100 or 110 or 122 or 244 or 44 or 83 or 86 or 118 or 128 or 138 or 139 or 134 or 135)
            {
                chromaFormatIdc = reader.ReadUe();
                if (chromaFormatIdc == 3)
                {
                    separateColourPlane = reader.Read(1);
                }

                reader.ReadUe(); // bit_depth_luma_minus8
                reader.ReadUe(); // bit_depth_chroma_minus8
                reader.Read(1);  // qpprime_y_zero_transform_bypass_flag
                if (reader.Read(1) == 1)
                {
                    var count = chromaFormatIdc != 3 ? 8 : 12;
                    for (var i = 0; i < count; i++)
                    {
                        if (reader.Read(1) == 1)
                        {
                            var size = i < 6 ? 16 : 64;
                            SkipScalingList(ref reader, size);
                        }
                    }
                }
            }

            reader.ReadUe(); // log2_max_frame_num_minus4
            var picOrderCntType = reader.ReadUe();
            if (picOrderCntType == 0)
            {
                reader.ReadUe();
            }
            else if (picOrderCntType == 1)
            {
                reader.Read(1);
                reader.ReadSe();
                reader.ReadSe();
                var n = reader.ReadUe();
                for (var i = 0; i < n; i++)
                {
                    reader.ReadSe();
                }
            }

            reader.ReadUe(); // max_num_ref_frames
            reader.Read(1);  // gaps_in_frame_num_value_allowed_flag
            var widthMbs = reader.ReadUe() + 1;
            var heightMapUnits = reader.ReadUe() + 1;
            var frameMbsOnly = reader.Read(1);
            if (frameMbsOnly == 0)
            {
                reader.Read(1); // mb_adaptive_frame_field_flag
            }

            reader.Read(1); // direct_8x8_inference_flag
            var cropLeft = 0;
            var cropRight = 0;
            var cropTop = 0;
            var cropBottom = 0;
            if (reader.Read(1) == 1)
            {
                cropLeft = reader.ReadUe();
                cropRight = reader.ReadUe();
                cropTop = reader.ReadUe();
                cropBottom = reader.ReadUe();
            }

            var subWidthC = chromaFormatIdc switch { 1 => 2, 2 => 2, 3 => 1, _ => 1 };
            var subHeightC = chromaFormatIdc switch { 1 => 2, 2 => 1, 3 => 1, _ => 1 };
            if (separateColourPlane == 1)
            {
                subWidthC = 1;
                subHeightC = 1;
            }

            var width = widthMbs * 16 - (cropLeft + cropRight) * subWidthC;
            var height = (2 - frameMbsOnly) * heightMapUnits * 16 - (cropTop + cropBottom) * subHeightC;
            return (Math.Max(width, 0), Math.Max(height, 0));
        }
        catch
        {
            return (0, 0);
        }
    }

    private static void SkipScalingList(ref BitReader reader, int size)
    {
        var lastScale = 8;
        var nextScale = 8;
        for (var i = 0; i < size; i++)
        {
            if (nextScale != 0)
            {
                var delta = reader.ReadSe();
                nextScale = (lastScale + delta + 256) % 256;
            }

            lastScale = nextScale == 0 ? lastScale : nextScale;
        }
    }

    private static byte[] RemoveEmulationPrevention(ReadOnlySpan<byte> data)
    {
        var result = new byte[data.Length];
        var count = 0;
        for (var i = 0; i < data.Length; i++)
        {
            if (i >= 2 && data[i] == 0x03 && data[i - 1] == 0x00 && data[i - 2] == 0x00)
            {
                continue;
            }

            result[count++] = data[i];
        }

        return result[..count];
    }

    private ref struct BitReader
    {
        private readonly ReadOnlySpan<byte> _data;
        private int _bit;

        public BitReader(ReadOnlySpan<byte> data)
        {
            _data = data;
            _bit = 0;
        }

        public int Read(int count)
        {
            var value = 0;
            for (var i = 0; i < count; i++)
            {
                var byteIndex = _bit >> 3;
                if (byteIndex >= _data.Length)
                {
                    throw new EndOfStreamException();
                }

                var bit = (_data[byteIndex] >> (7 - (_bit & 7))) & 1;
                value = (value << 1) | bit;
                _bit++;
            }

            return value;
        }

        public int ReadUe()
        {
            var zeros = 0;
            while (Read(1) == 0)
            {
                zeros++;
                if (zeros > 32)
                {
                    throw new InvalidDataException("bad exp-golomb");
                }
            }

            return zeros == 0 ? 0 : (1 << zeros) - 1 + Read(zeros);
        }

        public int ReadSe()
        {
            var v = ReadUe();
            return (v & 1) == 1 ? (v + 1) / 2 : -(v / 2);
        }
    }
}
