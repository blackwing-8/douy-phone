//
//  FXCommon.h —— 原相机替换 · 公共声明
//
//  拍照替换的核心是一个「当前照片」槽：谁往里放图，宿主拍照就拿哪张。
//  图片来源：本地相册 / USB（电脑推送）/ 局域网（电脑 HTTP）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, FXPhotoSource)
{
    FXPhotoSourceNone = 0,
    FXPhotoSourceLocal,
    FXPhotoSourceUSB,
    FXPhotoSourceLAN,
};

@interface FXPhotoStore : NSObject

+ (instancetype)shared;

/// 替换开关：关掉后宿主拿到的永远是真实照片，行为与未注入一致
@property (atomic, assign) BOOL replaceEnabled;

/// 当前照片来源
@property (atomic, readonly) FXPhotoSource source;

- (BOOL)hasPhoto;
- (BOOL)setPhotoData:(NSData *)jpeg name:(NSString *)name source:(FXPhotoSource)source;

/// 当前 JPEG 数据（可能为 nil）
- (NSData *)currentData;

/// 当前图片的 CGImage（借用，不需要调用方 release；无图返回 NULL）
- (CGImageRef)currentCGImage;

/// 当前图片像素尺寸
- (CGSize)currentPixelSize;

- (NSString *)photoName;
- (NSString *)statusText;
- (void)setStatus:(NSString *)text;

@end

/// 安装拍照相关钩子（只接管数据出口，不改采集流程）
void FXInstallPhotoHooks(void);

/// 把浮窗挂到指定场景
void FXAttachOverlayToScene(UIWindowScene *scene);

/// 内置兜鱼 logo
UIImage *FXLogoImage(void);

// ---- 局域网取图（PC「兜鱼选图」提供 HTTP）----
void FXLanStart(NSString *host, int port);
void FXLanStop(void);
BOOL FXLanRunning(void);
NSString *FXLanStatus(void);
NSString *FXLanSavedAddress(void);

/// 诊断计数
typedef struct {
    int captureRequests;   // capturePhotoWithSettings 被调用次数
    int dataCalls;         // fileDataRepresentation 被调用次数
    int imageCalls;        // CGImageRepresentation 被调用次数
    int replaced;          // 实际替换次数
    int skippedNoPhoto;    // 开关开着但没有照片
} FXPhotoStats;

FXPhotoStats FXPhotoStatsGet(void);
NSString *FXPhotoStatsReport(void);
