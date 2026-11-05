import Foundation
import Observation
import SkylightCore
import SkylightEngine

/// Media in tabs: what's playing (for the sidebar's controls), Picture in Picture, and taking a
/// playing video along in Picture in Picture when you switch away from its tab.
@MainActor
@Observable
public final class MediaService {
    public struct State: Equatable, Sendable {
        /// Something is playing.
        public var playing = false
        /// Everything playing is muted.
        public var muted = false
        /// The page has a video that could go into Picture in Picture.
        public var hasVideo = false
        public var inPictureInPicture = false
    }

    public private(set) var states: [TabID: State] = [:]

    /// Finds a tab's page, if it's awake.
    @ObservationIgnored var page: @MainActor (TabID) -> WebPage? = { _ in nil }
    @ObservationIgnored var autoPictureInPicture: @MainActor () -> Bool = { true }
    /// Tabs whose video we put into Picture in Picture, to bring back when you return.
    @ObservationIgnored private var autoEntered: Set<TabID> = []

    public func state(of id: TabID) -> State { states[id] ?? State() }

    /// Puts the tab's main video into Picture in Picture, or brings it back. You asked, so this
    /// overrides a site that turns Picture in Picture off.
    public func togglePictureInPicture(_ id: TabID) {
        autoEntered.remove(id)
        if state(of: id).inPictureInPicture { run("exit", in: id) } else { runAsClick("enter(true)", in: id) }
    }

    /// Playing can need a click, under the autoplay rules; you just clicked.
    public func togglePlayback(_ id: TabID) { runAsClick("toggle()", in: id) }

    public func toggleMute(_ id: TabID) { run("mute", in: id) }

    /// Call when the visible tabs change. A video left playing with sound follows you in Picture in
    /// Picture; coming back to its tab puts it back in the page.
    func visibleTabsChanged(from old: [TabID], to new: [TabID]) {
        for id in new where autoEntered.remove(id) != nil { run("exit", in: id) }
        guard autoPictureInPicture() else { return }
        for id in old where !new.contains(id) {
            let state = state(of: id)
            guard state.playing, state.hasVideo, !state.muted, !state.inPictureInPicture, let page = page(id) else { continue }
            autoEntered.insert(id)
            // You didn't click this page, so it gets a click only once Skylight has seen for itself
            // (not from the page's own report) that a video really is playing with sound.
            Task {
                guard (try? await page.evaluate("window.__skylightMedia ? window.__skylightMedia.canEnter() : false"))?.boolValue == true,
                      self.autoEntered.contains(id) else { return }
                page.runWithUserGesture("window.__skylightMedia.enter(false)")
            }
        }
    }

    func handle(_ message: JSONValue, tab id: TabID) -> JSONValue {
        guard message["type"]?.stringValue == "media.state" else { return .null }
        let state = State(playing: message["playing"]?.boolValue ?? false,
                          muted: message["muted"]?.boolValue ?? false,
                          hasVideo: message["video"]?.boolValue ?? false,
                          inPictureInPicture: message["pip"]?.boolValue ?? false)
        // Closing the Picture in Picture window yourself means it stays closed.
        if states[id]?.inPictureInPicture == true, !state.inPictureInPicture { autoEntered.remove(id) }
        if states[id] != state { states[id] = state }
        return .null
    }

    func pageWentAway(_ id: TabID) {
        states[id] = nil
        autoEntered.remove(id)
    }

    private func run(_ command: String, in id: TabID) {
        guard let page = page(id) else { return }
        Task { _ = try? await page.evaluate("window.__skylightMedia && window.__skylightMedia.\(command)()") }
    }

    /// Runs as if you clicked the page, as Picture in Picture and playing with sound need. The page
    /// script makes sure only its own code runs in that click, and asking for Picture in Picture
    /// uses the click up.
    private func runAsClick(_ call: String, in id: TabID) {
        page(id)?.runWithUserGesture("window.__skylightMedia && window.__skylightMedia.\(call)")
    }

    /// Reports the page's media state and gives Skylight a few controls. Media events don't
    /// bubble, so it listens while they're captured on the way down.
    ///
    /// Skylight calls `enter` and `toggle` as a click, so they must not run any of the page's code:
    /// a page that swapped `requestPictureInPicture` (or a getter, or `Array.prototype.sort`) for
    /// its own function would get that click to open popups with. So everything they touch is
    /// taken from the browser before the page's scripts run, and called with `Reflect.apply`.
    static let pageScript = """
    (() => {
      if (!window.__skylight || window.__skylightMedia) return;
      const { apply } = Reflect;
      const { getOwnPropertyDescriptor: describe, defineProperty, freeze } = Object;
      const getter = (proto, name) => { const get = describe(proto, name).get; return (o) => apply(get, o, []); };
      const method = (proto, name) => { const fn = proto[name]; return (o, args) => apply(fn, o, args || []); };
      const Media = HTMLMediaElement.prototype;
      const queryAll = method(Document.prototype, 'querySelectorAll');
      const count = getter(NodeList.prototype, 'length');
      const tag = getter(Element.prototype, 'localName');
      const width = getter(HTMLElement.prototype, 'offsetWidth');
      const height = getter(HTMLElement.prototype, 'offsetHeight');
      const videoWidth = getter(HTMLVideoElement.prototype, 'videoWidth');
      const paused = getter(Media, 'paused');
      const ended = getter(Media, 'ended');
      const readyState = getter(Media, 'readyState');
      const isMuted = getter(Media, 'muted');
      const volume = getter(Media, 'volume');
      const setMuted = describe(Media, 'muted').set;
      const play = method(Media, 'play');
      const pause = method(Media, 'pause');
      const hasAttribute = method(Element.prototype, 'hasAttribute');
      const removeAttribute = method(Element.prototype, 'removeAttribute');
      const requestPiP = method(HTMLVideoElement.prototype, 'requestPictureInPicture');
      const exitPiP = method(Document.prototype, 'exitPictureInPicture');
      const pipElement = getter(Document.prototype, 'pictureInPictureElement');
      const ignore = () => {};
      const thenFn = Promise.prototype.then;
      // Swallows a rejection without looking anything up on the promise.
      const quiet = (p) => { try { apply(thenFn, p, [ignore, ignore]); } catch (_) {} };

      // Calls fn on each <video> and <audio>, without making arrays the page could hook.
      const each = (fn) => { const list = queryAll(document, ['video, audio']); for (let i = 0, n = count(list); i < n; i++) fn(list[i]); };
      const live = (m) => !paused(m) && !ended(m) && readyState(m) > 1;
      const audible = (m) => !isMuted(m) && volume(m) > 0;
      const size = (v) => width(v) * height(v);
      // The video you'd mean: the biggest one playing, else the biggest one at all.
      const main = () => {
        let best = null;
        each((m) => {
          if (tag(m) !== 'video' || videoWidth(m) <= 0 || size(m) <= 0) return;
          if (!best || (live(m) && !live(best)) || (live(m) === live(best) && size(m) > size(best))) best = m;
        });
        return best;
      };

      let last = '';
      let pending = false;
      const report = () => {
        pending = false;
        let playing = 0, silent = 0;
        each((m) => { if (live(m)) { playing++; if (!audible(m)) silent++; } });
        const state = {
          type: 'media.state',
          playing: playing > 0,
          muted: playing > 0 && silent === playing,
          video: !!main(),
          pip: !!pipElement(document),
        };
        const key = JSON.stringify(state);
        if (key === last) return;
        last = key;
        window.__skylight.post(state).catch(() => {});
      };
      const schedule = () => { if (!pending) { pending = true; setTimeout(report, 50); } };
      for (const name of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange', 'loadedmetadata',
                          'resize', 'enterpictureinpicture', 'leavepictureinpicture']) {
        document.addEventListener(name, schedule, true);
      }

      // Worth taking along when you leave the tab: a sizeable video playing with sound, from a site
      // that allows Picture in Picture.
      const canEnter = () => {
        const video = main();
        return !!video && !pipElement(document) && live(video) && audible(video) && size(video) >= 200 * 112 &&
          !hasAttribute(video, ['disablepictureinpicture']);
      };
      const enter = (asked) => {
        const video = main();
        if (!video || pipElement(document)) return;
        if (!asked && !canEnter()) return;
        if (asked) removeAttribute(video, ['disablepictureinpicture']);
        try { quiet(requestPiP(video)); } catch (_) {}
      };
      const exit = () => { if (pipElement(document)) { try { quiet(exitPiP(document)); } catch (_) {} } };
      const toggle = () => {
        let any = false;
        each((m) => { if (live(m)) { any = true; pause(m); } });
        if (any) return;
        const m = main() || queryAll(document, ['video, audio'])[0];
        if (m) { try { quiet(play(m)); } catch (_) {} }
      };
      const mute = () => {
        let live_ = 0, muted = 0;
        each((m) => { if (live(m)) { live_++; if (isMuted(m)) muted++; } });
        const unmute = live_ > 0 && muted === live_;
        each((m) => { if (!live_ || live(m)) apply(setMuted, m, [!unmute]); });
      };
      defineProperty(window, '__skylightMedia', {
        __proto__: null,
        value: freeze({ __proto__: null, enter, exit, toggle, mute, canEnter, pip: () => (pipElement(document) ? exit() : enter(true)) }),
        configurable: false, enumerable: false, writable: false,
      });
    })();
    """
}
