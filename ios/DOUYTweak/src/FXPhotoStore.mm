//
//  FXPhotoStore.mm —— 「当前照片」槽
//
//  线程模型：
//    · 写入：主线程（本地选图）/ USB 线程 / 局域网线程
//    · 读取：宿主拍照回调（可能任意线程）
//  所以用一把锁保护，临界区只做指针交换，不在锁内解码图片。
//

#import "FXCommon.h"
#import <ImageIO/ImageIO.h>

@implementation FXPhotoStore
{
    NSLock *_lock;
    NSData *_jpeg;
    CGImageRef _cgImage;
    NSString *_name;
    CGSize _pixelSize;
    NSString *_status;
}

+ (instancetype)shared
{
    static FXPhotoStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[FXPhotoStore alloc] init];
    });
    return store;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _lock = [[NSLock alloc] init];
        _status = @"等待选择照片";
    }
    return self;
}

- (BOOL)hasPhoto
{
    [_lock lock];
    BOOL ok = (_jpeg.length > 0 || _cgImage != NULL);
    [_lock unlock];
    return ok;
}

- (BOOL)setPhotoData:(NSData *)jpeg name:(NSString *)name source:(FXPhotoSource)source
{
    if (jpeg.length == 0)
    {
        return NO;
    }

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
    CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src)
    {
        CFRelease(src);
    }
    if (image == NULL)
    {
        NSLog(@"[原相机替换] 图片解码失败（%lu 字节）", (unsigned long)jpeg.length);
        return NO;
    }

    [_lock lock];
    NSData *oldData = _jpeg;
    CGImageRef oldImage = _cgImage;

    _jpeg = [jpeg copy];
    _cgImage = image;                       // 持有
    _name = [name copy];
    _pixelSize = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
    _source = source;
    [_lock unlock];

    (void)oldData;
    if (oldImage)
    {
        CGImageRelease(oldImage);
    }

    [self setStatus:[NSString stringWithFormat:@"已选定 %@ · %dx%d",
                     _name.length > 0 ? _name : @"图片",
                     (int)_pixelSize.width, (int)_pixelSize.height]];
    return YES;
}

- (NSData *)currentData
{
    [_lock lock];
    NSData *d = _jpeg;
    [_lock unlock];
    return d;
}

- (CGImageRef)currentCGImage
{
    [_lock lock];
    CGImageRef img = _cgImage;
    [_lock unlock];
    return img;
}

- (CGSize)currentPixelSize
{
    [_lock lock];
    CGSize s = _pixelSize;
    [_lock unlock];
    return s;
}

- (NSString *)photoName
{
    [_lock lock];
    NSString *n = _name;
    [_lock unlock];
    return n;
}

- (NSString *)statusText
{
    [_lock lock];
    NSString *s = _status;
    [_lock unlock];
    return s;
}

- (void)setStatus:(NSString *)text
{
    if (text.length == 0)
    {
        return;
    }
    [_lock lock];
    _status = [text copy];
    [_lock unlock];

    // 让浮窗刷新（主线程）
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"FXPhotoStoreChanged"
                                                            object:nil];
    });
}

@end
