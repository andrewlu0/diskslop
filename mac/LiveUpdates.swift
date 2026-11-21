import AppKit
import CoreServices

extension StartupSnapshot {
    init(_ base: Self, through event: FSEventStreamEventId) {
        root = base.root; identity = base.identity; file = base.file; journal = base.journal
        checkpoint = max(base.checkpoint, event)
    }
}

/// Publishes the newest committed inventory on a bounded cadence without retaining an evicted scan.
final class LiveCheckpointWriter {
    private struct Candidate {
        weak var model: ScanModel?
        let snapshot: StartupSnapshot
    }
    private let queue = DispatchQueue(label: "local.diskslop.live-checkpoints", qos: .utility)
    private let ordinaryInterval: TimeInterval, busyInterval: TimeInterval
    private var candidate: Candidate?, work: ScanProgress?, timer: DispatchWorkItem?
    private var notices = 0
    private var firstChange: TimeInterval = 0, scheduled: TimeInterval = 0, earliest: TimeInterval = 0

    init(ordinaryInterval: TimeInterval = 900, busyInterval: TimeInterval = 120) {
        self.ordinaryInterval = ordinaryInterval; self.busyInterval = busyInterval
    }

    func consider(_ scan: RecentScan, notices newNotices: Int) {
        guard let snapshot = scan.startupSnapshot, newNotices > 0 || candidate != nil else { return }
        if candidate == nil { firstChange = CACurrentMediaTime() }
        candidate = Candidate(model: scan.model, snapshot: snapshot)
        notices = min(512, notices + newNotices)
        schedule()
    }

    func cancel() {
        timer?.cancel(); timer = nil
        candidate = nil; notices = 0
        if let work { dt_cancel(work.handle) }
    }

    private func schedule() {
        guard candidate != nil, work == nil else { return }
        let deadline = max(earliest, firstChange + (notices >= 512 ? busyInterval : ordinaryInterval))
        if timer != nil && scheduled <= deadline { return }
        timer?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.write() }
        timer = task; scheduled = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime()), execute: task)
    }

    private func write() {
        timer = nil
        guard let pending = candidate, let model = pending.model else { candidate = nil; notices = 0; return }
        let weight = notices, progress = ScanProgress(), start = CACurrentMediaTime()
        candidate = nil; notices = 0; work = progress
        let minimum = busyInterval, regular = ordinaryInterval
        queue.async {
            let file = pending.snapshot.file
            let info = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .volumeAvailableCapacityKey])
            let age = info?.contentModificationDate.map { max(0, -$0.timeIntervalSinceNow) } ?? minimum
            var delay = max(0, minimum - age)
            if let size = info?.fileSize, let free = info?.volumeAvailableCapacity, free - free / 5 < size { delay = regular }
            if delay == 0, !dt_is_cancelled(progress.handle), !pending.snapshot.save(model, progress: progress) { delay = regular }
            let elapsed = CACurrentMediaTime() - start, retryAfter = delay
            DispatchQueue.main.async {
                self.work = nil
                if !dt_is_cancelled(progress.handle) {
                    self.earliest = CACurrentMediaTime() + (retryAfter > 0 ? retryAfter : max(minimum, elapsed * 100))
                    if retryAfter > 0, self.candidate == nil {
                        self.candidate = pending; self.firstChange = start - regular; self.notices = weight
                    }
                }
                self.schedule()
            }
        }
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
