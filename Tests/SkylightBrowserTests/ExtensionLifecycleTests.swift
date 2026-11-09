import Foundation
import SkylightCore
import SkylightEngine
import Testing
@testable import SkylightBrowser

@Suite @MainActor
struct ExtensionLifecycleTests {
    private final class Host: ExtensionHost {
        var openTab: (@MainActor (URL, Bool) -> WebPage?)?
        var selectTab: (@MainActor (WebPage) -> Void)?
        var closeTab: (@MainActor (WebPage) -> Void)?
        var showPopup: (@MainActor (ExtensionPopup) -> Void)?
        var resizePopup: (@MainActor (CGSize) -> Void)?
        var loaded: Set<String> = []
        var events: [String] = []
        var holdLoad = false
        var loadWaiter: CheckedContinuation<Void, Never>?
        var holdReset = false
        var resetWaiter: CheckedContinuation<Void, Never>?
        var failing = false
        var failingUnload = false
        var failedReset: Set<String> = []

        func load(_ directory: URL, id: String) async throws {
            events.append("load-start:\(id)")
            if holdLoad {
                holdLoad = false
                await withCheckedContinuation { loadWaiter = $0 }
            }
            if failing { throw CocoaError(.fileReadUnknown) }
            loaded.insert(id)
            events.append("load-end:\(id)")
        }
        func unload(_ id: String) async throws {
            events.append("unload:\(id)")
            if failingUnload { throw CocoaError(.fileReadUnknown) }
            loaded.remove(id)
        }
        func forgetWorkers() async -> Set<String> {
            events.append("reset")
            if holdReset {
                holdReset = false
                await withCheckedContinuation { resetWaiter = $0 }
            }
            return failedReset
        }
        func setTabs(_ groups: [ExtensionTabs]) {}
        func triggerAction(_ id: String, page: WebPage?) async throws {}
        func pageURL(_ id: String, path: String) -> URL? { nil }
    }

    private func fixture(_ count: Int) throws -> (URL, ExtensionService, Host) {
        let root = FileManager.default.temporaryDirectory.appending(path: "skylight-extension-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var installed: [ExtensionService.Installed] = []
        for index in 0..<count {
            let id = "fake\(index)"
            let folder = root.appending(path: id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = #"{"manifest_version":3,"name":"Fixture","version":"1.0","background":{"service_worker":"worker.js"}}"#
            try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
            try Data("// fixture".utf8).write(to: folder.appending(path: "worker.js"))
            installed.append(.init(id: id, folder: folder, source: .folder, enabled: true, pinned: true))
        }
        try JSONEncoder().encode(installed).write(to: root.appending(path: "extensions.json"))
        let host = Host()
        return (root, ExtensionService(host: host, root: root, toasts: ToastCenter()), host)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for extension lifecycle")
    }

    @Test func startupResetsWorkersOnceAndLoadsEveryExtension() async throws {
        let (root, service, host) = try fixture(3)
        defer { try? FileManager.default.removeItem(at: root) }
        await service.start()
        #expect(host.events.filter { $0 == "reset" }.count == 1)
        #expect(host.loaded == ["fake0", "fake1", "fake2"])
        #expect(host.events.first == "reset")
    }

    @Test func disablingWhileLoadingUnloadsAfterTheLoadFinishes() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        host.holdLoad = true
        let startup = Task { await service.start() }
        try await waitUntil { host.loadWaiter != nil }
        service.setEnabled("fake0", false)
        host.loadWaiter?.resume()
        host.loadWaiter = nil
        await startup.value
        try await waitUntil { host.events.contains("unload:fake0") }
        #expect(host.loaded.isEmpty)
        #expect(host.events.suffix(2) == ["load-end:fake0", "unload:fake0"])
    }

    @Test func rapidOffAndOnDoesNotLoadTheSameExtensionTwice() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        host.holdLoad = true
        let startup = Task { await service.start() }
        try await waitUntil { host.loadWaiter != nil }
        service.setEnabled("fake0", false)
        service.setEnabled("fake0", true)
        host.loadWaiter?.resume()
        host.loadWaiter = nil
        await startup.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.loaded == ["fake0"])
        #expect(host.events.filter { $0 == "load-start:fake0" }.count == 1)
        #expect(!host.events.contains("unload:fake0"))
    }

    @Test func unsuccessfulLoadRetriesWorkerResetOnTheNextStart() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        host.failing = true
        await service.start()
        #expect(host.loaded.isEmpty)
        host.failing = false
        let retry = ExtensionService(host: host, root: root, toasts: ToastCenter())
        await retry.start()
        #expect(host.events.filter { $0 == "reset" }.count == 2)
        #expect(host.loaded == ["fake0"])
    }

    @Test func requestedRestartWaitsForAnInFlightLoad() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        host.holdLoad = true
        let startup = Task { await service.start() }
        try await waitUntil { host.loadWaiter != nil }
        service.restartWorkers()
        #expect(service.restartingWorkers)
        #expect(host.events.filter { $0 == "reset" }.count == 1)
        host.loadWaiter?.resume()
        host.loadWaiter = nil
        await startup.value
        try await waitUntil { !service.restartingWorkers }
        #expect(host.events.suffix(2) == ["load-end:fake0", "reset"])
        #expect(host.loaded == ["fake0"])
    }

    @Test func resetFailureIsReportedAndRetried() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        host.failedReset = ["fake0"]
        await service.start()
        #expect(service.lastError?.contains("Couldn't restart") == true)
        #expect(host.loaded.isEmpty)
        host.failedReset = []
        let retry = ExtensionService(host: host, root: root, toasts: ToastCenter())
        await retry.start()
        #expect(host.events.filter { $0 == "reset" }.count == 2)
        #expect(host.loaded == ["fake0"])
    }

    @Test func disablingDuringResetDoesNotLoadTheDisabledExtension() async throws {
        let (root, service, host) = try fixture(2)
        defer { try? FileManager.default.removeItem(at: root) }
        host.holdReset = true
        let startup = Task { await service.start() }
        try await waitUntil { host.resetWaiter != nil }
        service.setEnabled("fake0", false)
        host.resetWaiter?.resume()
        host.resetWaiter = nil
        await startup.value
        #expect(host.loaded == ["fake1"])
        #expect(!host.events.contains("load-start:fake0"))
    }

    @Test func failedUnloadDoesNotPretendTheExtensionIsOff() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        await service.start()
        host.failingUnload = true
        service.setEnabled("fake0", false)
        try await waitUntil { service.lastError != nil }
        #expect(service.installed.first?.enabled == true)
        #expect(host.loaded == ["fake0"])
    }

    @Test func failedRemovalKeepsTheExtensionRegistered() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        await service.start()
        host.failingUnload = true
        service.remove("fake0")
        try await waitUntil { service.lastError != nil }
        #expect(service.installed.first?.id == "fake0")
        #expect(host.loaded == ["fake0"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "ExtensionRuntime/fake0").path))
    }

    @Test func restartRetriesAnExtensionThatDidNotLoad() async throws {
        let (root, service, host) = try fixture(1)
        defer { try? FileManager.default.removeItem(at: root) }
        host.failing = true
        await service.start()
        #expect(host.loaded.isEmpty)
        host.failing = false
        service.restartWorkers()
        try await waitUntil { !service.restartingWorkers }
        #expect(host.loaded == ["fake0"])
        #expect(host.events.filter { $0 == "reset" }.count == 2)
    }
}
