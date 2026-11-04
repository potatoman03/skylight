import AppKit
import Foundation
import Observation
import SkylightCore

/// Settings that aren't browser state. Saved to `preferences.json` on every change.
@MainActor
@Observable
public final class Preferences {
    public enum SearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
        case google, duckDuckGo, kagi, bing, perplexity

        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .google: "Google"
            case .duckDuckGo: "DuckDuckGo"
            case .kagi: "Kagi"
            case .bing: "Bing"
            case .perplexity: "Perplexity"
            }
        }

        public var template: String {
            switch self {
            case .google: "https://www.google.com/search?q=%s"
            case .duckDuckGo: "https://duckduckgo.com/?q=%s"
            case .kagi: "https://kagi.com/search?q=%s"
            case .bing: "https://www.bing.com/search?q=%s"
            case .perplexity: "https://www.perplexity.ai/search?q=%s"
            }
        }
    }

    public enum Appearance: String, Codable, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var name: String { rawValue.capitalized }
    }

    private struct Stored: Codable {
        var searchEngine: SearchEngine?
        var appearance: Appearance?
        var godRays: Bool?
        var archiveAfterHours: Double?
        var sidebarCollapsed: Bool?
    }

    public var searchEngine: SearchEngine = .google { didSet { save() } }
    /// Morning by default: Skylight is meant to feel bright. System follows macOS.
    public var appearance: Appearance = .light { didSet { save(); applyAppearance() } }
    /// The animated light in the sky. Off, the sky is a still gradient.
    public var godRays = true { didSet { save() } }
    /// Today tabs untouched this long are archived.
    public var archiveAfterHours: Double = 12 { didSet { save() } }
    public var sidebarCollapsed = false { didSet { save() } }

    public var omnibox: Omnibox { Omnibox(searchTemplate: searchEngine.template) }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var loading = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        loading = true
        defer { loading = false }
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        searchEngine = stored.searchEngine ?? searchEngine
        appearance = stored.appearance ?? appearance
        godRays = stored.godRays ?? godRays
        archiveAfterHours = stored.archiveAfterHours ?? archiveAfterHours
        sidebarCollapsed = stored.sidebarCollapsed ?? sidebarCollapsed
    }

    public func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func save() {
        guard !loading, let fileURL else { return }
        let stored = Stored(searchEngine: searchEngine, appearance: appearance, godRays: godRays,
                            archiveAfterHours: archiveAfterHours, sidebarCollapsed: sidebarCollapsed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(stored).write(to: fileURL, options: .atomic)
    }
}
