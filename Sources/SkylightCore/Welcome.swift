import Foundation

/// The steps a new install walks through, one question at a time.
public enum WelcomeStep: CaseIterable, Sendable {
    case hello, bringOver, look, defaultBrowser, basics

    /// The steps to show. There's no point asking for what's already true.
    public static func steps(isDefaultBrowser: Bool) -> [WelcomeStep] {
        allCases.filter { $0 != .defaultBrowser || !isDefaultBrowser }
    }

    /// Whether this looks like a new install. Someone with tabs has been here already, even if
    /// they arrived before there was a welcome to finish.
    public static func isDue(for state: BrowserState) -> Bool {
        state.tabs.isEmpty && state.closedTabs.isEmpty
    }
}
