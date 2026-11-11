#import "FXCommon.h"

static const int kOutputSampleRate = 48000;
static const int kOutputChannels = 2;

typedef struct
{
    const void *data;
    UInt32 length;
    UInt32 channels;
    BOOL consumed;
} FXAACFeed;

static OSStatus FXAACInputProc(AudioConverterRef converter,
                               UInt32 *ioNumberDataPackets,
                               AudioBufferList *ioData,
                               AudioStreamPacketDescription **outDataPacketDescription,
                               void *inUserData)
{
    FXAACFeed *feed = (FXAACFeed *)inUserData;
    if (feed == NULL || feed->consumed || feed->data == NULL || feed->length == 0)
    {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = feed->channels;
    ioData->mBuffers[0].mDataByteSize = feed->length;
    ioData->mBuffers[0].mData = (void *)feed->data;
    *ioNumberDataPackets = 1;

    if (outDataPacketDescription)
    {
        *outDataPacketDescription = NULL;
    }

    feed->consumed = YES;
    return noErr;
}

@implementation FXAudioDecoder
{
    AudioConverterRef _converter;
    int _sampleRate;
    int _channels;
    int _framesPerPacket;
}

- (BOOL)configureWithMagicCookie:(NSData *)cookie sampleRate:(int)sampleRate channels:(int)channels;

- (void)dealloc
{
    if (_converter)
    {
        AudioConverterDispose(_converter);
        _converter = NULL;
    }
}

- (int)sampleRate
{
    return _sampleRate;
}

- (int)channels
{
    return _channels;
}

- (void)reset
{
    if (_converter)
    {
        AudioConverterDispose(_converter);
        _converter = NULL;
    }
}

- (BOOL)configureWithAudioSpecificConfig:(NSData *)asc
{
    if (asc.length < 2)
    {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)asc.bytes;
    // 位读取（够用即可）
    __block uint32_t bitBuffer = 0;
    __block int bitCount = 0;
    __block NSUInteger byteIndex = 0;

    int (^readBits)(int) = ^int(int count) {
        int value = 0;
        for (int i = 0; i < count; i++)
        {
            if (bitCount == 0)
            {
                if (byteIndex >= asc.length)
                {
                    return -1;
                }
                bitBuffer = bytes[byteIndex++];
                bitCount = 8;
            }
            value = (value << 1) | (int)((bitBuffer >> (bitCount - 1)) & 1);
            bitCount--;
        }
        return value;
    };

    int objectType = readBits(5);
    if (objectType == 31)
    {
        objectType = 32 + readBits(6);
    }
    int rateIndex = readBits(4);
    int sampleRate = rateIndex;
    if (rateIndex == 15)
    {
        sampleRate = readBits(24);
    }
    else
    {
        static const int rates[16] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                       16000, 12000, 11025, 8000, 7350, 0, 0, 0 };
        sampleRate = (rateIndex >= 0 && rateIndex < 16) ? rates[rateIndex] : 48000;
    }
    int channels = readBits(4);
    if (channels <= 0)
    {
        channels = 2;
    }

    if (objectType <= 0)
    {
        objectType = 2; // AAC-LC
    }
    if (sampleRate <= 0)
    {
        sampleRate = kOutputSampleRate;
    }

    return [self configureWithMagicCookie:asc sampleRate:sampleRate channels:channels];
}

- (BOOL)configureWithADTSHeader:(NSData *)adts
{
    if (adts.length < 7)
    {
        return NO;
    }

    const uint8_t *bytes = (const uint8_t *)adts.bytes;
    int profile = ((bytes[2] >> 6) & 0x03) + 1; // ADTS profile -> object type
    int rateIndex = (bytes[2] >> 2) & 0x0F;
    int channels = ((bytes[2] & 0x01) << 2) | ((bytes[3] >> 6) & 0x03);
    if (channels <= 0)
    {
        channels = 2;
    }

    static const int rates[16] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                   16000, 12000, 11025, 8000, 7350, 0, 0, 0 };
    int sampleRate = (rateIndex >= 0 && rateIndex < 16) ? rates[rateIndex] : 48000;
    if (sampleRate <= 0)
    {
        sampleRate = kOutputSampleRate;
    }

    // 用 profile/sampleRateIndex/channels 组一个最小 AudioSpecificConfig
    uint16_t asc = 0;
    asc |= (uint16_t)((profile & 0x1F) << 11);
    asc |= (uint16_t)((rateIndex & 0x0F) << 7);
    asc |= (uint16_t)((channels & 0x0F) << 3);
    uint8_t ascBytes[2] = { (uint8_t)((asc >> 8) & 0xFF), (uint8_t)(asc & 0xFF) };

    return [self configureWithMagicCookie:[NSData dataWithBytes:ascBytes length:2]
                               sampleRate:sampleRate
                                 channels:channels];
}

- (BOOL)configureWithMagicCookie:(NSData *)cookie sampleRate:(int)sampleRate channels:(int)channels
{
    [self reset];

    AudioStreamBasicDescription input = {0};
    input.mSampleRate = sampleRate;
    input.mFormatID = kAudioFormatMPEG4AAC;
    input.mChannelsPerFrame = (UInt32)channels;
    input.mFramesPerPacket = 1024;
    input.mBytesPerPacket = 0;
    input.mBytesPerFrame = 0;
    input.mBitsPerChannel = 0;

    AudioStreamBasicDescription output = {0};
    output.mSampleRate = kOutputSampleRate;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    output.mChannelsPerFrame = kOutputChannels;
    output.mFramesPerPacket = 1;
    output.mBitsPerChannel = 16;
    output.mBytesPerFrame = (UInt32)(kOutputChannels * 2);
    output.mBytesPerPacket = output.mBytesPerFrame;

    OSStatus status = AudioConverterNew(&input, &output, &_converter);
    if (status != noErr || _converter == NULL)
    {
        _converter = NULL;
        return NO;
    }

    UInt32 primeMethod = kConverterPrimeMethod_None;
    AudioConverterSetProperty(_converter,
                              kAudioConverterPrimeMethod,
                              sizeof(primeMethod),
                              &primeMethod);

    if (cookie.length > 0)
    {
        AudioConverterSetProperty(_converter,
                                  kAudioConverterDecompressionMagicCookie,
                                  (UInt32)cookie.length,
                                  cookie.bytes);
    }

    _sampleRate = sampleRate;
    _channels = channels;
    _framesPerPacket = 1024;
    return YES;
}

- (void)decodeRawAAC:(NSData *)rawAac
{
    if (_converter == NULL || rawAac.length == 0)
    {
        return;
    }

    FXAACFeed feed = { 0 };
    feed.data = rawAac.bytes;
    feed.length = (UInt32)rawAac.length;
    feed.channels = (UInt32)_channels;
    feed.consumed = NO;

    uint8_t output[16 * 1024];
    AudioBufferList outList = { 0 };
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = (UInt32)kOutputChannels;
    outList.mBuffers[0].mDataByteSize = sizeof(output);
    outList.mBuffers[0].mData = output;

    UInt32 packets = 1;
    OSStatus status = AudioConverterFillComplexBuffer(_converter, FXAACInputProc, &feed, &packets, &outList, NULL);
    if (status != noErr && status != kAudioConverterErr_NoMoreData)
    {
        return;
    }

    UInt32 size = outList.mBuffers[0].mDataByteSize;
    if (size >= 4)
    {
        NSData *pcm = [NSData dataWithBytes:output length:size];
        [[FXMediaStore shared] appendAudio:pcm ptsMs:0];
    }
}

- (void)decodeADTS:(NSData *)adts
{
    if (adts.length <= 7)
    {
        return;
    }

    const uint8_t *bytes = (const uint8_t *)adts.bytes;
    BOOL protectionAbsent = (bytes[1] & 0x01) != 0;
    NSUInteger headerLength = protectionAbsent ? 7 : 9;
    if (adts.length <= headerLength)
    {
        return;
    }

    if (_converter == NULL)
    {
        [self configureWithADTSHeader:adts];
        if (_converter == NULL)
        {
            return;
        }
    }

    NSData *raw = [adts subdataWithRange:NSMakeRange(headerLength, adts.length - headerLength)];
    [self decodeRawAAC:raw];
}

@end
