import AppKit
let root = CommandLine.arguments[1]
let dir = URL(fileURLWithPath: root).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (size, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus()
    let s = CGFloat(size), scale = s / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 30, y: 30, width: 964, height: 964)
    let path = NSBezierPath(roundedRect: rect, xRadius: 215, yRadius: 215)
    NSColor(calibratedRed: 0.19, green: 0.33, blue: 0.29, alpha: 1).setFill(); path.fill()
    NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.52, blue: 0.40, alpha: 1), ending: NSColor(calibratedRed: 0.13, green: 0.27, blue: 0.26, alpha: 1))!.draw(in: path, angle: -65)
    NSColor(calibratedRed: 0.95, green: 0.90, blue: 0.69, alpha: 1).setFill()
    let sun = NSBezierPath(ovalIn: NSRect(x: 340, y: 352, width: 344, height: 344)); sun.fill()
    NSColor(calibratedRed: 0.18, green: 0.33, blue: 0.29, alpha: 1).setFill(); NSBezierPath(rect: NSRect(x: 190, y: 235, width: 650, height: 210)).fill()
    NSColor(calibratedRed: 0.91, green: 0.91, blue: 0.77, alpha: 1).setStroke()
    for y: CGFloat in [445, 340] { let line = NSBezierPath(); line.lineWidth = 25; line.lineCapStyle = .round; line.move(to: NSPoint(x: 246, y: y)); line.line(to: NSPoint(x: 778, y: y)); line.stroke() }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name + ".png"))
}
