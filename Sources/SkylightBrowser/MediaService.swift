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

    /// Puts the tab's main video into Picture in Picture, or brings it back.
    public func togglePictureInPicture(_ id: TabID) {
        autoEntered.remove(id)
        run("pip", in: id)
    }

    public func togglePlayback(_ id: TabID) { run("toggle", in: id) }

    public func toggleMute(_ id: TabID) { run("mute", in: id) }

    /// Call when the visible tabs change. A video left playing follows you in Picture in Picture;
    /// coming back to its tab puts it back in the page.
    func visibleTabsChanged(from old: [TabID], to new: [TabID]) {
        for id in new where autoEntered.remove(id) != nil { run("exit", in: id) }
        guard autoPictureInPicture() else { return }
        for id in old where !new.contains(id) {
            let state = state(of: id)
            guard state.playing, state.hasVideo, !state.inPictureInPicture else { continue }
            autoEntered.insert(id)
            run("enter", in: id)
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

    /// Picture in Picture needs a user gesture; this runs as one.
    private func run(_ command: String, in id: TabID) {
        page(id)?.runWithUserGesture("window.__skylightMedia && window.__skylightMedia.\(command)()")
    }

    /// Reports the page's media state and gives Skylight a few controls. Media events don't
    /// bubble, so it listens while they're captured on the way down.
    static let pageScript = """
    (() => {
      if (!window.__skylight || window.__skylightMedia) return;
      const all = () => Array.from(document.querySelectorAll('video, audio'));
      const live = (m) => !m.paused && !m.ended && m.readyState > 1;
      const visible = (v) => v.videoWidth > 0 && v.offsetWidth * v.offsetHeight > 0;
      // The video you'd mean: the biggest one playing, else the biggest one at all.
      const main = () => {
        const videos = all().filter((m) => m instanceof HTMLVideoElement && visible(m));
        const size = (v) => v.offsetWidth * v.offsetHeight;
        const sorted = videos.sort((a, b) => (live(b) - live(a)) || (size(b) - size(a)));
        return sorted[0] || null;
      };
      let last = '';
      let pending = false;
      const report = () => {
        pending = false;
        const playing = all().filter(live);
        const state = {
          type: 'media.state',
          playing: playing.length > 0,
          muted: playing.length > 0 && playing.every((m) => m.muted || m.volume === 0),
          video: !!main(),
          pip: !!document.pictureInPictureElement,
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
      const enter = async () => {
        const video = main();
        if (!video || document.pictureInPictureElement) return;
        video.removeAttribute('disablepictureinpicture');
        try { await video.requestPictureInPicture(); } catch (_) {}
      };
      const exit = async () => {
        if (document.pictureInPictureElement) { try { await document.exitPictureInPicture(); } catch (_) {} }
      };
      Object.defineProperty(window, '__skylightMedia', {
        value: Object.freeze({
          enter,
          exit,
          pip: () => (document.pictureInPictureElement ? exit() : enter()),
          toggle: () => {
            const playing = all().filter(live);
            if (playing.length) playing.forEach((m) => m.pause());
            else { const m = main() || all()[0]; if (m) m.play().catch(() => {}); }
          },
          mute: () => {
            const targets = all().filter(live);
            const muted = targets.length > 0 && targets.every((m) => m.muted);
            (targets.length ? targets : all()).forEach((m) => { m.muted = !muted; });
          },
        }),
        configurable: false, enumerable: false, writable: false,
      });
    })();
    """
}
