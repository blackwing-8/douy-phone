//
//  FXOverlay.mm —— 悬浮控制面板
//
//  一个挂在最顶层的 UIWindow（UIWindowLevelAlert），可拖动；
//  提供：真实摄像头 / USB 直连 / RTMP 拉流 / 本地视频 / 旋转 / 镜像 / 音频替换。
//

#import "FXCommon.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "FXLicense.h"

@interface FXOverlayWindow : UIWindow
@end

@implementation FXOverlayWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    BOOL inside = [super pointInside:point withEvent:event];
    if (!inside)
    {
        return NO;
    }
    return YES;
}

@end

@interface FXOverlayController : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, strong) FXOverlayWindow *window;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *modeButtons;
@property (nonatomic, strong) UIButton *audioButton;
@property (nonatomic, strong) UIButton *rotateButton;
@property (nonatomic, strong) UIButton *mirrorButton;
@property (nonatomic, strong) UIButton *collapseButton;
@property (nonatomic, strong) UIButton *accountButton;
@property (nonatomic, assign) BOOL collapsed;
+ (instancetype)shared;
- (void)attachToScene:(UIWindowScene *)scene;
- (void)setVisible:(BOOL)visible;
@end

@implementation FXOverlayController

+ (instancetype)shared
{
    static FXOverlayController *controller = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[FXOverlayController alloc] init];
        controller.modeButtons = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:controller
                                                 selector:@selector(statusChanged:)
                                                     name:FXStatusDidChangeNotification
                                                   object:nil];
    });
    return controller;
}

- (void)statusChanged:(NSNotification *)note
{
    NSString *text = note.userInfo[@"text"];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
        [self refreshButtons];
    });
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    button.layer.cornerRadius = 8.0;
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 10);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:32].active = YES;
    return button;
}

- (void)attachToScene:(UIWindowScene *)scene
{
    if (self.window != nil)
    {
        return;
    }

    FXOverlayWindow *window = [[FXOverlayWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = [[UIViewController alloc] init];
    window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window = window;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 210)];
    panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.88];
    panel.layer.cornerRadius = 14.0;
    panel.layer.masksToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    self.panel = panel;
    [window.rootViewController.view addSubview:panel];

    UIImageView *logoView = [[UIImageView alloc] initWithImage:FXLogoImage()];
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.layer.cornerRadius = 6.0;
    logoView.layer.masksToBounds = YES;
    logoView.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"兜鱼";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *status = [[UILabel alloc] init];
    status.text = [[FXMediaStore shared] statusText];
    status.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    status.font = [UIFont systemFontOfSize:11];
    status.numberOfLines = 2;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    [collapse setTitle:@"收起" forState:UIControlStateNormal];
    [collapse setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    collapse.titleLabel.font = [UIFont systemFontOfSize:12];
    [collapse addTarget:self action:@selector(toggleCollapse) forControlEvents:UIControlEventTouchUpInside];
    collapse.translatesAutoresizingMaskIntoConstraints = NO;
    self.collapseButton = collapse;

    UIStackView *modes = [[UIStackView alloc] init];
    modes.axis = UILayoutConstraintAxisHorizontal;
    modes.spacing = 6;
    modes.distribution = UIStackViewDistributionFillEqually;
    modes.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray *titles = @[ @"真实摄像头", @"USB 直连", @"RTMP", @"本地视频" ];
    for (NSInteger i = 0; i < titles.count; i++)
    {
        UIButton *button = [self makeButton:titles[i] action:@selector(modeTapped:)];
        button.tag = 100 + i;
        [modes addArrangedSubview:button];
        [self.modeButtons addObject:button];
    }

    UIStackView *actions = [[UIStackView alloc] init];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 6;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    self.rotateButton = [self makeButton:@"旋转 0°" action:@selector(rotateTapped)];
    self.mirrorButton = [self makeButton:@"镜像：关" action:@selector(mirrorTapped)];
    self.audioButton = [self makeButton:@"音频替换：关" action:@selector(audioTapped)];
    [actions addArrangedSubview:self.rotateButton];
    [actions addArrangedSubview:self.mirrorButton];
    [actions addArrangedSubview:self.audioButton];

    UIStackView *accountRow = [[UIStackView alloc] init];
    accountRow.axis = UILayoutConstraintAxisHorizontal;
    accountRow.distribution = UIStackViewDistributionFillEqually;
    accountRow.translatesAutoresizingMaskIntoConstraints = NO;
    self.accountButton = [self makeButton:@"账号与卡包" action:@selector(accountTapped)];
    [accountRow addArrangedSubview:self.accountButton];

    [panel addSubview:logoView];
    [panel addSubview:title];
    [panel addSubview:collapse];
    [panel addSubview:status];
    [panel addSubview:modes];
    [panel addSubview:actions];
    [panel addSubview:accountRow];

    UILayoutGuide *guide = panel.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [panel.widthAnchor constraintEqualToConstant:260],
        [logoView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [logoView.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [logoView.widthAnchor constraintEqualToConstant:22],
        [logoView.heightAnchor constraintEqualToConstant:22],
        [title.leadingAnchor constraintEqualToAnchor:logoView.trailingAnchor constant:8],
        [title.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [collapse.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [collapse.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [status.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [status.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [modes.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [modes.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [modes.topAnchor constraintEqualToAnchor:status.bottomAnchor constant:8],
        [actions.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [actions.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [actions.topAnchor constraintEqualToAnchor:modes.bottomAnchor constant:6],
        [accountRow.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [accountRow.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [accountRow.topAnchor constraintEqualToAnchor:actions.bottomAnchor constant:6],
        [accountRow.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
    ]];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [title addGestureRecognizer:pan];
    title.userInteractionEnabled = YES;

    NSLayoutConstraint *top = [panel.topAnchor constraintEqualToAnchor:window.rootViewController.view.safeAreaLayoutGuide.topAnchor constant:60];
    NSLayoutConstraint *trailing = [panel.trailingAnchor constraintEqualToAnchor:window.rootViewController.view.trailingAnchor constant:-12];
    top.active = YES;
    trailing.active = YES;

    window.hidden = NO;
    [self refreshButtons];
}

- (void)setVisible:(BOOL)visible
{
    self.window.hidden = !visible;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    CGPoint translation = [pan translationInView:self.window];
    self.panel.transform = CGAffineTransformMakeTranslation(translation.x, translation.y);
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled)
    {
        CGRect frame = self.panel.frame;
        self.panel.transform = CGAffineTransformIdentity;
        UIView *root = self.window.rootViewController.view;
        frame.origin.x = MAX(8, MIN(frame.origin.x, root.bounds.size.width - frame.size.width - 8));
        frame.origin.y = MAX(40, MIN(frame.origin.y, root.bounds.size.height - frame.size.height - 40));
        self.panel.translatesAutoresizingMaskIntoConstraints = YES;
        self.panel.frame = frame;
    }
}

- (void)toggleCollapse
{
    self.collapsed = !self.collapsed;
    for (UIView *view in self.panel.subviews)
    {
        if (view == self.statusLabel || view == self.collapseButton)
        {
            continue;
        }
        if ([view isKindOfClass:[UIStackView class]])
        {
            view.hidden = self.collapsed;
        }
    }
}

- (void)refreshButtons
{
    FXMediaStore *store = [FXMediaStore shared];
    for (UIButton *button in self.modeButtons)
    {
        NSInteger mode = button.tag - 100;
        BOOL selected = (NSInteger)store.mode == mode;
        button.backgroundColor = selected ? [UIColor colorWithRed:0.23 green:0.63 blue:1.0 alpha:0.9]
                                          : [UIColor colorWithWhite:1.0 alpha:0.12];
    }

    [self.rotateButton setTitle:[NSString stringWithFormat:@"旋转 %ld°", (long)store.rotation] forState:UIControlStateNormal];
    [self.mirrorButton setTitle:store.mirror ? @"镜像：开" : @"镜像：关" forState:UIControlStateNormal];
    [self.audioButton setTitle:store.audioReplaceEnabled ? @"音频替换：开" : @"音频替换：关" forState:UIControlStateNormal];
    FXLicense *license = [FXLicense shared];
    if (!license.loggedIn)
    {
        [self.accountButton setTitle:@"账号与卡包（未登录）" forState:UIControlStateNormal];
        self.accountButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    }
    else if ([license isAuthorized])
    {
        [self.accountButton setTitle:@"账号与卡包（已授权）" forState:UIControlStateNormal];
        self.accountButton.backgroundColor = [UIColor colorWithRed:0.21 green:0.78 blue:0.35 alpha:0.85];
    }
    else
    {
        [self.accountButton setTitle:@"账号与卡包（待激活）" forState:UIControlStateNormal];
        self.accountButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.04 alpha:0.85];
    }

    self.statusLabel.text = store.statusText;
}

- (void)modeTapped:(UIButton *)sender
{
    NSInteger mode = sender.tag - 100;
    FXMediaStore *store = [FXMediaStore shared];
    FXUSBSource *usb = [FXUSBSource shared];
    FXFileSource *file = [FXFileSource shared];
    FXRTMPSource *rtmp = [FXRTMPSource shared];

    if (mode != FXSourceModeRealCamera && ![[FXLicense shared] isAuthorized])
    {
        [store setStatus:@"授权已失效，正在重新验证…"];
        [[FXLicense shared] refreshNowWithCompletion:nil];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未授权"
                                                                       message:@"请先在「账号与卡包」里登录并激活卡密。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
        [self refreshButtons];
        return;
    }

    switch (mode)
    {
        case FXSourceModeRealCamera:
        {
            [usb stop];
            [file stop];
            [rtmp stop];
            [store setMode:FXSourceModeRealCamera];
            [store invalidateVideo];
            [store resetAudio];
            [store setStatus:@"真实摄像头 · 前置始终保持真实画面"];
            break;
        }
        case FXSourceModeUSB:
        {
            [file stop];
            [rtmp stop];
            [usb setListenPort:28767];
            [usb start];
            break;
        }
        case FXSourceModeRTMP:
        {
            [usb stop];
            [file stop];
            [self promptForRTMPURL];
            break;
        }
        case FXSourceModeLocalFile:
        {
            [usb stop];
            [rtmp stop];
            [self presentDocumentPicker];
            break;
        }
        default:
            break;
    }

    [self refreshButtons];
}

- (void)promptForRTMPURL
{
    UIWindow *window = self.window;
    UIViewController *presenter = window.rootViewController;
    if (presenter == nil)
    {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RTMP 拉流"
                                                                   message:@"输入拉流地址。音频替换开启时使用流内声音。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"rtmp://服务器/live/stream";
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        NSString *current = [FXRTMPSource shared].currentURLString;
        if (current.length > 0)
        {
            textField.text = current;
        }
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"连接直播流" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text ?: @"";
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSURL *url = [NSURL URLWithString:text];
        if (url == nil || url.scheme.length == 0)
        {
            [[FXMediaStore shared] setStatus:@"请输入有效的 rtmp:// 或 rtmps:// 地址"];
            return;
        }

        if ([url.scheme isEqualToString:@"rtmps"])
        {
            [[FXMediaStore shared] setStatus:@"暂不支持 rtmps，请改用 rtmp://"];
            return;
        }

        [[FXRTMPSource shared] connectURL:url];
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentDocumentPicker
{
    UIViewController *presenter = self.window.rootViewController;
    if (presenter == nil)
    {
        return;
    }

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.movie" ]
                                                               inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (url == nil)
    {
        return;
    }

    NSError *error = nil;
    FXFileSource *file = [FXFileSource shared];
    if (![file openURL:url error:&error])
    {
        [[FXMediaStore shared] setStatus:error.localizedDescription ?: @"视频无法解码，请选择 MP4 / MOV"];
        return;
    }

    [[FXMediaStore shared] setAudioReplaceEnabled:YES];
    [file start];
    [self refreshButtons];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    [[FXMediaStore shared] setStatus:@"已取消选择"];
}

- (void)accountTapped
{
    UIViewController *panel = FXCreateAccountPanel();
    UIViewController *presenter = self.window.rootViewController;
    if (panel == nil || presenter == nil)
    {
        return;
    }
    panel.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [presenter presentViewController:panel animated:YES completion:nil];
}

- (void)rotateTapped
{
    FXMediaStore *store = [FXMediaStore shared];
    NSInteger next = (store.rotation + 90) % 360;
    [store setRotation:next];
    [store setStatus:[NSString stringWithFormat:@"旋转 %ld°", (long)next]];
    [self refreshButtons];
}

- (void)mirrorTapped
{
    FXMediaStore *store = [FXMediaStore shared];
    [store setMirror:!store.mirror];
    [store setStatus:store.mirror ? @"镜像：开" : @"镜像：关"];
    [self refreshButtons];
}

- (void)audioTapped
{
    FXMediaStore *store = [FXMediaStore shared];
    [store setAudioReplaceEnabled:!store.audioReplaceEnabled];
    [store setStatus:store.audioReplaceEnabled ? @"音频替换：开 · USB 电脑声音" : @"音频替换：关 · 真实麦克风"];
    [self refreshButtons];
}

@end

void FXShowOverlay(BOOL show)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[FXOverlayController shared] setVisible:show];
    });
}

void FXAttachOverlayToScene(UIWindowScene *scene)
{
    if (scene == nil)
    {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[FXOverlayController shared] attachToScene:scene];
    });
}
