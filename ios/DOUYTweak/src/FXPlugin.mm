//
//  FXPlugin.mm —— 插件入口
//
//  注入器把 Yuancam.dylib 塞进目标 App（LC_LOAD_DYLIB），
//  启动时 dyld 执行这里的 constructor：装拍照钩子 + 挂浮窗。
//
//  注意：constructor 里只做「装钩子 + 排一次主线程任务」，
//        不扫内存、不改代码页 —— 任何失败都只是"没生效"。
//

#import "FXCommon.h"
#import <UIKit/UIKit.h>

static const char *kFXVersion = "1.0.0";

@interface FXPluginBootstrap : NSObject
@end

@implementation FXPluginBootstrap

+ (void)attachToActiveScene
{
    if (@available(iOS 13.0, *))
    {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        {
            if (![scene isKindOfClass:[UIWindowScene class]])
            {
                continue;
            }
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive)
            {
                continue;
            }
            FXAttachOverlayToScene((UIWindowScene *)scene);
            return;
        }
    }
}

@end

__attribute__((constructor))
static void FXPluginInitialize(void)
{
    @autoreleasepool
    {
        NSLog(@"[原相机替换] plugin loaded %s", kFXVersion);

        // 1) 装拍照钩子（只接管数据出口）
        FXInstallPhotoHooks();

        // 2) 浮窗挂载：等 App 起来再挂
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

            [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                [FXPluginBootstrap attachToActiveScene];
            }];

            [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                [FXPluginBootstrap attachToActiveScene];
            }];

            [FXPluginBootstrap attachToActiveScene];
        });
    }
}
