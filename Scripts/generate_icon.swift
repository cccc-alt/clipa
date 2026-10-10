import AppKit

guard CommandLine.arguments.count > 1 else {
    print("usage: generate_icon.swift <output.png>")
    exit(1)
}
let output = CommandLine.arguments[1]
_ = NSApplication.shared

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)

// Rounded gradient background
let backgroundPath = NSBezierPath(roundedRect: canvas.insetBy(dx: 46, dy: 46), xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.27, green: 0.45, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.98, alpha: 1)
])!
gradient.draw(in: backgroundPath, angle: -45)

// Subtle inner glow
NSColor.white.withAlphaComponent(0.14).setStroke()
backgroundPath.lineWidth = 5
backgroundPath.stroke()

// Clipboard body
let bodyRect = NSRect(x: 282, y: 200, width: 460, height: 620)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 72, yRadius: 72)
NSColor(calibratedWhite: 1.0, alpha: 0.97).setFill()
bodyPath.fill()

// Clip handle
let handleRect = NSRect(x: 402, y: 786, width: 220, height: 128)
let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: 52, yRadius: 52)
NSColor(calibratedWhite: 1.0, alpha: 0.97).setFill()
handlePath.fill()

// Handle inner cut to suggest open clip
let cutRect = NSRect(x: 462, y: 872, width: 100, height: 30)
let cutPath = NSBezierPath(roundedRect: cutRect, xRadius: 10, yRadius: 10)
NSColor(calibratedRed: 0.35, green: 0.42, blue: 0.96, alpha: 1).setFill()
cutPath.fill()

// Document lines
let lineColor = NSColor(calibratedRed: 0.22, green: 0.26, blue: 0.42, alpha: 0.85)
lineColor.setFill()
for (i, width) in [300.0, 360.0, 300.0, 360.0].enumerated() {
    let line = NSBezierPath(roundedRect: NSRect(
        x: 362,
        y: Double(300 + i * 76),
        width: width,
        height: 40
    ), xRadius: 20, yRadius: 20)
    line.fill()
}

// Small sparkle dot top-right
let sparkle = NSBezierPath()
sparkle.appendOval(in: NSRect(x: 762, y: 742, width: 92, height: 92))
NSColor.white.withAlphaComponent(0.92).setFill()
sparkle.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("icon: PNG encode failed")
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: output))
    print("icon: 已生成 \(output)")
} catch {
    print("icon: 写入失败 \(error)")
    exit(1)
}
