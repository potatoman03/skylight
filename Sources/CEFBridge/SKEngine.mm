#import "CEFBridge.h"

#include <fcntl.h>
#include <unistd.h>

#include <map>
#include <memory>
#include <string>

#include "Internal.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#pragma mark - Settings

@implementation SKEngineSettings
- (instancetype)init {
  if ((self = [super init])) {
    _rootCachePath = @"";
  }
  return self;
}
@end

#pragma mark - Application

@interface SKApplication () <CefAppProtocol>
@end

@implementation SKApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// CEF must close its browsers before the process exits, so termination is routed through the app.
- (void)terminate:(id)sender {
  if (self.terminationHandler) {
    self.terminationHandler();
  } else {
    [super terminate:sender];
  }
}

@end

#pragma mark - Foreign browsers

@interface SKForeignBrowser ()
- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser;
@end

@implementation SKForeignBrowser {
  CefRefPtr<CefBrowser> _browser;
}

- (instancetype)initWithBrowser:(CefRefPtr<CefBrowser>)browser {
  if ((self = [super init])) {
    _browser = browser;
    _identifier = browser->GetIdentifier();
  }
  return self;
}

- (void)close {
  if (_browser) _browser->GetHost()->CloseBrowser(true);
  _browser = nullptr;
}

@end

#pragma mark - Browser-process app

namespace skylight {
namespace {

std::unique_ptr<CefScopedLibraryLoader> g_library;
std::vector<std::string> g_scripts;
std::map<int, CefRefPtr<CefBrowser>> g_browsers;
void (^g_closeCompletion)(void) = nil;
void (^g_foreignHandler)(SKForeignBrowser*, NSString*) = nil;

// MARK: DevTools pipe
//
// Chromium's `--remote-debugging-pipe` reads commands from fd 3 and writes replies to fd 4, as
// NUL-separated JSON. Skylight is the browser process, so it plugs both ends into itself: the
// protocol is reachable only from inside the app, never from a port other programs could open.

int g_pipeWrite = -1;
void (^g_devToolsHandler)(NSString*) = nil;
dispatch_queue_t g_pipeQueue = nil;

int MoveHigh(int fd) {
  int moved = fcntl(fd, F_DUPFD_CLOEXEC, 64);
  close(fd);
  return moved;
}

bool OpenDevToolsPipe() {
  int commands[2], replies[2];
  if (pipe(commands) != 0) return false;
  if (pipe(replies) != 0) return false;
  for (int* fd : {&commands[0], &commands[1], &replies[0], &replies[1]}) *fd = MoveHigh(*fd);
  // Something else already owns 3 or 4: don't take it from them.
  if (fcntl(3, F_GETFD) != -1 || fcntl(4, F_GETFD) != -1) return false;
  if (dup2(commands[0], 3) != 3 || dup2(replies[1], 4) != 4) return false;
  fcntl(3, F_SETFD, FD_CLOEXEC);
  fcntl(4, F_SETFD, FD_CLOEXEC);
  close(commands[0]);
  close(replies[1]);
  g_pipeWrite = commands[1];
  g_pipeQueue = dispatch_queue_create("skylight.devtools.write", DISPATCH_QUEUE_SERIAL);

  int readFD = replies[0];
  [NSThread detachNewThreadWithBlock:^{
    std::string buffer;
    char chunk[64 * 1024];
    ssize_t n;
    while ((n = read(readFD, chunk, sizeof chunk)) > 0) {
      buffer.append(chunk, static_cast<size_t>(n));
      size_t end;
      while ((end = buffer.find('\0')) != std::string::npos) {
        NSString* message = [[NSString alloc] initWithBytes:buffer.data() length:end encoding:NSUTF8StringEncoding];
        buffer.erase(0, end + 1);
        if (!message) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (g_devToolsHandler) g_devToolsHandler(message);
        });
      }
    }
  }];
  return true;
}

/// Browsers Chromium creates without Skylight asking (extension windows). Skylight decides
/// what to do with each once it knows where it's going.
class ForeignClient : public CefClient, public CefDisplayHandler, public CefLifeSpanHandler {
 public:
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    CEF_REQUIRE_UI_THREAD();
    RegisterBrowser(b);
  }

  void OnAddressChange(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> frame, const CefString& url) override {
    if (!frame->IsMain() || url.empty() || reported_.count(b->GetIdentifier())) return;
    reported_[b->GetIdentifier()] = true;
    if (!g_foreignHandler) return;
    SKForeignBrowser* foreign = [[SKForeignBrowser alloc] initWithBrowser:b];
    g_foreignHandler(foreign, ToNS(url));
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
    reported_.erase(b->GetIdentifier());
    UnregisterBrowser(b);
  }

 private:
  std::map<int, bool> reported_;
  IMPLEMENT_REFCOUNTING(ForeignClient);
};

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
 public:
  BrowserApp(SKEngineSettings* settings, void (^ready)(void))
      : useMockKeychain_(settings.useMockKeychain), ready_([ready copy]), foreign_(new ForeignClient) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;
    if (useMockKeychain_) command_line->AppendSwitch("use-mock-keychain");
    // Skylight draws its own UI; keep Chromium from adding background extras.
    command_line->AppendSwitch("disable-background-networking");
    // Add to CEF's own list rather than replacing it: Chrome-style windows (which extensions
    // open) crash without the features CEF turns off.
    std::string features = command_line->GetSwitchValue("disable-features").ToString();
    features += std::string(features.empty() ? "" : ",") + "MediaRouter,DialMediaRouteProvider";
    command_line->AppendSwitchWithValue("disable-features", features);
    // The DevTools pipe Skylight talks to itself over would mark every page as driven by
    // automation (navigator.webdriver), and sites like Google answer that with CAPTCHAs.
    std::string blink = command_line->GetSwitchValue("disable-blink-features").ToString();
    blink += std::string(blink.empty() ? "" : ",") + "AutomationControlled";
    command_line->AppendSwitchWithValue("disable-blink-features", blink);
  }

  CefRefPtr<CefClient> GetDefaultClient() override { return foreign_; }

  void OnContextInitialized() override {
    if (ready_) ready_();
    ready_ = nil;
  }

 private:
  bool useMockKeychain_;
  void (^ready_)(void);
  CefRefPtr<ForeignClient> foreign_;

  IMPLEMENT_REFCOUNTING(BrowserApp);
};

}  // namespace

CefRefPtr<CefListValue> CurrentScriptsList() {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  for (size_t i = 0; i < g_scripts.size(); ++i) list->SetString(i, g_scripts[i]);
  return list;
}

void RegisterBrowser(CefRefPtr<CefBrowser> browser) {
  g_browsers[browser->GetIdentifier()] = browser;
}

void UnregisterBrowser(CefRefPtr<CefBrowser> browser) {
  g_browsers.erase(browser->GetIdentifier());
  if (g_browsers.empty() && g_closeCompletion) {
    auto completion = g_closeCompletion;
    g_closeCompletion = nil;
    completion();
  }
}

}  // namespace skylight

#pragma mark - Engine

@implementation SKEngine

+ (BOOL)loadFramework {
  if (skylight::g_library) return YES;
  skylight::g_library = std::make_unique<CefScopedLibraryLoader>();
  return skylight::g_library->LoadInMain();
}

+ (BOOL)initializeWithSettings:(SKEngineSettings*)settings ready:(void (^)(void))ready {
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  std::vector<std::string> storage;
  for (NSString* a in args) storage.emplace_back(a.UTF8String);
  if (settings.enableDevToolsPipe && skylight::OpenDevToolsPipe()) {
    storage.emplace_back("--remote-debugging-pipe");
    // Lets the pipe install and remove extensions (Extensions.loadUnpacked).
    storage.emplace_back("--enable-unsafe-extension-debugging");
    // The only way in for profiles other than the default: Extensions.loadUnpacked ignores them.
    if (settings.extensionPaths.count > 0) {
      NSString* paths = [settings.extensionPaths componentsJoinedByString:@","];
      storage.emplace_back(std::string("--load-extension=") + paths.UTF8String);
    }
  }
  std::vector<char*> argv;
  for (auto& s : storage) argv.push_back(s.data());
  CefMainArgs mainArgs(static_cast<int>(argv.size()), argv.data());

  CefSettings cef;
  // Each helper sandboxes itself as it starts (SKHelperMain).
  cef.no_sandbox = false;
  cef.persist_session_cookies = true;
  cef.log_severity = LOGSEVERITY_WARNING;
  CefString(&cef.root_cache_path) = skylight::ToCef(settings.rootCachePath);
  // Chromium's own profile is Skylight's default one, so extensions run where its pages do.
  NSString* initial = settings.defaultProfilePath ?: [settings.rootCachePath stringByAppendingPathComponent:@"Default"];
  CefString(&cef.cache_path) = skylight::ToCef(initial);
  if (settings.logFilePath) CefString(&cef.log_file) = skylight::ToCef(settings.logFilePath);
  if (settings.remoteDebuggingPort > 0) cef.remote_debugging_port = static_cast<int>(settings.remoteDebuggingPort);
  CefString(&cef.locale) = "en-US";

  CefRefPtr<skylight::BrowserApp> app(new skylight::BrowserApp(settings, ready));
  return CefInitialize(mainArgs, cef, app.get(), nullptr);
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
}

+ (void)quitMessageLoop {
  CefQuitMessageLoop();
}

+ (void)shutdown {
  CefShutdown();
  skylight::g_library.reset();
}

+ (void)setPageScripts:(NSArray<NSString*>*)scripts {
  skylight::g_scripts.clear();
  for (NSString* s in scripts) skylight::g_scripts.emplace_back(s.UTF8String);

  // Existing renderer processes pick the new scripts up for their next navigation. DevTools have
  // a script of their own and don't take page scripts.
  for (auto& [id, browser] : skylight::g_browsers) {
    CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create(skylight::kScriptsMessage);
    msg->GetArgumentList()->SetList(0, skylight::CurrentScriptsList());
    auto frame = browser->GetMainFrame();
    if (frame && !frame->GetURL().ToString().starts_with("devtools:")) frame->SendProcessMessage(PID_RENDERER, msg);
  }
}

+ (void)closeAllBrowsersWithCompletion:(void (^)(void))completion {
  if (skylight::g_browsers.empty()) {
    completion();
    return;
  }
  skylight::g_closeCompletion = [completion copy];
  auto browsers = skylight::g_browsers;  // closing mutates the map
  for (auto& [id, browser] : browsers) browser->GetHost()->CloseBrowser(true);
}

+ (BOOL)hasDevToolsPipe {
  return skylight::g_pipeWrite >= 0;
}

+ (void)sendDevToolsMessage:(NSString*)json {
  if (skylight::g_pipeWrite < 0) return;
  NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
  int fd = skylight::g_pipeWrite;
  dispatch_async(skylight::g_pipeQueue, ^{
    std::string bytes(static_cast<const char*>(data.bytes), data.length);
    bytes.push_back('\0');
    size_t sent = 0;
    while (sent < bytes.size()) {
      ssize_t n = write(fd, bytes.data() + sent, bytes.size() - sent);
      if (n <= 0) return;
      sent += static_cast<size_t>(n);
    }
  });
}

+ (void)setDevToolsMessageHandler:(void (^)(NSString*))handler {
  skylight::g_devToolsHandler = [handler copy];
}

+ (void)setForeignBrowserHandler:(void (^)(SKForeignBrowser*, NSString*))handler {
  skylight::g_foreignHandler = [handler copy];
}

@end
