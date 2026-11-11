//
//  FXAccountPanel.mm —— 账号与卡包面板
//
//  由浮窗按钮弹出（presentViewController:）。职责：
//    * 未登录：用户名 / 密码 / 邮箱 / 推荐码 → 登录、注册；
//    * 已登录：账号与设备信息、授权状态、卡密激活、备用卡包、刷新、退出、检查更新；
//    * 订阅 FXLicenseDidChangeNotification 自动刷新界面。
//
//  纯 UIKit + FXLicense，零第三方依赖，ARC。颜色与主浮窗保持一致。
//

#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import "FXLicense.h"
#import "FXCommon.h"

#pragma mark - 配色

static UIColor *FXAPColor(uint32_t hex)
{
    CGFloat red = (CGFloat)((hex >> 16) & 0xFFu) / 255.0;
    CGFloat green = (CGFloat)((hex >> 8) & 0xFFu) / 255.0;
    CGFloat blue = (CGFloat)(hex & 0xFFu) / 255.0;
    return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
}

static UIColor *FXAPBackgroundColor(void) { return FXAPColor(0x1E1F22); }
static UIColor *FXAPCardColor(void) { return FXAPColor(0x2B2D31); }
static UIColor *FXAPTextColor(void) { return FXAPColor(0xE6E6E6); }
static UIColor *FXAPTextSecondaryColor(void) { return FXAPColor(0x9AA0A6); }
static UIColor *FXAPAccentColor(void) { return FXAPColor(0x3AA0FF); }
static UIColor *FXAPSuccessColor(void) { return FXAPColor(0x35C759); }
static UIColor *FXAPWarningColor(void) { return FXAPColor(0xFF9F0A); }

#pragma mark - 取值小工具（服务端字段可能为 null / 字符串 / 数字）

static NSString *FXAPStringValue(id value)
{
    if ([value isKindOfClass:[NSString class]])
    {
        return (NSString *)value;
    }
    if ([value isKindOfClass:[NSNumber class]])
    {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

static int64_t FXAPInt64Value(id value)
{
    if ([value isKindOfClass:[NSNumber class]])
    {
        return [(NSNumber *)value longLongValue];
    }
    if ([value isKindOfClass:[NSString class]])
    {
        return [(NSString *)value longLongValue];
    }
    return 0;
}

static BOOL FXAPBoolValue(id value)
{
    if ([value isKindOfClass:[NSNumber class]])
    {
        return [(NSNumber *)value boolValue];
    }
    if ([value isKindOfClass:[NSString class]])
    {
        NSString *text = [(NSString *)value lowercaseString];
        return [text isEqualToString:@"1"] || [text isEqualToString:@"true"] || [text isEqualToString:@"yes"];
    }
    return NO;
}

static int64_t FXAPNowMs(void)
{
    return (int64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static NSString *FXAPFormatDate(int64_t ms)
{
    if (ms <= 0)
    {
        return @"—";
    }

    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone localTimeZone];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });

    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)ms / 1000.0];
    NSString *text = [formatter stringFromDate:date];
    return text.length > 0 ? text : @"—";
}

static NSString *FXAPFormatSize(int64_t bytes)
{
    if (bytes <= 0)
    {
        return @"—";
    }
    if (bytes >= (int64_t)(1024 * 1024))
    {
        return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
    }
    if (bytes >= 1024)
    {
        return [NSString stringWithFormat:@"%.0f KB", (double)bytes / 1024.0];
    }
    return [NSString stringWithFormat:@"%lld B", (long long)bytes];
}

#pragma mark - 带内边距的输入框

@interface FXAPTextField : UITextField
@end

@implementation FXAPTextField

- (CGRect)textRectForBounds:(CGRect)bounds
{
    return CGRectInset(bounds, 12.0, 4.0);
}

- (CGRect)editingRectForBounds:(CGRect)bounds
{
    return CGRectInset(bounds, 12.0, 4.0);
}

- (CGRect)placeholderRectForBounds:(CGRect)bounds
{
    return CGRectInset(bounds, 12.0, 4.0);
}

@end

#pragma mark - 面板

@interface FXAccountPanelController : UIViewController <UITextFieldDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;

@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) UIView *gateBox;
@property (nonatomic, strong) UILabel *gateLabel;

@property (nonatomic, strong) UIStackView *loginSection;
@property (nonatomic, strong) FXAPTextField *usernameField;
@property (nonatomic, strong) FXAPTextField *passwordField;
@property (nonatomic, strong) FXAPTextField *emailField;
@property (nonatomic, strong) FXAPTextField *referralField;
@property (nonatomic, strong) UILabel *loginHintLabel;

@property (nonatomic, strong) UIStackView *accountSection;
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UILabel *deviceLabel;
@property (nonatomic, strong) UILabel *authLabel;
@property (nonatomic, strong) UILabel *expiryLabel;
@property (nonatomic, strong) FXAPTextField *cardField;
@property (nonatomic, strong) UILabel *actionHintLabel;
@property (nonatomic, strong) UIStackView *cardsStack;

@property (nonatomic, strong) NSMutableArray<UIButton *> *allButtons;
@property (nonatomic, strong) NSMutableArray<FXAPTextField *> *allFields;
@property (nonatomic, weak) FXAPTextField *activeField;
@property (nonatomic, assign) BOOL requestInFlight;

- (void)scrollActiveFieldIntoViewAnimated:(BOOL)animated;

@end

@implementation FXAccountPanelController

#pragma mark 生命周期

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _allButtons = [NSMutableArray array];
        _allFields = [NSMutableArray array];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];
    [self buildInterface];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(licenseDidChange:)
                                                 name:FXLicenseDidChangeNotification
                                               object:nil];

    [self reloadUI];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIKeyboardWillChangeFrameNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillChangeFrame:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [self reloadUI];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIKeyboardWillChangeFrameNotification
                                                  object:nil];
    [self.view endEditing:YES];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    FXLicense *license = [FXLicense shared];
    if (!license.loggedIn)
    {
        return;
    }

    [self setHint:self.actionHintLabel text:@"正在核实授权…" color:FXAPTextSecondaryColor()];
    __weak typeof(self) weakSelf = self;
    [license refreshNowWithCompletion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            if ([message isKindOfClass:[NSString class]] && message.length > 0)
            {
                [weakSelf setHint:weakSelf.actionHintLabel
                             text:message
                            color:(ok ? FXAPSuccessColor() : FXAPWarningColor())];
            }
            [weakSelf reloadUI];
        }];
    }];
}

#pragma mark 界面搭建

- (void)buildInterface
{
    if (self.allButtons == nil)
    {
        self.allButtons = [NSMutableArray array];
    }
    if (self.allFields == nil)
    {
        self.allFields = [NSMutableArray array];
    }

    UIView *dimView = [[UIView alloc] init];
    dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    dimView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:dimView];
    [dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(dimTapped)]];

    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = FXAPBackgroundColor();
    panel.layer.cornerRadius = 16.0;
    panel.layer.masksToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:panel];
    self.panelView = panel;

    UITapGestureRecognizer *panelTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                             action:@selector(panelTapped)];
    panelTap.cancelsTouchesInView = NO;
    panelTap.delegate = self;
    [panel addGestureRecognizer:panelTap];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"兜鱼 · 账号与卡包";
    titleLabel.textColor = FXAPTextColor();
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *titleSpacer = [[UIView alloc] init];
    titleSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [titleSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [titleSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                 forAxis:UILayoutConstraintAxisHorizontal];
    [titleSpacer.heightAnchor constraintEqualToConstant:1.0].active = YES;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = FXAPTextSecondaryColor();
    spinner.hidesWhenStopped = YES;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner = spinner;

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    [closeButton setTitleColor:FXAPAccentColor() forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    [closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *headerRow = [[UIStackView alloc] initWithArrangedSubviews:@[ titleLabel, titleSpacer, spinner, closeButton ]];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 8.0;
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:headerRow];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"正在读取授权状态…";
    subtitle.textColor = FXAPTextSecondaryColor();
    subtitle.font = [UIFont systemFontOfSize:12.0];
    subtitle.numberOfLines = 2;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel = subtitle;
    [panel addSubview:subtitle];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.backgroundColor = [UIColor clearColor];
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:scroll];
    self.scrollView = scroll;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    self.contentStack = stack;

    [stack addArrangedSubview:[self makeGateBox]];
    [stack addArrangedSubview:[self makeLoginSection]];
    [stack addArrangedSubview:[self makeAccountSection]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *panelWidth = [panel.widthAnchor constraintEqualToConstant:360.0];
    panelWidth.priority = 999.0;
    NSLayoutConstraint *panelHeight = [panel.heightAnchor constraintEqualToConstant:560.0];
    panelHeight.priority = 999.0;

    [NSLayoutConstraint activateConstraints:@[
        [dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        panelWidth,
        panelHeight,
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-24.0],
        [panel.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-32.0],
        [panel.heightAnchor constraintGreaterThanOrEqualToConstant:300.0],

        [headerRow.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16.0],
        [headerRow.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18.0],
        [headerRow.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-18.0],

        [subtitle.topAnchor constraintEqualToAnchor:headerRow.bottomAnchor constant:2.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18.0],
        [subtitle.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-18.0],

        [scroll.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:8.0],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:4.0],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:18.0],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-18.0],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28.0],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36.0],
    ]];
}

- (UIView *)makeGateBox
{
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = [FXAPWarningColor() colorWithAlphaComponent:0.16];
    box.layer.cornerRadius = 8.0;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.hidden = YES;
    self.gateBox = box;

    UILabel *label = [[UILabel alloc] init];
    label.text = @"授权已失效，正在重新验证…";
    label.textColor = FXAPWarningColor();
    label.font = [UIFont systemFontOfSize:12.0];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    self.gateLabel = label;

    [box addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:box.topAnchor constant:8.0],
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],
        [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8.0],
    ]];
    return box;
}

- (UIStackView *)makeLoginSection
{
    UIStackView *section = [[UIStackView alloc] init];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 10.0;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    self.loginSection = section;

    [section addArrangedSubview:[self captionLabel:@"账号登录"]];

    self.usernameField = [self makeFieldWithPlaceholder:@"用户名" secure:NO];
    self.usernameField.keyboardType = UIKeyboardTypeDefault;
    self.usernameField.textContentType = UITextContentTypeUsername;

    self.passwordField = [self makeFieldWithPlaceholder:@"密码" secure:YES];
    self.passwordField.textContentType = UITextContentTypePassword;

    self.emailField = [self makeFieldWithPlaceholder:@"邮箱（注册时填写）" secure:NO];
    self.emailField.keyboardType = UIKeyboardTypeEmailAddress;
    self.emailField.textContentType = UITextContentTypeEmailAddress;

    self.referralField = [self makeFieldWithPlaceholder:@"推荐码（可选）" secure:NO];

    [section addArrangedSubview:self.usernameField];
    [section addArrangedSubview:self.passwordField];
    [section addArrangedSubview:self.emailField];
    [section addArrangedSubview:self.referralField];

    UIStackView *row = [self buttonRow];
    [row addArrangedSubview:[self buttonWithTitle:@"登录" action:@selector(loginTapped) primary:YES]];
    [row addArrangedSubview:[self buttonWithTitle:@"创建账号" action:@selector(registerTapped) primary:NO]];
    [section addArrangedSubview:row];

    self.loginHintLabel = [self hintLabel];
    [section addArrangedSubview:self.loginHintLabel];

    return section;
}

- (UIStackView *)makeAccountSection
{
    UIStackView *section = [[UIStackView alloc] init];
    section.axis = UILayoutConstraintAxisVertical;
    section.spacing = 10.0;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    section.hidden = YES;
    self.accountSection = section;

    UILabel *account = [[UILabel alloc] init];
    account.text = @"账号：—";
    account.textColor = FXAPTextColor();
    account.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    account.numberOfLines = 1;
    account.adjustsFontSizeToFitWidth = YES;
    account.minimumScaleFactor = 0.8;
    account.translatesAutoresizingMaskIntoConstraints = NO;
    self.accountLabel = account;

    UILabel *device = [[UILabel alloc] init];
    device.text = @"本机：—";
    device.textColor = FXAPTextSecondaryColor();
    device.font = [UIFont systemFontOfSize:11.0];
    device.numberOfLines = 1;
    device.adjustsFontSizeToFitWidth = YES;
    device.minimumScaleFactor = 0.8;
    device.translatesAutoresizingMaskIntoConstraints = NO;
    self.deviceLabel = device;

    UILabel *auth = [[UILabel alloc] init];
    auth.text = @"已登录 · 请激活卡密或刷新核实授权";
    auth.textColor = FXAPWarningColor();
    auth.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    auth.numberOfLines = 0;
    auth.translatesAutoresizingMaskIntoConstraints = NO;
    self.authLabel = auth;

    UILabel *expiry = [[UILabel alloc] init];
    expiry.text = @"";
    expiry.textColor = FXAPTextSecondaryColor();
    expiry.font = [UIFont systemFontOfSize:11.0];
    expiry.numberOfLines = 0;
    expiry.hidden = YES;
    expiry.translatesAutoresizingMaskIntoConstraints = NO;
    self.expiryLabel = expiry;

    [section addArrangedSubview:account];
    [section addArrangedSubview:device];
    [section addArrangedSubview:auth];
    [section addArrangedSubview:expiry];

    [section addArrangedSubview:[self separatorView]];
    [section addArrangedSubview:[self captionLabel:@"卡密"]];

    self.cardField = [self makeFieldWithPlaceholder:@"已有 iOS 卡密 · 粘贴到这里" secure:NO];
    self.cardField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    [section addArrangedSubview:self.cardField];

    UIStackView *cardRow = [self buttonRow];
    [cardRow addArrangedSubview:[self buttonWithTitle:@"激活并绑定本机" action:@selector(activateCardTapped) primary:YES]];
    [cardRow addArrangedSubview:[self buttonWithTitle:@"仅加入备用卡包" action:@selector(addCardTapped) primary:NO]];
    [section addArrangedSubview:cardRow];

    UILabel *explain = [[UILabel alloc] init];
    explain.text = @"立即使用：激活后绑定本机并开始计时。\n仅存备用：不绑定手机、不开始计时。";
    explain.textColor = FXAPTextSecondaryColor();
    explain.font = [UIFont systemFontOfSize:11.0];
    explain.numberOfLines = 0;
    explain.translatesAutoresizingMaskIntoConstraints = NO;
    [section addArrangedSubview:explain];

    [section addArrangedSubview:[self separatorView]];
    [section addArrangedSubview:[self captionLabel:@"卡包"]];

    UIStackView *cards = [[UIStackView alloc] init];
    cards.axis = UILayoutConstraintAxisVertical;
    cards.spacing = 8.0;
    cards.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardsStack = cards;
    [section addArrangedSubview:cards];

    UIStackView *utilityRow = [self buttonRow];
    [utilityRow addArrangedSubview:[self buttonWithTitle:@"刷新卡包" action:@selector(refreshCardsTapped) primary:NO]];
    [utilityRow addArrangedSubview:[self buttonWithTitle:@"退出登录" action:@selector(logoutTapped) primary:NO]];
    [section addArrangedSubview:utilityRow];

    UIButton *updateButton = [self buttonWithTitle:@"检查更新" action:@selector(checkUpdateTapped) primary:NO];
    [section addArrangedSubview:updateButton];

    self.actionHintLabel = [self hintLabel];
    [section addArrangedSubview:self.actionHintLabel];

    return section;
}

#pragma mark 小组件

- (UILabel *)captionLabel:(NSString *)text
{
    UILabel *label = [[UILabel alloc] init];
    label.text = text ?: @"";
    label.textColor = FXAPTextSecondaryColor();
    label.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    label.numberOfLines = 1;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UILabel *)hintLabel
{
    UILabel *label = [[UILabel alloc] init];
    label.text = @"";
    label.textColor = FXAPTextSecondaryColor();
    label.font = [UIFont systemFontOfSize:11.0];
    label.numberOfLines = 0;
    label.hidden = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (UIView *)separatorView
{
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view.heightAnchor constraintEqualToConstant:1.0].active = YES;
    return view;
}

- (UIStackView *)buttonRow
{
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentFill;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 10.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

- (FXAPTextField *)makeFieldWithPlaceholder:(NSString *)placeholder secure:(BOOL)secure
{
    FXAPTextField *field = [[FXAPTextField alloc] init];
    field.font = [UIFont systemFontOfSize:14.0];
    field.textColor = FXAPTextColor();
    field.tintColor = FXAPAccentColor();
    field.backgroundColor = FXAPCardColor();
    field.layer.cornerRadius = 10.0;
    field.layer.masksToBounds = YES;
    field.layer.borderWidth = 1.0;
    field.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.06].CGColor;
    field.secureTextEntry = secure;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.heightAnchor constraintEqualToConstant:42.0].active = YES;

    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:(placeholder ?: @"")
                                                                    attributes:@{
                                                                        NSForegroundColorAttributeName : FXAPTextSecondaryColor(),
                                                                        NSFontAttributeName : [UIFont systemFontOfSize:14.0]
                                                                    }];
    field.attributedPlaceholder = attributed;

    [self.allFields addObject:field];
    return field;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action primary:(BOOL)primary
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:(title ?: @"") forState:UIControlStateNormal];
    [button setTitleColor:(primary ? [UIColor whiteColor] : FXAPTextColor()) forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.45] forState:UIControlStateDisabled];
    button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    button.backgroundColor = primary ? FXAPAccentColor() : [UIColor colorWithWhite:1.0 alpha:0.08];
    button.layer.cornerRadius = 10.0;
    button.layer.masksToBounds = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:40.0].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.allButtons addObject:button];
    return button;
}

#pragma mark 刷新界面

- (void)licenseDidChange:(NSNotification *)note
{
    __weak typeof(self) weakSelf = self;
    [self onMain:^{
        [weakSelf reloadUI];
    }];
}

- (void)reloadUI
{
    if (![NSThread isMainThread])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadUI];
        });
        return;
    }

    if (self.subtitleLabel == nil || self.loginSection == nil || self.accountSection == nil)
    {
        return;
    }

    FXLicense *license = [FXLicense shared];

    NSString *status = license.statusText;
    self.subtitleLabel.text = status.length > 0 ? status : @"未连接授权服务";

    BOOL loggedIn = license.loggedIn;
    self.loginSection.hidden = loggedIn;
    self.accountSection.hidden = !loggedIn;

    BOOL authorized = [license isAuthorized];
    if (loggedIn && !authorized)
    {
        NSString *gate = (license.state == FXLicenseStateError) ? @"授权凭证格式无效" : @"授权已失效，正在重新验证…";
        self.gateLabel.text = gate;
        self.gateBox.hidden = NO;
    }
    else
    {
        self.gateBox.hidden = YES;
    }

    NSString *name = license.accountName;
    self.accountLabel.text = [NSString stringWithFormat:@"账号：%@", name.length > 0 ? name : @"—"];

    NSString *device = license.deviceIdentifier;
    NSString *deviceText = @"—";
    if (device.length > 12)
    {
        deviceText = [NSString stringWithFormat:@"%@…", [device substringToIndex:12]];
    }
    else if (device.length > 0)
    {
        deviceText = [NSString stringWithFormat:@"%@…", device];
    }
    self.deviceLabel.text = [NSString stringWithFormat:@"本机：%@", deviceText];

    if (authorized)
    {
        self.authLabel.text = @"已激活 · 全部功能可用";
        self.authLabel.textColor = FXAPSuccessColor();
        self.expiryLabel.text = [NSString stringWithFormat:@"到期时间 %@", FXAPFormatDate(license.licenseExpiryMs)];
        self.expiryLabel.hidden = NO;
    }
    else
    {
        self.authLabel.text = @"已登录 · 请激活卡密或刷新核实授权";
        self.authLabel.textColor = FXAPWarningColor();
        self.expiryLabel.text = @"";
        self.expiryLabel.hidden = YES;
    }

    [self rebuildCards];
}

- (void)rebuildCards
{
    for (UIView *view in [self.cardsStack.arrangedSubviews copy])
    {
        [self.cardsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSArray *cards = [FXLicense shared].cards;
    NSInteger added = 0;
    if ([cards isKindOfClass:[NSArray class]])
    {
        for (id item in cards)
        {
            if (![item isKindOfClass:[NSDictionary class]])
            {
                continue;
            }
            [self.cardsStack addArrangedSubview:[self cardRowForCard:(NSDictionary *)item]];
            added++;
        }
    }

    if (added == 0)
    {
        [self.cardsStack addArrangedSubview:[self emptyCardsBox]];
    }
}

- (UIView *)emptyCardsBox
{
    UIView *box = [[UIView alloc] init];
    box.backgroundColor = FXAPCardColor();
    box.layer.cornerRadius = 10.0;
    box.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *label = [[UILabel alloc] init];
    label.text = @"暂无卡密\n在线购买或添加全新卡密后，将显示在这里。";
    label.textColor = FXAPTextSecondaryColor();
    label.font = [UIFont systemFontOfSize:11.5];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [box addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:box.topAnchor constant:14.0],
        [label.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-12.0],
        [label.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-14.0],
    ]];
    return box;
}

- (UIView *)cardRowForCard:(NSDictionary *)card
{
    NSString *masked = FXAPStringValue(card[@"masked"]);
    if (masked.length == 0)
    {
        masked = @"卡密";
    }

    int64_t days = FXAPInt64Value(card[@"days"]);
    int64_t expires = FXAPInt64Value(card[@"expires_ms"]);
    BOOL currentDevice = FXAPBoolValue(card[@"current_device"]);
    BOOL usable = FXAPBoolValue(card[@"usable"]);
    int64_t now = FXAPNowMs();

    NSString *statusText = nil;
    UIColor *statusColor = nil;
    if (currentDevice)
    {
        statusText = @"当前使用中";
        statusColor = FXAPSuccessColor();
    }
    else if (!usable || (expires > 0 && expires <= now))
    {
        statusText = @"已过期";
        statusColor = FXAPWarningColor();
    }
    else
    {
        statusText = @"备用中 · 未开始计时";
        statusColor = FXAPAccentColor();
    }

    UILabel *maskedLabel = [[UILabel alloc] init];
    maskedLabel.text = masked;
    maskedLabel.textColor = FXAPTextColor();
    maskedLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];
    maskedLabel.numberOfLines = 1;
    maskedLabel.adjustsFontSizeToFitWidth = YES;
    maskedLabel.minimumScaleFactor = 0.75;
    maskedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [maskedLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *daysLabel = [[UILabel alloc] init];
    daysLabel.text = days > 0 ? [NSString stringWithFormat:@"%lld 天", (long long)days] : @"";
    daysLabel.textColor = FXAPTextSecondaryColor();
    daysLabel.font = [UIFont systemFontOfSize:11.0];
    daysLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [daysLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIView *spacer = [[UIView alloc] init];
    spacer.userInteractionEnabled = NO;
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                            forAxis:UILayoutConstraintAxisHorizontal];
    [spacer.heightAnchor constraintEqualToConstant:1.0].active = YES;

    UILabel *statusLabel = [[UILabel alloc] init];
    statusLabel.text = statusText;
    statusLabel.textColor = statusColor;
    statusLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    statusLabel.textAlignment = NSTextAlignmentRight;
    statusLabel.numberOfLines = 1;
    statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [statusLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [statusLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[ maskedLabel, daysLabel, spacer, statusLabel ]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = 6.0;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *bottomLabel = [[UILabel alloc] init];
    bottomLabel.text = expires > 0 ? [NSString stringWithFormat:@"到期 %@", FXAPFormatDate(expires)]
                                   : @"未开始计时 · 绑定本机后开始计时";
    bottomLabel.textColor = FXAPTextSecondaryColor();
    bottomLabel.font = [UIFont systemFontOfSize:10.5];
    bottomLabel.numberOfLines = 1;
    bottomLabel.adjustsFontSizeToFitWidth = YES;
    bottomLabel.minimumScaleFactor = 0.8;
    bottomLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:@[ topRow, bottomLabel ]];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.alignment = UIStackViewAlignmentFill;
    inner.spacing = 4.0;
    inner.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *row = [[UIView alloc] init];
    row.backgroundColor = FXAPCardColor();
    row.layer.cornerRadius = 10.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:row.topAnchor constant:9.0],
        [inner.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:11.0],
        [inner.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-11.0],
        [inner.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-9.0],
    ]];

    return row;
}

#pragma mark 提示 / 忙碌状态

- (void)setHint:(UILabel *)label text:(NSString *)text color:(UIColor *)color
{
    if (label == nil)
    {
        return;
    }
    NSString *safeText = [text isKindOfClass:[NSString class]] ? text : @"";
    label.text = safeText;
    label.textColor = color ?: FXAPTextSecondaryColor();
    label.hidden = (safeText.length == 0);
}

- (void)setBusy:(BOOL)busy
{
    self.requestInFlight = busy;

    for (UIButton *button in self.allButtons)
    {
        button.enabled = !busy;
        button.alpha = busy ? 0.5 : 1.0;
    }
    for (FXAPTextField *field in self.allFields)
    {
        field.enabled = !busy;
    }

    if (busy)
    {
        [self.spinner startAnimating];
    }
    else
    {
        [self.spinner stopAnimating];
    }
}

/// FXLicense 的回调可能来自后台线程，统一切回主线程再动 UI。
- (void)onMain:(dispatch_block_t)block
{
    if (block == nil)
    {
        return;
    }
    if ([NSThread isMainThread])
    {
        block();
        return;
    }
    dispatch_async(dispatch_get_main_queue(), block);
}

/// 请求收尾：解除忙碌、给出中文提示、刷新界面。message 为空时用 fallback。
- (void)finishRequest:(UILabel *)label ok:(BOOL)ok message:(NSString *)message fallback:(NSString *)fallback
{
    [self setBusy:NO];

    NSString *text = [message isKindOfClass:[NSString class]] ? message : nil;
    if (text.length == 0)
    {
        text = [fallback isKindOfClass:[NSString class]] ? fallback : @"";
    }
    if (text.length == 0)
    {
        text = ok ? @"操作成功" : @"操作失败，请稍后重试";
    }

    [self setHint:label text:text color:(ok ? FXAPSuccessColor() : FXAPWarningColor())];
    [self reloadUI];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message
{
    if (![NSThread isMainThread])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlertWithTitle:title message:message];
        });
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(title ?: @"")
                                                                   message:(message ?: @"")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];

    UIViewController *existing = self.presentedViewController;
    __weak typeof(self) weakSelf = self;
    if (existing != nil)
    {
        [existing dismissViewControllerAnimated:NO
                                     completion:^{
            if (weakSelf.presentedViewController == nil)
            {
                [weakSelf presentViewController:alert animated:YES completion:nil];
            }
        }];
        return;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)trimmed:(NSString *)text
{
    if (![text isKindOfClass:[NSString class]])
    {
        return @"";
    }
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark 账号动作

- (void)loginTapped
{
    if (self.requestInFlight) { return; }

    NSString *username = [self trimmed:self.usernameField.text];
    NSString *password = self.passwordField.text ?: @"";
    if (username.length == 0)
    {
        [self setHint:self.loginHintLabel text:@"请输入用户名" color:FXAPWarningColor()];
        return;
    }
    if (password.length == 0)
    {
        [self setHint:self.loginHintLabel text:@"请输入密码" color:FXAPWarningColor()];
        return;
    }

    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.loginHintLabel text:@"正在登录…" color:FXAPTextSecondaryColor()];

    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] loginWithUsername:username password:password completion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            [weakSelf finishRequest:weakSelf.loginHintLabel
                                ok:ok
                           message:message
                          fallback:(ok ? @"登录成功" : @"登录失败，请检查用户名或密码")];
            if (ok)
            {
                weakSelf.passwordField.text = @"";
            }
        }];
    }];
}

- (void)registerTapped
{
    if (self.requestInFlight) { return; }

    NSString *username = [self trimmed:self.usernameField.text];
    NSString *password = self.passwordField.text ?: @"";
    NSString *email = [self trimmed:self.emailField.text];
    NSString *referral = [self trimmed:self.referralField.text];

    if (username.length == 0)
    {
        [self setHint:self.loginHintLabel text:@"请输入用户名" color:FXAPWarningColor()];
        return;
    }
    if (password.length < 6)
    {
        [self setHint:self.loginHintLabel text:@"密码至少 6 位" color:FXAPWarningColor()];
        return;
    }
    if (email.length == 0)
    {
        [self setHint:self.loginHintLabel text:@"请输入邮箱" color:FXAPWarningColor()];
        return;
    }

    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.loginHintLabel text:@"正在创建账号…" color:FXAPTextSecondaryColor()];

    NSString *referralOrNil = referral.length > 0 ? referral : nil;
    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] registerWithUsername:username
                                    password:password
                                       email:email
                                    referral:referralOrNil
                                  completion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            [weakSelf finishRequest:weakSelf.loginHintLabel
                                ok:ok
                           message:message
                          fallback:(ok ? @"注册成功，请登录" : @"注册失败，请稍后重试")];
            if (ok)
            {
                weakSelf.passwordField.text = @"";
                [weakSelf showAlertWithTitle:@"注册成功" message:@"注册成功，请登录。"];
            }
        }];
    }];
}

#pragma mark 卡密动作

- (void)activateCardTapped
{
    if (self.requestInFlight) { return; }

    NSString *keyCode = [self trimmed:self.cardField.text];
    if (keyCode.length == 0)
    {
        [self setHint:self.actionHintLabel text:@"请先粘贴或输入卡密" color:FXAPWarningColor()];
        return;
    }

    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.actionHintLabel text:@"正在激活卡密并绑定本机…" color:FXAPTextSecondaryColor()];

    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] activateCard:keyCode completion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            [weakSelf finishRequest:weakSelf.actionHintLabel
                                ok:ok
                           message:message
                          fallback:(ok ? @"卡密已激活并绑定本机" : @"激活失败，请确认卡密是否可用")];
            if (ok)
            {
                weakSelf.cardField.text = @"";
            }
        }];
    }];
}

- (void)addCardTapped
{
    if (self.requestInFlight) { return; }

    NSString *keyCode = [self trimmed:self.cardField.text];
    if (keyCode.length == 0)
    {
        [self setHint:self.actionHintLabel text:@"请先粘贴或输入卡密" color:FXAPWarningColor()];
        return;
    }

    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.actionHintLabel text:@"正在加入备用卡包…" color:FXAPTextSecondaryColor()];

    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] addCardToWallet:keyCode completion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            [weakSelf finishRequest:weakSelf.actionHintLabel
                                ok:ok
                           message:message
                          fallback:(ok ? @"已加入备用卡包，未开始计时" : @"添加失败，请确认卡密是否可用")];
            if (ok)
            {
                weakSelf.cardField.text = @"";
            }
        }];
    }];
}

- (void)refreshCardsTapped
{
    if (self.requestInFlight) { return; }

    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.actionHintLabel text:@"正在刷新卡包…" color:FXAPTextSecondaryColor()];

    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] refreshCardsWithCompletion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            [weakSelf finishRequest:weakSelf.actionHintLabel
                                ok:ok
                           message:message
                          fallback:(ok ? @"卡包已刷新" : @"刷新失败，请检查网络后重试")];
        }];
    }];
}

- (void)logoutTapped
{
    if (self.requestInFlight) { return; }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"退出登录"
                                            message:@"退出后停止替换功能。卡密归属和原到期时间不变，是否继续？"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"退出登录"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [weakSelf performLogout];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performLogout
{
    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.actionHintLabel text:@"正在退出登录…" color:FXAPTextSecondaryColor()];

    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] logoutWithCompletion:^(BOOL ok, NSString *message) {
        [weakSelf onMain:^{
            NSString *text = [message isKindOfClass:[NSString class]] ? message : nil;
            if (text.length == 0)
            {
                text = ok ? @"已退出登录" : @"退出失败，请稍后重试";
            }
            [weakSelf finishRequest:weakSelf.actionHintLabel
                                ok:ok
                           message:text
                          fallback:@""];
            // 退出后登录表单才是可见的，提示也放到登录区，避免看不见。
            [weakSelf setHint:weakSelf.loginHintLabel text:text color:(ok ? FXAPSuccessColor() : FXAPWarningColor())];
            weakSelf.cardField.text = @"";
        }];
    }];
}

#pragma mark 检查更新

- (void)checkUpdateTapped
{
    if (self.requestInFlight) { return; }

    [self.view endEditing:YES];
    [self setBusy:YES];
    [self setHint:self.actionHintLabel text:@"正在检查更新…" color:FXAPTextSecondaryColor()];

    __weak typeof(self) weakSelf = self;
    [[FXLicense shared] checkUpdateWithCompletion:^(NSDictionary *manifest, NSString *message) {
        [weakSelf onMain:^{
            [weakSelf setBusy:NO];

            NSDictionary *info = [manifest isKindOfClass:[NSDictionary class]] ? manifest : nil;
            if (info != nil && FXAPBoolValue(info[@"has_update"]))
            {
                NSMutableArray<NSString *> *lines = [NSMutableArray array];

                NSString *version = FXAPStringValue(info[@"version_name"]);
                if (version.length > 0)
                {
                    [lines addObject:[NSString stringWithFormat:@"版本：%@", version]];
                }

                int64_t size = FXAPInt64Value(info[@"size"]);
                if (size > 0)
                {
                    [lines addObject:[NSString stringWithFormat:@"大小：%@", FXAPFormatSize(size)]];
                }

                NSString *changelog = FXAPStringValue(info[@"changelog"]);
                if (changelog.length > 0)
                {
                    [lines addObject:[NSString stringWithFormat:@"更新内容：\n%@", changelog]];
                }

                NSString *body = lines.count > 0 ? [lines componentsJoinedByString:@"\n"]
                                                 : (message.length > 0 ? message : @"发现新版本，请安装最新版本。");
                [weakSelf showAlertWithTitle:@"发现新版本" message:body];
                [weakSelf setHint:weakSelf.actionHintLabel text:@"发现新版本" color:FXAPAccentColor()];
                [weakSelf reloadUI];
                return;
            }

            NSString *text = [message isKindOfClass:[NSString class]] ? message : nil;
            if (text.length == 0)
            {
                text = @"当前没有可用的新版本，现有授权正常使用。";
            }
            [weakSelf showAlertWithTitle:@"检查更新" message:text];
            [weakSelf setHint:weakSelf.actionHintLabel text:text color:FXAPTextSecondaryColor()];
            [weakSelf reloadUI];
        }];
    }];
}

#pragma mark 键盘

- (void)keyboardWillChangeFrame:(NSNotification *)note
{
    NSDictionary *info = note.userInfo;
    CGRect endFrame = CGRectZero;
    id frameValue = [info isKindOfClass:[NSDictionary class]] ? info[UIKeyboardFrameEndUserInfoKey] : nil;
    if ([frameValue isKindOfClass:[NSValue class]])
    {
        endFrame = [(NSValue *)frameValue CGRectValue];
    }

    CGFloat duration = 0.25;
    id durationValue = [info isKindOfClass:[NSDictionary class]] ? info[UIKeyboardAnimationDurationUserInfoKey] : nil;
    if ([durationValue isKindOfClass:[NSNumber class]])
    {
        duration = [(NSNumber *)durationValue doubleValue];
    }

    CGRect keyboardInView = [self.view convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardInView));

    UIEdgeInsets insets = UIEdgeInsetsMake(0.0, 0.0, overlap, 0.0);
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:duration
                     animations:^{
        weakSelf.scrollView.contentInset = insets;
        weakSelf.scrollView.scrollIndicatorInsets = insets;
    }
                     completion:^(BOOL finished) {
        [weakSelf scrollActiveFieldIntoViewAnimated:YES];
    }];
}

- (void)scrollActiveFieldIntoViewAnimated:(BOOL)animated
{
    FXAPTextField *field = self.activeField;
    if (field == nil)
    {
        return;
    }

    CGRect rect = [field convertRect:field.bounds toView:self.scrollView];
    rect.origin.y -= 12.0;
    rect.size.height += 24.0;
    [self.scrollView scrollRectToVisible:rect animated:animated];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    if ([textField isKindOfClass:[FXAPTextField class]])
    {
        self.activeField = (FXAPTextField *)textField;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self scrollActiveFieldIntoViewAnimated:YES];
    });
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    if (self.activeField == (FXAPTextField *)textField)
    {
        self.activeField = nil;
    }
}

#pragma mark 关闭

/// 只接收落在空白区域的点击，避免点输入框/按钮时被这个手势抢走焦点。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    if ([touch.view isKindOfClass:[UIControl class]])
    {
        return NO;
    }
    return YES;
}

- (void)panelTapped
{
    [self.view endEditing:YES];
}

- (void)dimTapped
{
    [self.view endEditing:YES];
}

- (void)closeTapped
{
    [self.view endEditing:YES];
    if (self.presentingViewController != nil)
    {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

#pragma mark - 导出

UIViewController *FXCreateAccountPanel(void)
{
    return [[FXAccountPanelController alloc] init];
}
