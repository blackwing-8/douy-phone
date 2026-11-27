//
//  FXPhotoHooks.mm —— 拍照数据出口接管
//
//  原理（不伪造采集，只换数据出口）：
//    宿主照常启动相机、照常拍一张，我们不干预采集流程；
//    当宿主问 AVCapturePhoto 要数据时，我们返回准备好的图片。
//    这样预览、对焦、权限、时序全部保持原样，最不引人注意。
//
//  接管的三个出口：
//    -[AVCapturePhoto fileDataRepresentation]      主出口（JPEG/HEIF Data）
//    -[AVCapturePhoto CGImageRepresentation]       有的 App 用这个
//    -[AVCapturePhoto previewCGImageRepresentation] 缩略图，要跟主图一致
//
//  安全约定：
//    · 开关关闭 / 没有照片 → 原样返回，行为与未注入完全一致
//    · 任何异常都不返回空数据
//

#import "FXCommon.h"
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>

static volatile int gCaptureRequests = 0;
static volatile int gDataCalls = 0;
static volatile int gImageCalls = 0;
static volatile int gReplaced = 0;
static volatile int gSkippedNoPhoto = 0;

FXPhotoStats FXPhotoStatsGet(void)
{
    FXPhotoStats s;
    s.captureRequests = gCaptureRequests;
    s.dataCalls = gDataCalls;
    s.imageCalls = gImageCalls;
    s.replaced = gReplaced;
    s.skippedNoPhoto = gSkippedNoPhoto;
    return s;
}

NSString *FXPhotoStatsReport(void)
{
    FXPhotoStats s = FXPhotoStatsGet();
    return [NSString stringWithFormat:
            @"拍照请求: %d 次\n"
            @"取数据: %d 次 · 取图: %d 次\n"
            @"已替换: %d 次\n"
            @"无图跳过: %d 次",
            s.captureRequests, s.dataCalls, s.imageCalls, s.replaced, s.skippedNoPhoto];
}

static BOOL FXShouldReplace(void)
{
    FXPhotoStore *store = [FXPhotoStore shared];
    if (!store.replaceEnabled)
    {
        return NO;
    }
    if (![store hasPhoto])
    {
        __sync_add_and_fetch(&gSkippedNoPhoto, 1);
        return NO;
    }
    return YES;
}

/// 合成一份合理的 EXIF，避免元数据与图片不一致
static NSDictionary *FXBuildMetadata(void)
{
    FXPhotoStore *store = [FXPhotoStore shared];
    CGSize size = [store currentPixelSize];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy:MM:dd HH:mm:ss";
    NSString *now = [fmt stringFromDate:[NSDate date]];

    NSDictionary *exif = @{
        (NSString *)kCGImagePropertyExifDateTimeOriginal: now,
        (NSString *)kCGImagePropertyExifDateTimeDigitized: now,
        (NSString *)kCGImagePropertyExifPixelXDimension: @((int)size.width),
        (NSString *)kCGImagePropertyExifPixelYDimension: @((int)size.height),
        (NSString *)kCGImagePropertyExifColorSpace: @(1),
    };

    NSDictionary *tiff = @{
        (NSString *)kCGImagePropertyTIFFMake: @"Apple",
        (NSString *)kCGImagePropertyTIFFModel: @"iPhone",
        (NSString *)kCGImagePropertyTIFFDateTime: now,
    };

    return @{
        (NSString *)kCGImagePropertyExifDictionary: exif,
        (NSString *)kCGImagePropertyTIFFDictionary: tiff,
    };
}

#pragma mark - AVCapturePhoto 数据出口

@implementation AVCapturePhoto (FXReplace)

- (NSData *)fx_fileDataRepresentation
{
    __sync_add_and_fetch(&gDataCalls, 1);

    if (FXShouldReplace())
    {
        NSData *data = [[FXPhotoStore shared] currentData];
        if (data.length > 0)
        {
            __sync_add_and_fetch(&gReplaced, 1);
            return data;
        }
    }
    return [self fx_fileDataRepresentation];
}

- (CGImageRef)fx_CGImageRepresentation
{
    __sync_add_and_fetch(&gImageCalls, 1);

    if (FXShouldReplace())
    {
        CGImageRef image = [[FXPhotoStore shared] currentCGImage];
        if (image != NULL)
        {
            __sync_add_and_fetch(&gReplaced, 1);
            return image;                 // 借用，与系统契约一致
        }
    }
    return [self fx_CGImageRepresentation];
}

- (CGImageRef)fx_previewCGImageRepresentation
{
    if (FXShouldReplace())
    {
        CGImageRef image = [[FXPhotoStore shared] currentCGImage];
        if (image != NULL)
        {
            return image;
        }
    }
    return [self fx_previewCGImageRepresentation];
}

- (NSDictionary *)fx_metadata
{
    if ([[FXPhotoStore shared] replaceEnabled] && [[FXPhotoStore shared] hasPhoto])
    {
        return FXBuildMetadata();
    }
    return [self fx_metadata];
}

@end

#pragma mark - AVCapturePhotoOutput 计数（确认宿主走了这条路径）

@implementation AVCapturePhotoOutput (FXReplace)

- (void)fx_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
                           delegate:(id<AVCapturePhotoCaptureDelegate>)delegate
{
    __sync_add_and_fetch(&gCaptureRequests, 1);
    [self fx_capturePhotoWithSettings:settings delegate:delegate];
}

@end

#pragma mark - 安装

static void FXSwizzle(Class cls, SEL original, SEL replacement)
{
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a == NULL || b == NULL)
    {
        NSLog(@"[原相机替换] 跳过 %@ -> %@（方法不存在）",
              NSStringFromClass(cls), NSStringFromSelector(original));
        return;
    }
    method_exchangeImplementations(a, b);
    NSLog(@"[原相机替换] 已接管 %@ %@", NSStringFromClass(cls), NSStringFromSelector(original));
}

void FXInstallPhotoHooks(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class photo = NSClassFromString(@"AVCapturePhoto");
        if (photo != Nil)
        {
            FXSwizzle(photo,
                      @selector(fileDataRepresentation),
                      @selector(fx_fileDataRepresentation));
            FXSwizzle(photo,
                      @selector(CGImageRepresentation),
                      @selector(fx_CGImageRepresentation));
            FXSwizzle(photo,
                      @selector(previewCGImageRepresentation),
                      @selector(fx_previewCGImageRepresentation));
            FXSwizzle(photo,
                      @selector(metadata),
                      @selector(fx_metadata));
        }

        Class output = NSClassFromString(@"AVCapturePhotoOutput");
        if (output != Nil)
        {
            FXSwizzle(output,
                      @selector(capturePhotoWithSettings:delegate:),
                      @selector(fx_capturePhotoWithSettings:delegate:));
        }
    });
}
