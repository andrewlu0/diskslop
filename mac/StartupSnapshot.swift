import Foundation
import CoreServices
import CryptoKit

struct StartupSnapshot {
    let root: URL, identity: RootIdentity, file: URL
    let journal: UUID, checkpoint: FSEventStreamEventId

    static let startupPath = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
    static let policyPaths: [String] = {
        let policy = "/Library/Application Support/com.apple.TCC"
        let mount = startupPath == "/" ? "" : startupPath
        return [mount + policy, mount + FileManager.default.homeDirectoryForCurrentUser.path + policy]
    }()
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.diskslop.app", isDirectory: true)
        .appendingPathComponent("ScanIndex", isDirectory: true)

    static func forRoot(_ url: URL, identity: RootIdentity?) -> Self? {
        let path = canonicalScanPath(url)
        guard let identity, identity.isLocal, identity.devicePath(path) != nil else { return nil }
        let file: URL
        if path == startupPath {
            file = directory.appendingPathComponent("startup.index")
        } else {
            let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            file = directory.appendingPathComponent("folder-\(key).index")
        }
        return Self(root: URL(fileURLWithPath: path, isDirectory: true), identity: identity, file: file)
    }

    init?(root: URL, identity: RootIdentity, file: URL, checkpoint: FSEventStreamEventId? = nil) {
        guard identity.isLocal, let journal = Self.journalID(identity.device) else { return nil }
        let cursor = checkpoint ?? FSEventsGetLastEventIdForDeviceBeforeTime(identity.device, Date().timeIntervalSince1970)
        guard cursor > 0 && cursor != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) else { return nil }
        self.root = root
        self.identity = identity
        self.file = file
        self.journal = journal
        self.checkpoint = cursor
    }

    private static func journalID(_ device: dev_t) -> UUID? {
        guard let id = FSEventsCopyUUIDForDevice(device) else { return nil }
        let b = CFUUIDGetUUIDBytes(id)
        return UUID(uuid: (b.byte0,b.byte1,b.byte2,b.byte3,b.byte4,b.byte5,b.byte6,b.byte7,
                           b.byte8,b.byte9,b.byte10,b.byte11,b.byte12,b.byte13,b.byte14,b.byte15))
    }

    var needsRenewal: Bool {
        guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return true }
        return Date().timeIntervalSince(date) > 3600
    }

    var fileInode: UInt64 {
        var info = stat()
        return file.withUnsafeFileSystemRepresentation { lstat($0!, &info) == 0 ? UInt64(info.st_ino) : 0 }
    }

    @discardableResult
    func save(_ model: ScanModel, progress: ScanProgress, replacingInode: UInt64 = 0) -> Bool {
        guard Self.journalID(identity.device) == journal, RootIdentity(root) == identity else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return false }
        let saved = withUnsafeBytes(of: journal.uuid) { bytes in
            file.withUnsafeFileSystemRepresentation {
                dt_snapshot_save(model.handle, $0, bytes.bindMemory(to: UInt8.self).baseAddress, checkpoint, replacingInode, progress.handle)
            }
        }
        if saved, file.deletingLastPathComponent() == Self.directory, root.path != Self.startupPath {
            Self.trimFolderIndexes(keeping: file)
        }
        return saved
    }

    private static func trimFolderIndexes(keeping file: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let indexes = files.compactMap { url -> (URL, Date, Int)? in
            guard url.lastPathComponent.hasPrefix("folder-"), url.pathExtension == "index",
                  let values = try? url.resourceValues(forKeys: keys),
                  let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (offset, index) in indexes.enumerated() {
            bytes += index.2
            if index.0 != file && (offset >= 8 || bytes > 512 * 1024 * 1024) { try? FileManager.default.removeItem(at: index.0) }
        }
    }

    func restore(progress: ScanProgress, preview: (ScanModel) -> Void) throws -> (model: ScanModel, notices: Int)? {
        guard fileInode != 0, RootIdentity.canReadDirectory(root) else { return nil }
        let deadline = DispatchTime.now() + 15
        let cursor = withUnsafeBytes(of: journal.uuid) { bytes in
            file.withUnsafeFileSystemRepresentation { file in
                root.withUnsafeFileSystemRepresentation { path in
                    dt_snapshot_checkpoint(file, path, bytes.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        guard cursor > 0, cursor <= max(checkpoint, FSEventsGetCurrentEventId()),
              let history = ChangeWatch(url: root, identity: identity, since: cursor) else { return nil }
        var policyHistory: [ChangeWatch] = []
        if identity.mount == Self.startupPath && root.path != identity.mount {
            for path in Self.policyPaths {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                guard let policy = RootIdentity(url), policy.device == identity.device else { continue }
                guard let watch = ChangeWatch(url: url, identity: policy, since: cursor) else { return nil }
                policyHistory.append(watch)
            }
        }
        var event: UInt64 = 0
        let handle = withUnsafeBytes(of: journal.uuid) { bytes in
            file.withUnsafeFileSystemRepresentation { file in
                root.withUnsafeFileSystemRepresentation { path in
                    dt_snapshot_load(file, path, bytes.bindMemory(to: UInt8.self).baseAddress, &event, progress.handle)
                }
            }
        }
        guard let handle else { return nil }
        let model = ScanModel(handle: handle)
        guard event == cursor else { return nil }
        for watch in policyHistory {
            guard case .clean = watch.historicalChanges(progress: progress, deadline: deadline) else { return nil }
        }
        let changed: ChangedDirectories
        switch history.historicalChanges(progress: progress, deadline: deadline) {
        case .full: return nil
        case .clean: changed = ChangedDirectories()
        case .paths(let paths):
            guard !paths.recursive.contains(root.path) else { return nil }
            changed = paths
        }
        guard Self.journalID(identity.device) == journal, RootIdentity(root) == identity else { return nil }
        if !changed.shallow.isEmpty || !changed.recursive.isEmpty || dt_summary(model.handle, 0).issues != 0 { preview(model) }
        let restored = try model.refreshed(changes: changed, retryIssues: true, progress: progress)
        let notices = changed.outsideSnapshotDirectory ? changed.shallow.count + changed.recursive.count : 0
        return (restored, notices)
    }
}
