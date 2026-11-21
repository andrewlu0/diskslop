import Foundation
import CoreServices
import Darwin

func canonicalScanPath(_ url: URL) -> String {
    var parent = url
    var missing: [String] = []
    while true {
        let resolved: String? = parent.withUnsafeFileSystemRepresentation { path in
            guard let path, let actual = realpath(path, nil) else { return nil }
            defer { free(actual) }
            return FileManager.default.string(withFileSystemRepresentation: actual, length: strlen(actual))
        }
        if let resolved {
            guard !missing.isEmpty else { return resolved }
            return (resolved == "/" ? "" : resolved) + "/" + missing.reversed().joined(separator: "/")
        }
        let next = parent.deletingLastPathComponent()
        guard !parent.lastPathComponent.isEmpty, next.path != parent.path else { return url.path }
        missing.append(parent.lastPathComponent); parent = next
    }
}

func isWithin(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}

struct RootIdentity: Equatable {
    let device: dev_t, inode: ino_t
    let isLocal: Bool
    let mount: String
    init?(_ url: URL) {
        var file = stat()
        var volume = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return fstat(fd, &file) == 0 && fstatfs(fd, &volume) == 0
        }
        guard result else { return nil }
        device = file.st_dev; inode = file.st_ino
        isLocal = volume.f_flags & UInt32(MNT_LOCAL) != 0
        mount = withUnsafeBytes(of: volume.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    func devicePath(_ root: String) -> String? {
        if root == mount { return "" }
        if isWithin(root, mount) { return String(root.dropFirst(mount == "/" ? 1 : mount.count + 1)) }
        if mount == StartupSnapshot.startupPath,
           RootIdentity(URL(fileURLWithPath: mount + root, isDirectory: true)) == self {
            return String(root.dropFirst())
        }
        return nil
    }

    static func canReadDirectory(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { return false }
            close(fd)
            return true
        }
    }
}

struct ChangedDirectories {
    static let limit = 131_072
    var shallow = Set<String>()
    var recursive = Set<String>()
    var throughEvent: FSEventStreamEventId = 0
    var outsideSnapshotDirectory = false
    var hardLinkEvents = false
    var sawRemoval = false
}
enum CacheChanges {
    case clean, paths(ChangedDirectories), full
    func including(_ other: Self) -> Self {
        switch (self, other) {
        case (.full, _), (_, .full): return .full
        case (.clean, _): return other
        case (_, .clean): return self
        case (.paths(var all), .paths(let more)):
            all.shallow.formUnion(more.shallow); all.recursive.formUnion(more.recursive)
            all.throughEvent = max(all.throughEvent, more.throughEvent)
            all.outsideSnapshotDirectory = all.outsideSnapshotDirectory || more.outsideSnapshotDirectory
            all.hardLinkEvents = all.hardLinkEvents || more.hardLinkEvents
            all.sawRemoval = all.sawRemoval || more.sawRemoval
            return all.shallow.count + all.recursive.count > ChangedDirectories.limit ? .full : .paths(all)
        }
    }
}
private final class EventState: @unchecked Sendable {
    private let root: String, mount: String, deviceRoot: String?
    private let snapshotPath: String, snapshotPrefix: String
    private let policyPaths: [String]
    private let directoryHistory: Bool
    init(root: String, mount: String, relative: String?, snapshotDirectory: URL, directoryHistory: Bool, policyPaths: [String]) {
        self.directoryHistory = directoryHistory
        self.root = root; self.mount = mount; self.policyPaths = policyPaths
        deviceRoot = relative.map { $0.isEmpty ? mount : (mount == "/" ? "" : mount) + "/" + $0 }
        let base = canonicalScanPath(snapshotDirectory)
        snapshotPath = relative != nil && mount == "/System/Volumes/Data" && !isWithin(base, mount) ? mount + base : base
        snapshotPrefix = snapshotPath + "/"
    }
    private func mountedPath(_ raw: String) -> String {
        if deviceRoot != nil {
            if raw == mount || raw.hasPrefix(mount + "/") { return raw }
            if raw.isEmpty || raw == "/" { return mount }
            return (mount == "/" ? "" : mount) + (raw.hasPrefix("/") ? raw : "/" + raw)
        }
        if mount != "/", raw.hasPrefix(mount + "/"), !raw.hasPrefix(root + "/") {
            let alias = String(raw.dropFirst(mount.count))
            if alias == root || alias.hasPrefix(root + "/") { return alias }
        }
        return raw
    }
    let historyDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var paths = ChangedDirectories()
    private var lost = false
    private var reading: CacheChanges = .clean
    private var historyActivity = DispatchTime.now()
    private var onChange: (() -> Void)?
    private var dirty: Bool { lost || !paths.shallow.isEmpty || !paths.recursive.isEmpty }
    func observe(_ notify: (() -> Void)?) {
        let pending = lock.withLock { onChange = notify; return dirty }
        if pending { notify?() }
    }
    func record(_ changes: NSArray, count: Int, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        let unreliable = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let historyMarker = UnsafeBufferPointer(start: flags, count: count).contains {
            $0 & UInt32(kFSEventStreamEventFlagHistoryDone) != 0
        }
        let notify: (() -> Void)? = lock.withLock {
            guard !lost else { return nil }
            if directoryHistory { historyActivity = .now() }
            let wasDirty = dirty
            for i in 0..<count {
                if flags[i] == kFSEventStreamEventFlagHistoryDone { continue }
                guard flags[i] & unreliable == 0, i < changes.count, let raw = changes[i] as? String else { lost = true; break }
                let mounted = mountedPath(raw)
                let item = flags[i]
                let recursive = item & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                if policyPaths.contains(where: { isWithin(mounted, $0) || (recursive && isWithin($0, mounted)) }) {
                    lost = true; break
                }
                let watched = deviceRoot ?? root
                guard isWithin(mounted, watched) else {
                    if recursive && isWithin(watched, mounted) { lost = true; break }
                    continue
                }
                let suffix = mounted.dropFirst(watched == "/" && mounted != "/" ? 0 : watched.count)
                let path = watched == root ? mounted : root + suffix
                if item & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { paths.sawRemoval = true }
                if deviceRoot != nil { paths.throughEvent = max(paths.throughEvent, ids[i]) }
                if item & UInt32(kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink) != 0 {
                    paths.hardLinkEvents = true
                }
                if !paths.outsideSnapshotDirectory, mounted != snapshotPath, !mounted.hasPrefix(snapshotPrefix) { paths.outsideSnapshotDirectory = true }
                let isFile = item & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0
                let isFolder = item & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                if recursive || (!directoryHistory && !isFile && !isFolder) {
                    paths.recursive.insert(path)
                } else {
                    if path != root { paths.shallow.insert((path as NSString).deletingLastPathComponent) }
                    if directoryHistory || isFolder { paths.shallow.insert(path) }
                }
                if paths.shallow.count + paths.recursive.count > ChangedDirectories.limit { lost = true; paths = ChangedDirectories(); break }
            }
            return !wasDirty && dirty ? onChange : nil
        }
        if historyMarker || lock.withLock({ lost }) { historyDone.signal() }
        notify?()
    }
    private var pending: CacheChanges { lost ? .full : dirty ? .paths(paths) : .clean }
    var historyIdleDeadline: DispatchTime { lock.withLock { historyActivity + 6 } }
    var changes: CacheChanges { lock.withLock { reading.including(pending) } }
    func beginBatch() -> CacheChanges {
        lock.withLock {
            reading = reading.including(pending)
            paths = ChangedDirectories(); lost = false
            return reading
        }
    }
    func endBatch(committed: Bool) {
        lock.withLock {
            if !committed {
                switch reading.including(pending) {
                case .full: lost = true; paths = ChangedDirectories()
                case .paths(let all): paths = all
                case .clean: break
                }
            }
            reading = .clean
        }
    }
}

final class ChangeWatch: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let state: EventState
    private let queue = DispatchQueue(label: "local.diskslop.filesystem-events", qos: .utility)

    init?(url: URL, identity: RootIdentity?, since: FSEventStreamEventId? = nil, snapshotDirectory: URL = StartupSnapshot.directory) {
        guard let identity, identity.isLocal else { return nil }
        let root = canonicalScanPath(url), mount = identity.mount
        let relative = identity.devicePath(root)
        let policies = since != nil && mount == StartupSnapshot.startupPath ? StartupSnapshot.policyPaths : []
        let state = EventState(root: root, mount: mount, relative: relative, snapshotDirectory: snapshotDirectory,
                               directoryHistory: since != nil, policyPaths: policies)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { raw in _ = Unmanaged<EventState>.fromOpaque(raw!).retain(); return raw },
            release: { raw in Unmanaged<EventState>.fromOpaque(raw!).release() }, copyDescription: nil)
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        if since == nil {
            flags |= UInt32(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        } else {
            flags |= UInt32(kFSEventStreamCreateFlagFullHistory)
        }
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
            guard let context else { return }
            let state = Unmanaged<EventState>.fromOpaque(context).takeUnretainedValue()
            state.record(unsafeBitCast(paths, to: NSArray.self), count: count, flags: flags, ids: ids)
        }
        let created: FSEventStreamRef?
        if let relative {
            created = FSEventStreamCreateRelativeToDevice(nil, callback, &ctx, identity.device, [relative] as CFArray,
                since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.08, flags)
        } else {
            guard since == nil else { return nil }
            created = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, FSEventsGetCurrentEventId(), 0.08, flags)
        }
        guard let stream = created else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil
        }
        self.stream = stream; self.state = state
    }
    func historicalChanges(progress: ScanProgress, deadline: DispatchTime) -> CacheChanges {
        repeat {
            if state.historyDone.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .success { return changes() }
        } while DispatchTime.now() < min(deadline, state.historyIdleDeadline) && !dt_is_cancelled(progress.handle)
        return .full
    }
    func changes() -> CacheChanges {
        if case .full = state.changes { return .full }
        FSEventStreamFlushSync(stream)
        queue.sync {}
        return state.changes
    }
    func observe(_ notify: (() -> Void)?) { state.observe(notify) }
    func beginBatch() -> CacheChanges { state.beginBatch() }
    func endBatch(committed: Bool) { state.endBatch(committed: committed) }
    var hasChanges: Bool { if case .clean = state.changes { return false }; return true }
    deinit {
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    }
}

final class RecentScan: @unchecked Sendable {
    let model: ScanModel, listing: FolderListing?, root: URL
    let summary: DTSummary
    let identity: RootIdentity?, watcher: ChangeWatch?
    let elapsed: Double
    let startupSnapshot: StartupSnapshot?
    init(model: ScanModel, listing: FolderListing?, root: URL, identity: RootIdentity?, watcher: ChangeWatch?, elapsed: Double, startupSnapshot: StartupSnapshot? = nil) {
        summary = listing?.summary ?? dt_summary(model.handle, 0)
        self.startupSnapshot = startupSnapshot
        self.model = model; self.listing = listing; self.root = root; self.identity = identity; self.watcher = watcher; self.elapsed = elapsed
    }

    func subtree(at url: URL, identity target: RootIdentity, progress: ScanProgress) -> ScanModel? {
        guard identity?.device == target.device, RootIdentity(root) == identity, let watcher else { return nil }
        let canonical = canonicalScanPath(url)
        let candidates = [canonical, target.devicePath(canonical).map { (target.mount == "/" ? "" : target.mount) + "/" + $0 }]
        guard let folder = candidates.compactMap({ $0 }).lazy.compactMap({
            self.model.route(to: URL(fileURLWithPath: $0, isDirectory: true))?.last
        }).first(where: \.isFolder) else { return nil }
        guard let scope = model.url(folder: folder.child, directory: true)?.path else { return nil }
        let scopedChanges: ChangedDirectories
        switch watcher.changes() {
        case .full: return nil
        case .clean: scopedChanges = ChangedDirectories()
        case .paths(let changes):
            guard !changes.hardLinkEvents, !changes.recursive.contains(where: { isWithin(scope, $0) }) else { return nil }
            func rebase(_ paths: Set<String>) -> Set<String> {
                Set(paths.lazy.filter { isWithin($0, scope) }.map { canonical + $0.dropFirst(scope.count) })
            }
            scopedChanges = ChangedDirectories(shallow: rebase(changes.shallow), recursive: rebase(changes.recursive))
        }
        guard let projected = model.subtree(folder: folder.child, at: url, progress: progress) else { return nil }
        return try? projected.refreshed(changes: scopedChanges, retryIssues: true, progress: progress)
    }
}

final class ScanCache {
    private var recent: [(key: String, entry: RecentScan)] = []
    func read(_ url: URL) -> RecentScan? {
        let key = url.standardizedFileURL.path
        guard let i = recent.firstIndex(where: { $0.key == key || $0.entry.root.path == key }) else { return nil }
        let hit = recent.remove(at: i); recent.append(hit)
        return hit.entry
    }
    func parents(of url: URL) -> [RecentScan] {
        let root = canonicalScanPath(url)
        let mounted = StartupSnapshot.startupPath != "/" && !isWithin(root, StartupSnapshot.startupPath)
            ? StartupSnapshot.startupPath + root : root
        return recent.map(\.entry).filter {
            let source = canonicalScanPath($0.root)
            return source != root && source != mounted && (isWithin(root, source) || isWithin(mounted, source))
        }.sorted { $0.root.path.count > $1.root.path.count }
    }
    func put(_ entry: RecentScan, for url: URL) {
        recent.removeAll { $0.key == url.standardizedFileURL.path || $0.entry.root == entry.root }
        recent.append((url.standardizedFileURL.path, entry))
        let budget = min(2 * 1024 * 1024 * 1024, max(512 * 1024 * 1024, ProcessInfo.processInfo.physicalMemory / 32))
        while recent.count > 1 {
            let inventory = recent.reduce(UInt64(0)) { $0 + dt_memory_bytes($1.entry.model.handle) }
            if recent.count <= 3, inventory <= budget,
               recent.reduce(UInt64(0), { $0 + ($1.entry.listing?.geometry.memoryBytes ?? 0) }) <= budget - inventory { break }
            recent.removeFirst()
        }
    }
}
