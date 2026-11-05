// Renders the Snapback app icon (1024×1024 PNG) with CoreGraphics.
// Blueprint style to match Thumbcursor: a tilted close-up of a monitor with a
// tiled layout, and one window dropping back into its (dashed) slot.
//
// Usage: swift Resources/make-icon.swift <output.png>

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let blue = rgb(0x1E40AF)
let white = rgb(0xFFFFFF)
let lightBlue = rgb(0xBFDBFE)

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Top-left origin so layout numbers read naturally.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A solid white window with a light title bar and three "traffic light" dots.
func solidWindow(_ r: CGRect, barFraction: CGFloat) {
    let path = roundedRect(r, 20)
    ctx.addPath(path); ctx.setFillColor(white); ctx.fillPath()
    let barH = max(28, r.height * barFraction)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.setFillColor(lightBlue); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: barH))
    ctx.restoreGState()
    let d = barH * 0.34
    for i in 0..<3 {
        ctx.addEllipse(in: CGRect(x: r.minX + barH * 0.45 + CGFloat(i) * d * 1.6, y: r.minY + barH / 2 - d / 2, width: d, height: d))
    }
    ctx.setFillColor(blue); ctx.fillPath()
}

// MARK: Background: macOS icon grid (824pt body, 100pt inset) with blueprint grid

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(blue); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(bodyPath); ctx.clip()

ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(2)
for i in stride(from: CGFloat(100), through: 924, by: 41.2) {
    ctx.move(to: CGPoint(x: i, y: 100)); ctx.addLine(to: CGPoint(x: i, y: 924))
    ctx.move(to: CGPoint(x: 100, y: i)); ctx.addLine(to: CGPoint(x: 924, y: i))
}
ctx.strokePath()

// MARK: Tilted monitor close-up (same tilt as Thumbcursor's keyboard)

ctx.translateBy(x: 512, y: 512); ctx.rotate(by: -0.22); ctx.scaleBy(x: 0.82, y: 0.82); ctx.translateBy(x: -512, y: -512)

let monitor = CGRect(x: 40, y: 190, width: 1000, height: 640)
ctx.addPath(roundedRect(monitor, 40)); ctx.setStrokeColor(white); ctx.setLineWidth(16); ctx.strokePath()

let inner = monitor.insetBy(dx: 40, dy: 40)
let left = CGRect(x: inner.minX, y: inner.minY, width: 420, height: inner.height)
let topRight = CGRect(x: left.maxX + 24, y: inner.minY, width: inner.maxX - left.maxX - 24, height: 260)
let slot = CGRect(x: topRight.minX, y: topRight.maxY + 24, width: topRight.width, height: inner.maxY - topRight.maxY - 24)

solidWindow(left, barFraction: 0.1)
solidWindow(topRight, barFraction: 0.2)

// Empty slot the window snaps back into
ctx.saveGState()
ctx.setLineDash(phase: 0, lengths: [18, 12])
ctx.addPath(roundedRect(slot, 20)); ctx.setStrokeColor(white); ctx.setLineWidth(8); ctx.strokePath()
ctx.restoreGState()

// The window, lifted out of its slot, with a down arrow
let window = slot.offsetBy(dx: -40, dy: -150).insetBy(dx: 20, dy: 20)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 28, color: rgb(0x0B1F5C, 0.7))
solidWindow(window, barFraction: 0.18)
ctx.restoreGState()

let c = CGPoint(x: window.midX, y: window.midY + 30)
let len: CGFloat = 46, head: CGFloat = 36
ctx.setStrokeColor(blue); ctx.setLineWidth(22); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: c.x, y: c.y - len)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + len))
ctx.move(to: CGPoint(x: c.x - head, y: c.y + len - head))
ctx.addLine(to: CGPoint(x: c.x, y: c.y + len))
ctx.addLine(to: CGPoint(x: c.x + head, y: c.y + len - head))
ctx.strokePath()

// MARK: Write PNG

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
