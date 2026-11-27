//
//  FXOverlay.mm —— 悬浮窗（兜鱼图标 + 少量控件）
//
//  控件：本地选图 / 替换开关 / 诊断 / 收起成球
//  卡密入口先预留位置（后续接授权）。
//

#import "FXCommon.h"
#import <objc/runtime.h>

static const CGFloat kPanelWidth = 268;
static const CGFloat kBallSize = 56;

#pragma mark - 穿透窗口

@interface FXOverlayWindow : UIWindow
@end

@implementation FXOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    // 只在点到浮窗自身内容时接管触摸，其它一律放行
    if (v == self || v == self.rootViewController.view)
    {
        return nil;
    }
    return v;
}

@end

#pragma mark - 控制器

@interface FXOverlayController : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *replaceButton;
@property (nonatomic, strong) UIButton *thumbView;
@end

@implementation FXOverlayController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self buildPanel];
    [self buildBall];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeChanged)
                                                 name:@"FXPhotoStoreChanged"
                                               object:nil];
    [self refresh];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)action height:(CGFloat)height fontSize:(CGFloat)fontSize
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    b.layer.cornerRadius = 9;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.heightAnchor constraintEqualToConstant:height].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPanel
{
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(16, 120, kPanelWidth, 300)];
    panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    panel.layer.cornerRadius = 16;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.userInteractionEnabled = YES;
    self.panel = panel;
    [self.view addSubview:panel];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [panel addGestureRecognizer:pan];

    // 头部
    UIImageView *logo = [[UIImageView alloc] initWithImage:FXLogoImage()];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.layer.cornerRadius = 7;
    logo.layer.masksToBounds = YES;
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:26].active = YES;
    [logo.heightAnchor constraintEqualToConstant:26].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"兜鱼 · 原相机替换";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    [collapse setTitle:@"收起" forState:UIControlStateNormal];
    [collapse setTitleColor:[UIColor colorWithWhite:0.85 alpha:1.0] forState:UIControlStateNormal];
    collapse.titleLabel.font = [UIFont systemFontOfSize:14];
    [collapse addTarget:self action:@selector(collapseTapped) forControlEvents:UIControlEventTouchUpInside];
    collapse.translatesAutoresizingMaskIntoConstraints = NO;
    [collapse.widthAnchor constraintEqualToConstant:44].active = YES;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[ logo, title, collapse ]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 8;
    header.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *status = [[UILabel alloc] init];
    status.text = [[FXPhotoStore shared] statusText];
    status.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    status.font = [UIFont systemFontOfSize:13];
    status.numberOfLines = 2;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = status;

    // 缩略图（点一下可以换图）
    UIButton *thumb = [UIButton buttonWithType:UIButtonTypeCustom];
    thumb.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    thumb.layer.cornerRadius = 8;
    thumb.layer.masksToBounds = YES;
    thumb.contentMode = UIViewContentModeScaleAspectFit;
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    [thumb.heightAnchor constraintEqualToConstant:120].active = YES;
    [thumb addTarget:self action:@selector(pickTapped) forControlEvents:UIControlEventTouchUpInside];
    self.thumbView = thumb;

    UIButton *pick = [self makeButton:@"本地选图" action:@selector(pickTapped) height:42 fontSize:15];
    self.replaceButton = [self makeButton:@"替换：关" action:@selector(replaceTapped) height:42 fontSize:15];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ pick, self.replaceButton ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.distribution = UIStackViewDistributionFillEqually;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *diag = [self makeButton:@"诊断" action:@selector(diagTapped) height:36 fontSize:14];
    UIButton *lan = [self makeButton:@"局域网取图" action:@selector(lanTapped) height:36 fontSize:14];

    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[ lan, diag ]];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.spacing = 8;
    row2.distribution = UIStackViewDistributionFillEqually;
    row2.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[ header, status, thumb, row, row2 ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 10;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [panel.widthAnchor constraintEqualToConstant:kPanelWidth],
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14],
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor constant:14],
        [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-14],
    ]];
}

- (void)buildBall
{
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    [ball setImage:FXLogoImage() forState:UIControlStateNormal];
    ball.imageView.contentMode = UIViewContentModeScaleAspectFit;
    ball.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    ball.layer.cornerRadius = kBallSize / 2;
    ball.layer.masksToBounds = YES;
    ball.frame = CGRectMake(16, 120, kBallSize, kBallSize);
    ball.translatesAutoresizingMaskIntoConstraints = NO;
    [ball.widthAnchor constraintEqualToConstant:kBallSize].active = YES;
    [ball.heightAnchor constraintEqualToConstant:kBallSize].active = YES;
    [ball addTarget:self action:@selector(expandTapped) forControlEvents:UIControlEventTouchUpInside];
    [ball addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
    ball.hidden = YES;
    self.ball = ball;
    [self.view addSubview:ball];
}

#pragma mark - 交互

- (void)handlePan:(UIPanGestureRecognizer *)g
{
    UIView *v = g.view;
    CGPoint t = [g translationInView:self.view];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.view];
}

- (void)collapseTapped
{
    self.panel.hidden = YES;
    self.ball.hidden = NO;
    self.ball.center = self.panel.center;
}

- (void)expandTapped
{
    self.panel.hidden = NO;
    self.ball.hidden = YES;
}

- (void)replaceTapped
{
    FXPhotoStore *store = [FXPhotoStore shared];
    store.replaceEnabled = !store.replaceEnabled;
    [self refresh];
}

- (void)pickTapped
{
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)lanTapped
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"局域网取图"
                                                                  message:@"输入电脑「兜鱼选图」上显示的地址（IP:端口）"
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"192.168.1.5:28900";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"连接" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text;
        NSArray *parts = [text componentsSeparatedByString:@":"];
        if (parts.count == 2 && [parts[1] intValue] > 0)
        {
            FXLanStart(parts[0], [parts[1] intValue]);
        }
        else
        {
            [[FXPhotoStore shared] setStatus:@"地址格式不对，应形如 192.168.1.5:28900"];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"停止同步" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { FXLanStop(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)diagTapped
{
    FXPhotoStore *store = [FXPhotoStore shared];
    NSString *msg = [NSString stringWithFormat:@"%@\n%@\n\n%@\n开关：%@ · 有图：%@",
                     [store statusText],
                     FXLanStatus(),
                     FXPhotoStatsReport(),
                     store.replaceEnabled ? @"开" : @"关",
                     [store hasPhoto] ? @"是" : @"否"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"原相机替换 · 诊断"
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 选图回调

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info
{
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (image == nil)
    {
        return;
    }

    NSData *jpeg = UIImageJPEGRepresentation(image, 0.92);
    if (jpeg.length == 0)
    {
        return;
    }

    [[FXPhotoStore shared] setPhotoData:jpeg
                                   name:@"本地图片"
                                 source:FXPhotoSourceLocal];
    [[FXPhotoStore shared] setStatus:[NSString stringWithFormat:@"已选定本地图片 · %.0f×%.0f",
                                      image.size.width, image.size.height]];
    [self refresh];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - 刷新

- (void)storeChanged
{
    [self refresh];
}

- (void)refresh
{
    FXPhotoStore *store = [FXPhotoStore shared];
    self.statusLabel.text = [store statusText];
    [self.replaceButton setTitle:store.replaceEnabled ? @"替换：开" : @"替换：关"
                        forState:UIControlStateNormal];
    self.replaceButton.backgroundColor = store.replaceEnabled
        ? [UIColor colorWithRed:0.23 green:0.55 blue:1.0 alpha:0.85]
        : [UIColor colorWithWhite:1.0 alpha:0.16];

    NSData *data = [store currentData];
    UIImage *img = data.length > 0 ? [UIImage imageWithData:data] : nil;
    [self.thumbView setImage:img forState:UIControlStateNormal];
    self.thumbView.imageView.contentMode = UIViewContentModeScaleAspectFit;
}

@end

#pragma mark - 挂载

void FXAttachOverlayToScene(UIWindowScene *scene)
{
    static UIWindow *overlayWindow = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (scene == nil)
        {
            return;
        }
        overlayWindow = [[FXOverlayWindow alloc] initWithWindowScene:scene];
        overlayWindow.windowLevel = UIWindowLevelAlert + 1;
        overlayWindow.backgroundColor = [UIColor clearColor];
        overlayWindow.rootViewController = [[FXOverlayController alloc] init];
        overlayWindow.hidden = NO;
        NSLog(@"[原相机替换] 浮窗已挂载");
    });
}
