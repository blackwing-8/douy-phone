//
//  FXLicense.h —— 卡密 / 账号 / 租约 / 更新的客户端
//
//  契约见 docs/API-zh.md（douy-ios-proof-v1）。
//  设备身份：ECDSA P-256（优先 Secure Enclave，失败回落 Keychain 软件密钥）。
//  服务端签名用同一套 P-256 公钥验签（内置在 kFXServerPublicKeyECDSA）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const FXLicenseDidChangeNotification;

typedef NS_ENUM(NSInteger, FXLicenseState) {
    FXLicenseStateUnknown = 0,
    FXLicenseStateNone,      // 未激活
    FXLicenseStateStandby,   // 卡包里有备用卡，但未绑定/未计时
    FXLicenseStateActive,    // 授权有效
    FXLicenseStateExpired,   // 已过期
    FXLicenseStateError,     // 网络/服务端异常
};

@interface FXLicense : NSObject

+ (instancetype)shared;

/// 授权服务地址（默认取编译期常量 / NSUserDefaults 覆盖）
- (void)setBaseURLString:(NSString *)baseURLString;
- (NSString *)baseURLString;

/// 生成/读取设备身份，若有本地会话则立刻刷新一次
- (void)bootstrap;

/// 每 60 秒续租一次（服务端租约 90 秒）
- (void)startAutoRefresh;
- (void)stopAutoRefresh;

/// 立刻刷新 account/status
- (void)refreshNowWithCompletion:(void (^__nullable)(BOOL ok, NSString *message))completion;

@property (atomic, readonly) FXLicenseState state;
@property (atomic, readonly, copy) NSString *statusText;      // 中文提示（与界面一致）
@property (atomic, readonly, copy) NSString *accountName;
@property (atomic, readonly, copy) NSString *deviceIdentifier;
@property (atomic, readonly) int64_t licenseExpiryMs;
@property (atomic, readonly) BOOL loggedIn;
@property (atomic, readonly, copy) NSArray<NSDictionary *> *cards;

/// 是否放行"替换"功能
- (BOOL)isAuthorized;

/// 账号
- (void)registerWithUsername:(NSString *)username
                    password:(NSString *)password
                       email:(NSString *)email
                    referral:(nullable NSString *)referral
                  completion:(void (^__nullable)(BOOL ok, NSString *message))completion;

- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(void (^__nullable)(BOOL ok, NSString *message))completion;

- (void)logoutWithCompletion:(void (^__nullable)(BOOL ok, NSString *message))completion;

/// 卡密
- (void)activateCard:(NSString *)keyCode
          completion:(void (^__nullable)(BOOL ok, NSString *message))completion;

- (void)addCardToWallet:(NSString *)keyCode
             completion:(void (^__nullable)(BOOL ok, NSString *message))completion;

- (void)refreshCardsWithCompletion:(void (^__nullable)(BOOL ok, NSString *message))completion;

/// 插件更新（返回 has_update 时的 manifest 字典；无更新返回 nil）
- (void)checkUpdateWithCompletion:(void (^__nullable)(NSDictionary *__nullable manifest, NSString *message))completion;

@end

NS_ASSUME_NONNULL_END
