//
//  FXLicense.mm —— 卡密/账号/租约客户端实现
//
//  签名原文与请求头见 docs/API-zh.md §2.3。设备私钥永不出 Keychain
//  （优先 Secure Enclave），服务端签名用内置公钥验签。
//

#import "FXLicense.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>

NSString *const FXLicenseDidChangeNotification = @"FXLicenseDidChangeNotification";

// ---- 配置 ----------------------------------------------------------------
// 授权服务地址（部署后改成你自己的；运行时可用 NSUserDefaults 的
// FXLicenseBaseURL 覆盖，便于测试）
static NSString *const kFXDefaultBaseURL = @"https://example.com";
static NSString *const kFXDefaultsBaseURLKey = @"FXLicenseBaseURL";

// 服务端签名公钥（ECDSA P-256，X.509 SPKI 的 base64）。
// 生成方法：php server/bin/douyctl.php key:gen
// ⚠️ 这是测试密钥，部署前必须换成你自己 key:gen 出来的那把。
static NSString *const kFXServerPublicKeyECDSA =
    @"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEJ+vPCM6tFVsKB9N/PXGDHc5yHni/Eu6aDzfrks0CGNqQhS038ccwqXXJePaxttvBdBI17V2iGcBpI7/cbilwQA==";

static NSString *const kFXKeyId = @"ec-p256-1";

// 测试便利：可在运行时用 NSUserDefaults 覆盖服务端公钥，避免每次换钥都重编 iOS。
//   defaults write <宿主BundleId> FXLicenseServerPublicKey "MFkw...=="
// 生产建议留空、只用上面编译期常量（防止被本机改钥绕过）。
static NSString *FXCurrentServerPublicKey(void)
{
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:@"FXLicenseServerPublicKey"];
    if ([override isKindOfClass:[NSString class]] && override.length > 32)
    {
        return override;
    }
    return kFXServerPublicKeyECDSA;
}
static NSString *const kFXProofVersion = @"douy-ios-proof-v1";
static NSString *const kFXKeychainService = @"app.douy.plugin-auth";
static NSString *const kFXDeviceTag = @"app.douy.plugin.device-key.v1";

static NSString *const kFXDefaultsSession = @"FXLicenseSessionToken";
static NSString *const kFXDefaultsAccount = @"FXLicenseAccountName";
static NSString *const kFXDefaultsAccountId = @"FXLicenseAccountId";
static NSString *const kFXDefaultsLicensePayload = @"FXLicensePayload";
static NSString *const kFXDefaultsLicenseSig = @"FXLicenseSignature";
static NSString *const kFXDefaultsLicenseExpiry = @"FXLicenseExpiry";
static NSString *const kFXDefaultsLicenseMasked = @"FXLicenseMasked";

static int64_t FXNowMs(void)
{
    return (int64_t)llround([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static NSString *FXHexString(NSData *data)
{
    if (data.length == 0)
    {
        return @"";
    }
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++)
    {
        [out appendFormat:@"%02x", bytes[i]];
    }
    return out;
}

static NSString *FXSHA256Hex(NSData *data)
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return FXHexString([NSData dataWithBytes:digest length:sizeof(digest)]);
}

static NSString *FXRandomHex(NSUInteger bytes)
{
    NSMutableData *data = [NSMutableData dataWithLength:bytes];
    if (SecRandomCopyBytes(kSecRandomDefault, bytes, data.mutableBytes) != errSecSuccess)
    {
        arc4random_buf(data.mutableBytes, bytes);
    }
    return FXHexString(data);
}

/// 计算本插件 __text 段的 SHA-256（服务端可选校验，用于 IOS_MODULE_CHANGED）
static NSString *FXModuleTextSHA256(void)
{
    Dl_info info;
    if (dladdr((const void *)&FXModuleTextSHA256, &info) == 0 || info.dli_fbase == NULL)
    {
        return @"";
    }

    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (header->magic != MH_MAGIC_64)
    {
        return @"";
    }

    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++)
    {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmd == LC_SEGMENT_64)
        {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (strncmp(seg->segname, "__TEXT", 16) == 0)
            {
                const struct section_64 *sect = (const struct section_64 *)(cursor + sizeof(struct segment_command_64));
                for (uint32_t s = 0; s < seg->nsects; s++)
                {
                    if (strncmp(sect[s].sectname, "__text", 16) == 0 && sect[s].size > 0)
                    {
                        NSData *text = [NSData dataWithBytes:(const void *)((uintptr_t)info.dli_fbase + sect[s].offset)
                                                      length:(NSUInteger)sect[s].size];
                        return FXSHA256Hex(text);
                    }
                }
            }
        }
        cursor += cmd->cmdsize;
        if (cmd->cmdsize == 0)
        {
            break;
        }
    }
    return @"";
}

// ---- Keychain ------------------------------------------------------------

static NSMutableDictionary *FXKeychainBaseQuery(NSString *tag)
{
    return [@{
        (id)kSecClass : (id)kSecClassGenericPassword,
        (id)kSecAttrService : kFXKeychainService,
        (id)kSecAttrAccount : tag,
    } mutableCopy];
}

static NSData *FXKeychainGet(NSString *tag)
{
    NSMutableDictionary *query = FXKeychainBaseQuery(tag);
    query[(id)kSecReturnData] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL)
    {
        return (__bridge_transfer NSData *)result;
    }
    return nil;
}

static void FXKeychainSet(NSString *tag, NSData *value)
{
    if (value == nil)
    {
        SecItemDelete((__bridge CFDictionaryRef)FXKeychainBaseQuery(tag));
        return;
    }
    NSMutableDictionary *query = FXKeychainBaseQuery(tag);
    NSDictionary *attrs = @{ (id)kSecValueData : value };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
    if (status == errSecItemNotFound)
    {
        query[(id)kSecValueData] = value;
        query[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
}

static SecKeyRef FXCopyDevicePrivateKey(void)
{
    NSDictionary *query = @{
        (id)kSecClass : (id)kSecClassKey,
        (id)kSecAttrApplicationTag : [kFXDeviceTag dataUsingEncoding:NSUTF8StringEncoding],
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPrivate,
        (id)kSecReturnRef : @YES,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result != NULL)
    {
        return (SecKeyRef)result;
    }
    return NULL;
}

static SecKeyRef FXCreateDevicePrivateKey(BOOL secureEnclave)
{
    NSData *tagData = [kFXDeviceTag dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *privateAttrs = [@{
        (id)kSecAttrIsPermanent : @YES,
        (id)kSecAttrApplicationTag : tagData,
    } mutableCopy];

    CFTypeRef accessControl = NULL;
    if (secureEnclave)
    {
        accessControl = SecAccessControlCreateWithFlags(NULL,
                                                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                        kSecAccessControlPrivateKeyUsage,
                                                        NULL);
        if (accessControl != NULL)
        {
            privateAttrs[(id)kSecAttrAccessControl] = (__bridge id)accessControl;
        }
    }

    NSMutableDictionary *attrs = [@{
        (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeySizeInBits : @256,
        (id)kSecPrivateKeyAttrs : privateAttrs,
    } mutableCopy];
    if (secureEnclave)
    {
        attrs[(id)kSecAttrTokenID] = (id)kSecAttrTokenIDSecureEnclave;
    }

    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &error);
    if (accessControl != NULL)
    {
        CFRelease(accessControl);
    }
    if (error != NULL)
    {
        CFRelease(error);
    }
    return key;
}

static NSString *FXBase64OfPublicKey(SecKeyRef privateKey)
{
    SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey);
    if (publicKey == NULL)
    {
        return @"";
    }
    CFErrorRef error = NULL;
    CFDataRef raw = SecKeyCopyExternalRepresentation(publicKey, &error);
    CFRelease(publicKey);
    if (raw == NULL)
    {
        if (error != NULL)
        {
            CFRelease(error);
        }
        return @"";
    }
    NSData *data = (__bridge_transfer NSData *)raw;
    if (error != NULL)
    {
        CFRelease(error);
    }
    // 注意：ECDSA 公钥这里拿到的是未压缩点（65B），服务端需要 SPKI DER。
    // SecKeyCreateWithData 与 openssl 都接受 SPKI；我们在这里手工包一层 SPKI。
    if (data.length == 65)
    {
        // SubjectPublicKeyInfo for prime256v1:
        // 30 59 30 13 06 07 2A8648CE3D0201 06 08 2A8648CE3D030107 03 42 00 || point
        static const uint8_t prefix[] = {
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        };
        NSMutableData *spki = [NSMutableData dataWithBytes:prefix length:sizeof(prefix)];
        [spki appendData:data];
        return [spki base64EncodedStringWithOptions:0];
    }
    return [data base64EncodedStringWithOptions:0];
}

static NSData *FXSignWithDeviceKey(SecKeyRef key, NSData *data)
{
    if (key == NULL || data == nil)
    {
        return nil;
    }
    CFErrorRef error = NULL;
    CFDataRef signature = SecKeyCreateSignature(key,
                                                kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                                (__bridge CFDataRef)data,
                                                &error);
    if (signature == NULL)
    {
        if (error != NULL)
        {
            NSLog(@"[DOUY] 设备签名失败: %@", error);
            CFRelease(error);
        }
        return nil;
    }
    return (__bridge_transfer NSData *)signature;
}

// ---- 主体 ----------------------------------------------------------------

@interface FXLicense ()
@property (atomic, readwrite) FXLicenseState state;
@property (atomic, copy, readwrite) NSString *statusText;
@property (atomic, copy, readwrite) NSString *accountName;
@property (atomic, copy, readwrite) NSString *deviceIdentifier;
@property (atomic, readwrite) int64_t licenseExpiryMs;
@property (atomic, readwrite) BOOL loggedIn;
@property (atomic, copy, readwrite) NSArray<NSDictionary *> *cards;
@end

@implementation FXLicense
{
    SecKeyRef _deviceKey;
    SecKeyRef _serverKey;
    NSString *_serverKeySource;
    NSString *_publicKeyBase64;
    NSString *_sessionToken;
    NSTimer *_refreshTimer;
    BOOL _busy;
    NSURLSession *_session;
}

+ (instancetype)shared
{
    static FXLicense *license = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        license = [[FXLicense alloc] init];
    });
    return license;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _state = FXLicenseStateUnknown;
        _statusText = @"正在联网验证授权…";
        _cards = @[];
        _accountName = @"";
        _deviceIdentifier = @"";
        _session = [NSURLSession sessionWithConfiguration:
                    [NSURLSessionConfiguration ephemeralSessionConfiguration]];
    }
    return self;
}

- (void)dealloc
{
    [_refreshTimer invalidate];
    if (_deviceKey)
    {
        CFRelease(_deviceKey);
    }
    if (_serverKey)
    {
        CFRelease(_serverKey);
    }
}

// ---------------------------------------------------------------- 配置

- (void)setBaseURLString:(NSString *)baseURLString
{
    [[NSUserDefaults standardUserDefaults] setObject:baseURLString forKey:kFXDefaultsBaseURLKey];
}

- (NSString *)baseURLString
{
    NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:kFXDefaultsBaseURLKey];
    if (custom.length > 0)
    {
        return custom;
    }
    return kFXDefaultBaseURL;
}

// ---------------------------------------------------------------- 设备身份

- (BOOL)ensureDeviceKey
{
    if (_deviceKey != NULL)
    {
        return YES;
    }

    SecKeyRef key = FXCopyDevicePrivateKey();
    if (key == NULL)
    {
        // 优先 Secure Enclave，失败回落普通 Keychain 软件密钥
        key = FXCreateDevicePrivateKey(YES);
        if (key == NULL)
        {
            NSLog(@"[DOUY] Secure Enclave 不可用，回落软件密钥");
            key = FXCreateDevicePrivateKey(NO);
        }
    }
    if (key == NULL)
    {
        self.statusText = @"无法读取本机安全身份";
        [self notify];
        return NO;
    }

    _deviceKey = key;
    _publicKeyBase64 = FXBase64OfPublicKey(key);

    NSData *spki = [[NSData alloc] initWithBase64EncodedString:_publicKeyBase64 options:0];
    NSString *fingerprint = FXSHA256Hex(spki);
    self.deviceIdentifier = fingerprint.length >= 40 ? [fingerprint substringToIndex:40] : fingerprint;
    return YES;
}

- (void)bootstrap
{
    if (![self ensureDeviceKey])
    {
        self.state = FXLicenseStateError;
        return;
    }

    // 设备首次上报（服务端按 device_id 建表；重复上报是幂等的）
    [self registerDeviceWithCompletion:^(BOOL ok, NSString *message) {
        if (!ok)
        {
            NSLog(@"[DOUY] 设备登记失败: %@", message);
        }
        [self restoreCachedLicense];
        [self refreshNowWithCompletion:nil];
        [self startAutoRefresh];
    }];
}

- (void)restoreCachedLicense
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *payload = [defaults stringForKey:kFXDefaultsLicensePayload];
    NSString *signature = [defaults stringForKey:kFXDefaultsLicenseSig];
    int64_t expiry = [defaults integerForKey:kFXDefaultsLicenseExpiry];
    NSString *token = [[NSString alloc] initWithData:FXKeychainGet(kFXDefaultsSession) encoding:NSUTF8StringEncoding];

    if (token.length > 0)
    {
        _sessionToken = token;
        self.loggedIn = YES;
        self.accountName = [defaults stringForKey:kFXDefaultsAccount] ?: @"";
    }

    if (payload.length > 0 && signature.length > 0)
    {
        BOOL valid = [self verifyServerSignature:signature forPayload:payload];
        if (valid && expiry > FXNowMs())
        {
            self.state = FXLicenseStateActive;
            self.licenseExpiryMs = expiry;
            self.statusText = @"授权有效";
        }
    }
}

// ---------------------------------------------------------------- HTTP + 签名

- (void)registerDeviceWithCompletion:(void (^)(BOOL, NSString *))completion
{
    NSDictionary *body = @{
        @"device_id" : self.deviceIdentifier ?: @"",
        @"key_id" : kFXKeyId,
        @"public_key" : _publicKeyBase64 ?: @"",
        @"platform" : @"ios",
        @"ios_version" : [[UIDevice currentDevice] systemVersion] ?: @"14.0",
        @"bundle_id" : [[NSBundle mainBundle] bundleIdentifier] ?: @"",
        @"model" : @"",
    };
    [self performPath:@"/api/ios/plugin/device/register" method:@"POST" body:body completion:^(NSDictionary *json, NSString *error) {
        if (json == nil)
        {
            if (completion)
            {
                completion(NO, error ?: @"网络请求未确认，稍后自动重试");
            }
            return;
        }
        BOOL ok = [json[@"success"] boolValue];
        if (completion)
        {
            completion(ok, json[@"message"] ?: @"");
        }
    }];
}

- (NSURLRequest *)buildRequestWithMethod:(NSString *)method
                                    path:(NSString *)path
                                    body:(NSData *)body
{
    NSString *base = [self baseURLString];
    NSString *urlString = [base stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil)
    {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString *timeString = [NSString stringWithFormat:@"%lld", (long long)FXNowMs()];
    NSString *nonce = FXRandomHex(16);
    NSString *bodyHash = FXSHA256Hex(body ?: [NSData data]);

    NSString *canonical = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@\n%@\n%@\n%@",
                           kFXProofVersion, method, path, timeString, nonce, bodyHash,
                           self.deviceIdentifier ?: @"", kFXKeyId];
    NSData *signature = FXSignWithDeviceKey(_deviceKey, [canonical dataUsingEncoding:NSUTF8StringEncoding]);
    if (signature == nil)
    {
        return nil;
    }

    [request setValue:kFXProofVersion forHTTPHeaderField:@"X-DOUY-IOS-Proof"];
    [request setValue:kFXKeyId forHTTPHeaderField:@"X-DOUY-IOS-Key"];
    [request setValue:@"child" forHTTPHeaderField:@"X-DOUY-IOS-Role"];
    [request setValue:timeString forHTTPHeaderField:@"X-DOUY-IOS-Time"];
    [request setValue:nonce forHTTPHeaderField:@"X-DOUY-IOS-Nonce"];
    [request setValue:self.deviceIdentifier ?: @"" forHTTPHeaderField:@"X-DOUY-IOS-Device"];
    [request setValue:[signature base64EncodedStringWithOptions:0] forHTTPHeaderField:@"X-DOUY-IOS-Signature"];

    if (_sessionToken.length > 0)
    {
        [request setValue:[@"Frame-Session " stringByAppendingString:_sessionToken]
       forHTTPHeaderField:@"Authorization"];
    }

    if (body.length > 0)
    {
        request.HTTPBody = body;
    }
    return request;
}

/// 统一请求入口：返回解析后的 JSON（失败时 json=nil, error=中文原因）
- (void)performPath:(NSString *)path
             method:(NSString *)method
               body:(NSDictionary *)bodyDict
         completion:(void (^)(NSDictionary *json, NSString *error))completion
{
    if (![self ensureDeviceKey])
    {
        if (completion)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"无法读取本机安全身份");
            });
        }
        return;
    }

    NSData *body = nil;
    if (bodyDict != nil)
    {
        body = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:NULL];
    }

    NSURLRequest *request = [self buildRequestWithMethod:method path:path body:body];
    if (request == nil)
    {
        if (completion)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"无法生成安全请求（本机签名失败）");
            });
        }
        return;
    }

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = nil;
        NSString *message = nil;

        if (error != nil)
        {
            message = @"网络请求未确认，稍后自动重试";
        }
        else if (data.length > 0)
        {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]])
            {
                json = (NSDictionary *)parsed;
            }
            else
            {
                message = @"服务器响应无效";
            }
        }
        else
        {
            message = @"服务器响应无效";
        }

        if (json != nil)
        {
            NSString *code = json[@"code"];
            if ([code isKindOfClass:[NSString class]])
            {
                [self handleErrorCode:code message:json[@"message"]];
            }
        }

        if (completion)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(json, message ?: (json[@"message"] ?: @""));
            });
        }
    }];
    [task resume];
}

- (void)handleErrorCode:(NSString *)code message:(NSString *)message
{
    if ([code isEqualToString:@"IOS_LOGIN_REQUIRED"] || [code isEqualToString:@"ACCOUNT_DISABLED"])
    {
        _sessionToken = nil;
        FXKeychainSet(kFXDefaultsSession, nil);
        self.loggedIn = NO;
        self.state = FXLicenseStateNone;
        self.statusText = @"已退出，请登录";
        [self notify];
    }
    else if ([code isEqualToString:@"IOS_MODULE_CHANGED"])
    {
        self.state = FXLicenseStateError;
        self.statusText = @"插件运行代码发生变化，请重新安装官方版本";
        [self notify];
    }
    else if ([code isEqualToString:@"IOS_LOCAL_IDENTITY_INVALID"]
             || [code isEqualToString:@"LICENSE_BOUND_TO_OTHER_DEVICE"]
             || [code isEqualToString:@"IOS_LEASE_REJECTED"])
    {
        self.statusText = message.length > 0 ? message : @"授权签名或绑定验证失败";
        [self notify];
    }
}

// ---------------------------------------------------------------- 服务端签名验签

- (BOOL)verifyServerSignature:(NSString *)signatureBase64 forPayload:(NSString *)payloadBase64
{
    NSString *keyB64 = FXCurrentServerPublicKey();
    if (_serverKey != NULL && ![_serverKeySource isEqualToString:keyB64])
    {
        CFRelease(_serverKey);
        _serverKey = NULL;
    }

    if (_serverKey == NULL)
    {
        NSData *der = [[NSData alloc] initWithBase64EncodedString:keyB64 options:0];
        if (der.length == 0)
        {
            return NO;
        }
        NSDictionary *attrs = @{
            (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
            (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
            (id)kSecAttrKeySizeInBits : @256,
        };
        CFErrorRef error = NULL;
        _serverKey = SecKeyCreateWithData((__bridge CFDataRef)der, (__bridge CFDictionaryRef)attrs, &error);
        _serverKeySource = [keyB64 copy];
        if (_serverKey == NULL)
        {
            if (error != NULL)
            {
                NSLog(@"[DOUY] 服务端公钥载入失败: %@", error);
                CFRelease(error);
            }
            return NO;
        }
    }

    NSData *payload = [[NSData alloc] initWithBase64EncodedString:payloadBase64 options:0];
    NSData *signature = [[NSData alloc] initWithBase64EncodedString:signatureBase64 options:0];
    if (payload.length == 0 || signature.length == 0)
    {
        return NO;
    }

    CFErrorRef error = NULL;
    BOOL ok = SecKeyVerifySignature(_serverKey,
                                    kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                    (__bridge CFDataRef)payload,
                                    (__bridge CFDataRef)signature,
                                    &error) ? YES : NO;
    if (!ok && error != NULL)
    {
        CFRelease(error);
    }
    return ok;
}

// ---------------------------------------------------------------- 状态

- (BOOL)isAuthorized
{
    if (_state != FXLicenseStateActive)
    {
        return NO;
    }
    if (self.licenseExpiryMs > 0 && self.licenseExpiryMs <= FXNowMs())
    {
        return NO;
    }
    return YES;
}

- (void)notify
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FXLicenseDidChangeNotification object:nil];
    });
}

- (void)applyStatusResponse:(NSDictionary *)json
{
    NSString *code = json[@"code"];
    if ([code isEqualToString:@"IOS_LOGIN_REQUIRED"])
    {
        _sessionToken = nil;
        FXKeychainSet(kFXDefaultsSession, nil);
        self.loggedIn = NO;
        self.state = FXLicenseStateNone;
        self.statusText = @"已退出，请登录";
        [self notify];
        return;
    }

    if (json[@"account"][@"username"] != nil)
    {
        self.accountName = [json[@"account"][@"username"] description];
        [[NSUserDefaults standardUserDefaults] setObject:self.accountName forKey:kFXDefaultsAccount];
    }

    NSArray *cards = json[@"cards"];
    if ([cards isKindOfClass:[NSArray class]])
    {
        self.cards = cards;
    }

    NSDictionary *license = json[@"license"];
    if ([license isKindOfClass:[NSDictionary class]] && license[@"payload"] != nil)
    {
        NSString *payload = [license[@"payload"] description];
        NSString *signature = [license[@"signature"] description];
        BOOL valid = [self verifyServerSignature:signature forPayload:payload];

        if (!valid)
        {
            self.state = FXLicenseStateError;
            self.statusText = @"授权签名或绑定验证失败";
            [self notify];
            return;
        }

        int64_t expiry = [license[@"expires_ms"] longLongValue];
        self.licenseExpiryMs = expiry;
        self.state = expiry > FXNowMs() ? FXLicenseStateActive : FXLicenseStateExpired;
        self.statusText = expiry > FXNowMs() ? @"授权有效" : @"已到期";

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:payload forKey:kFXDefaultsLicensePayload];
        [defaults setObject:signature forKey:kFXDefaultsLicenseSig];
        [defaults setInteger:(NSInteger)expiry forKey:kFXDefaultsLicenseExpiry];
        if ([license[@"masked"] isKindOfClass:[NSString class]])
        {
            [defaults setObject:license[@"masked"] forKey:kFXDefaultsLicenseMasked];
        }
        [defaults synchronize];

        if ([json[@"license_switched"] boolValue] == YES)
        {
            self.statusText = @"已自动续用备用卡，授权到期时间已更新";
        }
    }
    else
    {
        NSString *state = json[@"license_state"];
        if ([state isEqualToString:@"standby"])
        {
            self.state = FXLicenseStateStandby;
            self.statusText = @"已登录 · 请激活卡密或刷新核实授权";
        }
        else if ([state isEqualToString:@"expired"])
        {
            self.state = FXLicenseStateExpired;
            self.statusText = @"已到期";
        }
        else
        {
            self.state = FXLicenseStateNone;
            self.statusText = @"已登录 · 请激活卡密或刷新核实授权";
        }
    }

    NSString *message = json[@"message"];
    if ([message isKindOfClass:[NSString class]] && message.length > 0)
    {
        self.statusText = message;
    }
    [self notify];
}

// ---------------------------------------------------------------- 刷新 / 定时

- (void)refreshNowWithCompletion:(void (^)(BOOL, NSString *))completion
{
    if (_sessionToken.length == 0)
    {
        if (completion)
        {
            completion(NO, @"已退出，请登录");
        }
        return;
    }

    NSString *moduleHash = FXModuleTextSHA256();
    NSMutableDictionary *body = [@{ @"device_id" : self.deviceIdentifier ?: @"" } mutableCopy];
    if (moduleHash.length > 0)
    {
        body[@"module_text_sha256"] = moduleHash;
    }

    [self performPath:@"/api/ios/plugin/account/status" method:@"POST" body:body completion:^(NSDictionary *json, NSString *error) {
        if (json == nil)
        {
            if (self.state == FXLicenseStateUnknown)
            {
                self.state = FXLicenseStateError;
                self.statusText = error ?: @"网络请求未确认，稍后自动重试";
                [self notify];
            }
            if (completion)
            {
                completion(NO, error ?: @"");
            }
            return;
        }
        [self applyStatusResponse:json];
        if (completion)
        {
            completion([json[@"success"] boolValue], json[@"message"] ?: @"");
        }
    }];
}

- (void)startAutoRefresh
{
    if (_refreshTimer != nil)
    {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_refreshTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                              repeats:YES
                                                                block:^(NSTimer *timer) {
            [self refreshNowWithCompletion:nil];
        }];
    });
}

- (void)stopAutoRefresh
{
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

// ---------------------------------------------------------------- 账号

- (void)registerWithUsername:(NSString *)username
                    password:(NSString *)password
                       email:(NSString *)email
                    referral:(NSString *)referral
                  completion:(void (^)(BOOL, NSString *))completion
{
    NSMutableDictionary *body = [@{
        @"username" : username ?: @"",
        @"password" : password ?: @"",
        @"confirm_password" : password ?: @"",
        @"email" : email ?: @"",
    } mutableCopy];
    if (referral.length > 0)
    {
        body[@"referral_code"] = referral;
    }

    [self performPath:@"/api/register" method:@"POST" body:body completion:^(NSDictionary *json, NSString *error) {
        if (json == nil)
        {
            if (completion)
            {
                completion(NO, error ?: @"网络请求失败，请稍后重试");
            }
            return;
        }
        if (completion)
        {
            completion([json[@"success"] boolValue], json[@"message"] ?: @"");
        }
    }];
}

- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(BOOL, NSString *))completion
{
    self.statusText = @"正在登录…";
    [self notify];

    [self performPath:@"/api/ios/plugin/login" method:@"POST"
                 body:@{ @"username" : username ?: @"", @"password" : password ?: @"" }
           completion:^(NSDictionary *json, NSString *error) {
        if (json == nil || ![json[@"success"] boolValue])
        {
            NSString *message = json[@"message"] ?: error ?: @"登录响应无效";
            self.state = FXLicenseStateError;
            self.statusText = message;
            [self notify];
            if (completion)
            {
                completion(NO, message);
            }
            return;
        }

        NSString *challenge = json[@"challenge"];
        if (![challenge isKindOfClass:[NSString class]] || challenge.length == 0)
        {
            self.statusText = @"登录响应无效";
            [self notify];
            if (completion)
            {
                completion(NO, @"登录响应无效");
            }
            return;
        }

        NSData *challengeData = [challenge dataUsingEncoding:NSUTF8StringEncoding];
        NSData *signature = FXSignWithDeviceKey(self->_deviceKey, challengeData);
        if (signature == nil)
        {
            if (completion)
            {
                completion(NO, @"本机签名失败");
            }
            return;
        }

        NSDictionary *body = @{
            @"username" : username ?: @"",
            @"challenge" : challenge,
            @"challenge_response" : [signature base64EncodedStringWithOptions:0],
        };

        [self performPath:@"/api/ios/plugin/login_session" method:@"POST" body:body
               completion:^(NSDictionary *json2, NSString *error2) {
            if (json2 == nil || ![json2[@"success"] boolValue])
            {
                NSString *message = json2[@"message"] ?: error2 ?: @"登录响应无效";
                self.state = FXLicenseStateError;
                self.statusText = message;
                [self notify];
                if (completion)
                {
                    completion(NO, message);
                }
                return;
            }

            NSString *token = json2[@"session_token"];
            if ([token isKindOfClass:[NSString class]] && token.length > 0)
            {
                self->_sessionToken = token;
                FXKeychainSet(kFXDefaultsSession, [token dataUsingEncoding:NSUTF8StringEncoding]);
                self.loggedIn = YES;
            }

            self.accountName = json2[@"account"][@"username"] ?: (username ?: @"");
            [[NSUserDefaults standardUserDefaults] setObject:self.accountName forKey:kFXDefaultsAccount];

            self.statusText = @"账号已登录，正在验证卡密授权…";
            [self notify];
            [self refreshNowWithCompletion:nil];
            [self startAutoRefresh];

            if (completion)
            {
                completion(YES, @"登录成功");
            }
        }];
    }];
}

- (void)logoutWithCompletion:(void (^)(BOOL, NSString *))completion
{
    [self performPath:@"/api/ios/plugin/logout" method:@"POST" body:@{} completion:^(NSDictionary *json, NSString *error) {
        self->_sessionToken = nil;
        FXKeychainSet(kFXDefaultsSession, nil);
        self.loggedIn = NO;
        self.state = FXLicenseStateNone;
        self.statusText = @"已退出，请登录";

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removeObjectForKey:kFXDefaultsLicensePayload];
        [defaults removeObjectForKey:kFXDefaultsLicenseSig];
        [defaults removeObjectForKey:kFXDefaultsLicenseExpiry];
        [defaults synchronize];

        [self stopAutoRefresh];
        [self notify];

        if (completion)
        {
            completion(json != nil, json[@"message"] ?: (error ?: @""));
        }
    }];
}

// ---------------------------------------------------------------- 卡密

- (void)activateCard:(NSString *)keyCode completion:(void (^)(BOOL, NSString *))completion
{
    if (keyCode.length == 0)
    {
        if (completion)
        {
            completion(NO, @"请先输入兜鱼 iOS 卡密");
        }
        return;
    }

    self.statusText = @"正在激活卡密并绑定本机…";
    [self notify];

    NSDictionary *body = @{
        @"key_code" : keyCode,
        @"device_id" : self.deviceIdentifier ?: @"",
    };

    [self performPath:@"/api/ios/plugin/activate" method:@"POST" body:body completion:^(NSDictionary *json, NSString *error) {
        if (json == nil)
        {
            self.statusText = error ?: @"网络请求未确认，请重试；不要重复激活或购买";
            [self notify];
            if (completion)
            {
                completion(NO, self.statusText);
            }
            return;
        }

        if (![json[@"success"] boolValue])
        {
            NSString *message = json[@"message"] ?: @"激活失败";
            self.statusText = message;
            [self notify];
            if (completion)
            {
                completion(NO, message);
            }
            return;
        }

        [self applyStatusResponse:json];

        // 激活响应里就带 license/cards；若没有则刷新一次
        if (json[@"license"] == nil)
        {
            [self refreshNowWithCompletion:nil];
        }

        self.statusText = @"卡密已激活并绑定本机，正在核实授权";
        [self notify];

        if (completion)
        {
            completion(YES, self.statusText);
        }
    }];
}

- (void)addCardToWallet:(NSString *)keyCode completion:(void (^)(BOOL, NSString *))completion
{
    if (keyCode.length == 0)
    {
        if (completion)
        {
            completion(NO, @"请先输入全新的兜鱼 iOS 卡密");
        }
        return;
    }

    self.statusText = @"正在添加卡密…";
    [self notify];

    [self performPath:@"/api/ios/plugin/wallet/add" method:@"POST"
                 body:@{ @"key_code" : keyCode }
           completion:^(NSDictionary *json, NSString *error) {
        if (json == nil)
        {
            if (completion)
            {
                completion(NO, error ?: @"网络请求未确认，请重试");
            }
            return;
        }
        if ([json[@"success"] boolValue])
        {
            [self applyStatusResponse:json];
            self.statusText = json[@"message"] ?: @"新卡已加入卡包";
        }
        else
        {
            self.statusText = json[@"message"] ?: @"添加失败";
        }
        [self notify];
        if (completion)
        {
            completion([json[@"success"] boolValue], self.statusText);
        }
    }];
}

- (void)refreshCardsWithCompletion:(void (^)(BOOL, NSString *))completion
{
    self.statusText = @"正在刷新卡包…";
    [self notify];
    [self refreshNowWithCompletion:^(BOOL ok, NSString *message) {
        if (ok)
        {
            self.statusText = @"卡包已刷新";
            [self notify];
        }
        if (completion)
        {
            completion(ok, message);
        }
    }];
}

// ---------------------------------------------------------------- 更新

- (void)checkUpdateWithCompletion:(void (^)(NSDictionary *, NSString *))completion
{
    int installed = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"FXInstalledVersionCode"];
    NSDictionary *body = @{
        @"channel" : @"stable",
        @"product" : @"DOUY",
        @"plugin_id" : @"douy-ios-hook",
        @"ios_version" : [[UIDevice currentDevice] systemVersion] ?: @"14.0",
        @"architecture" : @"arm64",
        @"platform" : @"ios",
        @"installed_version_code" : @(installed),
        @"install_method" : @"injector",
        @"update_protocol" : @"douy-ios-plugin-update",
        @"device_id" : self.deviceIdentifier ?: @"",
    };

    [self performPath:@"/api/ios/update/check" method:@"POST" body:body completion:^(NSDictionary *json, NSString *error) {
        if (json == nil)
        {
            if (completion)
            {
                completion(nil, error ?: @"更新查询失败");
            }
            return;
        }
        if (![json[@"has_update"] boolValue])
        {
            if (completion)
            {
                completion(nil, json[@"message"] ?: @"当前没有可用的新版本，现有授权正常使用。");
            }
            return;
        }

        NSDictionary *signedUpdate = json[@"signed_update"];
        if ([signedUpdate isKindOfClass:[NSDictionary class]])
        {
            NSString *payload = signedUpdate[@"payload"];
            NSString *signature = signedUpdate[@"signature"];
            if (![self verifyServerSignature:signature forPayload:payload])
            {
                if (completion)
                {
                    completion(nil, @"更新信息签名验证失败，已拒绝下载");
                }
                return;
            }
        }

        if (completion)
        {
            completion(json, json[@"message"] ?: @"发现新版");
        }
    }];
}

@end
