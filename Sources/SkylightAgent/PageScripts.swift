import Foundation
import SkylightCore

/// JavaScript that agents use to read and operate pages. Expressions return JSON.
public enum AgentPageScripts {
    /// A compact view of the page: text plus numbered interactive elements.
    /// Elements get a `data-skylight-ref` attribute so `click`/`type` can find them again.
    public static let snapshot = """
    (() => {
      document.querySelectorAll('[data-skylight-ref]').forEach((el) => el.removeAttribute('data-skylight-ref'));
      const selector = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[role=option],[role=switch],[contenteditable=""],[contenteditable=true]';
      const roles = { A: 'link', BUTTON: 'button', SELECT: 'select', TEXTAREA: 'textbox', SUMMARY: 'summary' };
      const elements = [];
      let n = 0;
      for (const el of document.querySelectorAll(selector)) {
        const box = el.getBoundingClientRect();
        if (box.width < 1 || box.height < 1) continue;
        const style = getComputedStyle(el);
        if (style.visibility === 'hidden' || style.display === 'none') continue;
        const ref = String(++n);
        el.setAttribute('data-skylight-ref', ref);
        const role = el.getAttribute('role') || roles[el.tagName] || (el.tagName === 'INPUT' ? (el.type || 'text') : el.tagName.toLowerCase());
        // What's typed in a password or card field never leaves the page.
        const secret = el.type === 'password' || /(^|\\s)(current-password|new-password|one-time-code|cc-)/.test(el.autocomplete || '');
        const name = (el.getAttribute('aria-label') || el.innerText || (secret ? '' : el.value) || el.placeholder || el.title || el.getAttribute('alt') || '')
          .trim().replace(/\\s+/g, ' ').slice(0, 100);
        const item = { ref, role, name };
        if (el.href) item.href = el.href;
        if (el.disabled) item.disabled = true;
        if (box.bottom < 0 || box.top > innerHeight) item.offscreen = true;
        elements.push(item);
        if (elements.length >= 400) break;
      }
      const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n').slice(0, 24000);
      return { url: location.href, title: document.title, text, elements };
    })()
    """

    public static func click(ref: String) -> String {
        """
        (() => {
          const el = document.querySelector('[data-skylight-ref=' + \(JSONValue.jsLiteral(ref)) + ']');
          if (!el) throw new Error('No element with ref \(ref). Call read_page again; the page may have changed.');
          el.scrollIntoView({ block: 'center', inline: 'center' });
          el.focus({ preventScroll: true });
          el.click();
          return { clicked: \(JSONValue.jsLiteral(ref)), name: (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().slice(0, 100) };
        })()
        """
    }

    public static func type(ref: String, text: String, submit: Bool) -> String {
        """
        (() => {
          const el = document.querySelector('[data-skylight-ref=' + \(JSONValue.jsLiteral(ref)) + ']');
          if (!el) throw new Error('No element with ref \(ref). Call read_page again; the page may have changed.');
          const text = \(JSONValue.jsLiteral(text));
          el.scrollIntoView({ block: 'center' });
          el.focus();
          if (el.isContentEditable) {
            document.execCommand('selectAll', false);
            document.execCommand('insertText', false, text);
          } else {
            const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
              : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(el, text);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          if (\(submit ? "true" : "false")) {
            const form = el.form || el.closest('form');
            if (form && form.requestSubmit) form.requestSubmit();
            else el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
          }
          return { typed: text.length, into: \(JSONValue.jsLiteral(ref)) };
        })()
        """
    }

    public static func scroll(by pixels: Int) -> String {
        "(() => { window.scrollBy({ top: \(pixels), behavior: 'instant' }); return { scrollY: Math.round(scrollY), height: document.documentElement.scrollHeight }; })()"
    }
}

/// WebMCP: lets sites register tools for agents through `navigator.modelContext`
/// (the W3C Web Machine Learning community group draft). Skylight provides the API itself and
/// forwards whatever a page registers to the tool hub.
public enum WebMCP {
    /// Message type a page posts when its tool list changes.
    public static let toolsMessageType = "webmcp.tools"

    public static let polyfill = """
    (() => {
      if (navigator.modelContext || !window.__skylight) return;
      const tools = new Map();
      const describe = (t) => ({
        name: t.name,
        description: String(t.description || ''),
        inputSchema: t.inputSchema || { type: 'object', properties: {} },
        readOnly: !!(t.annotations && t.annotations.readOnlyHint),
      });
      let queued = false;
      const announce = () => {
        if (queued) return;
        queued = true;
        queueMicrotask(() => {
          queued = false;
          window.__skylight.post({ type: '\(toolsMessageType)', url: location.href, tools: [...tools.values()].map(describe) }).catch(() => {});
        });
      };
      const add = (tool) => {
        if (!tool || typeof tool.name !== 'string' || typeof tool.execute !== 'function') {
          throw new TypeError('A tool needs a name and an execute function.');
        }
        tools.set(tool.name, tool);
      };
      const modelContext = Object.freeze({
        registerTool(tool) {
          add(tool);
          announce();
          return { unregister: () => { tools.delete(tool.name); announce(); } };
        },
        unregisterTool(name) { tools.delete(name); announce(); },
        provideContext(context = {}) {
          tools.clear();
          (context.tools || []).forEach(add);
          announce();
        },
        clearContext() { tools.clear(); announce(); },
      });
      Object.defineProperty(navigator, 'modelContext', { value: modelContext, configurable: false });
      Object.defineProperty(window, '__skylightWebMCP', {
        value: Object.freeze({
          async call(name, input) {
            const tool = tools.get(name);
            if (!tool) throw new Error('This page no longer offers a tool named ' + name + '.');
            const client = { requestUserInteraction: async (fn) => fn() };
            return await tool.execute(input || {}, client);
          },
        }),
        configurable: false,
      });
      document.addEventListener('DOMContentLoaded', announce, { once: true });
    })();
    """

    /// A tool a page registered.
    public struct PageTool: Equatable, Sendable {
        public var name: String
        public var description: String
        public var inputSchema: JSONValue
        public var readOnly: Bool

        public init(name: String, description: String, inputSchema: JSONValue, readOnly: Bool) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.readOnly = readOnly
        }

        public init?(json: JSONValue) {
            guard let name = json["name"]?.stringValue, !name.isEmpty else { return nil }
            self.init(name: name, description: json["description"]?.stringValue ?? "",
                      inputSchema: json["inputSchema"] ?? ["type": "object", "properties": [:]],
                      readOnly: json["readOnly"]?.boolValue ?? false)
        }
    }

    public static func parseTools(_ message: JSONValue) -> [PageTool] {
        (message["tools"]?.arrayValue ?? []).compactMap(PageTool.init(json:))
    }

    public static func call(name: String, input: JSONValue) -> String {
        "window.__skylightWebMCP.call(\(JSONValue.jsLiteral(name)), \(input.serialized()))"
    }

    /// Tool names MCP accepts: letters, digits, `_` and `-`.
    public static func exposedName(host: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        }
        return String("site_\(clean(host))__\(clean(tool))".prefix(64))
    }
}
