import Foundation
import CoreServices
import Darwin

struct RootIdentity: Equatable {
    let device: dev_t, inode: ino_t
    let isLocal: Bool
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
    }
}

enum CacheChanges { case clean, paths(Set<String>), full }
private final class EventState: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()
    private var lost = false
    func record(_ changes: NSArray, count: Int, flags: UnsafePointer<FSEventStreamEventFlags>) {
        let unreliable = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        lock.withLock {
            guard !lost else { return }
            for i in 0..<count {
                if flags[i] == kFSEventStreamEventFlagHistoryDone { continue }
                guard flags[i] & unreliable == 0, i < changes.count, let path = changes[i] as? String else { lost = true; break }
                paths.insert(path)
                if paths.count > 128 { lost = true; paths.removeAll(); break }
            }
        }
    }
    var changes: CacheChanges { lock.withLock { lost ? .full : paths.isEmpty ? .clean : .paths(paths) } }
}

final class ChangeWatch: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let state: EventState
    private let queue = DispatchQueue(label: "local.diskslop.filesystem-events", qos: .utility)

    init?(url: URL, identity: RootIdentity?) {
        guard identity?.isLocal == true else { return nil }
        let state = EventState()
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(),
            retain: { raw in _ = Unmanaged<EventState>.fromOpaque(raw!).retain(); return raw },
            release: { raw in Unmanaged<EventState>.fromOpaque(raw!).release() }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, _ in
            guard let context else { return }
            let state = Unmanaged<EventState>.fromOpaque(context).takeUnretainedValue()
            state.record(unsafeBitCast(paths, to: NSArray.self), count: count, flags: flags)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &ctx, [url.path] as CFArray,
            FSEventsGetCurrentEventId(), 0.08, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil
        }
        self.stream = stream; self.state = state
    }
    func changes() -> CacheChanges {
        if case .full = state.changes { return .full }
        FSEventStreamFlushSync(stream)
        queue.sync {}
        return state.changes
    }
    deinit {
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    }
}

final class RecentScan: @unchecked Sendable {
    let model: ScanModel, listing: FolderListing, root: URL
    let identity: RootIdentity?, watcher: ChangeWatch?
    let elapsed: Double
    init(model: ScanModel, listing: FolderListing, root: URL, identity: RootIdentity?, watcher: ChangeWatch?, elapsed: Double) {
        self.model = model; self.listing = listing; self.root = root; self.identity = identity; self.watcher = watcher; self.elapsed = elapsed
    }
}

final class ScanCache {
    private var recent: [(key: String, entry: RecentScan, bytes: UInt64)] = []
    func read(_ url: URL) -> RecentScan? {
        let key = url.standardizedFileURL.path
        guard let i = recent.firstIndex(where: { $0.key == key }) else { return nil }
        let hit = recent.remove(at: i); recent.append(hit)
        return hit.entry
    }
    func remove(_ url: URL) { recent.removeAll { $0.key == url.standardizedFileURL.path } }
    func remove(_ model: ScanModel) { recent.removeAll { $0.entry.model === model } }
    func put(_ entry: RecentScan, for url: URL) {
        remove(url)
        let bytes = dt_memory_bytes(entry.model.handle) + entry.listing.geometry.memoryBytes
        recent.append((url.standardizedFileURL.path, entry, bytes))
        while recent.count > 1 && (recent.count > 3 || recent.reduce(UInt64(0), { $0 + $1.bytes }) > 512 * 1024 * 1024) { recent.removeFirst() }
    }
}
