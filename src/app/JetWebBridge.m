/*
 * JetWebBridge.m — Low-level POSIX / ObjC-runtime / Security bridge for JetWeb Swift app.
 */

#import "JetWebBridge.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <spawn.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <malloc/malloc.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, uid_t);
extern char **environ;

NSString *JWBridgeVersion(void) {
    return @JW_VERSION;
}

NSString *JWBridgeGitCommit(void) {
    return @JW_COMMIT;
}

static pid_t JWCallPIDSelector(id target, NSString *selName) {
    if (!target || selName.length == 0) return 0;
    SEL sel = NSSelectorFromString(selName);
    if ([target respondsToSelector:sel]) {
        pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(target, sel);
        if (pid > 0) return pid;
    }
    return 0;
}

pid_t JWBridgeWebViewProvisionalPID(WKWebView *webView) {
    return JWCallPIDSelector(webView, @"_provisionalWebProcessIdentifier");
}

pid_t JWBridgeWebViewContentPID(WKWebView *webView) {
    pid_t pid = JWCallPIDSelector(webView, @"_webProcessIdentifier");
    if (pid > 0) return pid;
    return JWBridgeWebViewProvisionalPID(webView);
}

pid_t JWBridgeWebViewNetworkingPID(WKWebView *webView) {
    if (!webView) return 0;
    pid_t pid = JWCallPIDSelector(webView.configuration.websiteDataStore, @"_networkProcessIdentifier");
    if (pid > 0) return pid;
    return JWCallPIDSelector(webView, @"_networkProcessIdentifier");
}

pid_t JWBridgeWebViewGPUPID(WKWebView *webView) {
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

NSString *JWBridgeRunJetWebCtl(NSArray<NSString *> *args, int *exitCodeOut) {
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
        uint64_t deadline = JWMonotonicMillis() + 2200ULL;
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

void JWBridgeSpawnDetachedBgGuard(NSInteger band,
                                  NSInteger maxMB,
                                  NSString *epochPath,
                                  NSUInteger epoch,
                                  NSString *logPathOrDash,
                                  NSArray<NSString *> *pidArgs) {
    if (pidArgs.count == 0 || epochPath.length == 0) return;
    NSString *binPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"jetwebctl"];
    const char *cbin = binPath.fileSystemRepresentation;
    if (!cbin || access(cbin, X_OK) != 0) return;

    NSString *safeLog = (logPathOrDash.length > 0) ? logPathOrDash : @"-";
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
                                        @"--bg-guard",
                                        [NSString stringWithFormat:@"%ld", (long)band],
                                        [NSString stringWithFormat:@"%ld", (long)maxMB],
                                        epochPath,
                                        [NSString stringWithFormat:@"%lu", (unsigned long)epoch],
                                        [NSString stringWithFormat:@"%d", (int)getpid()],
                                        safeLog,
                                        nil];
    [args addObjectsFromArray:pidArgs];

    NSUInteger argc = args.count + 1;
    char **argv = (char **)calloc(argc + 1, sizeof(char *));
    if (!argv) return;
    argv[0] = strdup(cbin);
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i + 1] = strdup([args[i] UTF8String] ?: "");
    }
    argv[argc] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

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

    if (rc == 0 && child > 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int status = 0;
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        });
    }
}

WKWebsiteDataStore *JWBridgeCreateIsolatedDataStore(NSString *uuidString, NSString *fallbackRootDir) {
    NSUUID *uuid = (uuidString.length > 0) ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
    if (!uuid) return [WKWebsiteDataStore defaultDataStore];

    /* Tier 1: iOS 17.0+ public API */
    SEL pubSel = NSSelectorFromString(@"dataStoreForIdentifier:");
    if ([WKWebsiteDataStore respondsToSelector:pubSel]) {
        WKWebsiteDataStore *ds = ((WKWebsiteDataStore *(*)(id, SEL, NSUUID *))objc_msgSend)([WKWebsiteDataStore class], pubSel, uuid);
        if (ds) return ds;
    }

    /* Tier 2: iOS 16.4+ _WKWebsiteDataStoreConfiguration initWithIdentifier: + _initWithConfiguration: */
    Class cfgCls = NSClassFromString(@"_WKWebsiteDataStoreConfiguration");
    SEL initIdSel = NSSelectorFromString(@"initWithIdentifier:");
    SEL initCfgSel = NSSelectorFromString(@"_initWithConfiguration:");
    if (cfgCls && [cfgCls instancesRespondToSelector:initIdSel] &&
        [WKWebsiteDataStore instancesRespondToSelector:initCfgSel]) {
        @try {
            id dsCfg = ((id (*)(id, SEL, NSUUID *))objc_msgSend)([cfgCls alloc], initIdSel, uuid);
            if (dsCfg) {
                WKWebsiteDataStore *ds = ((WKWebsiteDataStore *(*)(id, SEL, id))objc_msgSend)([WKWebsiteDataStore alloc], initCfgSel, dsCfg);
                if (ds) return ds;
            }
        } @catch (__unused NSException *ex) {}
    }

    /* Tier 3: iOS 15.0 - 16.3 persistent custom directory fallback */
    if (cfgCls && [WKWebsiteDataStore instancesRespondToSelector:initCfgSel] && fallbackRootDir.length > 0) {
        @try {
            id dsCfg = [[cfgCls alloc] init];
            if (dsCfg) {
                NSString *root = [fallbackRootDir stringByAppendingPathComponent:uuid.UUIDString.uppercaseString];
                NSFileManager *fm = [NSFileManager defaultManager];
                NSString *cookiesDir = [root stringByAppendingPathComponent:@"Cookies"];
                [fm createDirectoryAtPath:cookiesDir withIntermediateDirectories:YES attributes:nil error:nil];

                NSDictionary<NSString *, NSString *> *dirProps = @{
                    @"_setWebStorageDirectory:": @"LocalStorage",
                    @"_setIndexedDBDatabaseDirectory:": @"IndexedDB",
                    @"_setWebSQLDatabaseDirectory:": @"WebSQL",
                    @"_setResourceLoadStatisticsDirectory:": @"ITP",
                    @"_setCacheStorageDirectory:": @"CacheStorage",
                    @"_setServiceWorkerRegistrationDirectory:": @"ServiceWorkers",
                    @"setNetworkCacheDirectory:": @"NetworkCache",
                    @"setApplicationCacheDirectory:": @"AppCache",
                    @"setMediaCacheDirectory:": @"MediaCache",
                    @"setHSTSStorageDirectory:": @"HSTS",
                    @"setAlternativeServicesStorageDirectory:": @"AltServices",
                    @"setGeneralStorageDirectory:": @"GeneralStorage"
                };
                for (NSString *selStr in dirProps) {
                    SEL s = NSSelectorFromString(selStr);
                    if ([dsCfg respondsToSelector:s]) {
                        NSString *sub = [root stringByAppendingPathComponent:dirProps[selStr]];
                        [fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
                        NSURL *furl = [NSURL fileURLWithPath:sub isDirectory:YES];
                        ((void (*)(id, SEL, NSURL *))objc_msgSend)(dsCfg, s, furl);
                    }
                }
                SEL cookieSel = NSSelectorFromString(@"_setCookieStorageFile:");
                if ([dsCfg respondsToSelector:cookieSel]) {
                    NSString *cookieFile = [cookiesDir stringByAppendingPathComponent:@"Cookies.binarycookies"];
                    NSURL *curl = [NSURL fileURLWithPath:cookieFile isDirectory:NO];
                    ((void (*)(id, SEL, NSURL *))objc_msgSend)(dsCfg, cookieSel, curl);
                }
                WKWebsiteDataStore *ds = ((WKWebsiteDataStore *(*)(id, SEL, id))objc_msgSend)([WKWebsiteDataStore alloc], initCfgSel, dsCfg);
                if (ds) return ds;
            }
        } @catch (__unused NSException *ex) {}
    }

    return [WKWebsiteDataStore nonPersistentDataStore];
}

void JWBridgePurgeIsolatedDataStore(NSString *uuidString,
                                    NSString *fallbackRootDir,
                                    WKWebsiteDataStore *liveStore) {
    NSUUID *uuid = (uuidString.length > 0) ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
    if (!uuid) return;
    NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
    NSDate *since = [NSDate dateWithTimeIntervalSince1970:0];

    void (^removeDisk)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SEL pubRm = NSSelectorFromString(@"removeDataStoreForIdentifier:completionHandler:");
            SEL privRm = NSSelectorFromString(@"_removeDataStoreWithIdentifier:completionHandler:");
            void (^noop)(NSError *) = ^(__unused NSError *err) {};
            if ([WKWebsiteDataStore respondsToSelector:pubRm]) {
                ((void (*)(id, SEL, NSUUID *, void (^)(NSError *)))objc_msgSend)([WKWebsiteDataStore class], pubRm, uuid, noop);
            } else if ([WKWebsiteDataStore respondsToSelector:privRm]) {
                ((void (*)(id, SEL, NSUUID *, void (^)(NSError *)))objc_msgSend)([WKWebsiteDataStore class], privRm, uuid, noop);
            }
            if (fallbackRootDir.length > 0) {
                NSString *customDir = [fallbackRootDir stringByAppendingPathComponent:uuid.UUIDString.uppercaseString];
                [[NSFileManager defaultManager] removeItemAtPath:customDir error:nil];
            }
        });
    };

    if (liveStore) {
        [liveStore removeDataOfTypes:types modifiedSince:since completionHandler:^{
            removeDisk();
        }];
    } else {
        removeDisk();
    }
}

NSDictionary<NSString *, NSString *> *JWBridgeExtractLeafCertInfo(SecTrustRef trust) {
    if (!trust) return @{@"fingerprint": @"", @"subject": @""};
    SecCertificateRef leaf = NULL;
    if (@available(iOS 15.0, *)) {
        CFArrayRef chain = SecTrustCopyCertificateChain(trust);
        if (chain) {
            if (CFArrayGetCount(chain) > 0) {
                leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
                if (leaf) CFRetain(leaf);
            }
            CFRelease(chain);
        }
    }
    if (!leaf) return @{@"fingerprint": @"", @"subject": @""};

    NSString *fpHex = @"";
    CFDataRef der = SecCertificateCopyData(leaf);
    if (der) {
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
        CFRelease(der);
        NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            [hex appendFormat:@"%02X", digest[i]];
        }
        fpHex = [hex copy];
    }

    NSString *subj = @"";
    CFStringRef summary = SecCertificateCopySubjectSummary(leaf);
    if (summary) {
        subj = [(__bridge NSString *)summary copy];
        CFRelease(summary);
    }
    CFRelease(leaf);

    return @{
        @"fingerprint": fpHex ?: @"",
        @"subject": subj ?: @""
    };
}

NSURLCredential *JWBridgeCredentialForAcceptedTrust(SecTrustRef trust) {
    CFDataRef exceptions = SecTrustCopyExceptions(trust);
    if (exceptions) {
        SecTrustSetExceptions(trust, exceptions);
        CFRelease(exceptions);
    }
    return [NSURLCredential credentialForTrust:trust];
}

static void JWInvokeVoidSelectorSafely(id target, NSString *selName) {
    if (!target || selName.length == 0) return;
    SEL sel = NSSelectorFromString(selName);
    if ([target respondsToSelector:sel]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(target, sel);
        } @catch (__unused NSException *ex) {}
    }
}

void JWBridgeTrimWebViewMemory(WKWebView *webView, BOOL clearBFCache, BOOL suspendMedia) {
    if (!webView) return;
    if (clearBFCache) {
        JWInvokeVoidSelectorSafely(webView, @"_clearBackForwardCache");
    }
    if (suspendMedia) {
        JWInvokeVoidSelectorSafely(webView, @"_suspendAllMediaPlayback");
    }
    WKProcessPool *pool = webView.configuration.processPool;
    if (pool) {
        JWInvokeVoidSelectorSafely(pool, @"_clearWebProcessCache");
        JWInvokeVoidSelectorSafely(pool, @"_garbageCollectJavaScriptObjectsForTesting");
    }
}

void JWBridgeReleaseHostMemory(void) {
    [[NSURLCache sharedURLCache] removeAllCachedResponses];
    (void)malloc_zone_pressure_relief(NULL, 0);
}
