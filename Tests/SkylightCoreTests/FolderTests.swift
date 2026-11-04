import Foundation
import Testing
@testable import SkylightCore

@Suite struct FolderTests {
    let env = ReducerEnvironment(now: { Date(timeIntervalSince1970: 1_000_000) })

    func state(tabs count: Int) -> (BrowserState, [TabID]) {
        var state = BrowserState.initial()
        let ids = (0..<count).map { i in
            BrowserReducer.reduce(&state, .openTab(URL(string: "https://\(i).example")!, placement: .end), env: env).openedTabID!
        }
        return (state, ids)
    }

    @Test func aNewFolderPinsItsTabs() {
        var (state, ids) = state(tabs: 3)
        let space = state.activeSpaceID
        BrowserReducer.reduce(&state, .createFolder(id: "f", space: space, name: "Work", tabs: [ids[0], ids[2]]), env: env)
        let folder = state.activeSpace.folders[0]
        #expect(folder.name == "Work")
        #expect(folder.tabs == [ids[0], ids[2]])
        #expect(state.activeSpace.pinned == [ids[0], ids[2]])
        #expect(state.activeSpace.today == [ids[1]])
        #expect(state.activeSpace.loosePinned.isEmpty)
    }

    @Test func movingInAndOutAndReordering() {
        var (state, ids) = state(tabs: 3)
        BrowserReducer.reduce(&state, .createFolder(id: "f", space: state.activeSpaceID, name: "F", tabs: [ids[0]]), env: env)
        BrowserReducer.reduce(&state, .moveTabToFolder(ids[1], folder: "f", index: 0), env: env)
        #expect(state.activeSpace.folders[0].tabs == [ids[1], ids[0]])
        BrowserReducer.reduce(&state, .moveTabToFolder(ids[1], folder: nil), env: env)
        #expect(state.activeSpace.folders[0].tabs == [ids[0]])
        // Out of the folder, it stays pinned.
        #expect(state.activeSpace.loosePinned == [ids[1]])
    }

    @Test func unpinningOrRemovingATabTakesItOut() {
        var (state, ids) = state(tabs: 2)
        BrowserReducer.reduce(&state, .createFolder(id: "f", space: state.activeSpaceID, name: "F", tabs: ids), env: env)
        BrowserReducer.reduce(&state, .togglePin(ids[0]), env: env)
        #expect(state.activeSpace.folders[0].tabs == [ids[1]])
        BrowserReducer.reduce(&state, .removeTab(ids[1]), env: env)
        #expect(state.activeSpace.folders[0].tabs.isEmpty)
        // Closing a pinned tab only unloads it, so it stays.
        BrowserReducer.reduce(&state, .moveTabToFolder(ids[0], folder: "f"), env: env)
        BrowserReducer.reduce(&state, .closeTab(ids[0]), env: env)
        #expect(state.activeSpace.folders[0].tabs == [ids[0]])
    }

    @Test func deletingKeepsOrClosesTheTabs() {
        var (state, ids) = state(tabs: 2)
        let space = state.activeSpaceID
        BrowserReducer.reduce(&state, .createFolder(id: "a", space: space, name: "A", tabs: [ids[0]]), env: env)
        BrowserReducer.reduce(&state, .createFolder(id: "b", space: space, name: "B", tabs: [ids[1]]), env: env)
        BrowserReducer.reduce(&state, .moveFolder("b", to: 0), env: env)
        #expect(state.activeSpace.folders.map(\.id) == ["b", "a"])
        BrowserReducer.reduce(&state, .deleteFolder("a"), env: env)
        #expect(state.activeSpace.loosePinned == [ids[0]])
        BrowserReducer.reduce(&state, .deleteFolder("b", closeTabs: true), env: env)
        #expect(state.activeSpace.folders.isEmpty)
        #expect(state.tabs[ids[1]] == nil)
    }

    @Test func renamingAndOpening() {
        var (state, _) = state(tabs: 1)
        BrowserReducer.reduce(&state, .createFolder(id: "f", space: state.activeSpaceID, name: "F"), env: env)
        #expect(!BrowserReducer.reduce(&state, .renameFolder("f", "  "), env: env).applied)
        BrowserReducer.reduce(&state, .renameFolder("f", "Reading"), env: env)
        BrowserReducer.reduce(&state, .setFolderOpen("f", false), env: env)
        #expect(state.activeSpace.folders[0].name == "Reading")
        #expect(!state.activeSpace.folders[0].isOpen)
    }

    @Test func foldersSurviveSavingAndOldFilesLoad() throws {
        var (state, ids) = state(tabs: 1)
        BrowserReducer.reduce(&state, .createFolder(id: "f", space: state.activeSpaceID, name: "F", tabs: ids), env: env)
        let data = try JSONEncoder().encode(state.activeSpace)
        #expect(try JSONDecoder().decode(Space.self, from: data).folders == state.activeSpace.folders)
        let old = #"{"id":"s","name":"P","hue":0.5,"pinned":[],"today":[]}"#
        #expect(try JSONDecoder().decode(Space.self, from: Data(old.utf8)).folders.isEmpty)
    }
}
