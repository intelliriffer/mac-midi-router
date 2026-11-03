import AppKit
import ImageIO
import UniformTypeIdentifiers

// Renders the mac-midi-router app icon: dark squircle, faint routing grid,
// classic 5-pin MIDI DIN plug in the center, green "in" and blue "out"
// signal lines on the sides. Usage: swift scripts/make-icon.swift <out.icns>

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns"

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

let inset: CGFloat = 100
let radius: CGFloat = 230
let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// MARK: background gradient
ctx.addPath(squircle)
ctx.clip(using: .evenOdd)
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.16, 0.19, 0.26), color(0.06, 0.07, 0.11)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: inset, y: CGFloat(size) - inset),
    end: CGPoint(x: CGFloat(size) - inset, y: inset),
    options: []
)

// MARK: faint routing grid (the "matrix")
ctx.setStrokeColor(color(1, 1, 1, 0.05))
ctx.setLineWidth(3)
let gridStep: CGFloat = 128
for x in stride(from: CGFloat(size) / 2 + gridStep, through: rect.maxX, by: gridStep) {
    ctx.move(to: CGPoint(x: x, y: rect.minY))
    ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
    ctx.move(to: CGPoint(x: CGFloat(size) - x, y: rect.minY))
    ctx.addLine(to: CGPoint(x: CGFloat(size) - x, y: rect.maxY))
}
for y in stride(from: CGFloat(size) / 2 + gridStep, through: rect.maxY, by: gridStep) {
    ctx.move(to: CGPoint(x: rect.minX, y: y))
    ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
    ctx.move(to: CGPoint(x: rect.minX, y: CGFloat(size) - y))
    ctx.addLine(to: CGPoint(x: rect.maxX, y: CGFloat(size) - y))
}
ctx.strokePath()

let center = CGPoint(x: 512, y: 512)

// MARK: signal contacts — green "in" and blue "out" dots sitting on the ring
let contactRadius: CGFloat = 58
let contactOffset: CGFloat = 300   // on the ring stroke path
let contactAt: [(CGPoint, CGColor)] = [
    (CGPoint(x: center.x - contactOffset, y: center.y),
     color(0.20, 0.78, 0.35)),
    (CGPoint(x: center.x + contactOffset, y: center.y),
     color(0.36, 0.60, 0.98)),
]
for (at, tint) in contactAt {
    ctx.setFillColor(tint)
    ctx.fillEllipse(in: CGRect(x: at.x - contactRadius, y: at.y - contactRadius,
                               width: contactRadius * 2, height: contactRadius * 2))
    ctx.setStrokeColor(color(1, 1, 1))
    ctx.setLineWidth(14)
    ctx.strokeEllipse(in: CGRect(x: at.x - contactRadius, y: at.y - contactRadius,
                                 width: contactRadius * 2, height: contactRadius * 2))
}

// MARK: MIDI DIN plug — outer ring, hub, five pins
ctx.setStrokeColor(color(0.94, 0.96, 1.0, 1))
ctx.setLineWidth(34)
ctx.strokeEllipse(in: CGRect(x: center.x - 300, y: center.y - 300, width: 600, height: 600))

ctx.setFillColor(color(1, 1, 1, 0.07))
ctx.fillEllipse(in: CGRect(x: center.x - 216, y: center.y - 216, width: 432, height: 432))
ctx.setStrokeColor(color(1, 1, 1, 0.22))
ctx.setLineWidth(6)
ctx.strokeEllipse(in: CGRect(x: center.x - 216, y: center.y - 216, width: 432, height: 432))

ctx.setFillColor(color(0.94, 0.96, 1.0, 0.96))
let pinDistance: CGFloat = 142
let pinRadius: CGFloat = 44
for angle in stride(from: -90.0, to: 270.0, by: 72.0) {
    let rad = angle * .pi / 180
    let px = center.x + pinDistance * CGFloat(cos(rad))
    let py = center.y + pinDistance * CGFloat(sin(rad))
    ctx.fillEllipse(in: CGRect(x: px - pinRadius, y: py - pinRadius,
                               width: pinRadius * 2, height: pinRadius * 2))
}

// MARK: screenshot → PNG files at every required iconset size
let image = ctx.makeImage()!
let iconsetURL = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: "build/icon-base.png") as CFURL,
    UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)

print("icon base written to build/icon-base.png")
