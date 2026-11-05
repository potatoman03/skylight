#import "CEFBridge.h"

#include "Internal.h"
#include "include/cef_client.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_message_router.h"

#pragma mark - Profile

@interface SKProfile ()
@property (nonatomic, readonly) CefRefPtr<CefRequestContext> context;
@end

@implementation SKProfile {
  CefRefPtr<CefRequestContext> _context;
}

- (instancetype)initWithCachePath:(NSString*)path {
  if ((self = [super init])) {
    _cachePath = [path copy];
    CefRequestContextSettings settings;
    settings.persist_session_cookies = true;
    CefString(&settings.cache_path) = skylight::ToCef(path);
    _context = CefRequestContext::CreateContext(settings, nullptr);
  }
  return self;
}

- (CefRefPtr<CefRequestContext>)context {
  return _context;
}

@end

#pragma mark - Permission requests

namespace {

struct PermissionName {
  uint32_t bit;
  NSString* name;
};

NSArray<NSString*>* PermissionKinds(uint32_t mask) {
  static const PermissionName kNames[] = {
      {CEF_PERMISSION_TYPE_CAMERA_STREAM, @"camera"},
      {CEF_PERMISSION_TYPE_MIC_STREAM, @"microphone"},
      {CEF_PERMISSION_TYPE_GEOLOCATION, @"geolocation"},
      {CEF_PERMISSION_TYPE_NOTIFICATIONS, @"notifications"},
      {CEF_PERMISSION_TYPE_CLIPBOARD, @"clipboard"},
      {CEF_PERMISSION_TYPE_MIDI_SYSEX, @"midi"},
      {CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, @"fileSystem"},
      {CEF_PERMISSION_TYPE_STORAGE_ACCESS, @"storageAccess"},
      {CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, @"storageAccess"},
      {CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, @"windowManagement"},
      {CEF_PERMISSION_TYPE_LOCAL_FONTS, @"localFonts"},
      {CEF_PERMISSION_TYPE_IDLE_DETECTION, @"idleDetection"},
      {CEF_PERMISSION_TYPE_KEYBOARD_LOCK, @"keyboardLock"},
      {CEF_PERMISSION_TYPE_POINTER_LOCK, @"pointerLock"},
      {CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER, @"protocolHandler"},
      {CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, @"multipleDownloads"},
  };
  NSMutableOrderedSet<NSString*>* kinds = [NSMutableOrderedSet orderedSet];
  uint32_t known = 0;
  for (const auto& n : kNames) {
    known |= n.bit;
    if (mask & n.bit) [kinds addObject:n.name];
  }
  if (mask & ~known) [kinds addObject:@"other"];
  return kinds.array;
}

NSArray<NSString*>* MediaKinds(uint32_t mask) {
  NSMutableArray<NSString*>* kinds = [NSMutableArray array];
  if (mask & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) [kinds addObject:@"camera"];
  if (mask & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) [kinds addObject:@"microphone"];
  if (mask & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) [kinds addObject:@"screen"];
  return kinds;
}

}  // namespace

@implementation SKPermissionRequest {
  CefRefPtr<CefPermissionPromptCallback> _prompt;
  CefRefPtr<CefMediaAccessCallback> _media;
  uint32_t _mediaMask;
}

- (instancetype)initWithID:(uint64_t)requestID origin:(NSString*)origin topURL:(NSString*)topURL kinds:(NSArray<NSString*>*)kinds {
  if ((self = [super init])) {
    _requestID = requestID;
    _origin = [origin copy];
    _topURL = [topURL copy];
    _kinds = [kinds copy];
  }
  return self;
}

- (void)setPrompt:(CefRefPtr<CefPermissionPromptCallback>)cb {
  _prompt = cb;
}

- (void)setMedia:(CefRefPtr<CefMediaAccessCallback>)cb mask:(uint32_t)mask {
  _media = cb;
  _mediaMask = mask;
}

- (void)respond:(BOOL)allow {
  if (_prompt) {
    _prompt->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    _prompt = nullptr;
  }
  if (_media) {
    if (allow) _media->Continue(_mediaMask); else _media->Cancel();
    _media = nullptr;
  }
}

- (void)dealloc {
  if (_prompt) _prompt->Continue(CEF_PERMISSION_RESULT_DISMISS);
  if (_media) _media->Cancel();
}

@end

#pragma mark - Dialog requests

@implementation SKDialogRequest {
  CefRefPtr<CefJSDialogCallback> _callback;
}

- (instancetype)initWithKind:(SKDialogKind)kind origin:(NSString*)origin message:(NSString*)message
                 defaultText:(NSString*)defaultText callback:(CefRefPtr<CefJSDialogCallback>)callback {
  if ((self = [super init])) {
    _kind = kind;
    _origin = [origin copy];
    _message = [message copy];
    _defaultText = [defaultText copy];
    _callback = callback;
  }
  return self;
}

- (void)respond:(BOOL)ok text:(NSString*)text {
  if (!_callback) return;
  _callback->Continue(ok, skylight::ToCef(text));
  _callback = nullptr;
}

- (void)dealloc {
  if (_callback) _callback->Continue(false, CefString());
}

@end

#pragma mark - Container view

/// Keeps Chromium's child view filling the space the UI gives it.
@interface SKContainerView : NSView
@end

@implementation SKContainerView
- (BOOL)isFlipped {
  return YES;
}
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  for (NSView* v in self.subviews) v.frame = self.bounds;
}
@end

#pragma mark - Client

@interface SKBrowser ()
@property (nonatomic, weak) id<SKBrowserDelegate> delegate;
- (void)didCreate:(CefRefPtr<CefBrowser>)browser;
- (void)didClose;
@end

namespace skylight {
namespace {

/// Routes CEF callbacks for one tab to its SKBrowser.
class BrowserClient : public CefClient,
                      public CefDisplayHandler,
                      public CefLoadHandler,
                      public CefLifeSpanHandler,
                      public CefRequestHandler,
                      public CefPermissionHandler,
                      public CefJSDialogHandler,
                      public CefDownloadHandler,
                      public CefMessageRouterBrowserSide::Handler {
 public:
  explicit BrowserClient(SKBrowser* owner) : owner_(owner) {
    CefMessageRouterConfig config;
    router_ = CefMessageRouterBrowserSide::Create(config);
    router_->AddHandler(this, false);
  }

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    return router_->OnProcessMessageReceived(browser, frame, source, message);
  }

  // Popups (OAuth windows and the like) go to Chromium's default window, owned by this client.
  bool IsMain(CefRefPtr<CefBrowser> b) const { return mainID_ == b->GetIdentifier(); }

  // MARK: Display

  void OnAddressChange(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (IsMain(b) && frame->IsMain()) [owner_.delegate browser:owner_ didChangeAddress:ToNS(url)];
  }

  void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString& title) override {
    if (IsMain(b)) [owner_.delegate browser:owner_ didChangeTitle:ToNS(title)];
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString>& urls) override {
    if (IsMain(b) && !urls.empty()) [owner_.delegate browser:owner_ didChangeFaviconURL:ToNS(urls.front())];
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> b, double progress) override {
    if (IsMain(b)) [owner_.delegate browser:owner_ didChangeProgress:progress];
  }

  // MARK: Load

  void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool loading, bool back, bool forward) override {
    if (IsMain(b)) [owner_.delegate browser:owner_ didChangeLoading:loading canGoBack:back canGoForward:forward];
  }

  // MARK: Life span

  bool OnBeforePopup(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int popup_id, const CefString& url,
                     const CefString& frame_name, WindowOpenDisposition disposition, bool user_gesture,
                     const CefPopupFeatures& features, CefWindowInfo& window_info, CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings, CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    switch (disposition) {
      case CEF_WOD_NEW_FOREGROUND_TAB:
      case CEF_WOD_NEW_BACKGROUND_TAB:
      case CEF_WOD_NEW_WINDOW:
      case CEF_WOD_SINGLETON_TAB:
        [owner_.delegate browser:owner_ wantsNewTabWithURL:ToNS(url) background:disposition == CEF_WOD_NEW_BACKGROUND_TAB];
        return true;  // Skylight opens it as a tab.
      default:
        // Real popups keep their opener (sign-in flows depend on it).
        extra_info = CefDictionaryValue::Create();
        extra_info->SetList(kScriptsKey, CurrentScriptsList());
        return false;
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    CEF_REQUIRE_UI_THREAD();
    RegisterBrowser(b);
    if (mainID_ == 0) {
      mainID_ = b->GetIdentifier();
      [owner_ didCreate:b];
    }
  }

  bool DoClose(CefRefPtr<CefBrowser> b) override {
    CEF_REQUIRE_UI_THREAD();
    // Popups live in CEF's own window: let it close that window.
    if (!IsMain(b)) return false;
    // Tab browsers live in Skylight's window. The default would send performClose: to that window,
    // so instead tear down the browser's view, which completes the close.
    NSView* view = (__bridge NSView*)b->GetHost()->GetWindowHandle();
    [view removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
    CEF_REQUIRE_UI_THREAD();
    router_->OnBeforeClose(b);
    UnregisterBrowser(b);
    if (IsMain(b)) [owner_ didClose];
  }

  // MARK: Requests

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                      bool user_gesture, bool is_redirect) override {
    router_->OnBeforeBrowse(b, frame);
    return false;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> b, TerminationStatus status, int error_code,
                                 const CefString& error_string) override {
    router_->OnRenderProcessTerminated(b);
  }

  // MARK: Message router

  bool OnQuery(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, int64_t query_id, const CefString& request,
               bool persistent, CefRefPtr<Callback> callback) override {
    // Only a tab's own page, never a frame inside it: an ad or embed from another site would
    // otherwise speak with the page's address.
    if (!IsMain(b) || !frame->IsMain()) return false;
    [owner_.delegate browser:owner_
               receivedQuery:ToNS(request)
                       reply:^(NSString* result, NSString* error) {
                         if (error) callback->Failure(1, ToCef(error));
                         else callback->Success(ToCef(result ?: @"null"));
                       }];
    return true;
  }

  // MARK: Permissions

  static NSString* TopURL(CefRefPtr<CefBrowser> b) {
    CefRefPtr<CefFrame> main = b->GetMainFrame();
    return main ? ToNS(main->GetURL()) : @"";
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> b, uint64_t prompt_id, const CefString& origin,
                              uint32_t permissions, CefRefPtr<CefPermissionPromptCallback> callback) override {
    if (!IsMain(b)) return false;
    SKPermissionRequest* req = [[SKPermissionRequest alloc] initWithID:prompt_id origin:ToNS(origin) topURL:TopURL(b)
                                                                 kinds:PermissionKinds(permissions)];
    [req setPrompt:callback];
    [owner_.delegate browser:owner_ requestsPermission:req];
    return true;
  }

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, const CefString& origin,
                                      uint32_t permissions, CefRefPtr<CefMediaAccessCallback> callback) override {
    if (!IsMain(b)) return false;
    SKPermissionRequest* req = [[SKPermissionRequest alloc] initWithID:0 origin:ToNS(origin) topURL:TopURL(b)
                                                                 kinds:MediaKinds(permissions)];
    [req setMedia:callback mask:permissions];
    [owner_.delegate browser:owner_ requestsPermission:req];
    return true;
  }

  // MARK: Dialogs

  bool OnJSDialog(CefRefPtr<CefBrowser> b, const CefString& origin, JSDialogType type, const CefString& message,
                  const CefString& default_text, CefRefPtr<CefJSDialogCallback> callback, bool& suppress) override {
    if (!IsMain(b)) return false;
    SKDialogKind kind = type == JSDIALOGTYPE_ALERT ? SKDialogKindAlert
                        : type == JSDIALOGTYPE_CONFIRM ? SKDialogKindConfirm : SKDialogKindPrompt;
    SKDialogRequest* req = [[SKDialogRequest alloc] initWithKind:kind origin:ToNS(origin) message:ToNS(message)
                                                     defaultText:ToNS(default_text) callback:callback];
    [owner_.delegate browser:owner_ requestsDialog:req];
    return true;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> b, const CefString& message, bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    callback->Continue(true, CefString());  // Closing a tab never gets stuck behind "Leave site?".
    return true;
  }

  // MARK: Downloads

  bool OnBeforeDownload(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item, const CefString& suggested,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    NSString* downloads = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    NSString* name = ToNS(suggested).length ? ToNS(suggested) : @"download";
    NSString* path = [downloads stringByAppendingPathComponent:name];
    NSString* stem = [name stringByDeletingPathExtension];
    NSString* ext = [name pathExtension];
    for (int i = 2; [NSFileManager.defaultManager fileExistsAtPath:path]; ++i) {
      NSString* candidate = ext.length ? [NSString stringWithFormat:@"%@ %d.%@", stem, i, ext] : [NSString stringWithFormat:@"%@ %d", stem, i];
      path = [downloads stringByAppendingPathComponent:candidate];
    }
    callback->Continue(ToCef(path), false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (item->IsComplete()) [owner_.delegate browser:owner_ didFinishDownloadAtPath:ToNS(item->GetFullPath())];
  }

 private:
  __weak SKBrowser* owner_;
  int mainID_ = 0;
  CefRefPtr<CefMessageRouterBrowserSide> router_;

  IMPLEMENT_REFCOUNTING(BrowserClient);
};

}  // namespace
}  // namespace skylight

#pragma mark - Browser

@implementation SKBrowser {
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<skylight::BrowserClient> _client;
  NSString* _pendingURL;
  BOOL _pendingHidden;
}

- (instancetype)initWithURL:(NSString*)url profile:(SKProfile*)profile delegate:(id<SKBrowserDelegate>)delegate {
  if ((self = [super init])) {
    _delegate = delegate;
    _view = [[SKContainerView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)];
    _view.autoresizesSubviews = YES;
    _client = new skylight::BrowserClient(self);

    CefWindowInfo info;
    info.SetAsChild((__bridge void*)_view, CefRect(0, 0, 1024, 768));

    CefBrowserSettings settings;
    CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
    extra->SetList(skylight::kScriptsKey, skylight::CurrentScriptsList());

    CefBrowserHost::CreateBrowser(info, _client, skylight::ToCef(url), settings, extra, profile.context);
  }
  return self;
}

- (void)didCreate:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  NSView* child = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  child.frame = _view.bounds;
  if (_pendingURL) {
    [self loadURL:_pendingURL];
    _pendingURL = nil;
  }
  if (_pendingHidden) browser->GetHost()->WasHidden(true);
}

- (void)didClose {
  _isClosed = YES;
  _browser = nullptr;
  [_view removeFromSuperview];
  [self.delegate browserDidClose:self];
  _client = nullptr;
}

- (void)loadURL:(NSString*)url {
  if (!_browser) {
    _pendingURL = url;
    return;
  }
  _browser->GetMainFrame()->LoadURL(skylight::ToCef(url));
}

- (void)goBack {
  if (_browser) _browser->GoBack();
}

- (void)goForward {
  if (_browser) _browser->GoForward();
}

- (void)reload {
  if (_browser) _browser->Reload();
}

- (void)stopLoad {
  if (_browser) _browser->StopLoad();
}

- (void)executeJavaScript:(NSString*)script {
  if (!_browser) return;
  CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
  frame->ExecuteJavaScript(skylight::ToCef(script), frame->GetURL(), 0);
}

- (NSInteger)identifier {
  return _browser ? _browser->GetIdentifier() : 0;
}

- (void)evaluateWithUserGesture:(NSString*)script {
  if (!_browser) return;
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", skylight::ToCef(script));
  params->SetBool("userGesture", true);
  params->SetBool("awaitPromise", false);
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
}

- (void)setHidden:(BOOL)hidden {
  _pendingHidden = hidden;
  if (_browser) _browser->GetHost()->WasHidden(hidden);
}

- (void)showDevTools {
  if (!_browser) return;
  CefWindowInfo info;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
}

- (void)close {
  if (_browser) _browser->GetHost()->CloseBrowser(true);
}

@end
