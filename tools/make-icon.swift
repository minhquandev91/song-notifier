import AppKit

// Renders the app icon: a nervous, Bocchi-inspired anime guitarist girl (pink hair, cube hair clips,
// spiral "overwhelmed" eyes, sweat drop) wearing headphones on a sunburst, with flying music notes.
// Original flat vector art drawn in code. Usage: make-icon <out.png>

let S: CGFloat = 1024
let ink = NSColor(srgbRed: 0.16, green: 0.07, blue: 0.20, alpha: 1)
let pink = NSColor(srgbRed: 1.00, green: 0.56, blue: 0.76, alpha: 1)
let pinkDark = NSColor(srgbRed: 0.90, green: 0.38, blue: 0.62, alpha: 1)
let skin = NSColor(srgbRed: 1.00, green: 0.91, blue: 0.84, alpha: 1)
let blush = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.62, alpha: 0.55)
let teal = NSColor(srgbRed: 0.27, green: 0.72, blue: 0.86, alpha: 1)
let yellow = NSColor(srgbRed: 1.00, green: 0.83, blue: 0.25, alpha: 1)

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
}

func draw(_ p: NSBezierPath, fill: NSColor?, stroke: CGFloat = 14) {
    if let fill { fill.setFill(); p.fill() }
    if stroke > 0 {
        ink.setStroke(); p.lineWidth = stroke
        p.lineJoinStyle = .round; p.lineCapStyle = .round
        p.stroke()
    }
}

func roundedSquare(_ cx: CGFloat, _ cy: CGFloat, _ size: CGFloat, angle: CGFloat) -> NSBezierPath {
    let p = NSBezierPath(roundedRect: NSRect(x: -size / 2, y: -size / 2, width: size, height: size), xRadius: 10, yRadius: 10)
    var t = AffineTransform(translationByX: cx, byY: cy)
    t.rotate(byDegrees: angle)
    p.transform(using: t)
    return p
}

func spiral(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let turns: CGFloat = 2.6, steps = 120
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a = t * turns * 2 * .pi
        let pt = NSPoint(x: cx + cos(a) * r * t, y: cy + sin(a) * r * t)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    return p
}

func note(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, double: Bool, color: NSColor) {
    // eighth / beamed notes, x,y = bottom-left note head center
    let heads = double ? [NSPoint(x: x, y: y), NSPoint(x: x + 70 * s, y: y + 14 * s)] : [NSPoint(x: x, y: y)]
    for h in heads {
        let head = ellipse(h.x, h.y, 50 * s, 38 * s)
        var t = AffineTransform(translationByX: h.x, byY: h.y); t.rotate(byDegrees: -20); t.translate(x: -h.x, y: -h.y)
        head.transform(using: t)
        draw(head, fill: color, stroke: 8 * s)
        let stem = NSBezierPath(); stem.move(to: NSPoint(x: h.x + 22 * s, y: h.y + 6 * s)); stem.line(to: NSPoint(x: h.x + 22 * s, y: h.y + 120 * s))
        draw(stem, fill: nil, stroke: 10 * s)
    }
    let flag = NSBezierPath()
    if double {
        flag.move(to: NSPoint(x: x + 22 * s, y: y + 120 * s)); flag.line(to: NSPoint(x: x + 92 * s, y: y + 134 * s))
        draw(flag, fill: nil, stroke: 22 * s)
    } else {
        flag.move(to: NSPoint(x: x + 22 * s, y: y + 120 * s))
        flag.curve(to: NSPoint(x: x + 60 * s, y: y + 50 * s), controlPoint1: NSPoint(x: x + 30 * s, y: y + 90 * s), controlPoint2: NSPoint(x: x + 75 * s, y: y + 85 * s))
        draw(flag, fill: nil, stroke: 10 * s)
    }
}

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// squircle with drop shadow (macOS icon grid: 824px artwork inside 1024 canvas)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
ink.setFill(); shape.fill()
ctx.restoreGState()
ctx.saveGState()
shape.addClip()

// sunburst background
NSColor(srgbRed: 1.0, green: 0.74, blue: 0.40, alpha: 1).setFill(); rect.fill()
let center = NSPoint(x: 512, y: 470)
let rays = 18
for i in 0..<rays where i % 2 == 0 {
    let a0 = CGFloat(i) / CGFloat(rays) * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(rays) * 2 * .pi
    let ray = NSBezierPath()
    ray.move(to: center)
    ray.line(to: NSPoint(x: center.x + cos(a0) * 1000, y: center.y + sin(a0) * 1000))
    ray.line(to: NSPoint(x: center.x + cos(a1) * 1000, y: center.y + sin(a1) * 1000))
    ray.close()
    yellow.setFill(); ray.fill()
}
NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])!
    .draw(fromCenter: center, radius: 0, toCenter: center, radius: 420, options: [])

// flying notes
note(170, 690, 0.95, double: true, color: NSColor(srgbRed: 0.45, green: 0.35, blue: 0.95, alpha: 1))
note(760, 740, 0.8, double: false, color: teal)
note(150, 200, 0.7, double: false, color: pinkDark)

// hair, back layer (long hair falling to the sides)
let hairBack = NSBezierPath()
hairBack.move(to: NSPoint(x: 250, y: 110))
hairBack.curve(to: NSPoint(x: 512, y: 830), controlPoint1: NSPoint(x: 170, y: 520), controlPoint2: NSPoint(x: 270, y: 830))
hairBack.curve(to: NSPoint(x: 774, y: 110), controlPoint1: NSPoint(x: 754, y: 830), controlPoint2: NSPoint(x: 854, y: 520))
hairBack.close()
draw(hairBack, fill: pink)

// face
let face = ellipse(512, 450, 430, 420)
draw(face, fill: skin)

// blush
blush.setFill()
ellipse(395, 375, 90, 40).fill()
ellipse(629, 375, 90, 40).fill()

// spiral eyes
for cx: CGFloat in [420, 604] {
    draw(ellipse(cx, 450, 120, 130), fill: .white, stroke: 12)
    let sp = spiral(cx, 450, 52)
    teal.setStroke(); sp.lineWidth = 11; sp.lineCapStyle = .round; sp.stroke()
}

// wobbly nervous mouth
let mouth = NSBezierPath()
mouth.move(to: NSPoint(x: 450, y: 320))
for i in 1...6 {
    let x = 450 + CGFloat(i) * 21
    mouth.line(to: NSPoint(x: x, y: i % 2 == 0 ? 320 : 336))
}
draw(mouth, fill: nil, stroke: 10)

// bangs: dome over the forehead with a jagged fringe
let bangs = NSBezierPath()
bangs.move(to: NSPoint(x: 280, y: 520))
bangs.curve(to: NSPoint(x: 744, y: 520), controlPoint1: NSPoint(x: 270, y: 760), controlPoint2: NSPoint(x: 754, y: 760))
let fringe: [NSPoint] = [
    NSPoint(x: 720, y: 470), NSPoint(x: 680, y: 540), NSPoint(x: 630, y: 495),
    NSPoint(x: 590, y: 555), NSPoint(x: 540, y: 500), NSPoint(x: 500, y: 560),
    NSPoint(x: 450, y: 505), NSPoint(x: 405, y: 555), NSPoint(x: 360, y: 495),
    NSPoint(x: 320, y: 545), NSPoint(x: 295, y: 470),
]
for p in fringe { bangs.line(to: p) }
bangs.close()
draw(bangs, fill: pink)
// hair shine
let shine = NSBezierPath()
shine.move(to: NSPoint(x: 400, y: 680)); shine.curve(to: NSPoint(x: 520, y: 700), controlPoint1: NSPoint(x: 440, y: 710), controlPoint2: NSPoint(x: 490, y: 715))
NSColor.white.withAlphaComponent(0.75).setStroke(); shine.lineWidth = 16; shine.lineCapStyle = .round; shine.stroke()

// cube hair clips
draw(roundedSquare(330, 600, 62, angle: 18), fill: yellow, stroke: 10)
draw(roundedSquare(700, 610, 56, angle: -14), fill: teal, stroke: 10)

// headphones
let band = NSBezierPath()
band.move(to: NSPoint(x: 265, y: 470))
band.curve(to: NSPoint(x: 759, y: 470), controlPoint1: NSPoint(x: 240, y: 900), controlPoint2: NSPoint(x: 784, y: 900))
ink.setStroke(); band.lineWidth = 44; band.lineCapStyle = .round; band.stroke()
NSColor(srgbRed: 0.45, green: 0.35, blue: 0.95, alpha: 1).setStroke(); band.lineWidth = 22; band.stroke()
for cx: CGFloat in [262, 762] {
    draw(NSBezierPath(roundedRect: NSRect(x: cx - 55, y: 360, width: 110, height: 170), xRadius: 50, yRadius: 50),
         fill: NSColor(srgbRed: 0.45, green: 0.35, blue: 0.95, alpha: 1))
    draw(NSBezierPath(roundedRect: NSRect(x: cx - 28, y: 395, width: 56, height: 100), xRadius: 26, yRadius: 26),
         fill: NSColor(srgbRed: 0.75, green: 0.70, blue: 1.0, alpha: 1), stroke: 8)
}

// sweat drop
let drop = NSBezierPath()
drop.move(to: NSPoint(x: 690, y: 560))
drop.curve(to: NSPoint(x: 690, y: 450), controlPoint1: NSPoint(x: 650, y: 490), controlPoint2: NSPoint(x: 640, y: 450))
drop.curve(to: NSPoint(x: 690, y: 560), controlPoint1: NSPoint(x: 740, y: 450), controlPoint2: NSPoint(x: 730, y: 490))
draw(drop, fill: NSColor(srgbRed: 0.62, green: 0.88, blue: 1.0, alpha: 1), stroke: 9)

ctx.restoreGState()
// crisp border
shape.lineWidth = 16; ink.setStroke(); shape.stroke()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
