// Window picker logic (pure, unit tested): which on-screen windows get a
// number, in what order, and where to put each number's badge.

import CoreGraphics

public enum Picker {
    /// Number keys in label order: 1…9 then 0.
    public static let labels = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    public struct Choice: Equatable {
        /// Index into the front-to-back window list passed to `choices`.
        public var window: Int
        /// Where to centre the badge: the middle of the window's visible part.
        public var badgeCenter: CGPoint
        public var label: String
    }

    /// Picks the windows worth numbering and orders them by position.
    ///
    /// - Parameters:
    ///   - frontToBack: on-screen window frames, front-most first (global top-left coordinates).
    ///   - displays: display frames, used to order windows display by display, left to right.
    ///   - minVisible: windows with less than this fraction showing are skipped.
    public static func choices(frontToBack: [CGRect], displays: [CGRect], minVisible: CGFloat = 0.1) -> [Choice] {
        var visible: [(window: Int, center: CGPoint)] = []
        let grid = 12
        for (i, frame) in frontToBack.enumerated() {
            let inFront = frontToBack[..<i]
            var xs: CGFloat = 0, ys: CGFloat = 0, count = 0
            for gx in 0..<grid {
                for gy in 0..<grid {
                    let p = CGPoint(x: frame.minX + (CGFloat(gx) + 0.5) / CGFloat(grid) * frame.width,
                                    y: frame.minY + (CGFloat(gy) + 0.5) / CGFloat(grid) * frame.height)
                    if !inFront.contains(where: { $0.contains(p) }) {
                        xs += p.x; ys += p.y; count += 1
                    }
                }
            }
            if CGFloat(count) / CGFloat(grid * grid) >= minVisible {
                visible.append((i, CGPoint(x: xs / CGFloat(count), y: ys / CGFloat(count))))
            }
        }

        func displayIndex(_ p: CGPoint) -> Int {
            let sorted = displays.enumerated().sorted { ($0.element.minX, $0.element.minY) < ($1.element.minX, $1.element.minY) }
            return sorted.firstIndex { $0.element.contains(p) } ?? sorted.count
        }

        let ordered = visible.sorted { a, b in
            let fa = frontToBack[a.window], fb = frontToBack[b.window]
            let da = displayIndex(CGPoint(x: fa.midX, y: fa.midY)), db = displayIndex(CGPoint(x: fb.midX, y: fb.midY))
            if da != db { return da < db }
            if abs(fa.minX - fb.minX) > 40 { return fa.minX < fb.minX }
            return fa.minY < fb.minY
        }

        return ordered.prefix(labels.count).enumerated().map { n, v in
            Choice(window: v.window, badgeCenter: v.center, label: labels[n])
        }
    }

    /// The label index for a macOS virtual key code of a number key, if it is one.
    public static func labelIndex(forKeyCode code: UInt16) -> Int? {
        // kVK_ANSI_1…9, 0
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        return codes.firstIndex(of: code)
    }
}
