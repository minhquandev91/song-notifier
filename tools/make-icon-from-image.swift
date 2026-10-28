import AppKit

// Turns any picture into a macOS app icon with a small music-note badge.
// The artwork is full-bleed and opaque: macOS 26+ applies the squircle mask itself, and puts icons
// with their own rounded shape/transparent margins inside a grey plate instead.
// Usage: make-icon-from-image <in.jpg|png> <out.png>

let S: CGFloat = 1024
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-icon-from-image <in> <out.png>\n".data(using: .utf8)!); exit(1)
}

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
NSGraphicsContext.current!.imageInterpolation = .high

// center-crop the source to a square and fill the whole canvas
let side = min(src.size.width, src.size.height)
let from = NSRect(x: (src.size.width - side) / 2, y: (src.size.height - side) / 2, width: side, height: side)
src.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: from, operation: .copy, fraction: 1)

// music-note badge, bottom-right
let badge = NSBezierPath(ovalIn: NSRect(x: 690, y: 110, width: 230, height: 230))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.45, blue: 0.70, alpha: 1),
                    NSColor(srgbRed: 0.55, green: 0.35, blue: 0.95, alpha: 1)])!.draw(in: badge, angle: -60)
ctx.restoreGState()
badge.lineWidth = 12; NSColor.white.setStroke(); badge.stroke()
let note = NSAttributedString(string: "♫", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
    .foregroundColor: NSColor.white,
])
let ns = note.size()
note.draw(at: NSPoint(x: 805 - ns.width / 2, y: 225 - ns.height / 2))

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
