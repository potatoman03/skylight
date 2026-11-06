import Foundation

/// The script that puts saved values into a page's form. It's sent whole with each fill, so a page
/// has nothing of Skylight's to replace beforehand, and nothing stays behind afterwards.
public enum AutofillScript {
    /// Whether a page may be filled. A card's number stays off plain http, wherever it's from.
    public static func accepts(_ url: URL?, card: Bool) -> Bool {
        guard let url else { return false }
        if url.scheme == "https" { return true }
        return url.scheme == "http" && (!card || ["localhost", "127.0.0.1"].contains(url.host() ?? ""))
    }

    /// Fills the page's visible, empty fields, and evaluates to how many it filled.
    public static func fill(_ fields: [String: String]) -> String {
        let values = (try? JSONEncoder().encode(fields)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        ((values) => {
          const named = {
            'given-name': 'given', 'family-name': 'family', 'name': 'name', 'organization': 'organization',
            'address-line1': 'line1', 'address-line2': 'line2', 'street-address': 'line1',
            'address-level2': 'city', 'address-level1': 'state', 'postal-code': 'zip',
            'country': 'country', 'country-name': 'country', 'tel': 'tel', 'email': 'email',
            'cc-name': 'cc-name', 'cc-number': 'cc-number', 'cc-exp': 'cc-exp',
            'cc-exp-month': 'cc-exp-month', 'cc-exp-year': 'cc-exp-year',
          };
          const guessed = [
            ['cc-number', /card.?(number|no|num)|cc.?(number|num)|cardnumber/],
            ['cc-name', /(name.*card|card.*name|cc.?name|cardholder)/],
            ['cc-exp-month', /exp.*(month|mm\\b)|cc.?month/],
            ['cc-exp-year', /exp.*(year|yy)|cc.?year/],
            ['cc-exp', /expir|\\bexp\\b|mm.?.?yy/],
            ['email', /e.?mail/], ['tel', /phone|\\btel\\b|mobile/],
            ['given', /first.?name|given.?name|fname/], ['family', /last.?name|family.?name|surname|lname/],
            ['organization', /company|organi[sz]ation/],
            ['line2', /(address|addr).?(line)?.?2|\\bapt\\b|suite|\\bunit\\b/],
            ['line1', /(address|addr).?(line)?.?1|street|^(address|addr)$|shipping.?address|billing.?address/],
            ['city', /\\bcity\\b|\\btown\\b|locality/], ['state', /\\bstate\\b|province|\\bregion\\b/],
            ['zip', /\\bzip|postal|postcode/], ['country', /country/], ['name', /\\bname\\b/],
          ];
          const shown = (el) => {
            const box = el.getBoundingClientRect();
            const style = getComputedStyle(el);
            return box.width > 1 && box.height > 1 && style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0.05;
          };
          const label = (el) => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
            ...(el.labels ? [...el.labels].map((l) => l.textContent) : [])].filter(Boolean).join(' ').toLowerCase();
          const kind = (el) => {
            const tokens = (el.getAttribute('autocomplete') || '').toLowerCase().trim().split(/\\s+/);
            const token = tokens.find((t) => named[t]);
            if (token) return named[token];
            const text = label(el);
            return guessed.find(([, rule]) => rule.test(text))?.[0];
          };
          const setter = (el) => Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
          const pick = (el, value, field) => {
            const wanted = value.toLowerCase();
            const forms = [wanted, wanted.replace(/^0/, '')];
            if (field === 'cc-exp-year') forms.push(wanted.slice(-2));
            const option = [...el.options].find((o) => [o.value.toLowerCase(), o.text.trim().toLowerCase()].some(
              (text) => forms.includes(text)));
            if (!option) return false;
            el.value = option.value;
            return true;
          };
          let filled = 0;
          for (const el of document.querySelectorAll('input, select, textarea')) {
            if (el.disabled || el.readOnly || el.value && el.tagName !== 'SELECT' || !shown(el)) continue;
            if (['password', 'hidden', 'checkbox', 'radio', 'file', 'submit', 'button'].includes(el.type)) continue;
            const field = kind(el);
            const value = values[field];
            if (!value) continue;
            if (el.tagName === 'SELECT') { if (!pick(el, value, field)) continue; } else { setter(el).call(el, value); }
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            filled += 1;
          }
          return filled;
        })(\(values))
        """
    }
}
