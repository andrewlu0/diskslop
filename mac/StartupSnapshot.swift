import Foundation
import CoreServices

struct StartupSnapshot {
    let root: URL, identity: RootIdentity, file: URL
    let journal: UUID, checkpoint: FSEventStreamEventId

    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.diskslop.app", isDirectory: true)
        .appendingPathComponent("ScanIndex", isDirectory: true)

    static func forStartupVolume(_ url: URL, identity: RootIdentity?) -> Self? {
        guard let identity, identity.isLocal, url.path == identity.mount,
              url.path == "/System/Volumes/Data" || (url.path == "/" && !FileManager.default.fileExists(atPath: "/System/Volumes/Data"))
        else { return nil }
        return Self(root: url, identity: identity, file: directory.appendingPathComponent("startup.index"))
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
        return withUnsafeBytes(of: journal.uuid) { bytes in
            file.withUnsafeFileSystemRepresentation {
                dt_snapshot_save(model.handle, $0, bytes.bindMemory(to: UInt8.self).baseAddress, checkpoint, replacingInode, progress.handle)
            }
        }
    }

    func restore(progress: ScanProgress) throws -> ScanModel? {
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
        guard event > 0, event <= max(checkpoint, FSEventsGetCurrentEventId()), let history = ChangeWatch(url: root, identity: identity, since: event) else { return nil }
        let changed: ChangedDirectories
        switch history.historicalChanges() {
        case .full: return nil
        case .clean: changed = ChangedDirectories()
        case .paths(let paths):
            let policyDirectory = "/Library/Application Support/com.apple.TCC"
            let mount = identity.mount == "/" ? "" : identity.mount
            let policyPaths = [mount + policyDirectory, mount + FileManager.default.homeDirectoryForCurrentUser.path + policyDirectory]
            guard !paths.recursive.contains(root.path),
                  !policyPaths.contains(where: { paths.shallow.contains($0) || paths.recursive.contains($0) }) else { return nil }
            changed = paths
        }
        guard Self.journalID(identity.device) == journal, RootIdentity(root) == identity else { return nil }
        return try model.refreshed(changes: changed, retryIssues: true, progress: progress)
    }
}
