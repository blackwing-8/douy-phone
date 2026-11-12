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

// 覆盖层窗口的根控制器绝不允许成为第一响应者：
// 否则宿主页面转场时 UIKit 会遍历我们的视图树做 first-responder 提升，增加卡死风险。
@interface FXOverlayRootController : UIViewController
@end

@implementation FXOverlayRootController
- (BOOL)canBecomeFirstResponder { return NO; }
- (BOOL)shouldAutorotate { return NO; }
@end

@interface FXOverlayWindow : UIWindow
@end

@implementation FXOverlayWindow

/*
 * 关键：只让悬浮球 / 面板接收触摸，其它区域一律返回 nil 透传给下层的 App。
 * 之前这个 window 是 Alert 级别的全屏窗口且整块吃触摸，导致注入后宿主（抖音）
 * 点哪都没反应。
 */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *view = [super hitTest:point withEvent:event];
    if (view == nil)
    {
        return nil;
    }
    UIViewController *root = self.rootViewController;
    if (root != nil && view == root.view)
    {
        return nil;
    }
    return view;
}

@end

static NSString *const kFXDefaultsOverlayLeading = @"FXOverlayLeading";
static NSString *const kFXDefaultsOverlayTop     = @"FXOverlayTop";
static const CGFloat kFXBallSize   = 58.0;
static const CGFloat kFXPanelWidth = 300.0;

@interface FXOverlayController : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, strong) FXOverlayWindow *window;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIView *ball;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *modeButtons;
@property (nonatomic, strong) UIButton *audioButton;
@property (nonatomic, strong) UIButton *rotateButton;
@property (nonatomic, strong) UIButton *mirrorButton;
@property (nonatomic, strong) UIButton *collapseButton;
@property (nonatomic, strong) UIButton *accountButton;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, strong) NSLayoutConstraint *panelLeading;
@property (nonatomic, strong) NSLayoutConstraint *panelTop;
@property (nonatomic, strong) NSLayoutConstraint *ballLeading;
@property (nonatomic, strong) NSLayoutConstraint *ballTop;
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

- (UIButton *)makeButton:(NSString *)title action:(SEL)action height:(CGFloat)height fontSize:(CGFloat)fontSize
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    button.titleLabel.lineBreakMode = NSLineBreakByClipping;
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    button.layer.cornerRadius = 10.0;
    button.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:height].active = YES;
    return button;
}

- (UIStackView *)rowWithButtons:(NSArray<UIButton *> *)buttons spacing:(CGFloat)spacing
{
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = spacing;
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

#pragma mark - 悬浮球

- (UIView *)makeBallWithLogo:(UIImage *)logo
{
    UIView *ball = [[UIView alloc] init];
    ball.backgroundColor = [UIColor whiteColor];
    ball.layer.cornerRadius = kFXBallSize / 2.0;
    ball.layer.borderWidth = 2.0;
    ball.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
    ball.layer.shadowColor = [UIColor blackColor].CGColor;
    ball.layer.shadowOpacity = 0.35;
    ball.layer.shadowRadius = 9.0;
    ball.layer.shadowOffset = CGSizeMake(0, 3);
    ball.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *imageView = [[UIImageView alloc] initWithImage:logo];
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.layer.cornerRadius = kFXBallSize / 2.0 - 5.0;
    imageView.userInteractionEnabled = NO;
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [ball addSubview:imageView];
    [NSLayoutConstraint activateConstraints:@[
        [imageView.centerXAnchor constraintEqualToAnchor:ball.centerXAnchor],
        [imageView.centerYAnchor constraintEqualToAnchor:ball.centerYAnchor],
        [imageView.widthAnchor constraintEqualToConstant:kFXBallSize - 10.0],
        [imageView.heightAnchor constraintEqualToConstant:kFXBallSize - 10.0],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(expandPanel)];
    [ball addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [ball addGestureRecognizer:pan];

    return ball;
}

#pragma mark - 构建界面

- (void)attachToScene:(UIWindowScene *)scene
{
    if (self.window != nil)
    {
        return;
    }

    FXOverlayWindow *window = [[FXOverlayWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = [UIColor clearColor];
    window.rootViewController = [[FXOverlayRootController alloc] init];
    window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window = window;

    UIView *root = window.rootViewController.view;
    CGRect screen = scene.screen.bounds;

    // ---------------------------------------------------------- 面板
    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.93];
    panel.layer.cornerRadius = 16.0;
    panel.layer.masksToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    self.panel = panel;
    [root addSubview:panel];

    UIImageView *logoView = [[UIImageView alloc] initWithImage:FXLogoImage()];
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.layer.cornerRadius = 7.0;
    logoView.layer.masksToBounds = YES;
    logoView.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"兜鱼 DOUY";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    [collapse setTitle:@"收起" forState:UIControlStateNormal];
    [collapse setTitleColor:[UIColor colorWithWhite:0.85 alpha:1.0] forState:UIControlStateNormal];
    collapse.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [collapse addTarget:self action:@selector(collapsePanel) forControlEvents:UIControlEventTouchUpInside];
    collapse.translatesAutoresizingMaskIntoConstraints = NO;
    self.collapseButton = collapse;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ logoView, title, collapse ]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [header setCustomSpacing:16.0 afterView:title];
    [logoView.widthAnchor constraintEqualToConstant:26].active = YES;
    [logoView.heightAnchor constraintEqualToConstant:26].active = YES;
    [collapse.widthAnchor constraintEqualToConstant:48].active = YES;

    UILabel *status = [[UILabel alloc] init];
    status.text = [[FXMediaStore shared] statusText];
    status.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    status.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    status.numberOfLines = 2;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;

    UILabel *modeHint = [[UILabel alloc] init];
    modeHint.text = @"画面来源";
    modeHint.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    modeHint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    modeHint.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *real = [self makeButton:@"真实摄像头" action:@selector(modeTapped:) height:46 fontSize:15];
    real.tag = 100 + FXSourceModeRealCamera;
    UIButton *usb = [self makeButton:@"USB 直连" action:@selector(modeTapped:) height:46 fontSize:15];
    usb.tag = 100 + FXSourceModeUSB;
    UIButton *rtmp = [self makeButton:@"RTMP 拉流" action:@selector(modeTapped:) height:46 fontSize:15];
    rtmp.tag = 100 + FXSourceModeRTMP;
    UIButton *local = [self makeButton:@"本地视频" action:@selector(modeTapped:) height:46 fontSize:15];
    local.tag = 100 + FXSourceModeLocalFile;
    [self.modeButtons addObjectsFromArray:@[ real, usb, rtmp, local ]];

    UIStackView *modeRow1 = [self rowWithButtons:@[ real, usb ] spacing:8];
    UIStackView *modeRow2 = [self rowWithButtons:@[ rtmp, local ] spacing:8];

    UILabel *actionHint = [[UILabel alloc] init];
    actionHint.text = @"画面调整";
    actionHint.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    actionHint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    actionHint.translatesAutoresizingMaskIntoConstraints = NO;

    self.rotateButton = [self makeButton:@"旋转 0°" action:@selector(rotateTapped) height:42 fontSize:14];
    self.mirrorButton = [self makeButton:@"镜像：关" action:@selector(mirrorTapped) height:42 fontSize:14];
    self.audioButton = [self makeButton:@"音频替换：关" action:@selector(audioTapped) height:42 fontSize:14];
    UIStackView *actionRow = [self rowWithButtons:@[ self.rotateButton, self.mirrorButton, self.audioButton ] spacing:8];

    self.accountButton = [self makeButton:@"账号与卡包" action:@selector(accountTapped) height:48 fontSize:16];
    self.accountButton.backgroundColor = [UIColor colorWithRed:0.23 green:0.55 blue:1.0 alpha:0.85];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        header, status, modeHint, modeRow1, modeRow2, actionHint, actionRow, self.accountButton
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content setCustomSpacing:4.0 afterView:status];
    [content setCustomSpacing:4.0 afterView:modeHint];
    [content setCustomSpacing:4.0 afterView:actionHint];
    [content setCustomSpacing:14.0 afterView:actionRow];
    [panel addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16],
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
        [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-16],
        [panel.widthAnchor constraintEqualToConstant:kFXPanelWidth],
    ]];

    // 位置（可记住上次拖动的位置）
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat savedLeading = [defaults doubleForKey:kFXDefaultsOverlayLeading];
    CGFloat savedTop = [defaults doubleForKey:kFXDefaultsOverlayTop];
    if (savedLeading <= 0)
    {
        savedLeading = MAX(10.0, screen.size.width - kFXPanelWidth - 14.0);
    }
    if (savedTop <= 0)
    {
        savedTop = 110.0;
    }

    self.panelLeading = [panel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:savedLeading];
    self.panelTop = [panel.topAnchor constraintEqualToAnchor:root.topAnchor constant:savedTop];
    self.panelLeading.active = YES;
    self.panelTop.active = YES;

    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [panel addGestureRecognizer:panelPan];

    // ---------------------------------------------------------- 悬浮球（收起态）
    UIView *ball = [self makeBallWithLogo:FXLogoImage()];
    self.ball = ball;
    [root addSubview:ball];

    self.ballLeading = [ball.leadingAnchor constraintEqualToAnchor:root.leadingAnchor
                                                          constant:MAX(10.0, screen.size.width - kFXBallSize - 18.0)];
    self.ballTop = [ball.topAnchor constraintEqualToAnchor:root.topAnchor constant:savedTop];
    NSLayoutConstraint *ballW = [ball.widthAnchor constraintEqualToConstant:kFXBallSize];
    NSLayoutConstraint *ballH = [ball.heightAnchor constraintEqualToConstant:kFXBallSize];
    self.ballLeading.active = YES;
    self.ballTop.active = YES;
    ballW.active = YES;
    ballH.active = YES;

    ball.hidden = YES;

    window.hidden = NO;
    [self refreshButtons];
}

- (void)setVisible:(BOOL)visible
{
    self.window.hidden = !visible;
}

#pragma mark - 拖动 / 收起 / 展开

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    UIView *root = self.window.rootViewController.view;
    if (root == nil)
    {
        return;
    }
    CGPoint translation = [pan translationInView:root];

    if (pan.view == self.ball)
    {
        CGFloat maxX = MAX(10.0, root.bounds.size.width - kFXBallSize - 10.0);
        CGFloat maxY = MAX(60.0, root.bounds.size.height - kFXBallSize - 40.0);
        self.ballLeading.constant = MAX(10.0, MIN(self.ballLeading.constant + translation.x, maxX));
        self.ballTop.constant = MAX(60.0, MIN(self.ballTop.constant + translation.y, maxY));
    }
    else
    {
        [self.panel layoutIfNeeded];
        CGFloat panelH = self.panel.bounds.size.height;
        CGFloat maxX = MAX(10.0, root.bounds.size.width - kFXPanelWidth - 10.0);
        CGFloat maxY = MAX(60.0, root.bounds.size.height - panelH - 30.0);
        self.panelLeading.constant = MAX(10.0, MIN(self.panelLeading.constant + translation.x, maxX));
        self.panelTop.constant = MAX(60.0, MIN(self.panelTop.constant + translation.y, maxY));
    }

    [pan setTranslation:CGPointZero inView:root];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled)
    {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:self.panelLeading.constant forKey:kFXDefaultsOverlayLeading];
        [defaults setDouble:self.panelTop.constant forKey:kFXDefaultsOverlayTop];
    }
}

- (void)collapsePanel
{
    self.collapsed = YES;
    self.panel.hidden = YES;
    self.ball.hidden = NO;

    // 球放到面板右上角，视觉上像「缩成一个圆球」
    self.ballTop.constant = self.panelTop.constant + 8.0;
    self.ballLeading.constant = self.panelLeading.constant + kFXPanelWidth - kFXBallSize - 8.0;
}

- (void)expandPanel
{
    self.collapsed = NO;
    self.ball.hidden = YES;
    self.panel.hidden = NO;
}

- (void)toggleCollapse
{
    if (self.collapsed)
    {
        [self expandPanel];
    }
    else
    {
        [self collapsePanel];
    }
}

- (void)refreshButtons
{
    FXMediaStore *store = [FXMediaStore shared];
    for (UIButton *button in self.modeButtons)
    {
        NSInteger mode = button.tag - 100;
        BOOL selected = (NSInteger)store.mode == mode;
        button.backgroundColor = selected ? [UIColor colorWithRed:0.23 green:0.63 blue:1.0 alpha:0.95]
                                          : [UIColor colorWithWhite:1.0 alpha:0.14];
    }

    [self.rotateButton setTitle:[NSString stringWithFormat:@"旋转 %ld°", (long)store.rotation] forState:UIControlStateNormal];
    [self.mirrorButton setTitle:store.mirror ? @"镜像：开" : @"镜像：关" forState:UIControlStateNormal];
    [self.audioButton setTitle:store.audioReplaceEnabled ? @"音频替换：开" : @"音频替换：关" forState:UIControlStateNormal];

    FXLicense *license = [FXLicense shared];
    if (!license.loggedIn)
    {
        [self.accountButton setTitle:@"账号与卡包（未登录）" forState:UIControlStateNormal];
        self.accountButton.backgroundColor = [UIColor colorWithRed:0.23 green:0.55 blue:1.0 alpha:0.85];
    }
    else if ([license isAuthorized])
    {
        [self.accountButton setTitle:@"账号与卡包（已授权）" forState:UIControlStateNormal];
        self.accountButton.backgroundColor = [UIColor colorWithRed:0.21 green:0.78 blue:0.35 alpha:0.9];
    }
    else
    {
        [self.accountButton setTitle:@"账号与卡包（待激活）" forState:UIControlStateNormal];
        self.accountButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.04 alpha:0.9];
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
