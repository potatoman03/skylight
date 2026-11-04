import Foundation
import Testing
@testable import SkylightCore

@Suite struct TabTitleTests {
    func short(_ title: String, _ url: String) -> String {
        Tab(url: URL(string: url)!, title: title, now: .distantPast).shortTitle
    }

    @Test func dropsTheSiteNameAtTheEnd() {
        #expect(short("Page not found · GitHub · GitHub", "https://github.com/x") == "Page not found")
        #expect(short("Lo-fi beats - YouTube", "https://www.youtube.com/watch?v=1") == "Lo-fi beats")
        #expect(short("Inbox (3) - Gmail", "https://mail.google.com/mail/u/0") == "Inbox (3)")
        #expect(short("View | Google Calendar", "https://calendar.google.com") == "View")
        #expect(short("Swift | Apple Developer Documentation", "https://developer.apple.com/documentation/swift") == "Swift")
    }

    @Test func dropsTheSiteNameAtTheStart() {
        #expect(short("GitHub - potatoman03/skylight: A browser", "https://github.com/potatoman03/skylight") == "potatoman03/skylight: A browser")
    }

    @Test func keepsTitlesThatAreOnlyTheSiteOrDontNameIt() {
        #expect(short("YouTube", "https://www.youtube.com") == "YouTube")
        #expect(short("Gmail: Secure, AI-Powered Email", "https://mail.google.com") == "Gmail: Secure, AI-Powered Email")
        #expect(short("React - A JavaScript library", "https://react.dev") == "React - A JavaScript library")
        #expect(short("", "https://example.com/page") == "example.com")
    }

    @Test func aNameYouGiveOutlastsThePageTitle() {
        let env = ReducerEnvironment(now: { .distantPast })
        var state = BrowserState.initial()
        let id = BrowserReducer.reduce(&state, .openTab(URL(string: "https://github.com/x")!, placement: .end), env: env).openedTabID!
        state.tabs[id]?.title = "Page not found · GitHub"
        BrowserReducer.reduce(&state, .renameTab(id, "  Bug list "), env: env)
        #expect(state.tabs[id]?.shortTitle == "Bug list")
        #expect(state.tabs[id]?.displayTitle == "Bug list")
        state.tabs[id]?.title = "Issues · GitHub"
        #expect(state.tabs[id]?.shortTitle == "Bug list")
        BrowserReducer.reduce(&state, .renameTab(id, " "), env: env)
        #expect(state.tabs[id]?.customTitle == nil)
        #expect(state.tabs[id]?.shortTitle == "Issues")
        #expect(!BrowserReducer.reduce(&state, .renameTab(TabID(), "x"), env: env).applied)
    }

    @Test func tabsSavedBeforeRenamingLoad() throws {
        let old = #"{"id":"a","url":"https://example.com","title":"Example","createdAt":0,"lastActiveAt":0}"#
        let tab = try JSONDecoder().decode(Tab.self, from: Data(old.utf8))
        #expect(tab.customTitle == nil)
        #expect(tab.displayTitle == "Example")
    }
}
