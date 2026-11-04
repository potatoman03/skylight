import Foundation
import FoundationModels
import SkylightCore

/// Asks the system's on-device language model how to group tabs. It ships with macOS, so Skylight
/// carries no model of its own, and nothing leaves the Mac.
enum TidyModel {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    @Generable
    struct Plan {
        @Guide(description: "Folders of related tabs. Leave out tabs that fit no folder.")
        var folders: [Folder]

        @Generable
        struct Folder {
            @Guide(description: "A short folder name, one to three words, in title case")
            var name: String
            @Guide(description: "The numbers of the tabs that go in this folder")
            var tabs: [Int]
        }
    }

    static func groups(for tabs: [Tab], how: String) async throws -> [TidyGroup] {
        let session = LanguageModelSession(instructions: """
            You tidy a web browser's tabs into folders. Put tabs that belong together in one folder, \
            each tab in at most one folder, and only make folders of two or more tabs.
            """)
        let list = tabs.enumerated().map { "\($0.offset + 1). \($0.element.shortTitle) (\($0.element.url.host() ?? $0.element.url.absoluteString))" }
        let how = how.trimmingCharacters(in: .whitespaces)
        // Left to itself, the model sorts by website; Tidy has a "by site" of its own for that.
        let way = how.isEmpty || how == "by topic" ? "by what each tab is about, not by website" : how
        let plan = try await session.respond(to: "Group these tabs \(way):\n\(list.joined(separator: "\n"))", generating: Plan.self).content
        return plan.folders.map { folder in
            TidyGroup(name: folder.name, tabs: folder.tabs.compactMap { tabs.indices.contains($0 - 1) ? tabs[$0 - 1].id : nil })
        }
    }
}

extension Browser {
    /// Whether Tidy has the on-device model (otherwise it groups by site).
    public var tidyUsesModel: Bool { TidyModel.isAvailable }

    /// Works out folders for the active Space's loose tabs, `how` you ask (by topic when empty).
    public func tidyPlan(how: String) async -> (space: SpaceID, groups: [TidyGroup]) {
        let space = store.state.activeSpace
        let ids = Tidy.candidates(space)
        let tabs = ids.compactMap { store.state.tabs[$0] }
        guard tabs.count > 1 else { return (space.id, []) }
        if TidyModel.isAvailable, let groups = try? await TidyModel.groups(for: tabs, how: how) {
            let cleaned = Tidy.clean(groups, allowed: ids)
            if !cleaned.isEmpty { return (space.id, cleaned) }
        }
        return (space.id, Tidy.bySite(tabs))
    }

    /// Makes the folders, leaving out tabs closed or moved in the meantime.
    public func applyTidy(_ groups: [TidyGroup], in space: SpaceID) {
        let loose = Set(store.state.spaces.first { $0.id == space }.map(Tidy.candidates) ?? [])
        for group in groups {
            let tabs = group.tabs.filter(loose.contains)
            guard tabs.count > 1 else { continue }
            store.send(.createFolder(id: UUID().uuidString, space: space, name: group.name, tabs: tabs))
        }
    }
}
