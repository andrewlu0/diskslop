import AppKit
import ApplicationServices

enum DockEdge: String {
    case bottom, left, right

    func inset(_ frame: CGRect, visible: CGRect) -> CGFloat {
        switch self {
        case .bottom: return visible.minY - frame.minY
        case .left: return visible.minX - frame.minX
        case .right: return frame.maxX - visible.maxX
        }
    }

    func approach(to point: CGPoint, by distance: CGFloat) -> CGPoint {
        switch self {
        case .bottom: return CGPoint(x: point.x, y: point.y + distance)
        case .left: return CGPoint(x: point.x + distance, y: point.y)
        case .right: return CGPoint(x: point.x - distance, y: point.y)
        }
    }
}

struct DockTrashTarget {
    let point: CGPoint, edge: DockEdge
}

private struct DockObservation {
    var edge: DockEdge = .bottom
    var icon: CGRect?
    var strips: [CGRect] = []
    var tile: CGFloat = 48, tileCount = 12
    var pin = "middle"
}

final class DockTrashLocator {
    private var observation = DockObservation()
    private var fetching = false

    func prepare() {
        guard !fetching, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        fetching = true
        DispatchQueue.global(qos: .utility).async {
            let observed = Self.observe()
            DispatchQueue.main.async { self.observation = observed; self.fetching = false }
        }
    }

    private static func observe() -> DockObservation {
        var result = DockObservation()
        let defaults = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        result.edge = DockEdge(rawValue: defaults["orientation"] as? String ?? "") ?? .bottom
        result.pin = defaults["pinning"] as? String ?? "middle"
        result.tile = min(128, max(16, (defaults["tilesize"] as? NSNumber)?.doubleValue ?? 48))
        let pinned = (defaults["persistent-apps"] as? [Any])?.count ?? 0
        let others = (defaults["persistent-others"] as? [Any])?.count ?? 0
        let recent = (defaults["recent-apps"] as? [Any])?.count ?? 0
        result.tileCount = max(3, 2 + pinned + others + min(recent, 3))
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return result }
        if AXIsProcessTrusted() {
            let dock = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(dock, 0.06)
            result.icon = trashIcon(in: dock)
            if result.icon != nil { return result }
        }
        let level = Int(CGWindowLevelForKey(.dockWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == level,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { continue }
            result.strips.append(rect)
        }
        return result
    }

    private static func trashIcon(in dock: AXUIElement) -> CGRect? {
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
        let lists = attribute(dock, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        for list in lists.prefix(6) {
            let items = attribute(list, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            for item in items.reversed() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                guard attribute(item, kAXSubroleAttribute as CFString) as? String == kAXTrashDockItemSubrole,
                      let p = attribute(item, kAXPositionAttribute as CFString), CFGetTypeID(p) == AXValueGetTypeID(),
                      let s = attribute(item, kAXSizeAttribute as CFString), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
                var origin = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
                      AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 1, size.height > 1 else { continue }
                return CGRect(origin: origin, size: size)
            }
        }
        return nil
    }

    func target(from screen: NSScreen) -> DockTrashTarget {
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? screen.frame.maxY
        let edge = observation.edge
        func appKit(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        func edgeDistance(_ origin: CGPoint, _ frame: CGRect) -> CGFloat {
            switch edge {
            case .bottom: return hypot(max(frame.minX - origin.x, 0, origin.x - frame.maxX), origin.y - frame.minY)
            case .left: return hypot(max(frame.minY - origin.y, 0, origin.y - frame.maxY), origin.x - frame.minX)
            case .right: return hypot(max(frame.minY - origin.y, 0, origin.y - frame.maxY), origin.x - frame.maxX)
            }
        }
        if let observed = observation.icon {
            let r = appKit(observed), p = CGPoint(x: r.midX, y: r.midY)
            if let nearest = screens.min(by: { edgeDistance(p, $0.frame) < edgeDistance(p, $1.frame) }),
               edgeDistance(p, nearest.frame) < max(180, 2 * max(r.width, r.height)) {
                let f = nearest.frame
                return DockTrashTarget(point: CGPoint(x: min(f.maxX-1, max(f.minX+1, p.x)),
                    y: min(f.maxY-1, max(f.minY+1, p.y))), edge: edge)
            }
        }
        let rtl = NSApp.userInterfaceLayoutDirection == .rightToLeft
        let displays = [screen] + screens.filter { $0 !== screen }
        for display in displays {
            let matches = observation.strips.map(appKit).compactMap { r -> (CGRect, CGFloat)? in
                let breadth = edge == .bottom ? r.height : r.width
                let length = edge == .bottom ? r.width : r.height
                guard (8...250).contains(breadth), length > 1.8 * breadth,
                      r.intersects(display.frame), edgeDistance(CGPoint(x: r.midX, y: r.midY), display.frame) <= breadth/2 + 12 else { return nil }
                return (r, breadth)
            }
            if let (r, breadth) = matches.max(by: { $0.0.width * $0.0.height < $1.0.width * $1.0.height }) {
                let point = edge == .bottom ? CGPoint(x: rtl ? r.minX + breadth/2 : r.maxX - breadth/2, y: r.midY)
                    : CGPoint(x: r.midX, y: r.minY + breadth/2)
                return DockTrashTarget(point: point, edge: edge)
            }
        }
        let display = displays.first { edge.inset($0.frame, visible: $0.visibleFrame) > 5 }
            ?? (NSScreen.screensHaveSeparateSpaces ? screen : screens.first ?? screen)
        let frame = display.frame
        let available = edge == .bottom ? frame.width : display.visibleFrame.height
        let span = min(available - 6, (observation.tile + 4) * CGFloat(observation.tileCount) + 12)
        let inset = max(2, edge.inset(frame, visible: display.visibleFrame)/2)
        let margin = (available - span)/2
        let offset = observation.pin == "start" ? 3 : observation.pin == "end" ? available - span - 3 : margin
        let last = offset + span - min(observation.tile/2 + 4, span/2)
        let point: CGPoint
        switch edge {
        case .bottom: point = CGPoint(x: rtl ? frame.maxX - last : frame.minX + last, y: frame.minY + inset)
        case .left: point = CGPoint(x: frame.minX + inset, y: display.visibleFrame.maxY - last)
        case .right: point = CGPoint(x: frame.maxX - inset, y: display.visibleFrame.maxY - last)
        }
        return DockTrashTarget(point: point, edge: edge)
    }
}
