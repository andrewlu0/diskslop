import Foundation
import CoreServices
import Darwin

private func canonicalScanPath(_ url: URL) -> String {
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
}

struct ChangedDirectories {
    var shallow = Set<String>()
    var recursive = Set<String>()
    var throughEvent: FSEventStreamEventId = 0
    var outsideSnapshotDirectory = false
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
            return all.shallow.count + all.recursive.count > 4096 ? .full : .paths(all)
        }
    }
}
private final class EventState: @unchecked Sendable {
    private let root: String, mount: String, deviceRelative: Bool
    private let snapshotPath: String, snapshotPrefix: String
    private let directoryHistory: Bool
    init(root: String, mount: String, deviceRelative: Bool, snapshotDirectory: URL, directoryHistory: Bool) {
        self.directoryHistory = directoryHistory
        self.root = root; self.mount = mount; self.deviceRelative = deviceRelative
        let base = canonicalScanPath(snapshotDirectory)
        snapshotPath = deviceRelative && mount == "/System/Volumes/Data" && base != mount && !base.hasPrefix(mount + "/") ? mount + base : base
        snapshotPrefix = snapshotPath + "/"
    }
    private func inventoryPath(_ raw: String) -> String {
        if deviceRelative {
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
    private var onChange: (() -> Void)?
    private var dirty: Bool { lost || !paths.shallow.isEmpty || !paths.recursive.isEmpty }
    func observe(_ notify: (() -> Void)?) {
        let pending = lock.withLock { onChange = notify; return dirty }
        if pending { notify?() }
    }
    func record(_ changes: NSArray, count: Int, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        let unreliable = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let notify: (() -> Void)? = lock.withLock {
            guard !lost else { return nil }
            let wasDirty = dirty
            for i in 0..<count {
                if flags[i] == kFSEventStreamEventFlagHistoryDone { continue }
                guard flags[i] & unreliable == 0, i < changes.count, let raw = changes[i] as? String else { lost = true; break }
                let path = inventoryPath(raw)
                let item = flags[i]
                if deviceRelative { paths.throughEvent = max(paths.throughEvent, ids[i]) }
                if !paths.outsideSnapshotDirectory, path != snapshotPath, !path.hasPrefix(snapshotPrefix) { paths.outsideSnapshotDirectory = true }
                let isFile = item & UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0
                let isFolder = item & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
                if item & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || (!directoryHistory && !isFile && !isFolder) {
                    paths.recursive.insert(path)
                } else {
                    if path != root { paths.shallow.insert((path as NSString).deletingLastPathComponent) }
                    if directoryHistory || isFolder { paths.shallow.insert(path) }
                }
                if paths.shallow.count + paths.recursive.count > (directoryHistory ? 65536 : 4096) { lost = true; paths = ChangedDirectories(); break }
            }
            return !wasDirty && dirty ? onChange : nil
        }
        if UnsafeBufferPointer(start: flags, count: count).contains(where: { $0 & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) {
            historyDone.signal()
        }
        notify?()
    }
    private var pending: CacheChanges { lost ? .full : dirty ? .paths(paths) : .clean }
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
        let relative = root == mount ? "" : root.hasPrefix(mount == "/" ? "/" : mount + "/")
            ? String(root.dropFirst(mount == "/" ? 1 : mount.count + 1)) : nil
        let state = EventState(root: root, mount: mount, deviceRelative: relative != nil, snapshotDirectory: snapshotDirectory, directoryHistory: since != nil)
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
    func historicalChanges() -> CacheChanges {
        guard state.historyDone.wait(timeout: .now() + 5) == .success else { return .full }
        return changes()
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
}

final class ScanCache {
    private var recent: [(key: String, entry: RecentScan)] = []
    func read(_ url: URL) -> RecentScan? {
        let key = url.standardizedFileURL.path
        guard let i = recent.firstIndex(where: { $0.key == key || $0.entry.root.path == key }) else { return nil }
        let hit = recent.remove(at: i); recent.append(hit)
        return hit.entry
    }
    func put(_ entry: RecentScan, for url: URL) {
        recent.removeAll { $0.key == url.standardizedFileURL.path || $0.entry.root == entry.root }
        recent.append((url.standardizedFileURL.path, entry))
        let budget: UInt64 = 512 * 1024 * 1024
        while recent.count > 1 {
            let inventory = recent.reduce(UInt64(0)) { $0 + dt_memory_bytes($1.entry.model.handle) }
            if recent.count <= 3, inventory <= budget,
               recent.reduce(UInt64(0), { $0 + ($1.entry.listing?.geometry.memoryBytes ?? 0) }) <= budget - inventory { break }
            recent.removeFirst()
        }
    }
}
