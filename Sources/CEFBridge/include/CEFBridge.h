// CEFBridge: a small Objective-C surface over the CEF C++ API.
// This header must stay free of C++ so Swift can import it. All CEF types live in the .mm files.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Engine

@interface SKEngineSettings : NSObject
/// Parent directory of every profile's cache. Profiles must live inside it.
@property (nonatomic, copy) NSString *rootCachePath;
/// Where Chromium writes its log.
@property (nonatomic, copy, nullable) NSString *logFilePath;
/// Store cookie keys in a mock keychain instead of the login keychain (no keychain prompt in dev builds).
@property (nonatomic) BOOL useMockKeychain;
/// Port for Chromium's remote debugging (0 = off).
@property (nonatomic) NSInteger remoteDebuggingPort;
@end

/// The NSApplication subclass CEF requires (it tracks event dispatch).
/// Create it with `[SKApplication sharedApplication]` before anything touches NSApp.
@interface SKApplication : NSApplication
/// Called instead of terminating directly, so the app can close its browsers first.
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);
@end

@interface SKEngine : NSObject

/// Loads the Chromium Embedded Framework. Call first, from the main process.
+ (BOOL)loadFramework;

/// Starts Chromium. `ready` runs on the main thread once profiles and browsers can be created.
+ (BOOL)initializeWithSettings:(SKEngineSettings *)settings ready:(void (^)(void))ready;

/// Runs the message loop until `quitMessageLoop`.
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
+ (void)shutdown;

/// Scripts run at document start in every main frame, for new and existing processes.
+ (void)setPageScripts:(NSArray<NSString *> *)scripts;

/// Closes every browser and calls `completion` when the last one is gone.
+ (void)closeAllBrowsersWithCompletion:(void (^)(void))completion;

@end

#pragma mark - Profiles

/// A cookie jar and cache (a CEF request context).
@interface SKProfile : NSObject
- (instancetype)initWithCachePath:(NSString *)path;
@property (nonatomic, readonly, copy) NSString *cachePath;
@end

#pragma mark - Requests from pages

@interface SKPermissionRequest : NSObject
@property (nonatomic, readonly) uint64_t requestID;
@property (nonatomic, readonly, copy) NSString *origin;
/// Stable names: camera, microphone, screen, geolocation, notifications, clipboard, ...
@property (nonatomic, readonly, copy) NSArray<NSString *> *kinds;
/// Answer once. Unanswered requests are dismissed when the request is deallocated.
- (void)respond:(BOOL)allow;
@end

typedef NS_ENUM(NSInteger, SKDialogKind) {
    SKDialogKindAlert,
    SKDialogKindConfirm,
    SKDialogKindPrompt,
};

@interface SKDialogRequest : NSObject
@property (nonatomic, readonly) SKDialogKind kind;
@property (nonatomic, readonly, copy) NSString *origin;
@property (nonatomic, readonly, copy) NSString *message;
@property (nonatomic, readonly, copy) NSString *defaultText;
- (void)respond:(BOOL)ok text:(NSString *)text;
@end

#pragma mark - Browsers

@class SKBrowser;

@protocol SKBrowserDelegate <NSObject>
- (void)browser:(SKBrowser *)browser didChangeAddress:(NSString *)url;
- (void)browser:(SKBrowser *)browser didChangeTitle:(NSString *)title;
- (void)browser:(SKBrowser *)browser didChangeFaviconURL:(NSString *)url;
- (void)browser:(SKBrowser *)browser didChangeLoading:(BOOL)loading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)browser:(SKBrowser *)browser didChangeProgress:(double)progress;
- (void)browser:(SKBrowser *)browser wantsNewTabWithURL:(NSString *)url background:(BOOL)background;
/// A `cefQuery` request from the page. Call `reply` exactly once.
- (void)browser:(SKBrowser *)browser
   receivedQuery:(NSString *)request
           reply:(void (^)(NSString *_Nullable result, NSString *_Nullable error))reply;
- (void)browser:(SKBrowser *)browser requestsPermission:(SKPermissionRequest *)request;
- (void)browser:(SKBrowser *)browser requestsDialog:(SKDialogRequest *)request;
- (void)browser:(SKBrowser *)browser didFinishDownloadAtPath:(NSString *)path;
- (void)browserDidClose:(SKBrowser *)browser;
@end

@interface SKBrowser : NSObject

- (instancetype)initWithURL:(NSString *)url
                    profile:(SKProfile *)profile
                   delegate:(id<SKBrowserDelegate>)delegate;

/// Hosts Chromium's view and keeps it sized to fill.
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly) BOOL isClosed;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoad;
- (void)executeJavaScript:(NSString *)script;
- (void)setHidden:(BOOL)hidden;
- (void)showDevTools;
- (void)close;

@end

#pragma mark - Helper process

/// Entry point for the "Skylight Helper" sub-process executables.
FOUNDATION_EXPORT int SKHelperMain(int argc, char *_Nullable argv[_Nonnull]);

NS_ASSUME_NONNULL_END
