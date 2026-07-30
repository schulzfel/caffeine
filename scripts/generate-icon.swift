import AppKit
import CoreGraphics
import Foundation

private let canvasSize = 1024
private let statusIconPixelSize = 32
private let glyphViewBoxSize = 24

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func makeBitmap(
    pixels: Int,
    purpose: String
) -> (bitmap: NSBitmapImageRep, context: CGContext) {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(
        bitmapImageRep: bitmap
    )?.cgContext else {
        fail("could not create the \(purpose) bitmap")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.clear(
        CGRect(
            x: 0,
            y: 0,
            width: CGFloat(pixels),
            height: CGFloat(pixels)
        )
    )
    return (bitmap, context)
}

// These are the exact user-supplied Boxicons coffee SVG paths. Keeping the path
// data verbatim makes the application icon and menu-bar assets independent of
// SF Symbols. See THIRD_PARTY_NOTICES.md for the MIT attribution.
private let filledGlyphPathData = [
    #"M11.41 11.77c0-3.43 2.59-6.25 6.03-6.56l2.9-.26c-.19-.24-.39-.47-.61-.69C16.24.77 9.93 1.4 5.67 5.67c-2.04 2.04-3.32 4.6-3.61 7.21c-.17 1.53.02 2.96.52 4.24l4.97-.82c2.24-.37 3.87-2.27 3.87-4.52Z"#,
    #"M17.62 7.21c-2.4.22-4.21 2.18-4.21 4.57c0 3.23-2.33 5.97-5.54 6.5l-4.26.7c.2.26.42.52.66.76c1.48 1.48 3.49 2.27 5.74 2.27q.555 0 1.11-.06c2.61-.29 5.18-1.57 7.21-3.61s3.32-4.6 3.61-7.21c.17-1.53-.02-2.97-.52-4.25l-3.79.34Z"#,
]
private let outlineGlyphPathData = [
    #"M5.67 5.67c-2.04 2.04-3.32 4.6-3.61 7.21c-.3 2.7.48 5.13 2.2 6.85C5.74 21.21 7.75 22 10 22q.555 0 1.11-.06c2.61-.29 5.18-1.57 7.21-3.61s3.32-4.6 3.61-7.21c.3-2.7-.48-5.13-2.2-6.85C16.24.78 9.93 1.41 5.67 5.68ZM4.05 13.1c.24-2.16 1.32-4.3 3.04-6.02c2.03-2.03 4.58-3.09 6.89-3.09c1.67 0 3.21.55 4.34 1.68l.01.01l-1.47.13c-3.13.28-5.49 2.85-5.49 5.97c0 1.96-1.42 3.62-3.37 3.94l-3.58.59c-.36-.97-.5-2.06-.37-3.23Zm15.9-2.21c-.24 2.16-1.32 4.3-3.04 6.02s-3.85 2.79-6.02 3.04c-2.09.23-3.93-.35-5.22-1.63c-.05-.05-.08-.1-.13-.15l2.77-.46a5.994 5.994 0 0 0 5.05-5.92c0-2.08 1.58-3.79 3.67-3.98l2.51-.23c.39.98.53 2.1.4 3.31Z"#,
]

private func svgImage(pathData: [String]) -> NSImage {
    let pathElements = pathData.map {
        #"<path d="\#($0)"/>"#
    }.joined()
    let document = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="#000000">\(pathElements)</svg>
    """

    guard let image = NSImage(data: Data(document.utf8)) else {
        fail("could not render the supplied SVG glyph")
    }
    return image
}

private func drawGlyph(
    image: NSImage,
    in context: CGContext,
    rect: CGRect
) {
    let graphicsContext = NSGraphicsContext(
        cgContext: context,
        flipped: false
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    image.draw(
        in: rect,
        from: CGRect(
            x: 0,
            y: 0,
            width: glyphViewBoxSize,
            height: glyphViewBoxSize
        ),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()
}

guard CommandLine.arguments.count == 3
        || CommandLine.arguments.count == 5 else {
    fail(
        """
        usage: generate-icon <master-output.png> <output.icns> \
        [active-status-template-output.png inactive-status-template-output.png]
        """
    )
}

let filledGlyphImage = svgImage(pathData: filledGlyphPathData)
let outlineGlyphImage = svgImage(pathData: outlineGlyphPathData)

let (bitmap, context) = makeBitmap(
    pixels: canvasSize,
    purpose: "icon"
)

// Keep the tile and glyph geometry on whole design-grid coordinates so the
// master downsamples cleanly into the small ICNS representations.
let backgroundRect = CGRect(x: 64, y: 64, width: 896, height: 896)
let backgroundPath = CGPath(
    roundedRect: backgroundRect,
    cornerWidth: 210,
    cornerHeight: 210,
    transform: nil
)
let tileColor = NSColor(calibratedWhite: 0.995, alpha: 1)

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -16),
    blur: 32,
    color: NSColor.black.withAlphaComponent(0.20).cgColor
)
context.addPath(backgroundPath)
context.setFillColor(tileColor.cgColor)
context.fillPath()
context.restoreGState()

// A restrained edge gives the white tile definition on light backgrounds
// without making the icon look framed.
context.addPath(backgroundPath)
context.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
context.setLineWidth(4)
context.strokePath()

drawGlyph(
    image: filledGlyphImage,
    in: context,
    rect: CGRect(x: 160, y: 160, width: 704, height: 704)
)

guard let masterPNG = bitmap.representation(using: .png, properties: [:]),
      let masterImage = bitmap.cgImage else {
    fail("could not encode the icon as PNG")
}

do {
    try masterPNG.write(
        to: URL(fileURLWithPath: CommandLine.arguments[1]),
        options: .atomic
    )
} catch {
    fail("could not write the icon: \(error.localizedDescription)")
}

func writeStatusTemplate(
    image: NSImage,
    to outputPath: String
) {
    let (statusBitmap, statusContext) = makeBitmap(
        pixels: statusIconPixelSize,
        purpose: "menu-bar template"
    )

    drawGlyph(
        image: image,
        in: statusContext,
        rect: CGRect(
            x: 0,
            y: 0,
            width: statusIconPixelSize,
            height: statusIconPixelSize
        )
    )

    guard let statusPNG = statusBitmap.representation(
        using: .png,
        properties: [:]
    ) else {
        fail("could not encode the menu-bar template as PNG")
    }

    do {
        try statusPNG.write(
            to: URL(fileURLWithPath: outputPath),
            options: .atomic
        )
    } catch {
        fail(
            """
            could not write the menu-bar template: \
            \(error.localizedDescription)
            """
        )
    }
}

if CommandLine.arguments.count == 5 {
    writeStatusTemplate(
        image: filledGlyphImage,
        to: CommandLine.arguments[3]
    )
    writeStatusTemplate(
        image: outlineGlyphImage,
        to: CommandLine.arguments[4]
    )
}

var pngRepresentationsByPixelCount = [canvasSize: masterPNG]

func pngRepresentation(pixels: Int) -> Data {
    if let cached = pngRepresentationsByPixelCount[pixels] {
        return cached
    }

    let (scaledBitmap, scaledContext) = makeBitmap(
        pixels: pixels,
        purpose: "\(pixels)-pixel icon representation"
    )
    scaledContext.draw(
        masterImage,
        in: CGRect(x: 0, y: 0, width: pixels, height: pixels)
    )

    guard let result = scaledBitmap.representation(
        using: .png,
        properties: [:]
    ) else {
        fail("could not encode the \(pixels)-pixel icon representation")
    }
    pngRepresentationsByPixelCount[pixels] = result
    return result
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encodedValue = value.bigEndian
    withUnsafeBytes(of: &encodedValue) {
        data.append(contentsOf: $0)
    }
}

// ICNS stores PNG representations in a compact chunked container. Including
// both the base and Retina chunk types preserves scale semantics instead of
// asking the system to guess from pixel dimensions.
let icnsRepresentations: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512),
]

var iconPayload = Data()
for representation in icnsRepresentations {
    let imageData = pngRepresentation(pixels: representation.pixels)
    guard let typeData = representation.type.data(using: .ascii),
          typeData.count == 4,
          imageData.count <= Int(UInt32.max) - 8 else {
        fail("could not encode the \(representation.type) ICNS entry")
    }

    iconPayload.append(typeData)
    appendBigEndian(UInt32(imageData.count + 8), to: &iconPayload)
    iconPayload.append(imageData)
}

guard iconPayload.count <= Int(UInt32.max) - 8 else {
    fail("the generated ICNS payload is too large")
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(iconPayload.count + 8), to: &icns)
icns.append(iconPayload)

do {
    try icns.write(
        to: URL(fileURLWithPath: CommandLine.arguments[2]),
        options: .atomic
    )
} catch {
    fail("could not write the ICNS file: \(error.localizedDescription)")
}
