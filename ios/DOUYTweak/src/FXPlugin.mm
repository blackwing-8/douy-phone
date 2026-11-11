//
//  FXPlugin.mm —— 插件入口
//
//  由注入器把 DOUY.dylib 塞进目标 App 的 Mach-O（LC_LOAD_DYLIB），
//  启动时 dyld 会跑到这里的 constructor：装 hook + 挂浮窗 + 启动授权核验。
//

#import "FXCommon.h"
#import "FXLicense.h"
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
        NSLog(@"[DOUY] Plugin %s loaded (iOS / arm64)", kFXVersion);

        FXInstallHooks();

        // 授权：生成/读取设备身份，有本地会话就立刻联网核验
        [[FXLicense shared] bootstrap];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

            [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                                [FXPluginBootstrap attachToActiveScene];
                            }];

            [center addObserverForName:UISceneDidActivateNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                                if ([note.object isKindOfClass:[UIWindowScene class]])
                                {
                                    FXAttachOverlayToScene((UIWindowScene *)note.object);
                                }
                            }];

            // 授权状态变化：失效则立刻恢复真实摄像头，避免"白用"
            [center addObserverForName:FXLicenseDidChangeNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                                FXLicense *license = [FXLicense shared];
                                FXMediaStore *store = [FXMediaStore shared];
                                if (![license isAuthorized] && store.mode != FXSourceModeRealCamera)
                                {
                                    store.mode = FXSourceModeRealCamera;
                                    [store invalidateVideo];
                                    [store resetAudio];
                                    [store setStatus:license.statusText];
                                }
                                else if ([license isAuthorized] && license.statusText.length > 0)
                                {
                                    [store setStatus:license.statusText];
                                }
                            }];

            [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                                NSLog(@"[DOUY] entered background");
                            }];
        });
    }
}
