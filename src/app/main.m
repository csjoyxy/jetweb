/*
 * JetWeb (src/app/main.m) — 多合一常驻 WebApp 容器 (TrollStore / iOS 15.0+)
 *
 * 核心设计：
 *   1. 多站点单容器多实例常驻：每个启用站点拥有独立存活的 WKWebView 实例，切换标签 0ms 秒切不重载；
 *      非当前显示标签置 hidden=YES 让 WebKit 自动节流定时器省电，同时由 root 助手 jetwebctl
 *      将其对应的 WebContent / Networking / GPU 进程抬升至保护档位（默认 85，上限 95），防止系统回收白屏。
 *   2. 退后台多段重申：进入后台后开启短时后台任务，在 +0.8s/+3s/+8s/+18s 覆盖系统降档窗口，
 *      将主进程与各标签渲染进程锁回目标保护档位，20s 内结束后台任务实现零持续耗电。
 *   3. 单标签内存安全阀：超过阈值（默认 450MB）自动放弃保活并退回 30 档，保护 iPhone 11 4GB 内存。
 *   4. 全本地隐私配置：站点名称与 URL 仅保存在手机本地 /var/mobile/Library/JetWeb/config.json。
 */

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <spawn.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#define JW_VERSION "0.1.0"
#ifndef JW_COMMIT
#define JW_COMMIT "dev"
#endif

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
extern char **environ;

static NSString *const kJWDataDir       = @"/var/mobile/Library/JetWeb";
static NSString *const kJWConfigPath    = @"/var/mobile/Library/JetWeb/config.json";
static NSString *const kJWPilotDir      = @"/var/mobile/Library/JetPilot";
static NSString *const kJWSharedPidPath = @"/var/mobile/Library/JetPilot/webhub_pids.txt";

static const NSInteger kJWMaxSites      = 8;
static const NSInteger kJWDefaultBand   = 85;
static const NSInteger kJWDefaultMaxMB  = 450;

static NSString *const kJWAppearanceInherit = @"inherit";
static NSString *const kJWAppearanceSystem  = @"system";
static NSString *const kJWAppearanceLight   = @"light";
static NSString *const kJWAppearanceDark    = @"dark";

#pragma mark - Appearance & Certificate Helpers

static NSString *JWNormalizeGlobalAppearanceMode(NSString *raw) {
    if ([raw isEqualToString:kJWAppearanceLight]) return kJWAppearanceLight;
    if ([raw isEqualToString:kJWAppearanceDark]) return kJWAppearanceDark;
    return kJWAppearanceSystem;
}

static NSString *JWNormalizeSiteAppearanceMode(NSString *raw) {
    if ([raw isEqualToString:kJWAppearanceSystem]) return kJWAppearanceSystem;
    if ([raw isEqualToString:kJWAppearanceLight]) return kJWAppearanceLight;
    if ([raw isEqualToString:kJWAppearanceDark]) return kJWAppearanceDark;
    return kJWAppearanceInherit;
}

static NSString *JWAppearanceModeLabel(NSString *mode) {
    if ([mode isEqualToString:kJWAppearanceLight]) return @"强制浅色";
    if ([mode isEqualToString:kJWAppearanceDark]) return @"强制深色";
    if ([mode isEqualToString:kJWAppearanceSystem]) return @"跟随系统";
    return @"跟随全局";
}

static UIUserInterfaceStyle JWUIUserInterfaceStyleForMode(NSString *resolvedMode, UIUserInterfaceStyle fallbackSystemStyle) {
    if ([resolvedMode isEqualToString:kJWAppearanceLight]) return UIUserInterfaceStyleLight;
    if ([resolvedMode isEqualToString:kJWAppearanceDark]) return UIUserInterfaceStyleDark;
    return fallbackSystemStyle;
}

static void JWExtractLeafCertInfo(SecTrustRef trust, NSString **fingerprintOut, NSString **subjectOut) {
    NSString *fp = @"";
    NSString *subj = @"";
    if (trust) {
        CFArrayRef chain = SecTrustCopyCertificateChain(trust);
        if (chain && CFArrayGetCount(chain) > 0) {
            SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
            if (leaf) {
                CFStringRef subjRef = SecCertificateCopySubjectSummary(leaf);
                if (subjRef) {
                    subj = (__bridge_transfer NSString *)subjRef;
                }
                CFDataRef derRef = SecCertificateCopyData(leaf);
                if (derRef) {
                    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(CFDataGetBytePtr(derRef), (CC_LONG)CFDataGetLength(derRef), digest);
                    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
                    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
                        [hex appendFormat:@"%02X", digest[i]];
                    }
                    fp = [hex copy];
                    CFRelease(derRef);
                }
            }
        }
        if (chain) CFRelease(chain);
    }
    if (fingerprintOut) *fingerprintOut = fp;
    if (subjectOut) *subjectOut = subj;
}

static NSString *JWFormatShortFingerprint(NSString *hex) {
    if (hex.length < 24) return hex ?: @"";
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < 16; i += 2) {
        if (i > 0) [out appendString:@":"];
        [out appendString:[hex substringWithRange:NSMakeRange(i, 2)]];
    }
    [out appendString:@" ... "];
    NSUInteger tailStart = hex.length - 8;
    for (NSUInteger i = tailStart; i < hex.length; i += 2) {
        if (i > tailStart) [out appendString:@":"];
        [out appendString:[hex substringWithRange:NSMakeRange(i, 2)]];
    }
    return [out copy];
}

static BOOL JWIsSSLError(NSError *error) {
    if (!error || ![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
        case NSURLErrorClientCertificateRejected:
        case NSURLErrorClientCertificateRequired:
            return YES;
        default:
            return NO;
    }
}

#pragma mark - One-Shot Delegate Completion Guards

@interface JWAlertCompletionGuard : NSObject
- (instancetype)initWithBlock:(void (^)(void))block;
- (void)invoke;
@end

@implementation JWAlertCompletionGuard {
    void (^_block)(void);
}
- (instancetype)initWithBlock:(void (^)(void))block {
    self = [super init];
    if (self) _block = [block copy];
    return self;
}
- (void)invoke {
    void (^b)(void) = _block;
    _block = nil;
    if (b) b();
}
- (void)dealloc {
    [self invoke];
}
@end

@interface JWConfirmCompletionGuard : NSObject
- (instancetype)initWithBlock:(void (^)(BOOL))block;
- (void)invokeWithResult:(BOOL)result;
@end

@implementation JWConfirmCompletionGuard {
    void (^_block)(BOOL);
}
- (instancetype)initWithBlock:(void (^)(BOOL))block {
    self = [super init];
    if (self) _block = [block copy];
    return self;
}
- (void)invokeWithResult:(BOOL)result {
    void (^b)(BOOL) = _block;
    _block = nil;
    if (b) b(result);
}
- (void)dealloc {
    [self invokeWithResult:NO];
}
@end

@interface JWPromptCompletionGuard : NSObject
- (instancetype)initWithBlock:(void (^)(NSString *))block;
- (void)invokeWithText:(NSString *)text;
@end

@implementation JWPromptCompletionGuard {
    void (^_block)(NSString *);
}
- (instancetype)initWithBlock:(void (^)(NSString *))block {
    self = [super init];
    if (self) _block = [block copy];
    return self;
}
- (void)invokeWithText:(NSString *)text {
    void (^b)(NSString *) = _block;
    _block = nil;
    if (b) b(text);
}
- (void)dealloc {
    [self invokeWithText:nil];
}
@end

@interface JWAuthChallengeCompletionGuard : NSObject
- (instancetype)initWithBlock:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))block;
- (void)invokeWithDisposition:(NSURLSessionAuthChallengeDisposition)disposition credential:(NSURLCredential *)credential;
@end

@implementation JWAuthChallengeCompletionGuard {
    void (^_block)(NSURLSessionAuthChallengeDisposition, NSURLCredential *);
}
- (instancetype)initWithBlock:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))block {
    self = [super init];
    if (self) _block = [block copy];
    return self;
}
- (void)invokeWithDisposition:(NSURLSessionAuthChallengeDisposition)disposition credential:(NSURLCredential *)credential {
    void (^b)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) = nil;
    @synchronized (self) {
        b = _block;
        _block = nil;
    }
    if (b) b(disposition, credential);
}
- (void)dealloc {
    [self invokeWithDisposition:NSURLSessionAuthChallengeCancelAuthenticationChallenge credential:nil];
}
@end

@interface JWPendingTrustItem : NSObject
@property (nonatomic, strong) JWAuthChallengeCompletionGuard *guard;
@property (nonatomic, weak) WKWebView *webView;
- (instancetype)initWithServerTrust:(SecTrustRef)trust guard:(JWAuthChallengeCompletionGuard *)guard webView:(WKWebView *)webView;
- (void)resolveAccept:(BOOL)accept;
@end

@implementation JWPendingTrustItem {
    SecTrustRef _serverTrust;
}
- (instancetype)initWithServerTrust:(SecTrustRef)trust guard:(JWAuthChallengeCompletionGuard *)guard webView:(WKWebView *)webView {
    self = [super init];
    if (self) {
        if (trust) _serverTrust = (SecTrustRef)CFRetain(trust);
        _guard = guard;
        _webView = webView;
    }
    return self;
}
- (void)resolveAccept:(BOOL)accept {
    if (accept && _serverTrust) {
        CFDataRef exceptions = SecTrustCopyExceptions(_serverTrust);
        if (exceptions) {
            SecTrustSetExceptions(_serverTrust, exceptions);
            CFRelease(exceptions);
        }
        NSURLCredential *cred = [NSURLCredential credentialForTrust:_serverTrust];
        [self.guard invokeWithDisposition:NSURLSessionAuthChallengeUseCredential credential:cred];
    } else {
        [self.guard invokeWithDisposition:NSURLSessionAuthChallengeCancelAuthenticationChallenge credential:nil];
    }
}
- (void)dealloc {
    if (_serverTrust) {
        CFRelease(_serverTrust);
        _serverTrust = NULL;
    }
}
@end

@interface JWPendingBasicAuthItem : NSObject
@property (nonatomic, strong) JWAuthChallengeCompletionGuard *guard;
@property (nonatomic, weak) WKWebView *webView;
- (instancetype)initWithGuard:(JWAuthChallengeCompletionGuard *)guard webView:(WKWebView *)webView;
- (void)resolveWithCredential:(NSURLCredential *)credential;
@end

@implementation JWPendingBasicAuthItem
- (instancetype)initWithGuard:(JWAuthChallengeCompletionGuard *)guard webView:(WKWebView *)webView {
    self = [super init];
    if (self) {
        _guard = guard;
        _webView = webView;
    }
    return self;
}
- (void)resolveWithCredential:(NSURLCredential *)credential {
    if (credential) {
        [self.guard invokeWithDisposition:NSURLSessionAuthChallengeUseCredential credential:credential];
    } else {
        [self.guard invokeWithDisposition:NSURLSessionAuthChallengeCancelAuthenticationChallenge credential:nil];
    }
}
@end

#pragma mark - Data Models

@interface JWSiteItem : NSObject
@property (nonatomic, copy) NSString *siteId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *appearanceMode; // inherit / system / light / dark
+ (instancetype)siteWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;
@end

@implementation JWSiteItem
- (instancetype)init {
    self = [super init];
    if (self) {
        _siteId = [[NSUUID UUID] UUIDString];
        _title = @"";
        _urlString = @"";
        _enabled = YES;
        _appearanceMode = kJWAppearanceInherit;
    }
    return self;
}

+ (instancetype)siteWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *url = [dict[@"url"] isKindOfClass:[NSString class]] ? dict[@"url"] : @"";
    if (url.length == 0) return nil;
    JWSiteItem *item = [JWSiteItem new];
    NSString *sid = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
    if (sid.length > 0) item.siteId = sid;
    NSString *t = [dict[@"title"] isKindOfClass:[NSString class]] ? dict[@"title"] : @"";
    item.title = t.length > 0 ? t : url;
    item.urlString = url;
    NSNumber *en = [dict[@"enabled"] isKindOfClass:[NSNumber class]] ? dict[@"enabled"] : @YES;
    item.enabled = en.boolValue;
    NSString *am = [dict[@"appearanceMode"] isKindOfClass:[NSString class]] ? dict[@"appearanceMode"] : kJWAppearanceInherit;
    item.appearanceMode = JWNormalizeSiteAppearanceMode(am);
    return item;
}

- (NSDictionary *)toDictionary {
    return @{
        @"id": self.siteId ?: [[NSUUID UUID] UUIDString],
        @"title": self.title ?: @"",
        @"url": self.urlString ?: @"",
        @"enabled": @(self.enabled),
        @"appearanceMode": JWNormalizeSiteAppearanceMode(self.appearanceMode)
    };
}
@end

@interface JWProcStatus : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) NSInteger band;
@property (nonatomic, assign) NSUInteger footprintMB;
@property (nonatomic, copy) NSString *stateTag; // OK / FG / OVER_MEM / STAT / GONE / ERR
- (NSString *)displayBadgeForWebContentWithTargetBand:(NSInteger)targetBand maxMB:(NSInteger)maxMB;
@end

@implementation JWProcStatus
- (NSString *)displayBadgeForWebContentWithTargetBand:(NSInteger)targetBand maxMB:(NSInteger)maxMB {
    if ([self.stateTag isEqualToString:@"OVER_MEM"] ||
        (maxMB > 0 && self.footprintMB > (NSUInteger)maxMB)) {
        return @"OVER_MEM";
    }
    if ([self.stateTag isEqualToString:@"OK"] ||
        [self.stateTag isEqualToString:@"FG"] ||
        self.band >= targetBand ||
        self.band >= 100) {
        return @"OK";
    }
    return self.stateTag ?: @"";
}
@end

@interface JWAppConfig : NSObject
@property (nonatomic, strong) NSMutableArray<JWSiteItem *> *sites;
@property (nonatomic, copy) NSString *selectedSiteId;
@property (nonatomic, assign) NSInteger targetBand;
@property (nonatomic, assign) NSInteger maxMemoryMB;
@property (nonatomic, assign) BOOL dockCollapsed;
@property (nonatomic, copy) NSString *appearanceMode; // system / light / dark
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *trustedCerts; // host -> SHA256 hex
+ (instancetype)loadConfig;
- (BOOL)saveConfig;
- (NSString *)effectiveAppearanceModeForSite:(JWSiteItem *)site;
@end

@implementation JWAppConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        _sites = [NSMutableArray array];
        _selectedSiteId = @"";
        _targetBand = kJWDefaultBand;
        _maxMemoryMB = kJWDefaultMaxMB;
        _dockCollapsed = NO;
        _appearanceMode = kJWAppearanceSystem;
        _trustedCerts = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)effectiveAppearanceModeForSite:(JWSiteItem *)site {
    NSString *siteMode = JWNormalizeSiteAppearanceMode(site.appearanceMode);
    if (![siteMode isEqualToString:kJWAppearanceInherit]) {
        return siteMode;
    }
    return JWNormalizeGlobalAppearanceMode(self.appearanceMode);
}

+ (NSString *)effectiveDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm createDirectoryAtPath:kJWDataDir
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0755}
                            error:nil]) {
        return kJWDataDir;
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return docs ?: NSTemporaryDirectory();
}

+ (NSString *)effectiveConfigPath {
    NSString *dir = [self effectiveDir];
    if ([dir isEqualToString:kJWDataDir]) return kJWConfigPath;
    return [dir stringByAppendingPathComponent:@"config.json"];
}

+ (instancetype)loadConfig {
    JWAppConfig *cfg = [JWAppConfig new];
    NSString *path = [self effectiveConfigPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) return cfg;

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return cfg;

    NSArray *rawSites = [root[@"sites"] isKindOfClass:[NSArray class]] ? root[@"sites"] : @[];
    for (id obj in rawSites) {
        if (cfg.sites.count >= (NSUInteger)kJWMaxSites) break;
        JWSiteItem *item = [JWSiteItem siteWithDictionary:obj];
        if (item) [cfg.sites addObject:item];
    }

    if ([root[@"selectedSiteId"] isKindOfClass:[NSString class]]) {
        cfg.selectedSiteId = root[@"selectedSiteId"];
    }
    if ([root[@"targetBand"] isKindOfClass:[NSNumber class]]) {
        NSInteger b = [root[@"targetBand"] integerValue];
        if (b >= 30 && b <= 95) cfg.targetBand = b;
    }
    if ([root[@"maxMemoryMB"] isKindOfClass:[NSNumber class]]) {
        NSInteger m = [root[@"maxMemoryMB"] integerValue];
        if (m >= 150 && m <= 1200) cfg.maxMemoryMB = m;
    }
    if ([root[@"dockCollapsed"] isKindOfClass:[NSNumber class]]) {
        cfg.dockCollapsed = [root[@"dockCollapsed"] boolValue];
    }
    if ([root[@"appearanceMode"] isKindOfClass:[NSString class]]) {
        cfg.appearanceMode = JWNormalizeGlobalAppearanceMode(root[@"appearanceMode"]);
    }
    if ([root[@"trustedCerts"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *rawCerts = root[@"trustedCerts"];
        for (id key in rawCerts) {
            id val = rawCerts[key];
            if ([key isKindOfClass:[NSString class]] && [val isKindOfClass:[NSString class]]) {
                NSString *host = [(NSString *)key lowercaseString];
                NSString *fp = [(NSString *)val uppercaseString];
                if (host.length > 0 && fp.length >= 32) {
                    cfg.trustedCerts[host] = fp;
                }
            }
        }
    }
    return cfg;
}

- (BOOL)saveConfig {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:self.sites.count];
    for (JWSiteItem *s in self.sites) {
        [arr addObject:[s toDictionary]];
    }
    NSDictionary *root = @{
        @"sites": arr,
        @"selectedSiteId": self.selectedSiteId ?: @"",
        @"targetBand": @(self.targetBand),
        @"maxMemoryMB": @(self.maxMemoryMB),
        @"dockCollapsed": @(self.dockCollapsed),
        @"appearanceMode": JWNormalizeGlobalAppearanceMode(self.appearanceMode),
        @"trustedCerts": self.trustedCerts ?: @{}
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
    if (!json) return NO;
    NSString *path = [JWAppConfig effectiveConfigPath];
    return [json writeToFile:path atomically:YES];
}
@end

#pragma mark - WebKit PID & Root Helper Bridge

static pid_t JWCallPIDSelector(id target, NSString *selName) {
    if (!target || selName.length == 0) return 0;
    SEL sel = NSSelectorFromString(selName);
    if ([target respondsToSelector:sel]) {
        pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(target, sel);
        if (pid > 0) return pid;
    }
    return 0;
}

static pid_t JWWebViewContentPID(WKWebView *webView) {
    return JWCallPIDSelector(webView, @"_webProcessIdentifier");
}

static pid_t JWWebViewNetworkingPID(WKWebView *webView) {
    if (!webView) return 0;
    pid_t pid = JWCallPIDSelector(webView.configuration.websiteDataStore, @"_networkProcessIdentifier");
    if (pid > 0) return pid;
    return JWCallPIDSelector(webView, @"_networkProcessIdentifier");
}

static pid_t JWWebViewGPUPID(WKWebView *webView) {
    return JWCallPIDSelector(webView, @"_gpuProcessIdentifier");
}

static uint64_t JWMonotonicMillis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000L);
}

static void JWDrainPipeFD(int fd, NSMutableData *outData) {
    char buf[512];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n > 0) {
            [outData appendBytes:buf length:(NSUInteger)n];
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

static NSString *JWRunJetWebCtl(NSArray<NSString *> *args, int *exitCodeOut) {
    if (exitCodeOut) *exitCodeOut = -1;
    NSString *binPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"jetwebctl"];
    const char *cbin = binPath.fileSystemRepresentation;
    if (!cbin || access(cbin, X_OK) != 0) {
        return @"ERR helper_missing";
    }

    int pipefd[2] = {-1, -1};
    if (pipe(pipefd) != 0) {
        return @"ERR pipe_failed";
    }

    NSUInteger argc = args.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    if (!argv) {
        close(pipefd[0]);
        close(pipefd[1]);
        return @"ERR nomem";
    }
    argv[0] = strdup(cbin);
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = strdup([args[i] UTF8String] ?: "");
    }
    argv[argc] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (pipefd[0] > STDERR_FILENO) {
        posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    }
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    if (pipefd[1] > STDERR_FILENO) {
        posix_spawn_file_actions_addclose(&actions, pipefd[1]);
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t child = 0;
    int rc = posix_spawn(&child, cbin, &actions, &attr, argv, environ);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < argc; i++) {
        free(argv[i]);
    }
    free(argv);
    close(pipefd[1]);

    NSMutableData *outData = [NSMutableData data];
    if (rc == 0 && child > 0) {
        fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
        uint64_t deadline = JWMonotonicMillis() + 1500ULL;
        int status = 0;
        BOOL done = NO;

        while (JWMonotonicMillis() < deadline) {
            struct pollfd pfd;
            pfd.fd = pipefd[0];
            pfd.events = POLLIN | POLLHUP;
            pfd.revents = 0;
            (void)poll(&pfd, 1, 40);

            JWDrainPipeFD(pipefd[0], outData);

            pid_t w;
            do {
                w = waitpid(child, &status, WNOHANG);
            } while (w < 0 && errno == EINTR);

            if (w == child) {
                done = YES;
                if (WIFEXITED(status) && exitCodeOut) {
                    *exitCodeOut = WEXITSTATUS(status);
                }
                break;
            } else if (w < 0) {
                done = YES;
                break;
            }
        }
        JWDrainPipeFD(pipefd[0], outData);

        if (!done) {
            kill(child, SIGKILL);
            int status2 = 0;
            pid_t w2;
            do {
                w2 = waitpid(child, &status2, 0);
            } while (w2 < 0 && errno == EINTR);
        }
    }
    close(pipefd[0]);

    if (rc != 0) {
        return [NSString stringWithFormat:@"ERR spawn=%d", rc];
    }
    NSString *text = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static NSDictionary<NSNumber *, JWProcStatus *> *JWParseHelperOutput(NSString *output) {
    NSMutableDictionary<NSNumber *, JWProcStatus *> *map = [NSMutableDictionary dictionary];
    if (output.length == 0) return map;

    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (parts.count < 2) continue;
        NSString *tag = parts[0];
        pid_t pid = 0;
        NSInteger band = -1;
        NSUInteger fp = 0;
        for (NSUInteger i = 1; i < parts.count; i++) {
            NSString *kv = parts[i];
            if ([kv hasPrefix:@"pid="]) {
                pid = (pid_t)[[kv substringFromIndex:4] intValue];
            } else if ([kv hasPrefix:@"after="]) {
                band = [[kv substringFromIndex:6] integerValue];
            } else if ([kv hasPrefix:@"cur="] && band < 0) {
                band = [[kv substringFromIndex:4] integerValue];
            } else if ([kv hasPrefix:@"fp="]) {
                fp = (NSUInteger)[[kv substringFromIndex:3] longLongValue];
            }
        }
        if (pid > 0) {
            JWProcStatus *st = [JWProcStatus new];
            st.pid = pid;
            st.band = band;
            st.footprintMB = fp;
            st.stateTag = tag;
            map[@(pid)] = st;
        }
    }
    return map;
}

static NSString *JWNormalizeURLString(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"";
    if (![trimmed containsString:@"://"]) {
        trimmed = [@"https://" stringByAppendingString:trimmed];
    }
    NSURL *u = [NSURL URLWithString:trimmed];
    if (!u || u.scheme.length == 0 || u.host.length == 0) return @"";
    return trimmed;
}

static void JWConfigureCenteredPopover(UIAlertController *sheet, UIView *hostView) {
    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop && hostView) {
        pop.sourceView = hostView;
        pop.sourceRect = CGRectMake(CGRectGetMidX(hostView.bounds), CGRectGetMidY(hostView.bounds), 1, 1);
        pop.permittedArrowDirections = 0;
    }
}

#pragma mark - WebKit User Scripts (iOS 16.4 Polyfills & Input Contrast Fallback)

static WKUserScript *JWWebKitCompatPolyfillScript(void) {
    static NSString *const kPolyfillJS =
        @"(function(){\n"
        @"'use strict';\n"
        @"try{\n"
        @"  if(typeof Promise==='function'&&typeof Promise.withResolvers!=='function'){\n"
        @"    Object.defineProperty(Promise,'withResolvers',{configurable:true,writable:true,value:function withResolvers(){\n"
        @"      var resolve,reject;\n"
        @"      var promise=new this(function(res,rej){resolve=res;reject=rej;});\n"
        @"      return{promise:promise,resolve:resolve,reject:reject};\n"
        @"    }});\n"
        @"  }\n"
        @"  if(typeof Promise==='function'&&typeof Promise.try!=='function'){\n"
        @"    Object.defineProperty(Promise,'try',{configurable:true,writable:true,value:function promiseTry(fn){\n"
        @"      var args=Array.prototype.slice.call(arguments,1);\n"
        @"      return new this(function(resolve){resolve(fn.apply(undefined,args));});\n"
        @"    }});\n"
        @"  }\n"
        @"  if(typeof URL==='function'&&typeof URL.parse!=='function'){\n"
        @"    Object.defineProperty(URL,'parse',{configurable:true,writable:true,value:function parse(url,base){\n"
        @"      try{return(arguments.length>1&&base!==undefined)?new URL(url,base):new URL(url);}catch(_){return null;}\n"
        @"    }});\n"
        @"  }\n"
        @"  if(typeof URL==='function'&&typeof URL.canParse!=='function'){\n"
        @"    Object.defineProperty(URL,'canParse',{configurable:true,writable:true,value:function canParse(url,base){\n"
        @"      try{if(arguments.length>1&&base!==undefined){new URL(url,base);}else{new URL(url);}return true;}catch(_){return false;}\n"
        @"    }});\n"
        @"  }\n"
        @"  if(typeof Object.groupBy!=='function'){\n"
        @"    Object.defineProperty(Object,'groupBy',{configurable:true,writable:true,value:function groupBy(items,cb){\n"
        @"      var out=Object.create(null),idx=0;\n"
        @"      for(var item of items){var k=cb(item,idx++);if(Object.prototype.hasOwnProperty.call(out,k)){out[k].push(item);}else{out[k]=[item];}}\n"
        @"      return out;\n"
        @"    }});\n"
        @"  }\n"
        @"  if(typeof Map==='function'&&typeof Map.groupBy!=='function'){\n"
        @"    Object.defineProperty(Map,'groupBy',{configurable:true,writable:true,value:function groupBy(items,cb){\n"
        @"      var out=new Map(),idx=0;\n"
        @"      for(var item of items){var k=cb(item,idx++),arr=out.get(k);if(arr){arr.push(item);}else{out.set(k,[item]);}}\n"
        @"      return out;\n"
        @"    }});\n"
        @"  }\n"
        @"  if(typeof AbortSignal==='function'&&typeof AbortSignal.any!=='function'){\n"
        @"    Object.defineProperty(AbortSignal,'any',{configurable:true,writable:true,value:function any(signals){\n"
        @"      var ctrl=new AbortController(),list=Array.from(signals||[]);\n"
        @"      for(var i=0;i<list.length;i++){if(list[i]&&list[i].aborted){ctrl.abort(list[i].reason);return ctrl.signal;}}\n"
        @"      var onAbort=function(ev){\n"
        @"        ctrl.abort(ev&&ev.target?ev.target.reason:undefined);\n"
        @"        for(var j=0;j<list.length;j++){if(list[j])list[j].removeEventListener('abort',onAbort);}\n"
        @"      };\n"
        @"      for(var k=0;k<list.length;k++){if(list[k])list[k].addEventListener('abort',onAbort,{once:true});}\n"
        @"      return ctrl.signal;\n"
        @"    }});\n"
        @"  }\n"
        @"}catch(_){}\n"
        @"})();\n";
    return [[WKUserScript alloc] initWithSource:kPolyfillJS
                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                               forMainFrameOnly:NO
                                 inContentWorld:[WKContentWorld pageWorld]];
}

static WKUserScript *JWInputContrastFixScript(void) {
    static NSString *const kContrastJS =
        @"(function(){\n"
        @"'use strict';\n"
        @"if(window.__jwContrastFixInstalled)return;\n"
        @"window.__jwContrastFixInstalled=true;\n"
        @"var SKIP_TYPES={hidden:1,checkbox:1,radio:1,button:1,submit:1,reset:1,image:1,file:1,range:1,color:1};\n"
        @"var patched=new WeakMap();\n"
        @"function isTextInput(el){\n"
        @"  if(!el||el.nodeType!==1)return false;\n"
        @"  var tag=el.tagName;\n"
        @"  if(tag==='TEXTAREA')return true;\n"
        @"  if(tag==='INPUT'){var t=(el.getAttribute('type')||'text').toLowerCase();return !SKIP_TYPES[t];}\n"
        @"  return false;\n"
        @"}\n"
        @"function parseColor(str){\n"
        @"  if(!str||typeof str!=='string')return null;\n"
        @"  str=str.trim().toLowerCase();\n"
        @"  if(str==='transparent')return{r:0,g:0,b:0,a:0};\n"
        @"  var m=str.match(/^rgba?\\(([^)]+)\\)$/);\n"
        @"  if(m){\n"
        @"    var body=m[1].trim();\n"
        @"    var alpha=1;\n"
        @"    var slash=body.split('/');\n"
        @"    if(slash.length===2){\n"
        @"      var aStr=slash[1].trim();\n"
        @"      alpha=aStr.endsWith('%')?parseFloat(aStr)/100:parseFloat(aStr);\n"
        @"      body=slash[0].trim();\n"
        @"    }\n"
        @"    var parts=body.indexOf(',')!==-1?body.split(','):body.split(/\\s+/);\n"
        @"    if(parts.length<3)return null;\n"
        @"    var r=parseFloat(parts[0]),g=parseFloat(parts[1]),b=parseFloat(parts[2]);\n"
        @"    if(parts.length>=4&&slash.length===1){\n"
        @"      var a4=parts[3].trim();\n"
        @"      alpha=a4.endsWith('%')?parseFloat(a4)/100:parseFloat(a4);\n"
        @"    }\n"
        @"    if(isNaN(r)||isNaN(g)||isNaN(b)||isNaN(alpha))return null;\n"
        @"    return{r:Math.max(0,Math.min(255,r)),g:Math.max(0,Math.min(255,g)),b:Math.max(0,Math.min(255,b)),a:Math.max(0,Math.min(1,alpha))};\n"
        @"  }\n"
        @"  var srgb=str.match(/^color\\(\\s*srgb\\s+([\\d.e+-]+)\\s+([\\d.e+-]+)\\s+([\\d.e+-]+)(?:\\s*\\/\\s*([\\d.e+%-]+))?\\s*\\)$/);\n"
        @"  if(srgb){\n"
        @"    var a=1;\n"
        @"    if(srgb[4]!==undefined){a=srgb[4].endsWith('%')?parseFloat(srgb[4])/100:parseFloat(srgb[4]);}\n"
        @"    return{r:Math.max(0,Math.min(255,parseFloat(srgb[1])*255)),g:Math.max(0,Math.min(255,parseFloat(srgb[2])*255)),b:Math.max(0,Math.min(255,parseFloat(srgb[3])*255)),a:isNaN(a)?1:Math.max(0,Math.min(1,a))};\n"
        @"  }\n"
        @"  return null;\n"
        @"}\n"
        @"function compositeOver(fg,bg){\n"
        @"  var a=fg.a;\n"
        @"  return{r:fg.r*a+bg.r*(1-a),g:fg.g*a+bg.g*(1-a),b:fg.b*a+bg.b*(1-a),a:1};\n"
        @"}\n"
        @"function baseCanvasColor(){\n"
        @"  try{\n"
        @"    var isDark=window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches;\n"
        @"    if(isDark&&document.documentElement){\n"
        @"      var cs=(getComputedStyle(document.documentElement).colorScheme||'').toLowerCase();\n"
        @"      if(cs.indexOf('dark')!==-1&&cs!=='only light')return{r:18,g:18,b:18,a:1};\n"
        @"    }\n"
        @"  }catch(_){}\n"
        @"  return{r:255,g:255,b:255,a:1};\n"
        @"}\n"
        @"function effectiveBackground(el){\n"
        @"  var layers=[],node=el,depth=0;\n"
        @"  while(node&&node.nodeType===1&&depth<40){\n"
        @"    var bg=parseColor(getComputedStyle(node).backgroundColor);\n"
        @"    if(bg&&bg.a>0.01){\n"
        @"      layers.push(bg);\n"
        @"      if(bg.a>=0.99)break;\n"
        @"    }\n"
        @"    var next=node.parentElement;\n"
        @"    if(!next&&node.getRootNode){var rn=node.getRootNode();if(rn&&rn.host)next=rn.host;}\n"
        @"    node=next;\n"
        @"    depth++;\n"
        @"  }\n"
        @"  var cur=(layers.length>0&&layers[layers.length-1].a>=0.99)?layers.pop():baseCanvasColor();\n"
        @"  for(var i=layers.length-1;i>=0;i--){cur=compositeOver(layers[i],cur);}\n"
        @"  return cur;\n"
        @"}\n"
        @"function luminance(c){\n"
        @"  function lin(v){v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);}\n"
        @"  return 0.2126*lin(c.r)+0.7152*lin(c.g)+0.0722*lin(c.b);\n"
        @"}\n"
        @"function contrastRatio(c1,c2){\n"
        @"  var l1=luminance(c1),l2=luminance(c2);\n"
        @"  return(Math.max(l1,l2)+0.05)/(Math.min(l1,l2)+0.05);\n"
        @"}\n"
        @"function restoreOriginal(el){\n"
        @"  var orig=patched.get(el);\n"
        @"  if(!orig)return;\n"
        @"  if(orig.color)el.style.setProperty('color',orig.color,orig.colorPrio);\n"
        @"  else el.style.removeProperty('color');\n"
        @"  if(orig.fill)el.style.setProperty('-webkit-text-fill-color',orig.fill,orig.fillPrio);\n"
        @"  else el.style.removeProperty('-webkit-text-fill-color');\n"
        @"  if(orig.caret)el.style.setProperty('caret-color',orig.caret,orig.caretPrio);\n"
        @"  else el.style.removeProperty('caret-color');\n"
        @"}\n"
        @"function saveOriginal(el){\n"
        @"  if(patched.has(el))return;\n"
        @"  patched.set(el,{\n"
        @"    color:el.style.getPropertyValue('color'),\n"
        @"    colorPrio:el.style.getPropertyPriority('color'),\n"
        @"    fill:el.style.getPropertyValue('-webkit-text-fill-color'),\n"
        @"    fillPrio:el.style.getPropertyPriority('-webkit-text-fill-color'),\n"
        @"    caret:el.style.getPropertyValue('caret-color'),\n"
        @"    caretPrio:el.style.getPropertyPriority('caret-color')\n"
        @"  });\n"
        @"}\n"
        @"function checkAndFix(el){\n"
        @"  try{\n"
        @"    if(!isTextInput(el))return;\n"
        @"    var wasPatched=patched.has(el);\n"
        @"    if(wasPatched)restoreOriginal(el);\n"
        @"    var cs=getComputedStyle(el);\n"
        @"    if(!cs||cs.display==='none'||cs.visibility==='hidden'){if(wasPatched)patched.delete(el);return;}\n"
        @"    var op=parseFloat(cs.opacity);\n"
        @"    if(!isNaN(op)&&op<0.05){if(wasPatched)patched.delete(el);return;}\n"
        @"    var fs=parseFloat(cs.fontSize);\n"
        @"    if(!isNaN(fs)&&fs<1){if(wasPatched)patched.delete(el);return;}\n"
        @"    var rect=el.getBoundingClientRect();\n"
        @"    if(rect.width<=2||rect.height<=2){if(wasPatched)patched.delete(el);return;}\n"
        @"    var rawColor=parseColor(cs.color);\n"
        @"    var rawFill=parseColor(cs.getPropertyValue('-webkit-text-fill-color'));\n"
        @"    if((rawColor&&rawColor.a<0.05)||(rawFill&&rawFill.a<0.05)){if(wasPatched)patched.delete(el);return;}\n"
        @"    var selfBg=parseColor(cs.backgroundColor);\n"
        @"    if((!selfBg||selfBg.a<0.05)&&cs.backgroundImage&&cs.backgroundImage!=='none'){if(wasPatched)patched.delete(el);return;}\n"
        @"    var fg=rawFill||rawColor;\n"
        @"    if(!fg){if(wasPatched)patched.delete(el);return;}\n"
        @"    var bg=effectiveBackground(el);\n"
        @"    var effFg=(fg.a<0.99)?compositeOver(fg,bg):fg;\n"
        @"    var ratio=contrastRatio(effFg,bg);\n"
        @"    if(ratio<2.6){\n"
        @"      saveOriginal(el);\n"
        @"      var target=luminance(bg)>0.35?'#111827':'#f8fafc';\n"
        @"      el.style.setProperty('color',target,'important');\n"
        @"      el.style.setProperty('-webkit-text-fill-color',target,'important');\n"
        @"      el.style.setProperty('caret-color',target,'important');\n"
        @"    }else if(wasPatched){\n"
        @"      patched.delete(el);\n"
        @"    }\n"
        @"  }catch(_){}\n"
        @"}\n"
        @"function eventTarget(ev){\n"
        @"  if(ev&&typeof ev.composedPath==='function'){var p=ev.composedPath();if(p&&p.length)return p[0];}\n"
        @"  return ev?ev.target:null;\n"
        @"}\n"
        @"document.addEventListener('focusin',function(ev){\n"
        @"  var t=eventTarget(ev);\n"
        @"  if(!isTextInput(t))return;\n"
        @"  checkAndFix(t);\n"
        @"  requestAnimationFrame(function(){checkAndFix(t);});\n"
        @"  setTimeout(function(){checkAndFix(t);},80);\n"
        @"},true);\n"
        @"document.addEventListener('input',function(ev){checkAndFix(eventTarget(ev));},true);\n"
        @"document.addEventListener('change',function(ev){checkAndFix(eventTarget(ev));},true);\n"
        @"document.addEventListener('blur',function(ev){\n"
        @"  var t=eventTarget(ev);\n"
        @"  if(isTextInput(t)&&(patched.has(t)||(t.value&&t.value.length>0))){checkAndFix(t);}\n"
        @"},true);\n"
        @"window.__jwRecheckInputs=function(){\n"
        @"  try{\n"
        @"    if(document.activeElement)checkAndFix(document.activeElement);\n"
        @"    var list=document.querySelectorAll('input,textarea');\n"
        @"    for(var i=0;i<list.length;i++){\n"
        @"      var el=list[i];\n"
        @"      if(el===document.activeElement||patched.has(el)||(el.value&&el.value.length>0))checkAndFix(el);\n"
        @"    }\n"
        @"  }catch(_){}\n"
        @"};\n"
        @"try{\n"
        @"  var mq=window.matchMedia('(prefers-color-scheme: dark)');\n"
        @"  if(mq&&mq.addEventListener)mq.addEventListener('change',function(){setTimeout(window.__jwRecheckInputs,50);});\n"
        @"}catch(_){}\n"
        @"})();\n";
    return [[WKUserScript alloc] initWithSource:kContrastJS
                                  injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                               forMainFrameOnly:NO
                                 inContentWorld:[WKContentWorld defaultClientWorld]];
}

#pragma mark - Navigation Error Overlay View

@interface JWErrorOverlayView : UIView
@property (nonatomic, copy) NSString *failedURLString;
@property (nonatomic, copy) void (^onRetry)(void);
@property (nonatomic, copy) void (^onGoHome)(void);
- (void)configureWithError:(NSError *)error failedURL:(NSString *)failedURL homeURL:(NSString *)homeURL customTitle:(NSString *)customTitle customDetail:(NSString *)customDetail;
@end

@implementation JWErrorOverlayView {
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_urlLabel;
    UILabel *_detailLabel;
    UIButton *_retryButton;
    UIButton *_homeButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = UIColor.systemBackgroundColor;
        self.hidden = YES;

        UIStackView *stack = [UIStackView new];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 12;
        [self addSubview:stack];

        _iconView = [UIImageView new];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        [stack addArrangedSubview:_iconView];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 0;
        [stack addArrangedSubview:_titleLabel];

        _urlLabel = [UILabel new];
        _urlLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        _urlLabel.textColor = UIColor.secondaryLabelColor;
        _urlLabel.textAlignment = NSTextAlignmentCenter;
        _urlLabel.numberOfLines = 2;
        _urlLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [stack addArrangedSubview:_urlLabel];

        _detailLabel = [UILabel new];
        _detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _detailLabel.textColor = UIColor.secondaryLabelColor;
        _detailLabel.textAlignment = NSTextAlignmentCenter;
        _detailLabel.numberOfLines = 0;
        [stack addArrangedSubview:_detailLabel];

        UIStackView *btnRow = [UIStackView new];
        btnRow.axis = UILayoutConstraintAxisHorizontal;
        btnRow.spacing = 12;
        btnRow.alignment = UIStackViewAlignmentCenter;
        [stack addArrangedSubview:btnRow];
        [stack setCustomSpacing:20 afterView:_detailLabel];

        _retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *retryCfg = [UIButtonConfiguration filledButtonConfiguration];
        retryCfg.title = @"重新加载";
        retryCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        retryCfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 22, 10, 22);
        _retryButton.configuration = retryCfg;
        [_retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
        [btnRow addArrangedSubview:_retryButton];

        _homeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *homeCfg = [UIButtonConfiguration tintedButtonConfiguration];
        homeCfg.title = @"回到首页";
        homeCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        homeCfg.contentInsets = NSDirectionalEdgeInsetsMake(10, 18, 10, 18);
        _homeButton.configuration = homeCfg;
        [_homeButton addTarget:self action:@selector(homeTapped) forControlEvents:UIControlEventTouchUpInside];
        [btnRow addArrangedSubview:_homeButton];

        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-12],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:28],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-28],
            [_iconView.widthAnchor constraintEqualToConstant:44],
            [_iconView.heightAnchor constraintEqualToConstant:44]
        ]];
    }
    return self;
}

- (void)configureWithError:(NSError *)error failedURL:(NSString *)failedURL homeURL:(NSString *)homeURL customTitle:(NSString *)customTitle customDetail:(NSString *)customDetail {
    self.failedURLString = failedURL.length > 0 ? failedURL : (homeURL ?: @"");
    BOOL isSSL = JWIsSSLError(error);

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIFontWeightMedium];
    NSString *symbolName = isSSL ? @"lock.trianglebadge.exclamationmark" : @"exclamationmark.triangle.fill";
    UIImage *img = [UIImage systemImageNamed:symbolName withConfiguration:symCfg];
    if (!img) img = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:symCfg];
    _iconView.image = img;
    _iconView.tintColor = isSSL ? UIColor.systemRedColor : UIColor.systemOrangeColor;

    if (customTitle.length > 0) {
        _titleLabel.text = customTitle;
    } else if (isSSL) {
        _titleLabel.text = @"HTTPS 证书校验失败";
    } else if (error && [error.domain isEqualToString:NSURLErrorDomain] &&
               (error.code == NSURLErrorNotConnectedToInternet ||
                error.code == NSURLErrorCannotFindHost ||
                error.code == NSURLErrorCannotConnectToHost ||
                error.code == NSURLErrorTimedOut)) {
        _titleLabel.text = @"无法连接到服务器";
    } else {
        _titleLabel.text = @"页面加载失败";
    }

    _urlLabel.text = self.failedURLString;
    _urlLabel.hidden = (self.failedURLString.length == 0);

    if (customDetail.length > 0) {
        _detailLabel.text = customDetail;
    } else if (error) {
        NSString *tip = @"";
        if (isSSL) {
            tip = @"\n\n若这是你自建的内网或自签名 HTTPS 服务，请点击「重新加载」并在弹窗中选择信任此域名证书。";
        } else if ([error.domain isEqualToString:NSURLErrorDomain] &&
                   (error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorCannotFindHost)) {
            tip = @"\n\n请确认手机已接入对应内网 / VPN，并允许 JetWeb 访问「本地网络」。";
        }
        _detailLabel.text = [NSString stringWithFormat:@"%@\n（%@ · 错误码 %ld）%@",
                             error.localizedDescription ?: @"未知网络错误",
                             error.domain ?: @"",
                             (long)error.code,
                             tip];
    } else {
        _detailLabel.text = @"页面加载中断，请点击下方按钮重试。";
    }

    BOOL showHome = (homeURL.length > 0 && self.failedURLString.length > 0 && ![homeURL isEqualToString:self.failedURLString]);
    _homeButton.hidden = !showHome;
}

- (void)retryTapped {
    if (self.onRetry) self.onRetry();
}

- (void)homeTapped {
    if (self.onGoHome) self.onGoHome();
}
@end

#pragma mark - Tab Pill Control

@interface JWSitePillControl : UIControl
@property (nonatomic, copy) NSString *siteId;
@property (nonatomic, strong) UIView *dotView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) BOOL activeTab;
- (void)configureWithTitle:(NSString *)title active:(BOOL)active aliveState:(NSString *)stateTag;
@end

@implementation JWSitePillControl
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = 15;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _dotView = [UIView new];
        _dotView.translatesAutoresizingMaskIntoConstraints = NO;
        _dotView.layer.cornerRadius = 3.5;
        _dotView.userInteractionEnabled = NO;
        [self addSubview:_dotView];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:30],
            [self.widthAnchor constraintLessThanOrEqualToConstant:150],
            [_dotView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_dotView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_dotView.widthAnchor constraintEqualToConstant:7],
            [_dotView.heightAnchor constraintEqualToConstant:7],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_dotView.trailingAnchor constant:6],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-11],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title active:(BOOL)active aliveState:(NSString *)stateTag {
    self.activeTab = active;
    self.titleLabel.text = title.length > 0 ? title : @"网页";
    if (active) {
        self.backgroundColor = UIColor.systemBlueColor;
        self.titleLabel.textColor = UIColor.whiteColor;
    } else {
        self.backgroundColor = [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.85];
        self.titleLabel.textColor = UIColor.labelColor;
    }

    if ([stateTag isEqualToString:@"OK"] || [stateTag isEqualToString:@"FG"]) {
        self.dotView.backgroundColor = active ? [UIColor colorWithRed:0.35 green:1.0 blue:0.55 alpha:1.0] : UIColor.systemGreenColor;
    } else if ([stateTag isEqualToString:@"OVER_MEM"]) {
        self.dotView.backgroundColor = UIColor.systemOrangeColor;
    } else {
        self.dotView.backgroundColor = active ? [UIColor colorWithWhite:1.0 alpha:0.65] : UIColor.tertiaryLabelColor;
    }
}
@end

#pragma mark - Manage View Controller Delegate

@protocol JWManageViewControllerDelegate <NSObject>
- (NSDictionary<NSString *, NSNumber *> *)manageCurrentWebPIDsBySiteId;
- (void)manageQueryLiveStatusesAsync:(void (^)(NSDictionary<NSNumber *, JWProcStatus *> *statuses))completion;
- (void)manageDidUpdateConfigAndReloadSites:(BOOL)structureChanged selectedSiteId:(NSString *)siteId;
- (void)manageDidUpdateAppearanceConfig;
- (void)manageDidUpdateTrustedCerts;
- (void)manageDidRequestApplyProtectionNow:(void (^)(NSString *summary))completion;
- (void)manageDidRequestReloadSiteId:(NSString *)siteId;
- (void)manageDidClearWebsiteData;
@end

@interface JWManageViewController : UITableViewController
@property (nonatomic, strong) JWAppConfig *config;
@property (nonatomic, weak) id<JWManageViewControllerDelegate> delegate;
@property (nonatomic, strong) NSDictionary<NSNumber *, JWProcStatus *> *liveStatuses;
@property (nonatomic, copy) NSString *helperBannerText;
@end

@implementation JWManageViewController

- (instancetype)initWithConfig:(JWAppConfig *)config delegate:(id<JWManageViewControllerDelegate>)delegate {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _config = config;
        _delegate = delegate;
        _liveStatuses = @{};
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"常驻工作台设置";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                                                             style:UIBarButtonItemStyleDone
                                                                            target:self
                                                                            action:@selector(closeTapped)];
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                            target:self
                                                                            action:@selector(addSiteTapped)];
    self.navigationItem.rightBarButtonItems = @[addBtn, self.editButtonItem];
    [self refreshLiveStatus];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshLiveStatus {
    if (!self.delegate) return;
    __weak typeof(self) weakSelf = self;
    [self.delegate manageQueryLiveStatusesAsync:^(NSDictionary<NSNumber *, JWProcStatus *> *statuses) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.liveStatuses = statuses ?: @{};
        [self.tableView reloadData];
    }];
}

- (void)addSiteTapped {
    if (self.config.sites.count >= (NSUInteger)kJWMaxSites) {
        UIAlertController *err = [UIAlertController alertControllerWithTitle:@"已达上限"
                                                                     message:@"为保护 iPhone 4GB 内存，最多同时配置 8 个常驻站点。"
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [err addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:err animated:YES completion:nil];
        return;
    }
    [self showSiteEditorForItem:nil];
}

- (void)showSiteActionSheetForItem:(JWSiteItem *)site {
    if (!site) return;
    NSString *modeLabel = JWAppearanceModeLabel(site.appearanceMode);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:site.title
                                                                   message:site.urlString
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"编辑名称与网址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf showSiteEditorForItem:site];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"外观模式：%@", modeLabel]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf showAppearancePickerForSite:site];
    }]];
    if (site.enabled) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"重新加载此站点" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [weakSelf.delegate manageDidRequestReloadSiteId:site.siteId];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    JWConfigureCenteredPopover(sheet, self.view);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showAppearancePickerForSite:(JWSiteItem *)site {
    if (!site) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ · 外观模式", site.title]
                                                                   message:@"部分网页在深色模式下会出现输入框白底白字，可单独切换为强制浅色。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *modes = @[kJWAppearanceInherit, kJWAppearanceSystem, kJWAppearanceLight, kJWAppearanceDark];
    NSString *cur = JWNormalizeSiteAppearanceMode(site.appearanceMode);
    __weak typeof(self) weakSelf = self;
    for (NSString *m in modes) {
        NSString *prefix = [m isEqualToString:cur] ? @"✓ " : @"";
        NSString *title = [prefix stringByAppendingString:JWAppearanceModeLabel(m)];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            site.appearanceMode = m;
            [self.config saveConfig];
            [self.delegate manageDidUpdateAppearanceConfig];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    JWConfigureCenteredPopover(sheet, self.view);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showGlobalAppearancePicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"全局外观模式"
                                                                   message:@"作用于所有设为「跟随全局」的站点及工作台界面。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *modes = @[kJWAppearanceSystem, kJWAppearanceLight, kJWAppearanceDark];
    NSString *cur = JWNormalizeGlobalAppearanceMode(self.config.appearanceMode);
    __weak typeof(self) weakSelf = self;
    for (NSString *m in modes) {
        NSString *prefix = [m isEqualToString:cur] ? @"✓ " : @"";
        NSString *title = [prefix stringByAppendingString:JWAppearanceModeLabel(m)];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.config.appearanceMode = m;
            [self.config saveConfig];
            self.navigationController.overrideUserInterfaceStyle = JWUIUserInterfaceStyleForMode(m, UIUserInterfaceStyleUnspecified);
            [self.delegate manageDidUpdateAppearanceConfig];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    JWConfigureCenteredPopover(sheet, self.view);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showTrustedCertsManager {
    NSArray<NSString *> *hosts = [[self.config.trustedCerts allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    if (hosts.count == 0) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"暂无已信任的自签名证书"
                                                                       message:@"访问使用自签名证书的内网 HTTPS 站点时，会在弹窗中提示是否按域名永久信任。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:empty animated:YES completion:nil];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"已信任的自签名证书"
                                                                   message:@"点击对应域名可撤销信任（撤销后下次访问会重新询问）"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *host in hosts) {
        NSString *fp = self.config.trustedCerts[host] ?: @"";
        NSString *shortFp = JWFormatShortFingerprint(fp);
        NSString *title = [NSString stringWithFormat:@"撤销 %@ (%@)", host, shortFp];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.config.trustedCerts removeObjectForKey:host];
            [self.config saveConfig];
            [self.delegate manageDidUpdateTrustedCerts];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"清除全部已信任证书" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self.config.trustedCerts removeAllObjects];
        [self.config saveConfig];
        [self.delegate manageDidUpdateTrustedCerts];
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    JWConfigureCenteredPopover(sheet, self.view);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSiteEditorForItem:(JWSiteItem *)existing {
    BOOL isNew = (existing == nil);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(isNew ? @"添加常驻 WebApp" : @"编辑 WebApp")
                                                                   message:@"网址仅保存在本机，不会上传"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"名称（如：面板 / AI / 笔记）";
        tf.text = existing ? existing.title : @"";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"网址（如 https://example.com）";
        tf.text = existing ? existing.urlString : @"";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *rawTitle = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *normURL = JWNormalizeURLString(alert.textFields[1].text ?: @"");
        if (normURL.length == 0) {
            UIAlertController *bad = [UIAlertController alertControllerWithTitle:@"网址无效"
                                                                         message:@"请输入合法的 http:// 或 https:// 网址"
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [bad addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:bad animated:YES completion:nil];
            return;
        }
        NSString *finalTitle = rawTitle;
        if (finalTitle.length == 0) {
            NSURL *u = [NSURL URLWithString:normURL];
            finalTitle = u.host ?: normURL;
        }
        NSString *selectId = nil;
        if (isNew) {
            JWSiteItem *item = [JWSiteItem new];
            item.title = finalTitle;
            item.urlString = normURL;
            item.enabled = YES;
            [self.config.sites addObject:item];
            selectId = item.siteId;
        } else {
            BOOL urlChanged = ![existing.urlString isEqualToString:normURL];
            existing.title = finalTitle;
            existing.urlString = normURL;
            if (urlChanged) {
                [self.delegate manageDidRequestReloadSiteId:existing.siteId];
            }
        }
        [self.config saveConfig];
        [self.delegate manageDidUpdateConfigAndReloadSites:YES selectedSiteId:selectId];
        [self refreshLiveStatus];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.config.sites.count + 2; // Host + sites + refresh button
    if (section == 1) return MAX(1, (NSInteger)self.config.sites.count);
    return 5; // Global Appearance, Trusted Certs, Band, MaxMB, Clear Cache
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"实时进程与保活档位";
    if (section == 1) return [NSString stringWithFormat:@"常驻 WebApp (%lu/%ld)", (unsigned long)self.config.sites.count, (long)kJWMaxSites];
    return @"外观、证书与保活策略";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return self.helperBannerText.length > 0
            ? self.helperBannerText
            : @"切标签或退后台时，JetWeb 会把自身与各标签的 WebContent 渲染进程一起抬到目标档位，避免切回白屏重刷。";
    }
    if (section == 2) {
        return [NSString stringWithFormat:@"JetWeb v%s (%s) · 单标签超内存上限将自动退回 30 档防撑爆 4GB 内存", JW_VERSION, JW_COMMIT];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSInteger refreshRow = (NSInteger)self.config.sites.count + 1;
        if (indexPath.row == refreshRow) {
            UITableViewCell *btnCell = [tableView dequeueReusableCellWithIdentifier:@"ActionCell"];
            if (!btnCell) btnCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ActionCell"];
            btnCell.textLabel.text = @"立即刷新并重设保活档位";
            btnCell.textLabel.textColor = UIColor.systemBlueColor;
            btnCell.textLabel.textAlignment = NSTextAlignmentCenter;
            btnCell.accessoryView = nil;
            return btnCell;
        }

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"StatCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"StatCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        if (indexPath.row == 0) {
            pid_t selfPid = getpid();
            JWProcStatus *st = self.liveStatuses[@(selfPid)];
            cell.textLabel.text = [NSString stringWithFormat:@"JetWeb 主进程 (PID %d)", (int)selfPid];
            if (st && st.band >= 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"档位 %ld · %lu MB", (long)st.band, (unsigned long)st.footprintMB];
                cell.detailTextLabel.textColor = (st.band >= self.config.targetBand || st.band >= 100) ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
            } else {
                cell.detailTextLabel.text = @"读取中 / 需 TrollStore 安装";
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            }
            return cell;
        }

        JWSiteItem *site = self.config.sites[(NSUInteger)(indexPath.row - 1)];
        NSDictionary<NSString *, NSNumber *> *pidsBySite = [self.delegate manageCurrentWebPIDsBySiteId];
        pid_t wpid = [pidsBySite[site.siteId] intValue];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · 渲染进程", site.title];
        if (!site.enabled) {
            cell.detailTextLabel.text = @"已暂停";
            cell.detailTextLabel.textColor = UIColor.tertiaryLabelColor;
        } else if (wpid <= 0) {
            cell.detailTextLabel.text = @"待加载";
            cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        } else {
            JWProcStatus *st = self.liveStatuses[@(wpid)];
            if (st && st.band >= 0) {
                NSString *badge = [st displayBadgeForWebContentWithTargetBand:self.config.targetBand maxMB:self.config.maxMemoryMB];
                BOOL overMem = [badge isEqualToString:@"OVER_MEM"];
                NSString *warn = overMem ? @" (超内存限额)" : @"";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"PID %d · 档位 %ld · %lu MB%@",
                                             (int)wpid, (long)st.band, (unsigned long)st.footprintMB, warn];
                if (overMem) {
                    cell.detailTextLabel.textColor = UIColor.systemOrangeColor;
                } else if ([badge isEqualToString:@"OK"]) {
                    cell.detailTextLabel.textColor = UIColor.systemGreenColor;
                } else {
                    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
                }
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"PID %d", (int)wpid];
                cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
            }
        }
        return cell;
    }

    if (indexPath.section == 1) {
        if (self.config.sites.count == 0) {
            UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:@"EmptySite"];
            if (!empty) empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"EmptySite"];
            empty.textLabel.text = @"点击右上角「+」添加你的常驻 WebApp";
            empty.textLabel.textColor = UIColor.systemBlueColor;
            empty.textLabel.textAlignment = NSTextAlignmentCenter;
            empty.accessoryView = nil;
            return empty;
        }

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SiteCell"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SiteCell"];
        JWSiteItem *site = self.config.sites[(NSUInteger)indexPath.row];
        cell.textLabel.text = site.title;
        NSString *siteMode = JWNormalizeSiteAppearanceMode(site.appearanceMode);
        if (![siteMode isEqualToString:kJWAppearanceInherit]) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", site.urlString, JWAppearanceModeLabel(siteMode)];
        } else {
            cell.detailTextLabel.text = site.urlString;
        }
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

        UISwitch *sw = [UISwitch new];
        sw.on = site.enabled;
        [sw addTarget:self action:@selector(siteSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.showsReorderControl = YES;
        return cell;
    }

    UITableViewCell *cfgCell = [tableView dequeueReusableCellWithIdentifier:@"CfgCell"];
    if (!cfgCell) cfgCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"CfgCell"];
    cfgCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (indexPath.row == 0) {
        cfgCell.textLabel.text = @"全局外观模式";
        cfgCell.textLabel.textColor = UIColor.labelColor;
        cfgCell.detailTextLabel.text = JWAppearanceModeLabel(JWNormalizeGlobalAppearanceMode(self.config.appearanceMode));
    } else if (indexPath.row == 1) {
        cfgCell.textLabel.text = @"已信任的自签名证书";
        cfgCell.textLabel.textColor = UIColor.labelColor;
        NSUInteger certCount = self.config.trustedCerts.count;
        cfgCell.detailTextLabel.text = certCount > 0 ? [NSString stringWithFormat:@"%lu 个域名", (unsigned long)certCount] : @"无";
    } else if (indexPath.row == 2) {
        cfgCell.textLabel.text = @"后台保活目标档位";
        cfgCell.textLabel.textColor = UIColor.labelColor;
        cfgCell.detailTextLabel.text = [NSString stringWithFormat:@"%ld 档", (long)self.config.targetBand];
    } else if (indexPath.row == 3) {
        cfgCell.textLabel.text = @"单网页内存安全上限";
        cfgCell.textLabel.textColor = UIColor.labelColor;
        cfgCell.detailTextLabel.text = [NSString stringWithFormat:@"%ld MB", (long)self.config.maxMemoryMB];
    } else {
        cfgCell.textLabel.text = @"清理全部网页缓存与登录态";
        cfgCell.textLabel.textColor = UIColor.systemRedColor;
        cfgCell.detailTextLabel.text = @"";
        cfgCell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cfgCell;
}

- (void)siteSwitchChanged:(UISwitch *)sender {
    CGPoint pt = [sender convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:pt];
    if (!ip || ip.section != 1 || ip.row < 0 || (NSUInteger)ip.row >= self.config.sites.count) return;
    self.config.sites[(NSUInteger)ip.row].enabled = sender.isOn;
    [self.config saveConfig];
    [self.delegate manageDidUpdateConfigAndReloadSites:YES selectedSiteId:nil];
    [self refreshLiveStatus];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && self.config.sites.count > 0;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && self.config.sites.count > 1;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 1 || destinationIndexPath.section != 1) return;
    JWSiteItem *item = self.config.sites[(NSUInteger)sourceIndexPath.row];
    [self.config.sites removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [self.config.sites insertObject:item atIndex:(NSUInteger)destinationIndexPath.row];
    [self.config saveConfig];
    [self.delegate manageDidUpdateConfigAndReloadSites:NO selectedSiteId:nil];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf.tableView reloadData];
    });
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && editingStyle == UITableViewCellEditingStyleDelete && (NSUInteger)indexPath.row < self.config.sites.count) {
        [self.config.sites removeObjectAtIndex:(NSUInteger)indexPath.row];
        [self.config saveConfig];
        [self.delegate manageDidUpdateConfigAndReloadSites:YES selectedSiteId:nil];
        [self refreshLiveStatus];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == (NSInteger)self.config.sites.count + 1) {
        __weak typeof(self) weakSelf = self;
        [self.delegate manageDidRequestApplyProtectionNow:^(NSString *summary) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.helperBannerText = summary;
            [self refreshLiveStatus];
        }];
        return;
    }
    if (indexPath.section == 1) {
        if (self.config.sites.count == 0) {
            [self addSiteTapped];
        } else {
            [self showSiteActionSheetForItem:self.config.sites[(NSUInteger)indexPath.row]];
        }
        return;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self showGlobalAppearancePicker];
        } else if (indexPath.row == 1) {
            [self showTrustedCertsManager];
        } else if (indexPath.row == 2) {
            [self showBandPicker];
        } else if (indexPath.row == 3) {
            [self showMaxMemoryPicker];
        } else {
            [self confirmClearAllWebsiteData];
        }
    }
}

- (void)showBandPicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"后台保活目标档位"
                                                                   message:@"建议 85 档（高于普通后台 30 档，严禁超过 95 档）"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *b in @[@75, @80, @85, @90, @95]) {
        NSString *title = [NSString stringWithFormat:@"%ld 档%@", (long)b.integerValue, (b.integerValue == 85 ? @"（推荐）" : @"")];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.config.targetBand = b.integerValue;
            [self.config saveConfig];
            [self.delegate manageDidRequestApplyProtectionNow:^(NSString *summary) {
                self.helperBannerText = summary;
                [self refreshLiveStatus];
            }];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    JWConfigureCenteredPopover(sheet, self.view);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showMaxMemoryPicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"单网页内存安全上限"
                                                                   message:@"单个标签渲染进程超出此值时自动退回 30 档，防止异常网页耗尽 4GB 内存"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *m in @[@300, @450, @600, @800]) {
        NSString *title = [NSString stringWithFormat:@"%ld MB%@", (long)m.integerValue, (m.integerValue == 450 ? @"（推荐）" : @"")];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.config.maxMemoryMB = m.integerValue;
            [self.config saveConfig];
            [self.delegate manageDidRequestApplyProtectionNow:^(NSString *summary) {
                self.helperBannerText = summary;
                [self refreshLiveStatus];
            }];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    JWConfigureCenteredPopover(sheet, self.view);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmClearAllWebsiteData {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理全部缓存与登录态？"
                                                                   message:@"将清除所有站点的 Cookie、LocalStorage 与离线缓存，需重新登录。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确认清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf.delegate manageDidClearWebsiteData];
        [weakSelf refreshLiveStatus];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Main Hub View Controller

@interface JWHubViewController : UIViewController <WKNavigationDelegate, WKUIDelegate, JWManageViewControllerDelegate>
@property (nonatomic, strong) JWAppConfig *config;
@property (nonatomic, strong) NSMutableDictionary<NSString *, WKWebView *> *webViews;
@property (nonatomic, strong) NSMutableDictionary<NSString *, JWErrorOverlayView *> *errorOverlays;
@property (nonatomic, strong) NSMutableSet<NSString *> *terminatedSiteIds;
@property (nonatomic, strong) NSDictionary<NSNumber *, JWProcStatus *> *lastProcStatuses;
@property (nonatomic, strong) dispatch_queue_t protectQueue;
@property (nonatomic, strong) dispatch_queue_t trustEvalQueue;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, assign) NSUInteger bgEpoch;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *sessionTrustedCerts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLCredential *> *sessionBasicAuth;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<JWPendingTrustItem *> *> *pendingTrustQueues;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<JWPendingBasicAuthItem *> *> *pendingBasicAuthQueues;
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *authPromptQueue;
@property (nonatomic, assign) BOOL isPresentingAuthAlert;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *lastRejectedAuthBySiteId;

@property (nonatomic, strong) UIView *webContainerView;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIView *emptyStateView;

@property (nonatomic, strong) UIVisualEffectView *dockBar;
@property (nonatomic, strong) UIScrollView *tabsScrollView;
@property (nonatomic, strong) UIStackView *tabsStackView;
@property (nonatomic, strong) NSLayoutConstraint *webBottomToDockConstraint;
@property (nonatomic, strong) NSLayoutConstraint *webBottomToViewConstraint;

@property (nonatomic, strong) UIVisualEffectView *floatingPill;
@property (nonatomic, strong) UILabel *floatingLabel;
@property (nonatomic, strong) NSLayoutConstraint *floatingTrailingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *floatingBottomConstraint;
@end

@implementation JWHubViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (NSString *sid in self.webViews.allKeys) {
        [self detachObserversForWebView:self.webViews[sid]];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.config = [JWAppConfig loadConfig];
    self.webViews = [NSMutableDictionary dictionary];
    self.errorOverlays = [NSMutableDictionary dictionary];
    self.terminatedSiteIds = [NSMutableSet set];
    self.lastProcStatuses = @{};
    self.protectQueue = dispatch_queue_create("com.lili.jetweb.protect", DISPATCH_QUEUE_SERIAL);
    self.trustEvalQueue = dispatch_queue_create("com.lili.jetweb.trust", DISPATCH_QUEUE_SERIAL);
    self.bgTask = UIBackgroundTaskInvalid;

    self.sessionTrustedCerts = [NSMutableDictionary dictionary];
    self.sessionBasicAuth = [NSMutableDictionary dictionary];
    self.pendingTrustQueues = [NSMutableDictionary dictionary];
    self.pendingBasicAuthQueues = [NSMutableDictionary dictionary];
    self.authPromptQueue = [NSMutableArray array];
    self.lastRejectedAuthBySiteId = [NSMutableDictionary dictionary];

    [self setupLayout];
    [self syncWebViewsWithConfig];
    [self applyAppearanceStyles];
    [self applyDockCollapsedStateAnimated:NO];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection &&
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self applyAppearanceStyles];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self clampFloatingPillPosition];
}

- (void)clampFloatingPillPosition {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    if (w <= 120.0 || h <= 160.0) return;
    CGFloat minTrailing = -(w - 100.0);
    CGFloat minBottom = -(h - 120.0);
    self.floatingTrailingConstraint.constant = MIN(-8.0, MAX(minTrailing, self.floatingTrailingConstraint.constant));
    self.floatingBottomConstraint.constant = MIN(-8.0, MAX(minBottom, self.floatingBottomConstraint.constant));
}

- (void)setupLayout {
    self.webContainerView = [UIView new];
    self.webContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webContainerView.backgroundColor = UIColor.systemBackgroundColor;
    [self.view addSubview:self.webContainerView];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progressTintColor = UIColor.systemBlueColor;
    self.progressView.hidden = YES;
    [self.view addSubview:self.progressView];

    /* 底部磨砂切换栏 */
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    self.dockBar = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.dockBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.dockBar];

    UIView *topLine = [UIView new];
    topLine.translatesAutoresizingMaskIntoConstraints = NO;
    topLine.backgroundColor = UIColor.separatorColor;
    [self.dockBar.contentView addSubview:topLine];

    UIView *barRow = [UIView new];
    barRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dockBar.contentView addSubview:barRow];

    self.tabsScrollView = [UIScrollView new];
    self.tabsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabsScrollView.showsHorizontalScrollIndicator = NO;
    self.tabsScrollView.showsVerticalScrollIndicator = NO;
    self.tabsScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [barRow addSubview:self.tabsScrollView];

    self.tabsStackView = [UIStackView new];
    self.tabsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.tabsStackView.spacing = 8;
    self.tabsStackView.alignment = UIStackViewAlignmentCenter;
    [self.tabsScrollView addSubview:self.tabsStackView];

    UIButton *reloadBtn = [self makeIconButtonWithSymbol:@"arrow.clockwise" action:@selector(reloadCurrentSite)];
    UIButton *settingsBtn = [self makeIconButtonWithSymbol:@"slider.horizontal.3" action:@selector(openManageSheet)];
    UIButton *collapseBtn = [self makeIconButtonWithSymbol:@"arrow.down.right.and.arrow.up.left" action:@selector(collapseDockTapped)];

    UIStackView *rightTools = [[UIStackView alloc] initWithArrangedSubviews:@[reloadBtn, settingsBtn, collapseBtn]];
    rightTools.translatesAutoresizingMaskIntoConstraints = NO;
    rightTools.axis = UILayoutConstraintAxisHorizontal;
    rightTools.spacing = 2;
    rightTools.alignment = UIStackViewAlignmentCenter;
    [barRow addSubview:rightTools];

    self.webBottomToDockConstraint = [self.webContainerView.bottomAnchor constraintEqualToAnchor:self.dockBar.topAnchor];
    self.webBottomToViewConstraint = [self.webContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [self.webContainerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.webContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.webBottomToDockConstraint,

        [self.progressView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.progressView.heightAnchor constraintEqualToConstant:2.0],

        [self.dockBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.dockBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.dockBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [topLine.topAnchor constraintEqualToAnchor:self.dockBar.contentView.topAnchor],
        [topLine.leadingAnchor constraintEqualToAnchor:self.dockBar.contentView.leadingAnchor],
        [topLine.trailingAnchor constraintEqualToAnchor:self.dockBar.contentView.trailingAnchor],
        [topLine.heightAnchor constraintEqualToConstant:0.5],

        [barRow.topAnchor constraintEqualToAnchor:self.dockBar.contentView.topAnchor],
        [barRow.leadingAnchor constraintEqualToAnchor:self.dockBar.contentView.leadingAnchor constant:10],
        [barRow.trailingAnchor constraintEqualToAnchor:self.dockBar.contentView.trailingAnchor constant:-8],
        [barRow.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [barRow.heightAnchor constraintEqualToConstant:44],

        [rightTools.trailingAnchor constraintEqualToAnchor:barRow.trailingAnchor],
        [rightTools.centerYAnchor constraintEqualToAnchor:barRow.centerYAnchor],

        [self.tabsScrollView.leadingAnchor constraintEqualToAnchor:barRow.leadingAnchor],
        [self.tabsScrollView.trailingAnchor constraintEqualToAnchor:rightTools.leadingAnchor constant:-6],
        [self.tabsScrollView.topAnchor constraintEqualToAnchor:barRow.topAnchor],
        [self.tabsScrollView.bottomAnchor constraintEqualToAnchor:barRow.bottomAnchor],

        [self.tabsStackView.leadingAnchor constraintEqualToAnchor:self.tabsScrollView.contentLayoutGuide.leadingAnchor],
        [self.tabsStackView.trailingAnchor constraintEqualToAnchor:self.tabsScrollView.contentLayoutGuide.trailingAnchor],
        [self.tabsStackView.topAnchor constraintEqualToAnchor:self.tabsScrollView.contentLayoutGuide.topAnchor],
        [self.tabsStackView.bottomAnchor constraintEqualToAnchor:self.tabsScrollView.contentLayoutGuide.bottomAnchor],
        [self.tabsStackView.heightAnchor constraintEqualToAnchor:self.tabsScrollView.frameLayoutGuide.heightAnchor]
    ]];

    /* 空状态引导页 */
    self.emptyStateView = [UIView new];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.webContainerView addSubview:self.emptyStateView];

    UILabel *emptyTitle = [UILabel new];
    emptyTitle.translatesAutoresizingMaskIntoConstraints = NO;
    emptyTitle.text = @"JetWeb 多合一常驻容器";
    emptyTitle.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    emptyTitle.textAlignment = NSTextAlignmentCenter;
    [self.emptyStateView addSubview:emptyTitle];

    UILabel *emptySub = [UILabel new];
    emptySub.translatesAutoresizingMaskIntoConstraints = NO;
    emptySub.text = @"把常用的 3～4 个桌面 WebApp 放进同一个容器：\n秒切不白屏、独立持久登录态、后台自动提档保活";
    emptySub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    emptySub.textColor = UIColor.secondaryLabelColor;
    emptySub.numberOfLines = 0;
    emptySub.textAlignment = NSTextAlignmentCenter;
    [self.emptyStateView addSubview:emptySub];

    UIButton *addFirstBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addFirstBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *btnCfg = [UIButtonConfiguration filledButtonConfiguration];
    btnCfg.title = @"添加第一个常驻 WebApp";
    btnCfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    btnCfg.contentInsets = NSDirectionalEdgeInsetsMake(11, 22, 11, 22);
    addFirstBtn.configuration = btnCfg;
    [addFirstBtn addTarget:self action:@selector(openManageSheet) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:addFirstBtn];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.webContainerView.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.webContainerView.centerYAnchor],
        [self.emptyStateView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.webContainerView.leadingAnchor constant:28],
        [self.emptyStateView.trailingAnchor constraintLessThanOrEqualToAnchor:self.webContainerView.trailingAnchor constant:-28],

        [emptyTitle.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [emptyTitle.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [emptyTitle.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],

        [emptySub.topAnchor constraintEqualToAnchor:emptyTitle.bottomAnchor constant:10],
        [emptySub.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [emptySub.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],

        [addFirstBtn.topAnchor constraintEqualToAnchor:emptySub.bottomAnchor constant:20],
        [addFirstBtn.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [addFirstBtn.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor]
    ]];

    /* 全屏沉浸悬浮胶囊（点击展开底栏，长按快捷切站，可拖动防遮挡） */
    self.floatingPill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    self.floatingPill.translatesAutoresizingMaskIntoConstraints = NO;
    self.floatingPill.layer.cornerRadius = 17;
    self.floatingPill.layer.cornerCurve = kCACornerCurveContinuous;
    self.floatingPill.clipsToBounds = YES;
    self.floatingPill.layer.borderWidth = 0.5;
    self.floatingPill.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
    self.floatingPill.hidden = YES;
    [self.view addSubview:self.floatingPill];

    self.floatingLabel = [UILabel new];
    self.floatingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.floatingLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.floatingLabel.textColor = UIColor.labelColor;
    self.floatingLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.floatingLabel.text = @"◉ 展开";
    [self.floatingPill.contentView addSubview:self.floatingLabel];

    self.floatingTrailingConstraint = [self.floatingPill.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14];
    self.floatingBottomConstraint = [self.floatingPill.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-18];

    [NSLayoutConstraint activateConstraints:@[
        self.floatingTrailingConstraint,
        self.floatingBottomConstraint,
        [self.floatingPill.heightAnchor constraintEqualToConstant:34],
        [self.floatingPill.widthAnchor constraintLessThanOrEqualToConstant:180],
        [self.floatingLabel.leadingAnchor constraintEqualToAnchor:self.floatingPill.contentView.leadingAnchor constant:12],
        [self.floatingLabel.trailingAnchor constraintEqualToAnchor:self.floatingPill.contentView.trailingAnchor constant:-12],
        [self.floatingLabel.centerYAnchor constraintEqualToAnchor:self.floatingPill.contentView.centerYAnchor]
    ]];

    UITapGestureRecognizer *pillTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(expandDockTapped)];
    [self.floatingPill addGestureRecognizer:pillTap];
    UILongPressGestureRecognizer *pillLong = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(floatingPillLongPressed:)];
    [self.floatingPill addGestureRecognizer:pillLong];
    UIPanGestureRecognizer *pillPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(floatingPillPanned:)];
    [self.floatingPill addGestureRecognizer:pillPan];
}

- (UIButton *)makeIconButtonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIFontWeightSemibold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:symCfg] forState:UIControlStateNormal];
    b.tintColor = UIColor.labelColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:34],
        [b.heightAnchor constraintEqualToConstant:34]
    ]];
    return b;
}

#pragma mark - Appearance Management

- (UIUserInterfaceStyle)currentSystemInterfaceStyle {
    if (self.view.window) {
        return self.view.window.traitCollection.userInterfaceStyle;
    }
    return UIUserInterfaceStyleUnspecified;
}

- (void)applyAppearanceStyleToWebView:(WKWebView *)wv forSite:(JWSiteItem *)site {
    if (!wv) return;
    NSString *globalMode = JWNormalizeGlobalAppearanceMode(self.config.appearanceMode);
    NSString *effectiveMode = [self.config effectiveAppearanceModeForSite:site];
    UIUserInterfaceStyle targetStyle = UIUserInterfaceStyleUnspecified;
    if ([effectiveMode isEqualToString:kJWAppearanceLight]) {
        targetStyle = UIUserInterfaceStyleLight;
    } else if ([effectiveMode isEqualToString:kJWAppearanceDark]) {
        targetStyle = UIUserInterfaceStyleDark;
    } else {
        /* 站点显式设为「跟随系统」而全局为强制浅/深色时，从 window 获取真实系统外观防止被父 VC 覆盖 */
        targetStyle = [globalMode isEqualToString:kJWAppearanceSystem]
            ? UIUserInterfaceStyleUnspecified
            : [self currentSystemInterfaceStyle];
    }
    wv.overrideUserInterfaceStyle = targetStyle;
    wv.backgroundColor = UIColor.systemBackgroundColor;
    wv.scrollView.backgroundColor = UIColor.systemBackgroundColor;
    [wv evaluateJavaScript:@"if(window.__jwRecheckInputs)window.__jwRecheckInputs();"
                   inFrame:nil
            inContentWorld:[WKContentWorld defaultClientWorld]
         completionHandler:nil];
}

- (void)applyAppearanceStyles {
    NSString *globalMode = JWNormalizeGlobalAppearanceMode(self.config.appearanceMode);
    self.overrideUserInterfaceStyle = JWUIUserInterfaceStyleForMode(globalMode, UIUserInterfaceStyleUnspecified);
    for (JWSiteItem *s in [self enabledSites]) {
        WKWebView *wv = self.webViews[s.siteId];
        if (wv) {
            [self applyAppearanceStyleToWebView:wv forSite:s];
        }
    }
}

#pragma mark - WebView Management & Instant Tab Switching

- (WKWebView *)createWebViewForSite:(JWSiteItem *)site {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    cfg.defaultWebpagePreferences.allowsContentJavaScript = YES;
    [cfg.userContentController addUserScript:JWWebKitCompatPolyfillScript()];
    [cfg.userContentController addUserScript:JWInputContrastFixScript()];

    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.webContainerView.bounds configuration:cfg];
    wv.translatesAutoresizingMaskIntoConstraints = NO;
    wv.navigationDelegate = self;
    wv.UIDelegate = self;
    wv.allowsBackForwardNavigationGestures = YES;
    wv.customUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1";

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(handlePullToRefresh:) forControlEvents:UIControlEventValueChanged];
    wv.scrollView.refreshControl = rc;

    [wv addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionNew context:NULL];

    [self.webContainerView insertSubview:wv belowSubview:self.emptyStateView];
    [NSLayoutConstraint activateConstraints:@[
        [wv.topAnchor constraintEqualToAnchor:self.webContainerView.topAnchor],
        [wv.leadingAnchor constraintEqualToAnchor:self.webContainerView.leadingAnchor],
        [wv.trailingAnchor constraintEqualToAnchor:self.webContainerView.trailingAnchor],
        [wv.bottomAnchor constraintEqualToAnchor:self.webContainerView.bottomAnchor]
    ]];

    JWErrorOverlayView *overlay = [[JWErrorOverlayView alloc] initWithFrame:CGRectZero];
    NSString *capturedSiteId = [site.siteId copy];
    __weak typeof(self) weakSelf = self;
    overlay.onRetry = ^{
        [weakSelf reloadOrLoadInitialURLForSiteId:capturedSiteId];
    };
    overlay.onGoHome = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        JWSiteItem *s = [self siteForId:capturedSiteId];
        WKWebView *target = self.webViews[capturedSiteId];
        NSURL *home = s ? [NSURL URLWithString:s.urlString ?: @""] : nil;
        if (target && home) {
            [self hideErrorOverlayForSiteId:capturedSiteId];
            [target loadRequest:[NSURLRequest requestWithURL:home]];
        }
    };
    [wv addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.topAnchor constraintEqualToAnchor:wv.topAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:wv.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:wv.trailingAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:wv.bottomAnchor]
    ]];
    self.errorOverlays[site.siteId] = overlay;

    [self applyAppearanceStyleToWebView:wv forSite:site];

    NSURL *url = [NSURL URLWithString:site.urlString];
    if (url) {
        [wv loadRequest:[NSURLRequest requestWithURL:url]];
    }
    return wv;
}

- (void)detachObserversForWebView:(WKWebView *)wv {
    if (!wv) return;
    @try {
        [wv removeObserver:self forKeyPath:@"estimatedProgress"];
    } @catch (__unused NSException *ex) {}
    wv.navigationDelegate = nil;
    wv.UIDelegate = nil;
}

- (NSArray<JWSiteItem *> *)enabledSites {
    NSMutableArray<JWSiteItem *> *arr = [NSMutableArray array];
    for (JWSiteItem *s in self.config.sites) {
        if (s.enabled) [arr addObject:s];
    }
    return arr;
}

- (NSString *)siteIdForWebView:(WKWebView *)webView {
    if (!webView) return nil;
    for (NSString *sid in self.webViews) {
        if (self.webViews[sid] == webView) return sid;
    }
    return nil;
}

- (void)hideErrorOverlayForSiteId:(NSString *)siteId {
    if (siteId.length == 0) return;
    JWErrorOverlayView *overlay = self.errorOverlays[siteId];
    if (overlay) {
        overlay.hidden = YES;
    }
    [self.lastRejectedAuthBySiteId removeObjectForKey:siteId];
}

- (void)showErrorOverlayForWebView:(WKWebView *)webView error:(NSError *)error customTitle:(NSString *)customTitle customDetail:(NSString *)customDetail {
    NSString *sid = [self siteIdForWebView:webView];
    if (sid.length == 0) return;
    JWErrorOverlayView *overlay = self.errorOverlays[sid];
    if (!overlay) return;
    JWSiteItem *site = [self siteForId:sid];
    NSString *failedURL = nil;
    if ([error.userInfo[NSURLErrorFailingURLStringErrorKey] isKindOfClass:[NSString class]]) {
        failedURL = error.userInfo[NSURLErrorFailingURLStringErrorKey];
    } else if ([error.userInfo[NSURLErrorFailingURLErrorKey] isKindOfClass:[NSURL class]]) {
        failedURL = ((NSURL *)error.userInfo[NSURLErrorFailingURLErrorKey]).absoluteString;
    }
    if (failedURL.length == 0) {
        failedURL = webView.URL.absoluteString;
    }
    if (failedURL.length == 0 || [failedURL isEqualToString:@"about:blank"]) {
        failedURL = site.urlString ?: @"";
    }
    [overlay configureWithError:error
                      failedURL:failedURL
                        homeURL:(site.urlString ?: @"")
                    customTitle:customTitle
                   customDetail:customDetail];
    overlay.hidden = NO;
    [webView bringSubviewToFront:overlay];
}

- (void)syncWebViewsWithConfig {
    NSMutableSet<NSString *> *validIds = [NSMutableSet set];
    NSArray<JWSiteItem *> *enabled = [self enabledSites];
    for (JWSiteItem *s in enabled) {
        [validIds addObject:s.siteId];
        if (!self.webViews[s.siteId]) {
            self.webViews[s.siteId] = [self createWebViewForSite:s];
        }
    }

    for (NSString *existingId in [self.webViews.allKeys copy]) {
        if (![validIds containsObject:existingId]) {
            WKWebView *old = self.webViews[existingId];
            [self detachObserversForWebView:old];
            [old removeFromSuperview];
            [self.webViews removeObjectForKey:existingId];
            [self.errorOverlays removeObjectForKey:existingId];
            [self.terminatedSiteIds removeObject:existingId];
            [self.lastRejectedAuthBySiteId removeObjectForKey:existingId];
        }
    }

    if (enabled.count == 0) {
        self.config.selectedSiteId = @"";
        self.emptyStateView.hidden = NO;
        self.progressView.hidden = YES;
    } else {
        self.emptyStateView.hidden = YES;
        BOOL hasSelected = NO;
        for (JWSiteItem *s in enabled) {
            if ([s.siteId isEqualToString:self.config.selectedSiteId]) {
                hasSelected = YES;
                break;
            }
        }
        if (!hasSelected) {
            self.config.selectedSiteId = enabled.firstObject.siteId;
            [self.config saveConfig];
        }
        [self selectSiteById:self.config.selectedSiteId];
    }
    [self applyAppearanceStyles];
    [self rebuildTabPills];
    [self scheduleApplyProtectionAsync:nil];
}

- (void)reloadOrLoadInitialURLForSiteId:(NSString *)siteId {
    if (siteId.length == 0) return;
    WKWebView *wv = self.webViews[siteId];
    if (!wv) return;
    JWErrorOverlayView *overlay = self.errorOverlays[siteId];
    NSString *failedURL = overlay ? [overlay.failedURLString copy] : nil;
    [self hideErrorOverlayForSiteId:siteId];

    if (wv.URL && wv.URL.absoluteString.length > 0 && ![wv.URL.absoluteString isEqualToString:@"about:blank"]) {
        [wv reload];
    } else if (failedURL.length > 0) {
        NSURL *fu = [NSURL URLWithString:failedURL];
        if (fu) [wv loadRequest:[NSURLRequest requestWithURL:fu]];
    } else {
        JWSiteItem *site = [self siteForId:siteId];
        NSURL *u = site ? [NSURL URLWithString:site.urlString] : nil;
        if (u) [wv loadRequest:[NSURLRequest requestWithURL:u]];
    }
}

- (void)recoverWebViewIfTerminatedForSiteId:(NSString *)siteId {
    if (siteId.length == 0 || ![self.terminatedSiteIds containsObject:siteId]) return;
    [self.terminatedSiteIds removeObject:siteId];
    [self reloadOrLoadInitialURLForSiteId:siteId];
}

- (void)syncProgressBarForWebView:(WKWebView *)wv {
    if (!wv) {
        self.progressView.hidden = YES;
        return;
    }
    float p = (float)wv.estimatedProgress;
    self.progressView.hidden = (!wv.isLoading || p >= 1.0f || p <= 0.01f);
    [self.progressView setProgress:p animated:NO];
}

- (void)selectSiteById:(NSString *)siteId {
    if (siteId.length == 0) return;
    WKWebView *targetWV = self.webViews[siteId];
    if (!targetWV) return;

    self.config.selectedSiteId = siteId;
    [self.config saveConfig];

    for (NSString *sid in self.webViews) {
        WKWebView *wv = self.webViews[sid];
        BOOL isSel = [sid isEqualToString:siteId];
        wv.hidden = !isSel;
        wv.userInteractionEnabled = isSel;
    }
    [self.webContainerView bringSubviewToFront:targetWV];
    [self syncProgressBarForWebView:targetWV];
    [self recoverWebViewIfTerminatedForSiteId:siteId];

    JWSiteItem *curSite = [self siteForId:siteId];
    self.floatingLabel.text = [NSString stringWithFormat:@"◉ %@", curSite.title ?: @"展开"];
    [self rebuildTabPills];
    [self scheduleApplyProtectionAsync:nil];
}

- (JWSiteItem *)siteForId:(NSString *)siteId {
    for (JWSiteItem *s in self.config.sites) {
        if ([s.siteId isEqualToString:siteId]) return s;
    }
    return nil;
}

- (void)rebuildTabPills {
    for (UIView *v in [self.tabsStackView.arrangedSubviews copy]) {
        [self.tabsStackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSArray<JWSiteItem *> *enabled = [self enabledSites];
    if (enabled.count == 0) {
        JWSitePillControl *addPill = [[JWSitePillControl alloc] initWithFrame:CGRectZero];
        [addPill configureWithTitle:@"+ 添加站点" active:YES aliveState:@"OK"];
        [addPill addTarget:self action:@selector(openManageSheet) forControlEvents:UIControlEventTouchUpInside];
        [self.tabsStackView addArrangedSubview:addPill];
        return;
    }

    for (JWSiteItem *s in enabled) {
        JWSitePillControl *pill = [[JWSitePillControl alloc] initWithFrame:CGRectZero];
        pill.siteId = s.siteId;
        pid_t wpid = JWWebViewContentPID(self.webViews[s.siteId]);
        JWProcStatus *st = (wpid > 0) ? self.lastProcStatuses[@(wpid)] : nil;
        NSString *badge = st ? [st displayBadgeForWebContentWithTargetBand:self.config.targetBand maxMB:self.config.maxMemoryMB] : @"";
        BOOL active = [s.siteId isEqualToString:self.config.selectedSiteId];
        [pill configureWithTitle:s.title active:active aliveState:badge];
        [pill addTarget:self action:@selector(tabPillTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.tabsStackView addArrangedSubview:pill];
    }
}

- (void)tabPillTapped:(JWSitePillControl *)sender {
    if ([sender.siteId isEqualToString:self.config.selectedSiteId]) {
        [self showCurrentSiteQuickMenuFromSource:sender];
        return;
    }
    [self selectSiteById:sender.siteId];
}

- (void)showQuickAppearancePickerForSite:(JWSiteItem *)site sourceView:(UIView *)sourceView {
    if (!site) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ · 外观模式", site.title]
                                                                   message:@"遇到深色模式下输入框白底白字时，可切换为「强制浅色」立即生效。"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSString *> *modes = @[kJWAppearanceInherit, kJWAppearanceSystem, kJWAppearanceLight, kJWAppearanceDark];
    NSString *cur = JWNormalizeSiteAppearanceMode(site.appearanceMode);
    __weak typeof(self) weakSelf = self;
    for (NSString *m in modes) {
        NSString *prefix = [m isEqualToString:cur] ? @"✓ " : @"";
        NSString *title = [prefix stringByAppendingString:JWAppearanceModeLabel(m)];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            site.appearanceMode = m;
            [self.config saveConfig];
            [self applyAppearanceStyles];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sourceView) {
        sheet.popoverPresentationController.sourceView = sourceView;
        sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    } else {
        JWConfigureCenteredPopover(sheet, self.view);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showCurrentSiteQuickMenuFromSource:(UIView *)sourceView {
    WKWebView *wv = self.webViews[self.config.selectedSiteId];
    if (!wv) return;
    JWSiteItem *site = [self siteForId:self.config.selectedSiteId];
    NSString *siteId = site.siteId;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:(site.title ?: @"当前站点")
                                                                   message:(wv.URL.absoluteString ?: site.urlString)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if (wv.canGoBack) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"后退" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [wv goBack];
        }]];
    }
    if (wv.canGoForward) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"前进" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [wv goForward];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"刷新当前页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf reloadOrLoadInitialURLForSiteId:siteId];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"回到初始首页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSURL *u = [NSURL URLWithString:site.urlString ?: @""];
        if (u) {
            [weakSelf hideErrorOverlayForSiteId:siteId];
            [wv loadRequest:[NSURLRequest requestWithURL:u]];
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"外观模式：%@", JWAppearanceModeLabel(site.appearanceMode)]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf showQuickAppearancePickerForSite:site sourceView:sourceView];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制当前网址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = wv.URL.absoluteString ?: site.urlString ?: @"";
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sourceView) {
        sheet.popoverPresentationController.sourceView = sourceView;
        sheet.popoverPresentationController.sourceRect = sourceView.bounds;
    } else {
        JWConfigureCenteredPopover(sheet, self.view);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Dock Collapse / Fullscreen Mode

- (void)collapseDockTapped {
    self.config.dockCollapsed = YES;
    [self.config saveConfig];
    [self applyDockCollapsedStateAnimated:YES];
}

- (void)expandDockTapped {
    self.config.dockCollapsed = NO;
    [self.config saveConfig];
    [self applyDockCollapsedStateAnimated:YES];
}

- (void)applyDockCollapsedStateAnimated:(BOOL)animated {
    BOOL collapsed = self.config.dockCollapsed && ([self enabledSites].count > 0);
    /* 先停用互斥约束再激活新约束，杜绝同时激活两个 bottom 约束产生冲突 */
    if (collapsed) {
        self.webBottomToDockConstraint.active = NO;
        self.webBottomToViewConstraint.active = YES;
    } else {
        self.webBottomToViewConstraint.active = NO;
        self.webBottomToDockConstraint.active = YES;
    }
    self.dockBar.hidden = collapsed;
    self.floatingPill.hidden = !collapsed;
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            [self.view layoutIfNeeded];
        }];
    }
}

- (void)floatingPillLongPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    NSArray<JWSiteItem *> *enabled = [self enabledSites];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"快速切换常驻 WebApp"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (JWSiteItem *s in enabled) {
        NSString *prefix = [s.siteId isEqualToString:self.config.selectedSiteId] ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[prefix stringByAppendingString:s.title]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [weakSelf selectSiteById:s.siteId];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"工作台设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf openManageSheet];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.floatingPill;
    sheet.popoverPresentationController.sourceRect = self.floatingPill.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)floatingPillPanned:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self.view];
    [pan setTranslation:CGPointZero inView:self.view];
    self.floatingTrailingConstraint.constant += delta.x;
    self.floatingBottomConstraint.constant += delta.y;
    [self clampFloatingPillPosition];
}

- (void)reloadCurrentSite {
    [self reloadOrLoadInitialURLForSiteId:self.config.selectedSiteId];
}

- (void)handlePullToRefresh:(UIRefreshControl *)rc {
    for (NSString *sid in self.webViews) {
        WKWebView *wv = self.webViews[sid];
        if (wv.scrollView.refreshControl == rc) {
            [self reloadOrLoadInitialURLForSiteId:sid];
            break;
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [rc endRefreshing];
    });
}

- (void)openManageSheet {
    JWManageViewController *vc = [[JWManageViewController alloc] initWithConfig:self.config delegate:self];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = JWUIUserInterfaceStyleForMode(JWNormalizeGlobalAppearanceMode(self.config.appearanceMode), UIUserInterfaceStyleUnspecified);
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Jetsam Protection Engine

- (NSArray<NSString *> *)collectTargetPIDStringsOnMainThreadWithSnapshot:(NSString **)snapshotOut {
    NSMutableOrderedSet<NSNumber *> *pids = [NSMutableOrderedSet orderedSet];
    [pids addObject:@(getpid())];

    NSMutableString *sharedText = [NSMutableString stringWithFormat:@"host_pid=%d band=%ld max_mb=%ld\n",
                                   (int)getpid(), (long)self.config.targetBand, (long)self.config.maxMemoryMB];

    for (JWSiteItem *s in [self enabledSites]) {
        WKWebView *wv = self.webViews[s.siteId];
        pid_t wpid = JWWebViewContentPID(wv);
        if (wpid > 0) {
            [pids addObject:@(wpid)];
            [sharedText appendFormat:@"webcontent_pid=%d site=%@\n", (int)wpid, s.siteId];
        }
        pid_t npid = JWWebViewNetworkingPID(wv);
        if (npid > 0) {
            [pids addObject:@(npid)];
        }
        pid_t gpid = JWWebViewGPUPID(wv);
        if (gpid > 0) {
            [pids addObject:@(gpid)];
        }
    }

    if (snapshotOut) *snapshotOut = [sharedText copy];

    NSMutableArray<NSString *> *res = [NSMutableArray arrayWithCapacity:pids.count];
    for (NSNumber *n in pids) {
        [res addObject:[NSString stringWithFormat:@"%d", n.intValue]];
    }
    return res;
}

static void JWWriteSharedSnapshotOnBgQueue(NSString *sharedText) {
    if (sharedText.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kJWPilotDir]) {
        [sharedText writeToFile:kJWSharedPidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (void)scheduleApplyProtectionAsync:(void (^)(NSString *summary))completion {
    NSString *sharedSnapshot = nil;
    NSArray<NSString *> *pidArgs = [self collectTargetPIDStringsOnMainThreadWithSnapshot:&sharedSnapshot];
    NSInteger band = self.config.targetBand;
    NSInteger maxMB = self.config.maxMemoryMB;

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.protectQueue, ^{
        JWWriteSharedSnapshotOnBgQueue(sharedSnapshot);

        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
                                            @"--apply",
                                            [NSString stringWithFormat:@"%ld", (long)band],
                                            [NSString stringWithFormat:@"%ld", (long)maxMB],
                                            nil];
        [args addObjectsFromArray:pidArgs];

        int exitCode = -1;
        NSString *out = JWRunJetWebCtl(args, &exitCode);
        NSDictionary<NSNumber *, JWProcStatus *> *parsed = JWParseHelperOutput(out);

        NSString *summary = nil;
        if (exitCode == 0) {
            summary = [NSString stringWithFormat:@"✓ 已同步保活档位（目标 %ld 档 · 单页上限 %ld MB）", (long)band, (long)maxMB];
        } else {
            summary = [NSString stringWithFormat:@"提档助手返回码 %d（请确认通过 TrollStore 安装）", exitCode];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (parsed.count > 0) {
                self.lastProcStatuses = parsed;
                [self rebuildTabPills];
            }
            if (completion) completion(summary);
        });
    });
}

- (void)appDidEnterBackground {
    [self endBackgroundGuardTask];
    UIApplication *app = [UIApplication sharedApplication];
    __weak typeof(self) weakSelf = self;
    self.bgEpoch++;
    NSUInteger epoch = self.bgEpoch;

    self.bgTask = [app beginBackgroundTaskWithName:@"com.lili.jetweb.jetsamguard" expirationHandler:^{
        [weakSelf endBackgroundGuardTask];
    }];

    /* 覆盖 WebKit 与 RunningBoard 退后台后的数次降档时间点，随后立即结束任务实现零持续后台耗电 */
    NSArray<NSNumber *> *delays = @[@0.8, @3.0, @8.0, @18.0];
    for (NSUInteger i = 0; i < delays.count; i++) {
        double sec = delays[i].doubleValue;
        BOOL isLast = (i + 1 == delays.count);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self.bgEpoch != epoch) return;
            [self scheduleApplyProtectionAsync:^(NSString *summary) {
                if (isLast && self.bgEpoch == epoch) {
                    [self endBackgroundGuardTask];
                }
            }];
        });
    }
}

- (void)appWillEnterForeground {
    self.bgEpoch++;
    [self endBackgroundGuardTask];
    [self applyAppearanceStyles];
    [self recoverWebViewIfTerminatedForSiteId:self.config.selectedSiteId];
    [self scheduleApplyProtectionAsync:nil];
}

- (void)endBackgroundGuardTask {
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

#pragma mark - Auth Challenge Prompt Queue (ServerTrust & HTTP Basic Auth)

- (UIViewController *)topMostPresenterForAuthAlert {
    UIViewController *top = self;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

- (void)presentAuthAlertSafely:(UIAlertController *)alert
                     retryLeft:(NSInteger)retryLeft
                      onCancel:(void (^)(void))onCancel {
    if (self.view.window == nil) {
        if (retryLeft > 0) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf presentAuthAlertSafely:alert retryLeft:(retryLeft - 1) onCancel:onCancel];
            });
        } else {
            if (onCancel) onCancel();
            self.isPresentingAuthAlert = NO;
            [self drainAuthPromptQueue];
        }
        return;
    }

    UIViewController *top = [self topMostPresenterForAuthAlert];
    BOOL busy = [top isKindOfClass:[UIAlertController class]] ||
                top.isBeingDismissed ||
                top.isBeingPresented ||
                (top.transitionCoordinator != nil);
    if (busy) {
        if (retryLeft > 0) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf presentAuthAlertSafely:alert retryLeft:(retryLeft - 1) onCancel:onCancel];
            });
        } else {
            if (onCancel) onCancel();
            self.isPresentingAuthAlert = NO;
            [self drainAuthPromptQueue];
        }
        return;
    }

    [top presentViewController:alert animated:YES completion:nil];
}

- (void)enqueueAuthPrompt:(void (^)(void))promptBlock {
    if (!promptBlock) return;
    [self.authPromptQueue addObject:[promptBlock copy]];
    [self drainAuthPromptQueue];
}

- (void)drainAuthPromptQueue {
    if (self.isPresentingAuthAlert || self.authPromptQueue.count == 0) return;
    void (^next)(void) = self.authPromptQueue.firstObject;
    [self.authPromptQueue removeObjectAtIndex:0];
    self.isPresentingAuthAlert = YES;
    next();
}

- (void)resolvePendingTrustForKey:(NSString *)trustKey accept:(BOOL)accept rejectedHost:(NSString *)rejectedHost {
    NSArray<JWPendingTrustItem *> *items = [self.pendingTrustQueues[trustKey] copy];
    [self.pendingTrustQueues removeObjectForKey:trustKey];
    for (JWPendingTrustItem *item in items) {
        if (!accept && item.webView) {
            NSString *sid = [self siteIdForWebView:item.webView];
            if (sid.length > 0) {
                self.lastRejectedAuthBySiteId[sid] = @{
                    @"title": @"已拒绝不受信任的证书",
                    @"detail": [NSString stringWithFormat:@"你已取消对 %@ 自签名/不受信任证书的连接。\n\n若确认该站点可信，请点击「重新加载」并在弹窗中选择信任。", rejectedHost ?: @""]
                };
            }
        }
        [item resolveAccept:accept];
    }
}

- (void)resolvePendingBasicAuthForKey:(NSString *)realmKey credential:(NSURLCredential *)credential rejectedHost:(NSString *)rejectedHost {
    NSArray<JWPendingBasicAuthItem *> *items = [self.pendingBasicAuthQueues[realmKey] copy];
    [self.pendingBasicAuthQueues removeObjectForKey:realmKey];
    for (JWPendingBasicAuthItem *item in items) {
        if (!credential && item.webView) {
            NSString *sid = [self siteIdForWebView:item.webView];
            if (sid.length > 0) {
                self.lastRejectedAuthBySiteId[sid] = @{
                    @"title": @"需要身份验证",
                    @"detail": [NSString stringWithFormat:@"访问 %@ 需要 HTTP 账号密码验证。\n\n请点击「重新加载」重新输入凭据。", rejectedHost ?: @""]
                };
            }
        }
        [item resolveWithCredential:credential];
    }
}

- (void)handleServerTrustChallenge:(NSURLAuthenticationChallenge *)challenge
                           webView:(WKWebView *)webView
                             guard:(JWAuthChallengeCompletionGuard *)guard {
    SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
    if (!serverTrust) {
        [guard invokeWithDisposition:NSURLSessionAuthChallengePerformDefaultHandling credential:nil];
        return;
    }

    NSString *host = challenge.protectionSpace.host.lowercaseString ?: @"";
    NSInteger port = challenge.protectionSpace.port;
    CFRetain(serverTrust);

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.trustEvalQueue, ^{
        CFErrorRef evalErr = NULL;
        BOOL systemTrusted = SecTrustEvaluateWithError(serverTrust, &evalErr);
        NSString *evalReason = @"";
        if (evalErr) {
            CFStringRef desc = CFErrorCopyDescription(evalErr);
            if (desc) {
                evalReason = (__bridge_transfer NSString *)desc;
            }
            CFRelease(evalErr);
        }

        if (systemTrusted) {
            CFRelease(serverTrust);
            dispatch_async(dispatch_get_main_queue(), ^{
                [guard invokeWithDisposition:NSURLSessionAuthChallengePerformDefaultHandling credential:nil];
            });
            return;
        }

        NSString *fingerprint = @"";
        NSString *subject = @"";
        JWExtractLeafCertInfo(serverTrust, &fingerprint, &subject);

        /* 封装到 JWPendingTrustItem 托管 SecTrustRef 生命周期，避免任何路径泄漏 */
        JWPendingTrustItem *pendingItem = [[JWPendingTrustItem alloc] initWithServerTrust:serverTrust guard:guard webView:webView];
        CFRelease(serverTrust);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                [pendingItem resolveAccept:NO];
                return;
            }

            /* 命中已持久化信任或本次会话信任（自动覆盖同域名 HTTPS 子资源与 wss:// WebSocket） */
            if (host.length > 0 && fingerprint.length > 0) {
                NSString *savedFp = self.config.trustedCerts[host];
                NSString *sessionFp = self.sessionTrustedCerts[host];
                if ([savedFp isEqualToString:fingerprint] || [sessionFp isEqualToString:fingerprint]) {
                    [pendingItem resolveAccept:YES];
                    return;
                }
            }

            NSString *trustKey = [NSString stringWithFormat:@"%@|%@", host, fingerprint];
            NSMutableArray<JWPendingTrustItem *> *bucket = self.pendingTrustQueues[trustKey];
            if (bucket) {
                [bucket addObject:pendingItem];
                return;
            }
            bucket = [NSMutableArray arrayWithObject:pendingItem];
            self.pendingTrustQueues[trustKey] = bucket;

            NSString *displayHost = (port > 0 && port != 443)
                ? [NSString stringWithFormat:@"%@:%ld", host, (long)port]
                : host;

            [self enqueueAuthPrompt:^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;

                /* 排队等待期间若用户已信任同域名证书，直接放行不再重复弹窗 */
                if (host.length > 0 && fingerprint.length > 0 &&
                    ([strongSelf.config.trustedCerts[host] isEqualToString:fingerprint] ||
                     [strongSelf.sessionTrustedCerts[host] isEqualToString:fingerprint])) {
                    [strongSelf resolvePendingTrustForKey:trustKey accept:YES rejectedHost:displayHost];
                    strongSelf.isPresentingAuthAlert = NO;
                    [strongSelf drainAuthPromptQueue];
                    return;
                }

                NSMutableString *msg = [NSMutableString stringWithFormat:@"域名：%@", displayHost.length > 0 ? displayHost : @"未知主机"];
                if (subject.length > 0) {
                    [msg appendFormat:@"\n证书主体：%@", subject];
                }
                if (fingerprint.length > 0) {
                    [msg appendFormat:@"\nSHA-256：%@", JWFormatShortFingerprint(fingerprint)];
                }
                if (evalReason.length > 0) {
                    [msg appendFormat:@"\n校验详情：%@", evalReason];
                }
                [msg appendString:@"\n\n仅在你确认这是自建内网或受控服务时信任此证书。"];

                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"证书不受系统信任"
                                                                               message:msg
                                                                        preferredStyle:UIAlertControllerStyleAlert];

                if (host.length > 0 && fingerprint.length > 0) {
                    [alert addAction:[UIAlertAction actionWithTitle:@"永久信任此域名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                        __strong typeof(weakSelf) s = weakSelf;
                        if (!s) return;
                        s.config.trustedCerts[host] = fingerprint;
                        [s.config saveConfig];
                        [s resolvePendingTrustForKey:trustKey accept:YES rejectedHost:displayHost];
                        s.isPresentingAuthAlert = NO;
                        [s drainAuthPromptQueue];
                    }]];
                }
                [alert addAction:[UIAlertAction actionWithTitle:@"仅本次信任" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    __strong typeof(weakSelf) s = weakSelf;
                    if (!s) return;
                    if (host.length > 0 && fingerprint.length > 0) {
                        s.sessionTrustedCerts[host] = fingerprint;
                    }
                    [s resolvePendingTrustForKey:trustKey accept:YES rejectedHost:displayHost];
                    s.isPresentingAuthAlert = NO;
                    [s drainAuthPromptQueue];
                }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"拒绝连接" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                    __strong typeof(weakSelf) s = weakSelf;
                    if (!s) return;
                    [s resolvePendingTrustForKey:trustKey accept:NO rejectedHost:displayHost];
                    s.isPresentingAuthAlert = NO;
                    [s drainAuthPromptQueue];
                }]];

                [strongSelf presentAuthAlertSafely:alert retryLeft:30 onCancel:^{
                    __strong typeof(weakSelf) s = weakSelf;
                    if (s) [s resolvePendingTrustForKey:trustKey accept:NO rejectedHost:displayHost];
                }];
            }];
        });
    });
}

- (void)handleBasicAuthChallenge:(NSURLAuthenticationChallenge *)challenge
                         webView:(WKWebView *)webView
                           guard:(JWAuthChallengeCompletionGuard *)guard {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    NSString *host = space.host.lowercaseString ?: @"";
    NSInteger port = space.port;
    NSString *realm = space.realm ?: @"";
    NSString *realmKey = [NSString stringWithFormat:@"%@:%ld:%@", host, (long)port, realm];
    NSString *displayHost = (port > 0 && port != 443 && port != 80)
        ? [NSString stringWithFormat:@"%@:%ld", host, (long)port]
        : host;

    if (challenge.previousFailureCount == 0) {
        NSURLCredential *cached = self.sessionBasicAuth[realmKey];
        if (cached) {
            [guard invokeWithDisposition:NSURLSessionAuthChallengeUseCredential credential:cached];
            return;
        }
    } else {
        [self.sessionBasicAuth removeObjectForKey:realmKey];
    }

    JWPendingBasicAuthItem *pendingItem = [[JWPendingBasicAuthItem alloc] initWithGuard:guard webView:webView];
    NSMutableArray<JWPendingBasicAuthItem *> *bucket = self.pendingBasicAuthQueues[realmKey];
    if (bucket) {
        [bucket addObject:pendingItem];
        return;
    }
    bucket = [NSMutableArray arrayWithObject:pendingItem];
    self.pendingBasicAuthQueues[realmKey] = bucket;

    NSInteger prevFailures = challenge.previousFailureCount;
    NSString *proposedUser = challenge.proposedCredential.user ?: @"";
    __weak typeof(self) weakSelf = self;
    [self enqueueAuthPrompt:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (prevFailures == 0 && strongSelf.sessionBasicAuth[realmKey]) {
            [strongSelf resolvePendingBasicAuthForKey:realmKey credential:strongSelf.sessionBasicAuth[realmKey] rejectedHost:displayHost];
            strongSelf.isPresentingAuthAlert = NO;
            [strongSelf drainAuthPromptQueue];
            return;
        }

        NSMutableString *msg = [NSMutableString stringWithFormat:@"站点：%@", displayHost.length > 0 ? displayHost : @"未知主机"];
        if (realm.length > 0) {
            [msg appendFormat:@"\n认证域：%@", realm];
        }
        if (prevFailures > 0) {
            [msg appendString:@"\n用户名或密码错误，请重试。"];
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要身份验证"
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"用户名";
            tf.text = proposedUser;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"密码";
            tf.secureTextEntry = YES;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s resolvePendingBasicAuthForKey:realmKey credential:nil rejectedHost:displayHost];
            s.isPresentingAuthAlert = NO;
            [s drainAuthPromptQueue];
        }]];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"登录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) s = weakSelf;
            __strong UIAlertController *al = weakAlert;
            if (!s) return;
            NSString *user = (al.textFields.count > 0 ? al.textFields[0].text : nil) ?: @"";
            NSString *pass = (al.textFields.count > 1 ? al.textFields[1].text : nil) ?: @"";
            NSURLCredential *cred = [NSURLCredential credentialWithUser:user
                                                               password:pass
                                                            persistence:NSURLCredentialPersistenceForSession];
            s.sessionBasicAuth[realmKey] = cred;
            [s resolvePendingBasicAuthForKey:realmKey credential:cred rejectedHost:displayHost];
            s.isPresentingAuthAlert = NO;
            [s drainAuthPromptQueue];
        }]];

        [strongSelf presentAuthAlertSafely:alert retryLeft:30 onCancel:^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) [s resolvePendingBasicAuthForKey:realmKey credential:nil rejectedHost:displayHost];
        }];
    }];
}

#pragma mark - KVO & WKWebView Delegates

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"estimatedProgress"] && [object isKindOfClass:[WKWebView class]]) {
        WKWebView *wv = (WKWebView *)object;
        if (wv == self.webViews[self.config.selectedSiteId]) {
            float p = (float)wv.estimatedProgress;
            self.progressView.hidden = (p >= 1.0f || p <= 0.01f);
            [self.progressView setProgress:p animated:YES];
        }
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    NSString *sid = [self siteIdForWebView:webView];
    if (sid.length > 0) {
        [self hideErrorOverlayForSiteId:sid];
    }
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    NSString *sid = [self siteIdForWebView:webView];
    if (sid.length > 0) {
        [self hideErrorOverlayForSiteId:sid];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [webView.scrollView.refreshControl endRefreshing];
    NSString *sid = [self siteIdForWebView:webView];
    if (sid.length > 0) {
        [self hideErrorOverlayForSiteId:sid];
    }
    if (webView == self.webViews[self.config.selectedSiteId]) {
        self.progressView.hidden = YES;
    }
    [webView evaluateJavaScript:@"if(window.__jwRecheckInputs)window.__jwRecheckInputs();"
                        inFrame:nil
                 inContentWorld:[WKContentWorld defaultClientWorld]
              completionHandler:nil];
    [self scheduleApplyProtectionAsync:nil];
}

static BOOL JWShouldIgnoreNavigationError(NSError *error) {
    if (!error) return YES;
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return YES;
    }
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && (error.code == 102 || error.code == 204)) {
        return YES;
    }
    return NO;
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [webView.scrollView.refreshControl endRefreshing];
    if (webView == self.webViews[self.config.selectedSiteId]) {
        self.progressView.hidden = YES;
    }
    if (JWShouldIgnoreNavigationError(error)) return;
    if (webView.URL == nil || [webView.URL.absoluteString isEqualToString:@"about:blank"] || JWIsSSLError(error)) {
        [self showErrorOverlayForWebView:webView error:error customTitle:nil customDetail:nil];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [webView.scrollView.refreshControl endRefreshing];
    if (webView == self.webViews[self.config.selectedSiteId]) {
        self.progressView.hidden = YES;
    }

    NSString *sid = [self siteIdForWebView:webView];
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        NSDictionary<NSString *, NSString *> *rej = sid ? self.lastRejectedAuthBySiteId[sid] : nil;
        if (rej && (webView.URL == nil || [webView.URL.absoluteString isEqualToString:@"about:blank"])) {
            [self showErrorOverlayForWebView:webView error:error customTitle:rej[@"title"] customDetail:rej[@"detail"]];
        }
        return;
    }
    if (JWShouldIgnoreNavigationError(error)) return;
    [self showErrorOverlayForWebView:webView error:error customTitle:nil customDetail:nil];
}

- (void)webView:(WKWebView *)webView
didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    JWAuthChallengeCompletionGuard *guard = [[JWAuthChallengeCompletionGuard alloc] initWithBlock:completionHandler];
    NSString *method = challenge.protectionSpace.authenticationMethod;

    if ([method isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        /* 同时涵盖主页面 HTTPS、子资源 fetch/XHR 以及 wss:// WebSocket 的 TLS 证书校验 */
        [self handleServerTrustChallenge:challenge webView:webView guard:guard];
        return;
    }

    if ([method isEqualToString:NSURLAuthenticationMethodHTTPBasic] ||
        [method isEqualToString:NSURLAuthenticationMethodHTTPDigest] ||
        [method isEqualToString:NSURLAuthenticationMethodDefault]) {
        [self handleBasicAuthChallenge:challenge webView:webView guard:guard];
        return;
    }

    [guard invokeWithDisposition:NSURLSessionAuthChallengePerformDefaultHandling credential:nil];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    NSString *hitId = [self siteIdForWebView:webView];
    if (!hitId) return;
    if ([hitId isEqualToString:self.config.selectedSiteId] &&
        [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        [self reloadOrLoadInitialURLForSiteId:hitId];
    } else {
        [self.terminatedSiteIds addObject:hitId];
    }
}

- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *)windowFeatures {
    /* 处理 target="_blank" / window.open：直接在当前标签内打开 */
    if (!navigationAction.targetFrame.isMainFrame && navigationAction.request.URL) {
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if (url && scheme.length > 0 &&
        ![scheme isEqualToString:@"http"] &&
        ![scheme isEqualToString:@"https"] &&
        ![scheme isEqualToString:@"about"] &&
        ![scheme isEqualToString:@"blob"] &&
        ![scheme isEqualToString:@"data"] &&
        ![scheme isEqualToString:@"file"]) {
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (BOOL)canPresentJSDialogForWebView:(WKWebView *)webView {
    return (webView == self.webViews[self.config.selectedSiteId]) &&
           (self.view.window != nil) &&
           (self.presentedViewController == nil) &&
           (self.transitionCoordinator == nil);
}

- (void)webView:(WKWebView *)webView
runJavaScriptAlertPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(void))completionHandler {
    JWAlertCompletionGuard *guard = [[JWAlertCompletionGuard alloc] initWithBlock:completionHandler];
    if (![self canPresentJSDialogForWebView:webView]) {
        [guard invoke];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [guard invoke];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
runJavaScriptConfirmPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(BOOL))completionHandler {
    JWConfirmCompletionGuard *guard = [[JWConfirmCompletionGuard alloc] initWithBlock:completionHandler];
    if (![self canPresentJSDialogForWebView:webView]) {
        [guard invokeWithResult:NO];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [guard invokeWithResult:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [guard invokeWithResult:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSString *))completionHandler {
    JWPromptCompletionGuard *guard = [[JWPromptCompletionGuard alloc] initWithBlock:completionHandler];
    if (![self canPresentJSDialogForWebView:webView]) {
        [guard invokeWithText:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:prompt
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = defaultText;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        [guard invokeWithText:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [guard invokeWithText:(alert.textFields.firstObject.text ?: @"")];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - JWManageViewControllerDelegate

- (NSDictionary<NSString *, NSNumber *> *)manageCurrentWebPIDsBySiteId {
    NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionary];
    for (NSString *sid in self.webViews) {
        pid_t p = JWWebViewContentPID(self.webViews[sid]);
        if (p > 0) map[sid] = @(p);
    }
    return map;
}

- (void)manageQueryLiveStatusesAsync:(void (^)(NSDictionary<NSNumber *, JWProcStatus *> *statuses))completion {
    NSString *sharedSnapshot = nil;
    NSArray<NSString *> *pidArgs = [self collectTargetPIDStringsOnMainThreadWithSnapshot:&sharedSnapshot];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.protectQueue, ^{
        JWWriteSharedSnapshotOnBgQueue(sharedSnapshot);
        NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:@"--query"];
        [args addObjectsFromArray:pidArgs];
        int code = -1;
        NSString *out = JWRunJetWebCtl(args, &code);
        NSDictionary<NSNumber *, JWProcStatus *> *parsed = JWParseHelperOutput(out);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self && parsed.count > 0) {
                self.lastProcStatuses = parsed;
                [self rebuildTabPills];
            }
            if (completion) completion(parsed ?: @{});
        });
    });
}

- (void)manageDidUpdateConfigAndReloadSites:(BOOL)structureChanged selectedSiteId:(NSString *)siteId {
    if (siteId.length > 0) {
        self.config.selectedSiteId = siteId;
        [self.config saveConfig];
    }
    if (structureChanged) {
        [self syncWebViewsWithConfig];
    } else {
        [self rebuildTabPills];
    }
    [self applyDockCollapsedStateAnimated:NO];
}

- (void)manageDidUpdateAppearanceConfig {
    [self applyAppearanceStyles];
}

- (void)manageDidUpdateTrustedCerts {
    for (NSString *host in [self.sessionTrustedCerts.allKeys copy]) {
        if (!self.config.trustedCerts[host]) {
            [self.sessionTrustedCerts removeObjectForKey:host];
        }
    }
}

- (void)manageDidRequestApplyProtectionNow:(void (^)(NSString *summary))completion {
    [self scheduleApplyProtectionAsync:completion];
}

- (void)manageDidRequestReloadSiteId:(NSString *)siteId {
    JWSiteItem *site = [self siteForId:siteId];
    WKWebView *wv = self.webViews[siteId];
    NSURL *u = site ? [NSURL URLWithString:site.urlString] : nil;
    if (wv && u) {
        [self hideErrorOverlayForSiteId:siteId];
        [wv loadRequest:[NSURLRequest requestWithURL:u]];
    }
}

- (void)manageDidClearWebsiteData {
    [self.sessionBasicAuth removeAllObjects];
    NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
    NSDate *since = [NSDate dateWithTimeIntervalSince1970:0];
    __weak typeof(self) weakSelf = self;
    [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:types modifiedSince:since completionHandler:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        for (NSString *sid in self.webViews) {
            [self reloadOrLoadInitialURLForSiteId:sid];
        }
    }];
}

@end

#pragma mark - App Delegate & Entry

@interface JWAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation JWAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[JWHubViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([JWAppDelegate class]));
    }
}
