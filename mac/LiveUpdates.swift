import AppKit
import CoreServices

func performOnMainRunLoop(_ action: @escaping () -> Void) {
    // AppKit runs the modal loop while waiting for a deferred termination reply.
    let loop = CFRunLoopGetMain()
    let modes = [RunLoop.Mode.default.rawValue, RunLoop.Mode.modalPanel.rawValue]
    CFRunLoopPerformBlock(loop, modes as CFArray, action)
    CFRunLoopWakeUp(loop)
}

extension StartupSnapshot {
    init(_ base: Self, through event: FSEventStreamEventId) {
        root = base.root; identity = base.identity; file = base.file; journal = base.journal
        checkpoint = max(base.checkpoint, event)
    }
}

final class LiveCheckpointWriter {
    private struct Candidate {
        weak var model: ScanModel?
        let snapshot: StartupSnapshot
        let began: TimeInterval
        let notices: Int
        var notBefore: TimeInterval = 0

        var due: TimeInterval { max(notBefore, began + (notices >= 512 ? 120 : 900)) }
    }

    private let queue = DispatchQueue(label: "local.diskslop.scan-checkpoints", qos: .utility)
    private var pending: [URL: Candidate] = [:]
    private var timer: DispatchWorkItem?
    private var flushing = false

    func consider(_ scan: RecentScan, notices: Int) {
        guard let snapshot = scan.startupSnapshot else { return }
        let old = pending[snapshot.file]
        guard notices > 0 || old != nil else { return }
        pending[snapshot.file] = Candidate(model: scan.model, snapshot: snapshot,
            began: old?.began ?? CACurrentMediaTime(), notices: min(512, (old?.notices ?? 0) + notices),
            notBefore: old?.notBefore ?? 0)
        schedule()
    }

    func save(_ model: ScanModel, to snapshot: StartupSnapshot, replacingInode: UInt64 = 0) {
        if let old = pending[snapshot.file], old.snapshot.checkpoint <= snapshot.checkpoint {
            pending.removeValue(forKey: snapshot.file)
            schedule()
        }
        queue.async { snapshot.save(model, progress: ScanProgress(), replacingInode: replacingInode) }
    }

    func flush(_ completion: @escaping () -> Void) {
        flushing = true
        timer?.cancel(); timer = nil
        let candidates = Array(pending.values)
        pending.removeAll()
        for candidate in candidates {
            if let model = candidate.model { save(model, to: candidate.snapshot) }
        }
        queue.async {
            FileKindCatalog.shared.flush()
            performOnMainRunLoop(completion)
        }
    }

    private func schedule() {
        timer?.cancel(); timer = nil
        pending = pending.filter { $0.value.model != nil }
        guard let due = pending.values.map(\.due).min() else { return }
        let task = DispatchWorkItem { [weak self] in self?.writeDue() }
        timer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - CACurrentMediaTime()), execute: task)
    }

    private func writeDue() {
        timer = nil
        let now = CACurrentMediaTime()
        let ready = pending.filter { $0.value.due <= now }
        for (file, candidate) in ready {
            pending.removeValue(forKey: file)
            guard let model = candidate.model else { continue }
            queue.async {
                let space = try? file.resourceValues(forKeys: [.fileSizeKey, .volumeAvailableCapacityKey])
                let free = space?.volumeAvailableCapacity ?? Int.max
                let size = space?.fileSize ?? 0
                if free - free / 5 >= size, candidate.snapshot.save(model, progress: ScanProgress()) { return }
                DispatchQueue.main.async {
                    guard !self.flushing, self.pending[file] == nil else { return }
                    var retry = candidate
                    retry.notBefore = CACurrentMediaTime() + 900
                    self.pending[file] = retry
                    self.schedule()
                }
            }
        }
        schedule()
    }
}

func chartFrameRate(_ refreshRate: Int) -> CAFrameRateRange {
    let rate = Float(refreshRate > 0 ? refreshRate : 60)
    return CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
}

extension NSView {
    var displayRefreshRate: Int {
        let rate = (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 0
        return rate > 0 ? rate : 60
    }
}

private final class DisplayTick: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

final class ChartFrameClock {
    private var invalidate: (() -> Void)?
    var running: Bool { invalidate != nil }
    func start(on view: NSView, _ update: @escaping () -> Void) {
        guard !running else { return }
        if #available(macOS 14.0, *), view.window != nil {
            let link = view.displayLink(target: DisplayTick(update), selector: #selector(DisplayTick.tick))
            link.preferredFrameRateRange = chartFrameRate(view.displayRefreshRate)
            invalidate = { link.invalidate() }
            link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(timeInterval: 1 / Double(view.displayRefreshRate), repeats: true) { _ in update() }
            invalidate = { timer.invalidate() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func stop() { invalidate?(); invalidate = nil }
    deinit { stop() }
}

final class ChartMotion {
    static let duration: TimeInterval = 0.22
    static let timingFunction = CAMediaTimingFunction(controlPoints: 1/3, 1, 2/3, 1)
    static func easeOut(_ time: Double) -> Double {
        let remaining = 1 - time
        return 1 - remaining * remaining * remaining
    }
    private let clock = ChartFrameClock()
    private var deadline: DispatchWorkItem?
    private(set) var fraction: CGFloat = 1
    func stop() {
        clock.stop(); deadline?.cancel(); deadline = nil; fraction = 1
    }
    func start(on view: NSView, _ update: @escaping () -> Void) {
        stop()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { update(); return }
        let start = CACurrentMediaTime()
        fraction = 0; update()
        clock.start(on: view) { [weak self] in
            guard let self else { return }
            let t = min(1, (CACurrentMediaTime() - start) / Self.duration)
            self.fraction = Self.easeOut(t)
            if t == 1 { self.stop() }
            update()
        }
        let finish = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stop(); update()
        }
        deadline = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: finish)
    }
}

/// The event journal stays with the cached scan. Only the displayed scan has a subscriber.
final class LiveUpdates {
    let queue = DispatchQueue(label: "local.diskslop.live-updates", qos: .utility)
    var refresh: ((RecentScan, ScanProgress, CacheChanges) -> Void)?
    private(set) var source: RecentScan?
    private(set) var work: ScanProgress?
    private var pending: DispatchWorkItem?
    private var retryDelay: TimeInterval = 2
    private var started: TimeInterval = 0, nextUpdate: TimeInterval = 0
    private var batchDelay: TimeInterval { max(0.035, nextUpdate - CACurrentMediaTime()) }

    func follow(_ entry: RecentScan?) {
        guard source !== entry else { return }
        source?.watcher?.observe(nil)
        pending?.cancel(); pending = nil
        if let work { dt_cancel(work.handle); self.work = nil; source?.watcher?.endBatch(committed: false) }
        source = entry
        retryDelay = 2
        guard let entry else { return }
        if let watcher = entry.watcher {
            watcher.observe { [weak self, weak entry] in
                DispatchQueue.main.async {
                    guard let self, let entry, self.source === entry else { return }
                    self.schedule(after: self.batchDelay)
                }
            }
        } else {
            schedule(after: max(5, entry.elapsed * 4))
        }
    }

    func finish(_ progress: ScanProgress, retry: Bool = false, failed: Bool = false) {
        guard work === progress else { return }
        work = nil
        source?.watcher?.endBatch(committed: !retry && !failed)
        if failed {
            schedule(after: retryDelay)
            retryDelay = min(60, retryDelay * 2)
        } else if retry { schedule(after: 0.12) }
        else {
            let now = CACurrentMediaTime()
            nextUpdate = now + max(0.32, min(1, (now - started) / 2))
            if source?.watcher?.hasChanges == true { schedule(after: batchDelay) }
            else if source?.watcher == nil { schedule(after: max(5, (now - started) * 4)) }
        }
    }

    private func schedule(after delay: TimeInterval) {
        guard pending == nil, work == nil, let source else { return }
        let next = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source, self.source === source else { return }
            self.pending = nil
            let changes = source.watcher?.beginBatch() ?? .full
            if case .clean = changes { return }
            let progress = ScanProgress()
            self.started = CACurrentMediaTime()
            self.work = progress
            self.refresh?(source, progress, changes)
        }
        pending = next
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
    }
}
