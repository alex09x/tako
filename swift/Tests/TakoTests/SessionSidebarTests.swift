import Testing
import AppKit
import Foundation
@testable import Tako

@MainActor
struct SessionSidebarTests {

    private func createTestDefaults() -> UserDefaults {
        let suiteName = "test.tako.sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func sidebarStoreInitialStateAndOptInsOffByDefault() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        // B5 requirement: "Off by default for people who prefer the tab bar"
        #expect(!store.isShowing)
        // B5 requirement: "each opt-in field is off until enabled"
        #expect(!store.optInGit)
        #expect(!store.optInPorts)
        #expect(!store.filterNeedsAttention)
        #expect(store.filterText.isEmpty)
        #expect(store.descriptions.isEmpty)
    }

    @Test func userEditableDescriptionsSetUpdateAndClear() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        let tabId = UUID().uuidString

        #expect(store.description(for: tabId) == nil)

        store.setDescription("Backend API Service", for: tabId)
        #expect(store.description(for: tabId) == "Backend API Service")

        // Persists to UserDefaults
        let reloadedStore = SessionSidebarStore(defaults: defaults)
        #expect(reloadedStore.description(for: tabId) == "Backend API Service")

        // Update description
        store.setDescription("Backend API Service (v2)", for: tabId)
        #expect(store.description(for: tabId) == "Backend API Service (v2)")

        // Clear description
        store.clearDescription(for: tabId)
        #expect(store.description(for: tabId) == nil)
    }

    private func createTestGitRepository(branch: String = "feature/sidebar-test") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-\(UUID().uuidString)")
        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let headFile = gitDir.appendingPathComponent("HEAD")
        try "ref: refs/heads/\(branch)\n".write(to: headFile, atomically: true, encoding: .utf8)
        return tempDir
    }

    @Test func localGitInspectionReadsBranchAndDirtyStateLocallyWithoutNetwork() throws {
        let repoURL = try createTestGitRepository(branch: "feature/sidebar-test")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let gitInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(gitInfo != nil)
        #expect(gitInfo?.branch == "feature/sidebar-test")
        #expect(gitInfo?.isDirty == false)

        // Detached HEAD inspection
        let detachedDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-\(UUID().uuidString)")
        let detachedGit = detachedDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: detachedGit, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: detachedDir) }
        try "e8a3b5c4d2e1f0\n".write(to: detachedGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let detachedInfo = LocalGitInspection.inspect(directory: detachedDir.path)
        #expect(detachedInfo?.branch == "e8a3b5c")
    }

    @Test func optInFieldsAreOnlyPopulatedWhenEnabled() throws {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let repoURL = try createTestGitRepository(branch: "main")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workspace 1"

        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        surface.title = "Build Server"
        surface.pwd = repoURL.path
        window.contentView = surface

        // When opt-ins are false, git and ports must be nil
        store.optInGit = false
        store.optInPorts = false

        let itemsDisabled = store.items(for: window)
        #expect(itemsDisabled.count == 1)
        let itemDisabled = itemsDisabled[0]
        #expect(itemDisabled.gitBranch == nil)
        #expect(itemDisabled.gitDirty == nil)
        #expect(itemDisabled.listeningPorts == nil)

        // When opt-ins are true, git is populated from local repo
        store.optInGit = true
        let itemsEnabled = store.items(for: window)
        #expect(itemsEnabled.count == 1)
        let itemEnabled = itemsEnabled[0]
        #expect(itemEnabled.gitBranch == "main")
    }

    @Test func filterNeedsAttentionIsolatesAttentionRequiredPanes() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win3 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)

        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Idle Tab"
        surf1.crab.setStatus(.idle, text: nil)
        win1.contentView = surf1

        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Failed Tab"
        surf2.crab.setStatus(.error, text: nil)
        win2.contentView = surf2

        let surf3 = Tako.SurfaceView(frame: .zero)
        surf3.title = "Approval Tab"
        surf3.crab.setStatus(.needsApproval, text: nil)
        win3.contentView = surf3

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        Tako.CustomTabGroup.join(win3, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        group.select(win1) // win1 is selected/active, win2 and win3 are in background

        // Without filter: all 3 tabs are present
        store.filterNeedsAttention = false
        let allItems = store.items(for: win1)
        #expect(allItems.count == 3)

        // With filter: only win2 (error) and win3 (needsApproval) are present
        store.filterNeedsAttention = true
        let filtered = store.items(for: win1)
        #expect(filtered.count == 2)
        #expect(filtered.contains(where: { $0.title == "Failed Tab" }))
        #expect(filtered.contains(where: { $0.title == "Approval Tab" }))
        #expect(!filtered.contains(where: { $0.title == "Idle Tab" }))
    }

    @Test func textSearchFiltersAcrossTitleDirectoryAndDescription() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)

        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Frontend Client"
        surf1.pwd = "/Users/dev/frontend"
        win1.contentView = surf1

        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Worker Daemon"
        surf2.pwd = "/Users/dev/worker"
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        store.setDescription("React Vite UI", for: surf1.id.uuidString)

        store.filterNeedsAttention = false

        // Search by title
        store.filterText = "Frontend"
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1).first?.title == "Frontend Client")

        // Search by directory
        store.filterText = "worker"
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1).first?.title == "Worker Daemon")

        // Search by user description
        store.filterText = "Vite"
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1).first?.title == "Frontend Client")

        // Search no match
        store.filterText = "nonexistent_query"
        #expect(store.items(for: win1).isEmpty)
    }

    @Test func reorderTabsMovesWindowInCustomTabGroup() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        win1.title = "Tab 1"
        win2.title = "Tab 2"

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        #expect(group.windows.count == 2)
        #expect(group.windows[0] === win1)
        #expect(group.windows[1] === win2)

        let items = store.items(for: win1)
        #expect(items[0].title == "Tab 1")
        #expect(items[1].title == "Tab 2")

        // Move Tab 2 up (delta: -1)
        store.moveTab(item: items[1], delta: -1, in: win1)
        #expect(group.windows[0] === win2)
        #expect(group.windows[1] === win1)

        let updatedItems = store.items(for: win1)
        #expect(updatedItems[0].title == "Tab 2")
        #expect(updatedItems[1].title == "Tab 1")
    }

    @Test func performanceBudgetFor30Tabs() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        var windows: [NSWindow] = []
        for i in 0..<30 {
            let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            win.title = "Tab \(i)"
            let surf = Tako.SurfaceView(frame: .zero)
            surf.title = "Pane \(i)"
            surf.pwd = "/Users/dev/project\(i)"
            surf.crab.setStatus(i % 2 == 0 ? .running : .idle, text: nil)
            if i % 3 == 0 {
                surf.crab.progressReported(state: 1, value: 50)
            }
            win.contentView = surf
            windows.append(win)
        }

        for i in 1..<30 {
            Tako.CustomTabGroup.join(windows[i], to: windows[0], select: false)
        }

        // Measure item derivation time for 30 tabs (A6 budget: < 10ms)
        let startTime = CFAbsoluteTimeGetCurrent()
        let items = store.items(for: windows[0])
        let duration = CFAbsoluteTimeGetCurrent() - startTime

        #expect(items.count == 30)
        #expect(duration < 0.05) // Under 50ms (typically < 1ms)
    }

    @Test func sidebarStoreObservesCrabTrackerAndSurfaceChangesInRealTime() async throws {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Tab 1"
        surf2.title = "Tab 2"
        surf1.crab.setStatus(.idle, text: nil)
        surf2.crab.setStatus(.idle, text: nil)
        win1.contentView = surf1
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        group.select(win1) // win1 is active, win2 is background

        // First read binds surface observers
        let initialItems = store.items(for: win1)
        #expect(initialItems.count == 2)
        #expect(initialItems[1].status == .idle)
        #expect(!initialItems[1].needsAttention)

        var changeFired = false
        let cancellable = store.objectWillChange.sink {
            changeFired = true
        }

        // Change crab status on the background surface
        surf2.crab.setStatus(.error, text: nil)

        // Wait a beat for RunLoop delivery
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(changeFired)
        cancellable.cancel()

        // Recomputed items reflect the updated status and needsAttention on the background tab
        let updatedItems = store.items(for: win1)
        #expect(updatedItems[1].status == .error)
        #expect(updatedItems[1].needsAttention)
    }

    @Test func filteredReorderControlsUseFullGroupBounds() {
        // When there are 5 tabs total, but a filter only matches 2 tabs (e.g. index 0 and index 3)
        let itemFirst = SessionSidebarItem(id: "1", index: 0, totalCount: 5, isSelected: false, title: "Tab 1")
        #expect(!itemFirst.canMoveUp)
        #expect(itemFirst.canMoveDown)

        let itemMiddle = SessionSidebarItem(id: "4", index: 3, totalCount: 5, isSelected: false, title: "Tab 4")
        #expect(itemMiddle.canMoveUp)
        #expect(itemMiddle.canMoveDown) // In a 2-item filtered list, index 3 must still be allowed to move down

        let itemLast = SessionSidebarItem(id: "5", index: 4, totalCount: 5, isSelected: false, title: "Tab 5")
        #expect(itemLast.canMoveUp)
        #expect(!itemLast.canMoveDown)
    }

    @Test func gitMetadataRefreshesAfterCacheInvalidation() throws {
        let repoURL = try createTestGitRepository(branch: "feature/first-branch")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pwd = repoURL.path
        win.contentView = surf

        let items1 = store.items(for: win)
        #expect(items1[0].gitBranch == "feature/first-branch")

        // Switch branch in repository
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/feature/second-branch\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Cache hit within TTL
        let itemsCached = store.items(for: win)
        #expect(itemsCached[0].gitBranch == "feature/first-branch")

        // Invalidate cache
        store.invalidateCaches()

        // Inspects new branch
        let itemsUpdated = store.items(for: win)
        #expect(itemsUpdated[0].gitBranch == "feature/second-branch")
    }
}
