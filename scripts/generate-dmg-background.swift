import AppKit
import CoreGraphics
import Foundation

private let logicalWidth: CGFloat = 660
private let logicalHeight: CGFloat = 420
private let backingScale: CGFloat = 2
private let pixelWidth = Int(logicalWidth * backingScale)
private let pixelHeight = Int(logicalHeight * backingScale)

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: generate-dmg-background <output.png> <version>")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let version = CommandLine.arguments[2]

guard version.range(
    of: #"^[0-9]+(\.[0-9]+){0,2}$"#,
    options: .regularExpression
) != nil else {
    fail("version must contain one to three dot-separated integers")
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("could not create the background bitmap")
}

// PNG resolution is derived from the relationship between pixels and points.
// A 1320×840 backing store at 660×420 points is an exact 2×, 144-DPI image.
bitmap.size = NSSize(width: logicalWidth, height: logicalHeight)

guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fail("could not create the background graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
defer {
    NSGraphicsContext.restoreGraphicsState()
}

let context = graphicsContext.cgContext
let canvas = CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let backgroundGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor(
            calibratedRed: 0.965,
            green: 0.952,
            blue: 0.925,
            alpha: 1
        ).cgColor,
        NSColor(
            calibratedRed: 0.925,
            green: 0.92,
            blue: 0.905,
            alpha: 1
        ).cgColor,
        NSColor(
            calibratedRed: 0.99,
            green: 0.985,
            blue: 0.97,
            alpha: 1
        ).cgColor,
    ] as CFArray,
    locations: [0, 0.58, 1]
) else {
    fail("could not create the background gradient")
}

context.drawLinearGradient(
    backgroundGradient,
    start: CGPoint(x: 40, y: 30),
    end: CGPoint(x: 620, y: 420),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

guard let glowGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        NSColor.white.withAlphaComponent(0.8).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray,
    locations: [0, 1]
) else {
    fail("could not create the highlight gradient")
}

context.drawRadialGradient(
    glowGradient,
    startCenter: CGPoint(x: 520, y: 380),
    startRadius: 0,
    endCenter: CGPoint(x: 520, y: 380),
    endRadius: 370,
    options: [.drawsAfterEndLocation]
)

// A restrained frame keeps the artwork crisp against light and dark desktops.
context.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
context.setLineWidth(2)
context.stroke(canvas.insetBy(dx: 1, dy: 1))

let centeredParagraphStyle = NSMutableParagraphStyle()
centeredParagraphStyle.alignment = .center

("Caffeine" as NSString).draw(
    in: CGRect(x: 40, y: 343, width: 580, height: 48),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .bold),
        .foregroundColor: NSColor.black.withAlphaComponent(0.9),
        .paragraphStyle: centeredParagraphStyle,
    ]
)

("Drag Caffeine to Applications" as NSString).draw(
    in: CGRect(x: 40, y: 311, width: 580, height: 25),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: NSColor.black.withAlphaComponent(0.62),
        .paragraphStyle: centeredParagraphStyle,
    ]
)

// Finder places the app and Applications shortcut along this path.
let arrowY: CGFloat = 196
context.setStrokeColor(NSColor.black.withAlphaComponent(0.72).cgColor)
context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
context.setLineWidth(3.5)
context.setLineCap(.round)
context.move(to: CGPoint(x: 290, y: arrowY))
context.addLine(to: CGPoint(x: 370, y: arrowY))
context.strokePath()
context.move(to: CGPoint(x: 370, y: arrowY))
context.addLine(to: CGPoint(x: 355, y: arrowY + 10))
context.addLine(to: CGPoint(x: 355, y: arrowY - 10))
context.closePath()
context.fillPath()

let stepAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor.black.withAlphaComponent(0.5),
    .paragraphStyle: centeredParagraphStyle,
]
("DRAG TO INSTALL" as NSString).draw(
    in: CGRect(x: 288, y: 215, width: 88, height: 18),
    withAttributes: stepAttributes
)

// Steam-like curves echo the menu-bar cup without competing with the icons.
context.setStrokeColor(NSColor.black.withAlphaComponent(0.055).cgColor)
context.setLineWidth(13)
context.setLineCap(.round)
for offset in [CGFloat(0), 62, 124] {
    let steam = CGMutablePath()
    steam.move(to: CGPoint(x: 76 + offset, y: 18))
    steam.addCurve(
        to: CGPoint(x: 118 + offset, y: 120),
        control1: CGPoint(x: 132 + offset, y: 48),
        control2: CGPoint(x: 56 + offset, y: 88)
    )
    context.addPath(steam)
    context.strokePath()
}

let footer =
    "Version \(version)  •  macOS 14+  •  " +
    "Universal 2  •  Intel + Apple silicon"
(footer as NSString).draw(
    in: CGRect(x: 40, y: 22, width: 580, height: 18),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.black.withAlphaComponent(0.5),
        .paragraphStyle: centeredParagraphStyle,
    ]
)

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("could not encode the background as PNG")
}

do {
    try png.write(to: outputURL, options: .atomic)
} catch {
    fail("could not write the background: \(error.localizedDescription)")
}
