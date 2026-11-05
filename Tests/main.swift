// Tests for the pure layout logic (no XCTest needed). Run with `make test`.

import CoreGraphics
import Foundation

var failures = 0

func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T, line: Int = #line) {
    if actual == expected {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) (line \(line))\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// Laptop (1512×982) with a 2560×1440 monitor to its right, top-aligned.
let laptop = Display(id: "LAPTOP", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
let monitor = Display(id: "MONITOR", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440))
let both = [laptop, monitor]

check("setup key ignores order",
      Geometry.setupKey([monitor, laptop]), Geometry.setupKey([laptop, monitor]))
check("setup key differs per display set",
      Geometry.setupKey([laptop]) == Geometry.setupKey(both), false)

check("window belongs to the display it overlaps most",
      Geometry.display(for: CGRect(x: 1400, y: 100, width: 800, height: 600), in: both)?.id, "MONITOR")
check("off-screen window falls back to nearest display",
      Geometry.display(for: CGRect(x: -3000, y: 100, width: 400, height: 300), in: both)?.id, "LAPTOP")

let rightHalf = CGRect(x: 1512 + 1280, y: 0, width: 1280, height: 1440)
let saved = Geometry.save(rightHalf, displays: both)!
check("saved relative to its display", saved,
      SavedFrame(displayID: "MONITOR", relative: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
check("round-trips to the same frame", Geometry.restore(saved, displays: both), rightHalf)

// Rearrange: monitor now sits to the LEFT of the laptop.
let movedMonitor = Display(id: "MONITOR", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
check("survives display rearrangement",
      Geometry.restore(saved, displays: [laptop, movedMonitor]),
      CGRect(x: -1280, y: 0, width: 1280, height: 1440))

// Resolution change: monitor switched to 1920×1080.
let scaled = Display(id: "MONITOR", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
check("scales with resolution changes",
      Geometry.restore(saved, displays: [laptop, scaled]),
      CGRect(x: 1512 + 960, y: 0, width: 960, height: 1080))

check("missing display restores nothing",
      Geometry.restore(saved, displays: [laptop]), nil)

let left = CGRect(x: 0, y: 0, width: 700, height: 900)
let right = CGRect(x: 800, y: 0, width: 700, height: 900)
check("windows go to the nearest saved spot",
      Geometry.assign(current: [CGRect(x: 790, y: 10, width: 700, height: 900),
                                CGRect(x: 10, y: 10, width: 700, height: 900)],
                      targets: [left, right]),
      [1, 0])
check("extra windows go to the main (first) spot",
      Geometry.assign(current: [right, left, CGRect(x: 300, y: 300, width: 500, height: 500)],
                      targets: [left, right]),
      [1, 0, 0])
check("fewer windows than spots: each still gets the closest",
      Geometry.assign(current: [CGRect(x: 810, y: 0, width: 700, height: 900)], targets: [left, right]),
      [1])
check("no saved spots, no moves", Geometry.assign(current: [left], targets: []), [])

let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let store = Store(layouts: [Geometry.setupKey(both): Layout(savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                             apps: ["com.apple.Safari": [saved]])])
check("store round-trips through JSON",
      try! decoder.decode(Store.self, from: encoder.encode(store)), store)

// MARK: Hyper key

let F18 = HyperKey.triggerKeyCode
let S: UInt16 = 1, A: UInt16 = 0

func run(_ h: HyperKey, _ events: [(UInt16, Bool, TimeInterval)]) -> [HyperKey.Result] {
    events.map { h.handle(keyCode: $0.0, isDown: $0.1, time: $0.2) }
}

check("plain keys pass through",
      run(HyperKey(), [(A, true, 0), (A, false, 0.1)]), [.pass, .pass])
check("caps + key gets hyper on down and up",
      run(HyperKey(), [(F18, true, 0), (S, true, 0.1), (S, false, 0.2), (F18, false, 0.3)]),
      [.swallow, .hyper, .hyper, .swallow])
check("quick tap types escape",
      run(HyperKey(), [(F18, true, 0), (F18, false, 0.15)]), [.swallow, .escape])
check("long hold alone does not type escape",
      run(HyperKey(), [(F18, true, 0), (F18, false, 1.0)]), [.swallow, .swallow])
check("tap does nothing when escape is off",
      run(HyperKey(tapForEscape: false), [(F18, true, 0), (F18, false, 0.1)]), [.swallow, .swallow])
check("auto-repeat of caps does not reset the tap timer",
      run(HyperKey(), [(F18, true, 0), (F18, true, 0.4), (F18, true, 0.8), (F18, false, 1.0)]),
      [.swallow, .swallow, .swallow, .swallow])
check("key released after caps still gets hyper on key-up",
      run(HyperKey(), [(F18, true, 0), (S, true, 0.1), (F18, false, 0.2), (S, false, 0.3)]),
      [.swallow, .hyper, .swallow, .hyper])
check("keys after caps is released are normal again",
      run(HyperKey(), [(F18, true, 0), (S, true, 0.1), (S, false, 0.15), (F18, false, 0.2), (A, true, 0.3)]),
      [.swallow, .hyper, .hyper, .swallow, .pass])
check("key already held before caps keeps its plain key-up",
      run(HyperKey(), [(A, true, 0), (F18, true, 0.1), (A, false, 0.2), (F18, false, 0.3)]),
      [.pass, .swallow, .pass, .escape])

do {
    let h = HyperKey()
    _ = h.handle(keyCode: F18, isDown: true, time: 0)
    h.suppressTap()
    check("suppressed tap does not type escape", h.handle(keyCode: F18, isDown: false, time: 0.2), .swallow)
}

// MARK: Window picker

let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
let second = CGRect(x: 1000, y: 0, width: 1000, height: 800)

do {
    let left = CGRect(x: 0, y: 0, width: 500, height: 800)
    let right = CGRect(x: 500, y: 0, width: 500, height: 800)
    // front-to-back: right is in front
    let c = Picker.choices(frontToBack: [right, left], displays: [screen])
    check("numbered left to right, not by z-order", c.map(\.window), [1, 0])
    check("labels start at 1", c.map(\.label), ["1", "2"])
}
do {
    let big = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let hidden = CGRect(x: 100, y: 100, width: 300, height: 300)
    check("fully covered windows are skipped",
          Picker.choices(frontToBack: [big, hidden], displays: [screen]).map(\.window), [0])
}
do {
    let front = CGRect(x: 0, y: 0, width: 600, height: 800)
    let back = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let c = Picker.choices(frontToBack: [front, back], displays: [screen])
    check("partly covered window is kept", c.count, 2)
    check("badge sits on the visible part", c.first { $0.window == 1 }!.badgeCenter.x > 600, true)
}
do {
    let onSecond = CGRect(x: 1100, y: 0, width: 400, height: 400)
    let onFirst = CGRect(x: 600, y: 0, width: 300, height: 300)
    check("first display's windows come first",
          Picker.choices(frontToBack: [onSecond, onFirst], displays: [second, screen]).map(\.window), [1, 0])
}
do {
    let many = (0..<12).map { CGRect(x: CGFloat($0) * 80, y: 0, width: 70, height: 70) }
    let c = Picker.choices(frontToBack: many, displays: [screen])
    check("at most 10 windows, labelled 1-9 then 0", c.map(\.label), Picker.labels)
}
check("number key codes map to labels",
      [18, 29, 25, 0].map { Picker.labelIndex(forKeyCode: $0) }, [0, 9, 8, nil])

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}
print("\nall tests passed")
