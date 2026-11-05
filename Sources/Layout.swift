// Snapback layout model and geometry.
//
// Pure logic with no AppKit/Accessibility dependency so it can be unit tested.
// All rectangles use the global "top-left origin" coordinate space shared by
// CGDisplayBounds and the Accessibility API.

import CoreGraphics
import Foundation

/// A connected display: a stable hardware UUID plus its current bounds.
public struct Display: Equatable {
    public var id: String
    public var frame: CGRect

    public init(id: String, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// A window position saved relative to its display (fractions 0...1),
/// so it survives display rearrangement and resolution changes.
public struct SavedFrame: Codable, Equatable {
    public var displayID: String
    public var relative: CGRect

    public init(displayID: String, relative: CGRect) {
        self.displayID = displayID
        self.relative = relative
    }
}

/// A saved layout for one display setup: app identifier → its windows' frames
/// (front-most window first).
public struct Layout: Codable, Equatable {
    public var savedAt: Date
    public var apps: [String: [SavedFrame]]

    public init(savedAt: Date, apps: [String: [SavedFrame]]) {
        self.savedAt = savedAt
        self.apps = apps
    }
}

/// All saved layouts, keyed by display setup.
public struct Store: Codable, Equatable {
    public var layouts: [String: Layout] = [:]
    public init(layouts: [String: Layout] = [:]) { self.layouts = layouts }
}

public enum Geometry {
    /// Identifies a combination of connected displays, independent of arrangement.
    public static func setupKey(_ displays: [Display]) -> String {
        displays.map(\.id).sorted().joined(separator: "+")
    }

    /// The display a window belongs to: the one it overlaps most,
    /// or the nearest one if it's entirely off-screen.
    public static func display(for rect: CGRect, in displays: [Display]) -> Display? {
        let best = displays.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
        if let best, area(best.frame.intersection(rect)) > 0 { return best }
        return displays.min { distance(center($0.frame), center(rect)) < distance(center($1.frame), center(rect)) }
    }

    public static func toRelative(_ rect: CGRect, in display: CGRect) -> CGRect {
        CGRect(x: (rect.minX - display.minX) / display.width,
               y: (rect.minY - display.minY) / display.height,
               width: rect.width / display.width,
               height: rect.height / display.height)
    }

    public static func toAbsolute(_ rel: CGRect, in display: CGRect) -> CGRect {
        CGRect(x: (display.minX + rel.minX * display.width).rounded(),
               y: (display.minY + rel.minY * display.height).rounded(),
               width: (rel.width * display.width).rounded(),
               height: (rel.height * display.height).rounded())
    }

    /// Converts a window's absolute frame into a frame saved against its display.
    public static func save(_ rect: CGRect, displays: [Display]) -> SavedFrame? {
        guard let d = display(for: rect, in: displays) else { return nil }
        return SavedFrame(displayID: d.id, relative: toRelative(rect, in: d.frame))
    }

    /// Converts a saved frame back to an absolute one, if its display is connected.
    public static func restore(_ saved: SavedFrame, displays: [Display]) -> CGRect? {
        guard let d = displays.first(where: { $0.id == saved.displayID }) else { return nil }
        return toAbsolute(saved.relative, in: d.frame)
    }

    /// Chooses a target frame for each current window of an app.
    ///
    /// Windows are paired with saved frames so the total movement is small
    /// (greedy, closest pairs first). Windows left over once every saved frame
    /// is taken go to the first saved frame (the app's front-most window at save time).
    /// Returns one index into `targets` per current window.
    public static func assign(current: [CGRect], targets: [CGRect]) -> [Int] {
        guard !targets.isEmpty else { return [] }
        var pairs: [(window: Int, target: Int, dist: CGFloat)] = []
        for (w, wr) in current.enumerated() {
            for (t, tr) in targets.enumerated() {
                pairs.append((w, t, distance(center(wr), center(tr)) + abs(wr.width - tr.width) + abs(wr.height - tr.height)))
            }
        }
        pairs.sort { $0.dist < $1.dist || ($0.dist == $1.dist && ($0.window, $0.target) < ($1.window, $1.target)) }

        var result = [Int?](repeating: nil, count: current.count)
        var usedTargets = Set<Int>()
        for p in pairs where result[p.window] == nil && !usedTargets.contains(p.target) {
            result[p.window] = p.target
            usedTargets.insert(p.target)
        }
        return result.map { $0 ?? 0 }
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
