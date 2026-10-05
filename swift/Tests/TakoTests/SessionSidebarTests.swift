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

    @Test func tabDescriptionPersistsWhenFirstSplitPaneIsClosed() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        surf1.title = "Split Pane 1"
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        surf2.title = "Split Pane 2"
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        let initialItems = store.items(for: win)
        #expect(initialItems.count == 1)
        let tabId = initialItems[0].id
        #expect(!tabId.isEmpty)

        // Set description for the tab
        store.setDescription("Build and Logs Tab", for: tabId)
        let updatedItems = store.items(for: win)
        #expect(updatedItems[0].userDescription == "Build and Logs Tab")

        // Close the first split pane
        surf1.removeFromSuperview()

        // Tab still exists with surf2; row ID and description must remain intact
        let itemsAfterClosingFirstSplit = store.items(for: win)
        #expect(itemsAfterClosingFirstSplit.count == 1)
        #expect(itemsAfterClosingFirstSplit[0].id == tabId)
        #expect(itemsAfterClosingFirstSplit[0].userDescription == "Build and Logs Tab")
    }

    private func createTestGitRepository(branch: String = "feature/sidebar-test") throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-\(UUID().uuidString)")
        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        let headFile = gitDir.appendingPathComponent("HEAD")
        try "ref: refs/heads/\(branch)\n".write(to: headFile, atomically: true, encoding: .utf8)
        return tempDir
    }

    private func waitForGitInspection(store: SessionSidebarStore, directory: String) async throws {
        for _ in 0..<30 {
            if store.hasGitCache(for: directory) && !store.isGitInspectionPending(for: directory) {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func waitForPortsInspection(store: SessionSidebarStore, pids: [Int]) async throws {
        for _ in 0..<50 {
            if pids.allSatisfy({ store.hasPortsCache(for: $0) && !store.isPortsInspectionPending(for: $0) }) {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @Test func localGitInspectionReadsBranchAndDirtyStateLocallyWithoutNetwork() throws {
        let repoURL = try createTestGitRepository(branch: "feature/sidebar-test")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let gitInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(gitInfo != nil)
        #expect(gitInfo?.branch == "feature/sidebar-test")
        #expect(gitInfo?.isDirty == false)

        // Untracked file makes repository dirty
        let untrackedFile = repoURL.appendingPathComponent("untracked.txt")
        try "untracked content".write(to: untrackedFile, atomically: true, encoding: .utf8)
        let dirtyInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(dirtyInfo?.isDirty == true)
        try? FileManager.default.removeItem(at: untrackedFile)
        let cleanInfo = LocalGitInspection.inspect(directory: repoURL.path)
        #expect(cleanInfo?.isDirty == false)

        // Detached HEAD inspection
        let detachedDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-\(UUID().uuidString)")
        let detachedGit = detachedDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: detachedGit.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: detachedGit.appendingPathComponent("objects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: detachedDir) }
        try "e8a3b5c4d2e1f0\n".write(to: detachedGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let detachedInfo = LocalGitInspection.inspect(directory: detachedDir.path)
        #expect(detachedInfo?.branch == "e8a3b5c")
        // Non-existent commit object causes git status to fail; failure propagates nil rather than reporting false (clean)
        #expect(detachedInfo?.isDirty == nil)
    }

    @Test func failedGitInspectionDoesNotReportClean() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-git-corrupt-\(UUID().uuidString)")
        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        // Corrupt HEAD with invalid SHA that fails git status
        try "invalidsha123\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let info = LocalGitInspection.inspect(directory: tempDir.path)
        #expect(info != nil)
        #expect(info?.branch == "invalid")
        // When git status exits with non-zero status, isDirty must be nil (unavailable), NOT false (clean)
        #expect(info?.isDirty == nil)
    }

    @Test func optInFieldsAreOnlyPopulatedWhenEnabled() async throws {
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
        _ = store.items(for: window)
        try await waitForGitInspection(store: store, directory: repoURL.path)

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

    @Test func gitMetadataRefreshesAfterCacheInvalidation() async throws {
        let repoURL = try createTestGitRepository(branch: "feature/first-branch")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pwd = repoURL.path
        win.contentView = surf

        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)

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

        // Triggers async inspection for new branch
        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)

        let itemsUpdated = store.items(for: win)
        #expect(itemsUpdated[0].gitBranch == "feature/second-branch")
    }

    @Test func notificationsAndUnreadAggregateAcrossAllPanesInTab() throws {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        surf1.title = "Pane 1"
        surf2.title = "Pane 2"
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        // Post notification specifically to secondary split pane (surf2)
        NotificationStore.shared.addNotification(
            id: UUID().uuidString,
            surfaceId: surf2.id,
            paneTitle: "Pane 2",
            title: "Task completed",
            body: "Build finished in 4s",
            urgency: 1
        )
        defer {
            NotificationStore.shared.clear()
        }

        // Window is background tab in group
        let winOther = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surfOther = Tako.SurfaceView(frame: .zero)
        winOther.contentView = surfOther
        Tako.CustomTabGroup.join(win, to: winOther, select: false)
        let group = Tako.CustomTabGroup.group(for: winOther)
        group.select(winOther)

        let items = store.items(for: winOther)
        let tabItem = items.first(where: { $0.id == win.stableTabIdentifier })
        #expect(tabItem != nil)
        #expect(tabItem?.latestNotification == "Task completed")
        #expect(tabItem?.unreadCount == 1)
        #expect(tabItem?.needsAttention == true)
    }

    @Test func multipleWindowGroupsRetainLiveSubscriptionsAcrossSidebars() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Workspace A"
        win1.contentView = surf1

        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Workspace B"
        win2.contentView = surf2

        // Bind both distinct window groups
        _ = store.items(for: win1)
        _ = store.items(for: win2)

        // Verify items for both window sidebars are distinct and bound
        let items1 = store.items(for: win1)
        let items2 = store.items(for: win2)
        #expect(items1.count == 1)
        #expect(items2.count == 1)
        #expect(items1[0].title == "Workspace A")
        #expect(items2[0].title == "Workspace B")

        // Mutating surface in first group still notifies store
        surf1.title = "Workspace A (Renamed)"
        let items1Updated = store.items(for: win1)
        #expect(items1Updated[0].title == "Workspace A (Renamed)")
    }

    @Test func commandCompletionRefreshesGitMetadata() async throws {
        let repoURL = try createTestGitRepository(branch: "branch-a")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pwd = repoURL.path
        win.contentView = surf

        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)
        #expect(store.items(for: win)[0].gitBranch == "branch-a")

        // Switch branch in repository on disk
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/branch-b\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Without command completion, cached branch is preserved (no polling on render cadence)
        #expect(store.items(for: win)[0].gitBranch == "branch-a")

        // Simulate command running then completing
        surf.crab.setStatus(.running, text: nil)
        surf.crab.setStatus(.idle, text: nil)

        // Command completion invalidates the directory cache and triggers refresh
        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)
        #expect(store.items(for: win)[0].gitBranch == "branch-b")
    }

    @Test func inFlightInspectionDiscardedWhenInvalidated() async throws {
        let repoURL = try createTestGitRepository(branch: "branch-orig")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pwd = repoURL.path
        win.contentView = surf

        // Kick off first inspection (generation 0)
        _ = store.items(for: win)

        // Invalidate immediately before task can complete, bumping generation to 1
        store.invalidateGitCache(for: repoURL.path)

        // Switch branch on disk
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/branch-new\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Query items again, launching inspection for generation 1
        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)

        let items = store.items(for: win)
        #expect(items[0].gitBranch == "branch-new")
    }

    @Test func globalInvalidationDiscardsFirstEverPendingInspection() async throws {
        let repoURL = try createTestGitRepository(branch: "branch-orig")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pwd = repoURL.path
        win.contentView = surf

        // Kick off first-ever inspection (epoch 0, gen 0)
        _ = store.items(for: win)

        // Perform global invalidation (e.g. optIn toggle or invalidateCaches) while first task is in-flight
        store.invalidateCaches()

        // Switch branch on disk
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/branch-new\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Query items again, launching inspection for epoch 1
        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)

        let items = store.items(for: win)
        #expect(items[0].gitBranch == "branch-new")
    }

    @Test func tabIdentifierAndDescriptionPersistAcrossWindowRestoration() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Restored Tab Surface"
        win.contentView = surf1

        let initialItems = store.items(for: win)
        let tabId = initialItems[0].id
        #expect(tabId == win.stableTabIdentifier)

        // Set description using both tabId and surfaceIds
        store.setDescription("Critical Dev Server", for: tabId, surfaceIds: [surf1.id])
        #expect(store.items(for: win)[0].userDescription == "Critical Dev Server")

        // Simulate encode restorable state
        let internalState = TerminalRestorableState.InternalState(
            focusedSurface: surf1.id.uuidString,
            surfaceTree: SplitTree(view: surf1),
            tabIdentifier: win.stableTabIdentifier
        )
        #expect(internalState.tabIdentifier == tabId)

        // Simulate window reconstruction on restore
        let restoredWin = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        restoredWin.contentView = surf1
        if let restoredTabId = internalState.tabIdentifier {
            restoredWin.stableTabIdentifier = restoredTabId
        }

        let restoredItems = store.items(for: restoredWin)
        #expect(restoredItems[0].id == tabId)
        #expect(restoredItems[0].userDescription == "Critical Dev Server")

        // Also verify surfaceIds fallback when window restoration did not have tabIdentifier (legacy)
        let legacyRestoredWin = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        legacyRestoredWin.contentView = surf1
        let legacyItems = store.items(for: legacyRestoredWin)
        #expect(legacyItems[0].userDescription == "Critical Dev Server")
    }

    @Test func latestNotificationSelectsRecordWithLatestTimestamp() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let notifDefaults = createTestDefaults()
        let notifStore = NotificationStore(defaults: notifDefaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        win.contentView = surf
        let sid = surf.id

        // Inject first notification at t=1000
        notifStore.addNotification(
            id: "notif-1",
            surfaceId: sid,
            paneTitle: "Pane",
            title: "First Notification",
            body: "Body 1",
            time: Date(timeIntervalSince1970: 1000)
        )
        // Inject second notification at t=2000
        notifStore.addNotification(
            id: "notif-2",
            surfaceId: sid,
            paneTitle: "Pane",
            title: "Second Notification",
            body: "Body 2",
            time: Date(timeIntervalSince1970: 2000)
        )

        // Temporary swap of NotificationStore.shared records for testing
        _ = NotificationStore.shared.records
        defer {
            NotificationStore.shared.loadFromDefaults()
        }
        for rec in notifStore.records {
            NotificationStore.shared.addNotification(
                id: rec.id,
                surfaceId: rec.surfaceId,
                paneTitle: rec.paneTitle,
                title: rec.title,
                body: rec.body,
                time: rec.time
            )
        }

        #expect(store.items(for: win)[0].latestNotification == "Second Notification")

        // Update notif-1 in place with newer timestamp t=3000
        NotificationStore.shared.addNotification(
            id: "notif-1",
            surfaceId: sid,
            paneTitle: "Pane",
            title: "Updated First Notification",
            body: "Body 1 Updated",
            time: Date(timeIntervalSince1970: 3000)
        )

        #expect(store.items(for: win)[0].latestNotification == "Updated First Notification")
    }

    @Test func sidebarFiltersAreScopedPerWindowGroup() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Frontend Window"
        win1.contentView = surf1

        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Backend Window"
        win2.contentView = surf2

        // By default, both show their respective window
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win2).count == 1)

        // Scope filter to win1
        store.setFilterText("Frontend", for: win1)
        #expect(store.filterText(for: win1) == "Frontend")
        #expect(store.filterText(for: win2).isEmpty)

        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1)[0].title == "Frontend Window")
        #expect(store.items(for: win2).count == 1)
        #expect(store.items(for: win2)[0].title == "Backend Window")

        // Filter win1 to something that doesn't match
        store.setFilterText("Nomatch", for: win1)
        #expect(store.items(for: win1).isEmpty)
        #expect(store.items(for: win2).count == 1)

        // Reset win1
        store.setFilterText("", for: win1)

        // Scope filterNeedsAttention to win1
        let win1B = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1B = Tako.SurfaceView(frame: .zero)
        surf1B.title = "Frontend Background Worker"
        surf1B.crab.setStatus(.error, text: nil)
        win1B.contentView = surf1B
        Tako.CustomTabGroup.join(win1B, to: win1, select: false)
        let group1 = Tako.CustomTabGroup.group(for: win1)
        group1.select(win1)

        store.setFilterNeedsAttention(true, for: win1)
        #expect(store.filterNeedsAttention(for: win1) == true)
        #expect(store.filterNeedsAttention(for: win2) == false)

        // win1's group filtered to items needing attention shows only win1B (error)
        let win1Filtered = store.items(for: win1)
        #expect(win1Filtered.count == 1)
        #expect(win1Filtered[0].title == "Frontend Background Worker")

        // win2 is unfiltered and still shows its 1 normal tab
        #expect(store.items(for: win2).count == 1)
        #expect(store.items(for: win2)[0].title == "Backend Window")
    }

    @Test func sidebarFiltersPersistWhenSwitchingTabsInSameGroup() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Frontend Client"
        surf2.title = "Frontend Tests"
        win1.contentView = surf1
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        group.select(win1)

        // Set filter on win1
        store.setFilterText("Tests", for: win1)
        store.setFilterNeedsAttention(true, for: win1)

        // Switching to win2 in the same tab group preserves the filter
        #expect(store.filterText(for: win2) == "Tests")
        #expect(store.filterNeedsAttention(for: win2) == true)

        let itemsFromWin2 = store.items(for: win2)
        // With "Tests" and needsAttention (neither has attention), filtered list is empty
        #expect(itemsFromWin2.isEmpty)

        // Clear needsAttention for group
        store.setFilterNeedsAttention(false, for: win2)
        #expect(store.filterNeedsAttention(for: win1) == false)
        let itemsWithTextOnly = store.items(for: win2)
        #expect(itemsWithTextOnly.count == 1)
        #expect(itemsWithTextOnly[0].title == "Frontend Tests")
    }

    @Test func commandProgressingThroughAttentionStatusInvalidatesInspectionsOnTerminalStatus() async throws {
        let repoURL = try createTestGitRepository(branch: "branch-start")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pwd = repoURL.path
        win.contentView = surf

        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)
        #expect(store.items(for: win)[0].gitBranch == "branch-start")

        // Switch branch on disk
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/branch-interactive\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Command starts running
        surf.crab.setStatus(.running, text: nil)

        // Command enters attention state (.waitingForInput) - intermediate state, must NOT invalidate
        surf.crab.setStatus(.waitingForInput, text: nil)
        #expect(store.items(for: win)[0].gitBranch == "branch-start")

        // Command completes (.done) - terminal state from attention state, MUST invalidate
        surf.crab.setStatus(.done, text: nil)

        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)
        #expect(store.items(for: win)[0].gitBranch == "branch-interactive")
    }

    @Test func descendantProcessesAreInspectedForListeningPorts() {
        LocalPortInspection.descendantPidsOverride = { rootPid in
            if rootPid == 500 {
                return [500, 501, 502]
            }
            return [rootPid]
        }
        LocalPortInspection.lsofOutputOverride = { pids in
            #expect(pids.contains(500))
            #expect(pids.contains(501))
            #expect(pids.contains(502))
            return "p501\nf4\nn*:8080\np502\nf5\nn127.0.0.1:3000\n"
        }
        defer {
            LocalPortInspection.descendantPidsOverride = nil
            LocalPortInspection.lsofOutputOverride = nil
        }

        let ports = LocalPortInspection.inspectListeningPorts(pid: 500)
        #expect(ports == [3000, 8080])
    }

    @Test func listeningPortsAggregateAcrossSplitPanesInTab() async throws {
        let pty1 = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory(), program: ["/bin/sleep", "30"]))
        defer { pty1.terminate() }
        let pty2 = try #require(PTY(cols: 80, rows: 24, workingDirectory: NSHomeDirectory(), program: ["/bin/sleep", "30"]))
        defer { pty2.terminate() }

        let pid1 = pty1.foregroundPID ?? Int(pty1.child)
        let pid2 = pty2.foregroundPID ?? Int(pty2.child)

        LocalPortInspection.descendantPidsOverride = { [$0] }
        LocalPortInspection.lsofOutputOverride = { pids in
            if pids.contains(pid1) {
                return "p\(pid1)\nf3\nn*:8000\n"
            } else if pids.contains(pid2) {
                return "p\(pid2)\nf3\nn*:9000\n"
            }
            return ""
        }
        defer {
            LocalPortInspection.descendantPidsOverride = nil
            LocalPortInspection.lsofOutputOverride = nil
        }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInPorts = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let surf1 = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let surf2 = Tako.SurfaceView(frame: NSRect(x: 200, y: 0, width: 200, height: 400))
        surf1.title = "Pane 1"
        surf2.title = "Pane 2"
        surf1.pty = pty1
        surf2.pty = pty2
        container.addSubview(surf1)
        container.addSubview(surf2)
        win.contentView = container

        // First read kicks off async inspection for both PIDs
        _ = store.items(for: win)
        try await waitForPortsInspection(store: store, pids: [pid1, pid2])

        let finalItems = store.items(for: win)
        #expect(finalItems.first?.listeningPorts == [8000, 9000])
    }
}
