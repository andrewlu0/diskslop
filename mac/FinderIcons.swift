import AppKit
import UniformTypeIdentifiers

protocol FinderIconTarget: AnyObject {
    var finderImage: NSImage? { get set }
}

extension NSImageView: FinderIconTarget {
    var finderImage: NSImage? {
        get { image }
        set { image = newValue; imageScaling = .scaleProportionallyUpOrDown; contentTintColor = nil }
    }
}

final class FinderIcons {
    private final class Request: NSObject {
        let url: URL
        let job: BlockOperation
        init(url: URL, job: BlockOperation) {
            self.url = url
            self.job = job
        }
        deinit { job.cancel() }
    }

    private let requests = NSMapTable<AnyObject, Request>.weakToStrongObjects()
    private let cache = NSCache<NSURL, NSImage>()
    private let queue = OperationQueue()
    private var pending: [BlockOperation] = []
    private let folder = NSWorkspace.shared.icon(for: .folder)
    private let file = NSWorkspace.shared.icon(for: .data)
    private let link = NSWorkspace.shared.icon(for: .symbolicLink)

    init() {
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        cache.countLimit = 768
    }

    func reset() {
        queue.cancelAllOperations()
        pending.forEach { $0.cancel() }
        requests.removeAllObjects()
        cache.removeAllObjects()
    }

    func display<T: FinderIconTarget>(_ url: URL?, in imageView: T, row: DTRow) {
        display(url, in: imageView, placeholder: row.isFolder ? folder : row.kind == 2 ? link : file)
    }

    func displayFolder(_ url: URL, in imageView: NSImageView) {
        display(url, in: imageView, placeholder: folder)
    }

    private func display<T: FinderIconTarget>(_ url: URL?, in imageView: T, placeholder: NSImage) {
        if let url, requests.object(forKey: imageView)?.url == url { return }
        requests.removeObject(forKey: imageView)
        guard let url else {
            imageView.finderImage = nil
            return
        }
        if let icon = cache.object(forKey: url as NSURL) {
            imageView.finderImage = icon
            return
        }
        imageView.finderImage = placeholder
        let job = BlockOperation()
        let request = Request(url: url, job: job)
        requests.setObject(request, forKey: imageView)
        job.addExecutionBlock { [weak self, weak request, weak imageView] in
            guard let request, !request.job.isCancelled else { return }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            DispatchQueue.main.async {
                guard let self, let imageView, self.requests.object(forKey: imageView) === request else { return }
                self.cache.setObject(icon, forKey: url as NSURL)
                imageView.finderImage = icon
                self.requests.removeObject(forKey: imageView)
            }
        }
        if pending.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let jobs = self.pending.filter { !$0.isCancelled }
                self.pending.removeAll(keepingCapacity: true)
                self.queue.addOperations(jobs, waitUntilFinished: false)
            }
        }
        pending.append(job)
    }
}
