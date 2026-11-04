#import "CEFBridge.h"

#include <map>
#include <memory>

#include "Internal.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
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

#pragma mark - Browser-process app

namespace skylight {
namespace {

std::unique_ptr<CefScopedLibraryLoader> g_library;
std::vector<std::string> g_scripts;
std::map<int, CefRefPtr<CefBrowser>> g_browsers;
void (^g_closeCompletion)(void) = nil;

class BrowserApp : public CefApp, public CefBrowserProcessHandler {
 public:
  BrowserApp(SKEngineSettings* settings, void (^ready)(void))
      : useMockKeychain_(settings.useMockKeychain), ready_([ready copy]) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;
    if (useMockKeychain_) command_line->AppendSwitch("use-mock-keychain");
    // Skylight draws its own UI; keep Chromium from adding background extras.
    command_line->AppendSwitch("disable-background-networking");
    command_line->AppendSwitchWithValue("disable-features", "MediaRouter,DialMediaRouteProvider");
  }

  void OnContextInitialized() override {
    if (ready_) ready_();
    ready_ = nil;
  }

 private:
  bool useMockKeychain_;
  void (^ready_)(void);

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
  std::vector<char*> argv;
  for (auto& s : storage) argv.push_back(s.data());
  CefMainArgs mainArgs(static_cast<int>(argv.size()), argv.data());

  CefSettings cef;
  cef.no_sandbox = true;
  cef.persist_session_cookies = true;
  cef.log_severity = LOGSEVERITY_WARNING;
  CefString(&cef.root_cache_path) = skylight::ToCef(settings.rootCachePath);
  CefString(&cef.cache_path) = skylight::ToCef([settings.rootCachePath stringByAppendingPathComponent:@"Default"]);
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

  // Existing renderer processes pick the new scripts up for their next navigation.
  for (auto& [id, browser] : skylight::g_browsers) {
    CefRefPtr<CefProcessMessage> msg = CefProcessMessage::Create(skylight::kScriptsMessage);
    msg->GetArgumentList()->SetList(0, skylight::CurrentScriptsList());
    if (auto frame = browser->GetMainFrame()) frame->SendProcessMessage(PID_RENDERER, msg);
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

@end
