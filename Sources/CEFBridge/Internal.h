// Shared C++ helpers for the bridge. Not part of the public header.
#pragma once

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_values.h"

namespace skylight {

/// Process message that carries the current page scripts to renderer processes.
inline constexpr const char kScriptsMessage[] = "skylight.scripts";
/// Key in a browser's extra_info holding the page scripts.
inline constexpr const char kScriptsKey[] = "scripts";

inline NSString* ToNS(const CefString& s) {
  std::string utf8 = s.ToString();
  return [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding] ?: @"";
}

inline CefString ToCef(NSString* s) {
  return CefString(s ? std::string(s.UTF8String) : std::string());
}

/// The page scripts, as a CEF list.
CefRefPtr<CefListValue> CurrentScriptsList();

/// Every live browser (tabs and popups), so the engine can broadcast and shut down cleanly.
void RegisterBrowser(CefRefPtr<CefBrowser> browser);
void UnregisterBrowser(CefRefPtr<CefBrowser> browser);

}  // namespace skylight
