// A working model of Skylight's window. Nothing here loads a real site: pages are drawn in place.
(() => {
  const root = document.getElementById("demo");
  if (!root) return;

  const icon = {
    search: '<circle cx="7" cy="7" r="4.6"/><path d="m10.6 10.6 3.4 3.4"/>',
    sidebar: '<rect x="1.5" y="3" width="13" height="10" rx="2"/><path d="M6 3v10"/>',
    back: '<path d="M9.5 3 5 8l4.5 5"/>',
    forward: '<path d="m6.5 3 4.5 5-4.5 5"/>',
    reload: '<path d="M13 8a5 5 0 1 1-1.6-3.6L13 6V2.5"/>',
    plus: '<path d="M8 3v10M3 8h10"/>',
    close: '<path d="m4.5 4.5 7 7m0-7-7 7"/>',
    sun: '<circle cx="8" cy="8" r="2.8"/><path d="M8 1.5v1.6M8 12.9v1.6M1.5 8h1.6M12.9 8h1.6M3.4 3.4l1.1 1.1M11.5 11.5l1.1 1.1M3.4 12.6l1.1-1.1M11.5 4.5l1.1-1.1"/>',
    case: '<rect x="1.5" y="5" width="13" height="8.5" rx="2"/><path d="M5.5 5V3.5a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1V5"/>',
    undo: '<path d="M6 3 2.5 6.5 6 10"/><path d="M2.5 6.5H10a3.5 3.5 0 0 1 0 7H7"/>',
    clear: '<path d="M8 2v8m-3.5-3.5L8 10l3.5-3.5M3 13.5h10"/>',
  };
  const svg = (name) => `<svg viewBox="0 0 16 16" aria-hidden="true">${icon[name]}</svg>`;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

  let nextID = 0;
  const tab = (title, host, blurb) => ({ id: `t${nextID++}`, title, host, blurb });

  const spaces = {
    personal: {
      name: "Personal", symbol: "sun",
      favorites: [tab("GitHub", "github.com", "Skylight is open source. Read the code, file an issue, or send a fix."),
                  tab("YouTube", "youtube.com", "Video keeps playing in a small window when you switch tabs."),
                  tab("Hacker News", "news.ycombinator.com", "Pin the sites you read every day, and they stay put."),
                  tab("Wikipedia", "wikipedia.org", "One article leads to twelve. Tabs you stop using tidy themselves away.")],
      pinned: [tab("SwiftUI Documentation", "developer.apple.com", "Pinned tabs stay in their Space, ready when you come back."),
               tab("WebKit", "webkit.org", "Skylight is built on WebKit, the engine behind Safari, so video just plays.")],
      today: [tab("Example Domain", "example.com", "Today's tabs live here, and they're easy to clear when you're done."),
              tab("Swift Programming Language", "swift.org", "Skylight's interface is written in Swift and made for the Mac."),
              tab("Model Context Protocol", "modelcontextprotocol.io", "Agents can work in your tabs, and they ask before they act.")],
    },
    work: {
      name: "Work", symbol: "case",
      favorites: [tab("Mail", "mail.example.com", "Each Space keeps its own tabs, and it can have its own sign-ins."),
                  tab("Calendar", "calendar.example.com", "Work stays in Work. Switch Spaces and it's all out of sight."),
                  tab("Docs", "docs.example.com", "Give a Space its own theme, so you always know where you are."),
                  tab("Notes", "notes.example.com", "Everything's a keystroke away from the command bar.")],
      pinned: [tab("Team Handbook", "docs.example.com", "Pinned tabs stay in their Space, ready when you come back.")],
      today: [tab("Q4 Roadmap", "docs.example.com", "Today's tabs live here, and they're easy to clear when you're done."),
              tab("Design Review", "video.example.com", "Split two tabs side by side when you need both.")],
    },
  };
  for (const space of Object.values(spaces)) Object.assign(space, { selected: null, past: [], future: [], closed: [] });

  const commands = [
    { title: "Reopen closed tab", symbol: "undo", shown: () => current().closed.length > 0, run: reopen },
    { title: "Clear Today tabs", symbol: "clear", shown: () => current().today.length > 0, run: clearToday },
    { title: "Toggle sidebar", symbol: "sidebar", shown: () => true, run: () => { dismiss(); setSidebar(!sidebar); } },
  ];

  let spaceID = "personal";
  let sidebar = root.clientWidth >= 640;
  let barOpen = true;
  let query = "";
  let active = 0;
  let results = [];

  const narrow = () => root.clientWidth < 640;
  const current = () => spaces[spaceID];
  const everyTab = (s = current()) => [...s.favorites, ...s.pinned, ...s.today];
  const selected = () => everyTab().find((t) => t.id === current().selected) ?? null;

  root.innerHTML = `
    <div class="win">
      <picture class="sky">
        <source media="(prefers-color-scheme: dark)" srcset="theme-dark.jpg">
        <img src="theme-light.jpg" alt="">
      </picture>
      <div class="controls">
        <div class="lights" aria-hidden="true"><i></i><i></i><i></i></div>
        <button data-do="sidebar" aria-label="Toggle sidebar">${svg("sidebar")}</button>
        <button data-do="back" aria-label="Back">${svg("back")}</button>
        <button data-do="forward" aria-label="Forward">${svg("forward")}</button>
        <button data-do="reload" aria-label="Reload">${svg("reload")}</button>
      </div>
      <nav class="side" aria-label="Tabs">
        <div class="lists"></div>
        <div class="spaces"></div>
      </nav>
      <div class="content">
        <div class="sheet">
          <button class="bartop" data-do="bar" aria-label="Search or enter website name"></button>
          <div class="stage"></div>
        </div>
      </div>
      <div class="scrim" data-do="dismiss"></div>
      <div class="bar">
        <label class="field">${svg("search")}
          <input type="text" placeholder="Search or enter website name" aria-label="Search or enter website name"
                 role="combobox" aria-expanded="true" aria-controls="demo-list" aria-autocomplete="list"
                 autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" enterkeyhint="go">
        </label>
        <div class="list" id="demo-list" role="listbox" aria-label="Suggestions"></div>
      </div>
    </div>`;

  const win = root.querySelector(".win");
  const lists = root.querySelector(".lists");
  const switcher = root.querySelector(".spaces");
  const top = root.querySelector(".bartop");
  const stage = root.querySelector(".stage");
  const scrim = root.querySelector(".scrim");
  const input = root.querySelector("input");
  const list = root.querySelector(".list");
  const button = (name) => root.querySelector(`[data-do="${name}"]`);

  // Each page gets its own crop of the theme, chosen by its title so it looks the same every time.
  function page(t) {
    const seed = [...t.title].reduce((n, c) => (n * 31 + c.charCodeAt(0)) % 9973, 7);
    const turn = [-36, -14, 0, 16, 34][seed % 5];
    return `<div class="art" style="--x:${48 + seed % 30}%;--y:${36 + (seed >> 3) % 32}%;--turn:${turn}deg"></div>
      <h2>${esc(t.title)}</h2><p>${esc(t.blurb)}</p>`;
  }

  function row(t, closable) {
    return `<div class="row">
      <button data-tab="${t.id}" aria-current="${current().selected === t.id}"><span class="badge">${esc(t.title[0].toUpperCase())}</span><span>${esc(t.title)}</span></button>
      ${closable ? `<button class="x" data-close="${t.id}" aria-label="Close ${esc(t.title)}">${svg("close")}</button>` : ""}
    </div>`;
  }

  function renderLists() {
    const s = current();
    const favorites = s.favorites.map((t) =>
      `<button data-tab="${t.id}" aria-label="${esc(t.title)}" aria-current="${s.selected === t.id}"><span class="badge">${esc(t.title[0])}</span></button>`).join("");
    lists.innerHTML = `
      <div class="favs">${favorites}</div>
      <div class="head">${svg(s.symbol)}<span>${esc(s.name)}</span></div>
      ${s.pinned.map((t) => row(t, false)).join("")}
      <div class="head"><span>Today</span>${s.today.length ? '<button class="clear" data-do="clear">Clear</button>' : ""}</div>
      <div class="row"><button data-do="new"><span class="badge">${svg("plus")}</span><span>New Tab</span></button></div>
      ${s.today.map((t) => row(t, true)).join("")}`;
    switcher.innerHTML = Object.entries(spaces).map(([id, space]) =>
      `<button data-space="${id}" aria-pressed="${id === spaceID}" aria-label="${space.name}">${svg(space.symbol)}</button>`).join("");
  }

  function renderPage() {
    const t = selected();
    const s = current();
    win.dataset.open = String(!!t);
    win.dataset.look = spaceID;
    top.innerHTML = t ? `<b>${esc(t.host)}</b><span>${esc(t.title)}</span>` : "<span>New Tab</span>";
    if (stage.dataset.page !== (t?.id ?? "")) {
      stage.dataset.page = t?.id ?? "";
      stage.className = t ? "stage page" : "stage";
      stage.innerHTML = t ? page(t) : "";
    }
    button("back").disabled = !s.past.length;
    button("forward").disabled = !s.future.length;
    button("reload").disabled = !t;
  }

  function suggest() {
    const q = query.trim().toLowerCase();
    const limit = narrow() ? 5 : 8;
    const found = everyTab().filter((t) => !q || t.title.toLowerCase().includes(q) || t.host.includes(q));
    const tabs = found.map((t) => ({ title: t.title, badge: t.title[0].toUpperCase(), hint: "Switch to tab", run: () => select(t.id) }));
    const actions = commands.filter((c) => c.shown() && c.title.toLowerCase().includes(q))
      .map((c) => ({ title: c.title, symbol: c.symbol, run: c.run }));
    if (!q) return [...tabs.slice(0, limit - actions.length), ...actions];
    const text = query.trim();
    const address = /^[^\s/]+\.[a-z]{2,}(\/\S*)?$/i.test(text);
    const web = address
      ? { title: `Go to ${text}`, symbol: "search", run: () => open(text.split("/")[0].toLowerCase()) }
      : { title: `Search for “${text}”`, symbol: "search", run: () => open(text, "search") };
    return [...tabs, ...actions].slice(0, limit - 1).concat(web);
  }

  function renderBar() {
    win.dataset.bar = String(barOpen || !selected());
    scrim.hidden = !selected();
    results = suggest();
    active = Math.min(active, results.length - 1);
    list.innerHTML = results.map((r, i) => `
      <div class="opt" id="demo-opt-${i}" role="option" data-i="${i}" aria-selected="false">
        ${r.badge ? `<span class="badge">${esc(r.badge)}</span>` : svg(r.symbol)}
        <span>${esc(r.title)}</span>
        ${r.hint ? `<em>${r.hint}</em>` : ""}
      </div>`).join("");
    highlight(active);
  }

  function highlight(i) {
    active = i;
    list.querySelectorAll(".opt").forEach((el, n) => {
      el.classList.toggle("on", n === i);
      el.setAttribute("aria-selected", String(n === i));
    });
    input.setAttribute("aria-activedescendant", `demo-opt-${i}`);
  }

  function render() {
    renderLists();
    renderPage();
    renderBar();
  }

  function dismiss() {
    barOpen = false;
    query = input.value = "";
    active = 0;
  }

  function select(id, remember = true) {
    const s = current();
    if (remember && s.selected !== id) {
      s.past.push(s.selected);
      s.future = [];
    }
    s.selected = id;
    dismiss();
    if (narrow()) setSidebar(false);
    render();
  }

  function open(title, host = title) {
    const t = tab(title, host, "This is only a model of Skylight, so nothing loads here. Download it and this goes somewhere real.");
    current().today.push(t);
    select(t.id);
  }

  function newTab() {
    if (current().selected) select(null);
    if (narrow()) return;
    input.focus({ preventScroll: true });
  }

  function close(id) {
    const s = current();
    const index = s.today.findIndex((t) => t.id === id);
    s.closed.push(...s.today.splice(index, 1));
    forget(s, [id]);
    if (s.selected === id) s.selected = s.today[Math.min(index, s.today.length - 1)]?.id ?? null;
    render();
  }

  function clearToday() {
    const s = current();
    const ids = s.today.map((t) => t.id);
    s.closed.push(...s.today.splice(0));
    forget(s, ids);
    if (ids.includes(s.selected)) s.selected = null;
    dismiss();
    render();
  }

  function forget(s, ids) {
    s.past = s.past.filter((id) => !ids.includes(id));
    s.future = s.future.filter((id) => !ids.includes(id));
  }

  function reopen() {
    const s = current();
    const t = s.closed.pop();
    s.today.push(t);
    select(t.id);
  }

  function go(from, to) {
    to.push(current().selected);
    select(from.pop(), false);
  }

  function setSidebar(on) {
    sidebar = on;
    win.dataset.sidebar = on ? "open" : "closed";
    renderBar();
  }

  function switchSpace(id) {
    if (id === spaceID) return;
    const order = Object.keys(spaces);
    const forward = order.indexOf(id) > order.indexOf(spaceID);
    spaceID = id;
    dismiss();
    if (narrow()) setSidebar(false);
    render();
    lists.classList.remove("swap-next", "swap-back");
    void lists.offsetWidth;
    lists.classList.add(forward ? "swap-next" : "swap-back");
  }

  function showBar() {
    barOpen = true;
    renderBar();
    input.focus({ preventScroll: true });
  }

  const actions = {
    sidebar: () => setSidebar(!sidebar),
    back: () => go(current().past, current().future),
    forward: () => go(current().future, current().past),
    reload: () => stage.animate([{ opacity: 0 }, { opacity: 1 }], 160),
    bar: showBar,
    new: newTab,
    clear: clearToday,
    dismiss: () => { dismiss(); render(); },
  };

  root.addEventListener("click", (event) => {
    const hit = (selector) => event.target.closest(selector);
    const option = hit("[data-i]");
    if (option) return results[Number(option.dataset.i)]?.run();
    const closing = hit("[data-close]");
    if (closing) return close(closing.dataset.close);
    const opened = hit("[data-tab]");
    if (opened) return select(opened.dataset.tab);
    const space = hit("[data-space]");
    if (space) return switchSpace(space.dataset.space);
    const action = hit("[data-do]");
    if (action) actions[action.dataset.do]();
  });

  list.addEventListener("mousedown", (event) => event.preventDefault());
  list.addEventListener("mousemove", (event) => {
    const option = event.target.closest("[data-i]");
    if (option && Number(option.dataset.i) !== active) highlight(Number(option.dataset.i));
  });

  input.addEventListener("input", () => {
    query = input.value;
    active = 0;
    renderBar();
  });

  input.addEventListener("keydown", (event) => {
    const move = { ArrowDown: 1, ArrowUp: -1 }[event.key];
    if (move) {
      event.preventDefault();
      highlight((active + move + results.length) % results.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      results[active]?.run();
    } else if (event.key === "Escape") {
      dismiss();
      render();
      input.blur();
    }
  });

  // Typing anywhere on the page goes to the bar, as long as the window is on screen.
  document.addEventListener("keydown", (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.key.length !== 1 || event.key === " ") return;
    const focused = document.activeElement;
    if (focused === input || (focused && focused !== document.body && !root.contains(focused))) return;
    const box = root.getBoundingClientRect();
    if (box.bottom < 0 || box.top > innerHeight) return;
    showBar();
  });

  win.dataset.sidebar = sidebar ? "open" : "closed";
  render();
})();
