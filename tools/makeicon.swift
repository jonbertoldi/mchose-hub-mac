// Renders app/AppIcon.icns: usage `swiftc tools/makeicon.swift -o /tmp/mi && /tmp/mi app/AppIcon.icns`
import AppKit
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
        let inset = s * 0.0977
        let box = r.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
        NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.34, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1)])!.draw(in: path, angle: -90)
        // EQ bars behind
        let n = 5, bw = box.width * 0.07, gap = box.width * 0.05
        let total = CGFloat(n) * bw + CGFloat(n - 1) * gap
        let hs: [CGFloat] = [0.07, 0.14, 0.10, 0.16, 0.08]
        for i in 0..<n {
            let x = box.midX - total / 2 + CGFloat(i) * (bw + gap)
            let h = box.height * hs[i]
            NSColor(red: 0.30, green: 0.85, blue: 0.75, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: box.minY + box.height * 0.13, width: bw, height: h), xRadius: bw / 2, yRadius: bw / 2).fill()
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: box.width * 0.52, weight: .semibold)
        if let sym = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let t = sym.copy() as! NSImage
            t.lockFocus(); NSColor.white.set()
            NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop); t.unlockFocus()
            let sz = t.size
            t.draw(in: NSRect(x: box.midX - sz.width / 2, y: box.midY - sz.height / 2 + box.height * 0.13, width: sz.width, height: sz.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
let out = CommandLine.arguments[1]
let set = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
let p = Process(); p.launchPath = "/usr/bin/iconutil"; p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit(); print("wrote", out, p.terminationStatus)
