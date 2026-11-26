/*
 * JetWebBridge.h — Minimal C/ObjC bridge for POSIX persona spawning,
 * WebKit private PID / persistent isolated WKWebsiteDataStore SPIs, and TLS SHA-256 helpers.
 */

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>

#define JW_VERSION "0.1.0"
#ifndef JW_COMMIT
#define JW_COMMIT "dev"
#endif

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *JWBridgeVersion(void);
FOUNDATION_EXPORT NSString *JWBridgeGitCommit(void);

FOUNDATION_EXPORT pid_t JWBridgeWebViewContentPID(WKWebView * _Nullable webView);
FOUNDATION_EXPORT pid_t JWBridgeWebViewProvisionalPID(WKWebView * _Nullable webView);
FOUNDATION_EXPORT pid_t JWBridgeWebViewNetworkingPID(WKWebView * _Nullable webView);
FOUNDATION_EXPORT pid_t JWBridgeWebViewGPUPID(WKWebView * _Nullable webView);

FOUNDATION_EXPORT NSString *JWBridgeRunJetWebCtl(NSArray<NSString *> *args, int * _Nullable exitCodeOut);

FOUNDATION_EXPORT void JWBridgeSpawnDetachedBgGuard(NSInteger band,
                                                    NSInteger maxMB,
                                                    NSString *epochPath,
                                                    NSUInteger epoch,
                                                    NSString *logPathOrDash,
                                                    NSArray<NSString *> *pidArgs);

FOUNDATION_EXPORT WKWebsiteDataStore *JWBridgeCreateIsolatedDataStore(NSString *uuidString, NSString *fallbackRootDir);
FOUNDATION_EXPORT void JWBridgePurgeIsolatedDataStore(NSString *uuidString,
                                                      NSString *fallbackRootDir,
                                                      WKWebsiteDataStore * _Nullable liveStore);

FOUNDATION_EXPORT void JWBridgeTrimWebViewMemory(WKWebView * _Nullable webView,
                                                 BOOL clearBFCache,
                                                 BOOL suspendMedia);
FOUNDATION_EXPORT void JWBridgeReleaseHostMemory(void);

FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *JWBridgeExtractLeafCertInfo(SecTrustRef trust);
FOUNDATION_EXPORT NSURLCredential *JWBridgeCredentialForAcceptedTrust(SecTrustRef trust);

NS_ASSUME_NONNULL_END
