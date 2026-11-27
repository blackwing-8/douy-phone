//
//  Probe.mm —— 最小注入探针
//
//  只做两件事：
//    1. NSLog 一行，证明 dylib 被 dyld 加载了
//    2. 在屏幕上显示一个红点，证明代码真的跑进了 App 进程
//
//  如果注入后既没有日志也没有红点 → 注入本身失败（TrollFools / 签名 / 版本问题）
//  如果红点出现但主 dylib 的浮窗不出现 → 是我们的代码问题
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface FXProbeWindow : UIWindow
@end

@implementation FXProbeWindow
@end

static void FXProbeShowDot(void)
{
    if (@available(iOS 13.0, *))
    {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        {
            if (![scene isKindOfClass:[UIWindowScene class]])
            {
                continue;
            }

            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *w = [[FXProbeWindow alloc] initWithWindowScene:ws];
            w.windowLevel = UIWindowLevelAlert + 100;
            w.backgroundColor = [UIColor clearColor];

            UIViewController *vc = [[UIViewController alloc] init];
            vc.view.backgroundColor = [UIColor clearColor];

            UILabel *dot = [[UILabel alloc] initWithFrame:CGRectMake(24, 120, 84, 34)];
            dot.text = @"探针OK";
            dot.textColor = [UIColor whiteColor];
            dot.textAlignment = NSTextAlignmentCenter;
            dot.font = [UIFont boldSystemFontOfSize:15];
            dot.backgroundColor = [UIColor colorWithRed:0.9 green:0.15 blue:0.15 alpha:0.95];
            dot.layer.cornerRadius = 10;
            dot.layer.masksToBounds = YES;
            [vc.view addSubview:dot];

            w.rootViewController = vc;
            w.hidden = NO;
            NSLog(@"[PROBE] 窗口已显示");
            return;
        }
    }
}

__attribute__((constructor))
static void FXProbeInitialize(void)
{
    @autoreleasepool
    {
        NSLog(@"[PROBE] dylib loaded —— 注入成功");

        dispatch_async(dispatch_get_main_queue(), ^{
            FXProbeShowDot();
        });
    }
}
