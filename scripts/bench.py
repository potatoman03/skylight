#!/usr/bin/env python3
"""Measures Skylight: bundle size, launch time, memory and idle CPU.

    scripts/bundle.sh release && scripts/bench.py

Runs the built app against a throwaway data folder (your tabs are never touched), once per
scenario, and prints a table. Memory is each process's physical footprint (what Activity Monitor
calls Memory), summed over Skylight and its helpers. CPU is the share of one core used while idle.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.environ.get("SKYLIGHT_APP", os.path.join(ROOT, "build/Skylight.app"))
EXE = os.path.join(APP, "Contents/MacOS/Skylight")
RUNS = int(os.environ.get("RUNS", "3"))
IDLE_SECONDS = 10
NOW = "2026-01-01T00:00:00Z"


def du(path):
    out = subprocess.run(["du", "-sk", path], capture_output=True, text=True).stdout.split()
    return int(out[0]) * 1024 if out else 0


def mb(n):
    return f"{n / 1024 / 1024:.0f} MB"


def tree(pid):
    rows = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.split("\n")
    children = {}
    for row in rows:
        parts = row.split()
        if len(parts) == 2:
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, stack = [], [pid]
    while stack:
        p = stack.pop()
        found.append(p)
        stack += children.get(p, [])
    return found


def footprint(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint: ([\d.]+) (B|KB|MB|GB)", out)
    if not m:
        return 0
    return float(m.group(1)) * {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}[m.group(2)]


def cpu_seconds(pids):
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    total = 0.0
    for t in out.split():
        parts = [float(x) for x in t.replace("-", ":").split(":")]
        total += sum(v * 60 ** i for i, v in enumerate(reversed(parts)))
    return total


def seed(folder, tabs, rays):
    tab_ids = [f"t{i}" for i in range(len(tabs))]
    state = {
        "version": 1, "profiles": [{"id": "default", "name": "Default"}], "favorites": [], "closedTabs": [],
        "spaces": [{"id": "s", "name": "Personal", "hue": 0.58, "profileID": "default", "pinned": [],
                    "today": tab_ids, "selectedTabID": tab_ids[0] if tab_ids else None}],
        "tabs": {i: {"id": i, "url": u, "title": "", "createdAt": NOW, "lastActiveAt": NOW} for i, u in zip(tab_ids, tabs)},
        "activeSpaceID": "s",
    }
    with open(os.path.join(folder, "state.json"), "w") as f:
        json.dump(state, f)
    with open(os.path.join(folder, "preferences.json"), "w") as f:
        json.dump({"appearance": "light", "godRays": rays}, f)


def run(name, tabs, rays):
    folder = os.path.realpath(tempfile.mkdtemp(prefix="skylight-bench-"))
    seed(folder, tabs, rays)
    env = dict(os.environ, SKYLIGHT_DEV="1", SKYLIGHT_DATA_DIR=folder)
    start = time.monotonic()
    proc = subprocess.Popen([EXE], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    launch = None
    while time.monotonic() - start < 20:
        if window_ready(proc.pid):
            launch = time.monotonic() - start
            break
        time.sleep(0.02)
    time.sleep(6)  # Let pages load and settle.
    visible = window_state(proc.pid) == 2
    pids = tree(proc.pid)
    memory = sum(footprint(p) for p in pids)
    c0 = cpu_seconds(pids)
    time.sleep(IDLE_SECONDS)
    pids = tree(proc.pid)
    cpu = (cpu_seconds(pids) - c0) / IDLE_SECONDS * 100
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
    time.sleep(2)
    shutil.rmtree(folder, ignore_errors=True)
    return {"name": name, "launch": launch, "memory": memory, "cpu": cpu, "processes": len(pids), "visible": visible}


_LISTER = None


def window_ready(pid):
    """True once Skylight has a big on-screen window. Uses a compiled helper: `swift -e` is too slow to poll."""
    global _LISTER
    if _LISTER is None:
        src = os.path.join(tempfile.gettempdir(), "skylight-bench-windows.swift")
        _LISTER = os.path.join(tempfile.gettempdir(), "skylight-bench-windows")
        with open(src, "w") as f:
            f.write(
                "import CoreGraphics\n"
                "let pid = Int(CommandLine.arguments[1])!\n"
                "let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]\n"
                "let mine = l.filter { ($0[\"kCGWindowOwnerPID\"] as? Int) == pid && ($0[\"kCGWindowLayer\"] as? Int) == 0 && "
                "(($0[\"kCGWindowBounds\"] as? [String: Any])?[\"Width\"] as? Double ?? 0) > 600 }\n"
                "print(mine.isEmpty ? 0 : mine.contains { ($0[\"kCGWindowIsOnscreen\"] as? Bool) == true } ? 2 : 1)\n")
        subprocess.run(["swiftc", "-O", src, "-o", _LISTER], check=True, capture_output=True)
    return window_state(pid) > 0


def window_state(pid):
    """0: no window yet, 1: window exists but isn't on screen (another desktop), 2: visible."""
    window_ready(0) if _LISTER is None else None
    out = subprocess.run([_LISTER, str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out or 0)


def median(values):
    values = sorted(v for v in values if v is not None)
    return values[len(values) // 2] if values else None


def main():
    if not os.path.exists(EXE):
        sys.exit(f"Build the app first: scripts/bundle.sh release ({EXE} is missing)")
    window_ready(0)  # Compile the helper before timing anything.

    fw = os.path.join(APP, "Contents/Frameworks")
    cef = os.path.join(fw, "Chromium Embedded Framework.framework")
    print("Bundle")
    print(f"  Skylight.app            {mb(du(APP))}")
    print(f"  Chromium (CEF)          {mb(du(cef))}")
    print(f"  Skylight's own code     {mb(os.path.getsize(EXE))} (main binary)")
    helpers = [d for d in os.listdir(fw) if d.endswith(".app")]
    print(f"  Helper apps             {len(helpers)} × {mb(du(os.path.join(fw, helpers[0])))}" if helpers else "")
    for other in ["/Applications/Arc.app", "/Applications/Google Chrome.app", "/Applications/Microsoft Edge.app",
                  "/Applications/Brave Browser.app", "/Applications/Firefox.app"]:
        if os.path.exists(other):
            print(f"  for comparison: {os.path.basename(other):<14} {mb(du(other))}")
    print()

    scenarios = [
        ("Empty tab, sky animating", [], True),
        ("Empty tab, sky off", [], False),
        ("1 light page (example.com)", ["https://example.com"], True),
        ("1 heavy page (swift.org)", ["https://www.swift.org"], True),
        ("5 tabs, 1 awake", ["https://example.com", "https://www.swift.org", "https://github.com",
                             "https://en.wikipedia.org", "https://news.ycombinator.com"], True),
    ]
    print(f"Runtime (median of {RUNS} runs, {IDLE_SECONDS}s idle sample)")
    print(f"  {'scenario':<30} {'window':>8} {'memory':>9} {'idle CPU':>9} {'procs':>6}  visible")
    results = {}
    for name, tabs, rays in scenarios:
        runs = [run(name, tabs, rays) for _ in range(RUNS)]
        launch = median([r["launch"] for r in runs])
        memory = median([r["memory"] for r in runs])
        cpu = median([r["cpu"] for r in runs])
        procs = median([r["processes"] for r in runs])
        visible = all(r["visible"] for r in runs)
        results[name] = {"launch_s": launch, "memory_bytes": memory, "idle_cpu_percent": cpu, "processes": procs,
                         "window_visible": visible}
        shown = "-" if launch is None else f"{launch:.2f}s"
        print(f"  {name:<30} {shown:>8} {mb(memory):>9} {cpu:>8.1f}% {procs:>6}  {'yes' if visible else 'no (sky paused)'}")
    out = os.path.join(ROOT, "build/bench.json")
    with open(out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved {out}")


if __name__ == "__main__":
    main()
