import Foundation
import SkylightCore
import Testing

struct WelcomeTests {
    @Test func aNewInstallIsDue() {
        #expect(WelcomeStep.isDue(for: .initial()))
    }

    @Test func someoneWithTabsHasBeenHereAlready() {
        var state = BrowserState.initial()
        let tab = Tab(url: URL(string: "https://example.com")!, now: .now)
        state.tabs[tab.id] = tab
        #expect(!WelcomeStep.isDue(for: state))
    }

    @Test func theDefaultBrowserStepGoesOnceItsTrue() {
        #expect(WelcomeStep.steps(isDefaultBrowser: false) == [.hello, .bringOver, .look, .defaultBrowser, .basics])
        #expect(WelcomeStep.steps(isDefaultBrowser: true) == [.hello, .bringOver, .look, .basics])
    }
}
