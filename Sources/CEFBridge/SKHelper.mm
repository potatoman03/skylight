// Runs inside the "Skylight Helper" sub-processes. The renderer side injects page scripts at
// document start and hosts the renderer half of the message router (window.cefQuery).

#import "CEFBridge.h"

#include "Internal.h"
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

namespace skylight {
namespace {

class RendererApp : public CefApp, public CefRenderProcessHandler {
 public:
  RendererApp() {
    CefMessageRouterConfig config;
    router_ = CefMessageRouterRendererSide::Create(config);
  }

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info) override {
    if (extra_info && extra_info->HasKey(kScriptsKey)) SetScripts(extra_info->GetList(kScriptsKey));
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    router_->OnContextCreated(browser, frame, context);
    if (!frame->IsMain()) return;
    // Evaluated synchronously, before any of the page's own scripts.
    for (const auto& script : scripts_) {
      CefRefPtr<CefV8Value> result;
      CefRefPtr<CefV8Exception> exception;
      context->Eval(script, "skylight://page-scripts", 1, result, exception);
    }
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    router_->OnContextReleased(browser, frame, context);
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source,
                                CefRefPtr<CefProcessMessage> message) override {
    if (message->GetName() == kScriptsMessage) {
      SetScripts(message->GetArgumentList()->GetList(0));
      return true;
    }
    return router_->OnProcessMessageReceived(browser, frame, source, message);
  }

 private:
  void SetScripts(CefRefPtr<CefListValue> list) {
    scripts_.clear();
    if (!list) return;
    for (size_t i = 0; i < list->GetSize(); ++i) scripts_.push_back(list->GetString(i));
  }

  std::vector<CefString> scripts_;
  CefRefPtr<CefMessageRouterRendererSide> router_;

  IMPLEMENT_REFCOUNTING(RendererApp);
};

}  // namespace
}  // namespace skylight

int SKHelperMain(int argc, char* argv[]) {
  // Lock the process down (Chromium's seatbelt sandbox) before it loads the engine or touches
  // any web content: a page that breaks the renderer is then still boxed in.
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  CefMainArgs args(argc, argv);
  CefRefPtr<skylight::RendererApp> app(new skylight::RendererApp);
  return CefExecuteProcess(args, app.get(), nullptr);
}
