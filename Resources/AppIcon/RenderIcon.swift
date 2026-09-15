import AppKit

// Renders the app icon and packs it into Resources/AppIcon.icns.
//
//   swift Resources/AppIcon/RenderIcon.swift [preview.png]
//
// Drawn with Core Graphics rather than kept as an SVG, because the artwork is a
// handful of shapes and gradients and this machine has no SVG rasteriser — and
// because drawing each size from vectors keeps the small ones crisp instead of
// downsampled. The optional argument writes a 1024px preview beside the icns.
//
// The picture is the deck: three cards on the rail, the newest in front and
// fully lit, the older ones behind and fading — which is what "recent" means.

let canvas: CGFloat = 1024
/// Apple's macOS icon grid: the shape is 824pt on a 1024pt canvas.
let shapeSize: CGFloat = 824

// MARK: - Shapes

/// A rounded rectangle with continuous corners, Figma's smoothing model — the
/// same shape as a macOS app icon at 60% smoothing. Built in a y-down space,
/// clockwise from the top edge.
func squircle(_ rect: CGRect, radius: CGFloat, smoothing: CGFloat = 0.6) -> CGPath {
    let w = rect.width, h = rect.height
    let budget = min(w, h) / 2
    let r = min(radius, budget)
    let s = min(smoothing, budget / r - 1)
    let p = min((1 + s) * r, budget)
    func rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }
    let arcMeasure = 90 * (1 - s)
    let alpha = (90 - arcMeasure) / 2
    let p3p4 = r * tan(rad(alpha / 2))
    let beta = 45 * s
    let c = p3p4 * cos(rad(beta))
    let d = c * tan(rad(beta))
    let arcLen = sin(rad(arcMeasure / 2)) * r * sqrt(2)
    let b = (p - arcLen - c - d) / 3
    let a = 2 * b
    let k = 4 / 3 * tan(rad(arcMeasure) / 4) * r

    func add(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + q.x, y: p.y + q.y) }
    func mul(_ p: CGPoint, _ f: CGFloat) -> CGPoint { CGPoint(x: p.x * f, y: p.y * f) }
    func sub(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x - q.x, y: p.y - q.y) }
    /// The travel direction along a circle at `point`, clockwise on screen.
    func tangent(_ point: CGPoint, about centre: CGPoint) -> CGPoint {
        let v = sub(point, centre)
        let length = max(hypot(v.x, v.y), 0.0001)
        return CGPoint(x: -v.y / length, y: v.x / length)
    }

    let path = CGMutablePath()

    /// One corner at `corner`, arrived at travelling along `dir1` and left
    /// along `dir2`: a cubic easing off the side, the circular part, and a
    /// cubic easing onto the next side. Assumes the path is already at the
    /// point `p` short of the corner.
    func turn(at corner: CGPoint, dir1: CGPoint, dir2: CGPoint) {
        let t1 = sub(corner, mul(dir1, p))
        let t2 = add(corner, mul(dir2, p))
        let a1 = add(add(t1, mul(dir1, a + b + c)), mul(dir2, d))
        let a2 = sub(sub(t2, mul(dir2, a + b + c)), mul(dir1, d))
        let centre = add(sub(corner, mul(dir1, r)), mul(dir2, r))
        path.addCurve(to: a1, control1: add(t1, mul(dir1, a)), control2: add(t1, mul(dir1, a + b)))
        path.addCurve(
            to: a2,
            control1: add(a1, mul(tangent(a1, about: centre), k)),
            control2: sub(a2, mul(tangent(a2, about: centre), k))
        )
        path.addCurve(to: t2, control1: sub(t2, mul(dir2, a + b)), control2: sub(t2, mul(dir2, a)))
    }

    let o = rect.origin
    path.move(to: CGPoint(x: o.x + w - p, y: o.y))
    turn(at: CGPoint(x: o.x + w, y: o.y), dir1: CGPoint(x: 1, y: 0), dir2: CGPoint(x: 0, y: 1))
    path.addLine(to: CGPoint(x: o.x + w, y: o.y + h - p))
    turn(at: CGPoint(x: o.x + w, y: o.y + h), dir1: CGPoint(x: 0, y: 1), dir2: CGPoint(x: -1, y: 0))
    path.addLine(to: CGPoint(x: o.x + p, y: o.y + h))
    turn(at: CGPoint(x: o.x, y: o.y + h), dir1: CGPoint(x: -1, y: 0), dir2: CGPoint(x: 0, y: -1))
    path.addLine(to: CGPoint(x: o.x, y: o.y + p))
    turn(at: CGPoint(x: o.x, y: o.y), dir1: CGPoint(x: 0, y: -1), dir2: CGPoint(x: 1, y: 0))
    path.closeSubpath()
    return path
}

// MARK: - Palette

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

// MARK: - Drawing

/// One card of the deck, drawn about its centre in the y-down design space.
///
/// - Parameter prominence: 1 for the front card, less for the ones behind it,
///   which fades them and lightens their shadow.
func drawCard(
    _ ctx: CGContext, centre: CGPoint, size: CGSize, rotation: CGFloat,
    prominence: CGFloat, detailed: Bool
) {
    ctx.saveGState()
    ctx.translateBy(x: centre.x, y: centre.y)
    ctx.rotate(by: rotation * .pi / 180)
    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let radius = size.width * 0.13
    let shape = squircle(rect, radius: radius)

    // The face. Glass over a dark ground: light, a little translucent, lit from
    // the top.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size.height * 0.05),
        blur: size.height * 0.08,
        color: rgb(0.02, 0.03, 0.15, 0.30 + 0.25 * prominence)
    )
    ctx.addPath(shape)
    ctx.setFillColor(rgb(1, 1, 1, 0.55 + 0.45 * prominence))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0, rgb(1, 1, 1, 0.18)),
            (1, rgb(0.72, 0.76, 0.95, 0.22)),
        ]),
        start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: []
    )
    ctx.restoreGState()

    // The picture on the card: the window it stands for.
    let inset = size.width * 0.085
    let picture = CGRect(
        x: rect.minX + inset, y: rect.minY + inset,
        width: size.width - inset * 2, height: size.height * 0.62
    )
    let pictureShape = squircle(picture, radius: radius * 0.5)
    ctx.saveGState()
    ctx.addPath(pictureShape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0, rgb(0.62, 0.80, 1.00)),
            (1, rgb(0.30, 0.50, 0.96)),
        ]),
        start: CGPoint(x: picture.minX, y: picture.minY),
        end: CGPoint(x: picture.maxX, y: picture.maxY), options: []
    )
    if detailed {
        // A window's title bar, and three lines of whatever it is showing.
        let bar = CGRect(x: picture.minX, y: picture.minY, width: picture.width, height: picture.height * 0.16)
        ctx.setFillColor(rgb(1, 1, 1, 0.55))
        ctx.fill(bar)
        let dot = bar.height * 0.34
        for i in 0..<3 {
            let x = bar.minX + bar.height * 0.45 + CGFloat(i) * dot * 1.7
            ctx.setFillColor([rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.78, 0.30)][i])
            ctx.fillEllipse(in: CGRect(x: x, y: bar.midY - dot / 2, width: dot, height: dot))
        }
        let lineHeight = picture.height * 0.055
        for (i, fraction) in [0.62, 0.86, 0.48].enumerated() {
            let y = bar.maxY + picture.height * 0.16 + CGFloat(i) * lineHeight * 2.4
            ctx.setFillColor(rgb(1, 1, 1, 0.75))
            ctx.addPath(CGPath(
                roundedRect: CGRect(x: picture.minX + picture.width * 0.10, y: y,
                                    width: picture.width * fraction, height: lineHeight),
                cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil
            ))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    if detailed {
        // The caption under the picture.
        let captionHeight = size.height * 0.045
        let captionTop = picture.maxY + size.height * 0.07
        ctx.setFillColor(rgb(0.24, 0.27, 0.45, 0.85))
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: picture.minX, y: captionTop, width: picture.width * 0.66, height: captionHeight),
            cornerWidth: captionHeight / 2, cornerHeight: captionHeight / 2, transform: nil
        ))
        ctx.fillPath()
        ctx.setFillColor(rgb(0.24, 0.27, 0.45, 0.45))
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: picture.minX, y: captionTop + captionHeight * 2, width: picture.width * 0.42, height: captionHeight),
            cornerWidth: captionHeight / 2, cornerHeight: captionHeight / 2, transform: nil
        ))
        ctx.fillPath()

        // The glass edge.
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.75))
        ctx.setLineWidth(max(size.width * 0.006, 1))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Design space: 1024 wide, y down.
    let scale = CGFloat(pixels) / canvas
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)

    let shapeRect = CGRect(
        x: (canvas - shapeSize) / 2, y: (canvas - shapeSize) / 2,
        width: shapeSize, height: shapeSize
    )
    let shape = squircle(shapeRect, radius: shapeSize * 0.2237)

    // The ground: a blue-violet gradient, deeper toward the bottom right.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0, rgb(0.44, 0.50, 1.00)),
            (0.55, rgb(0.27, 0.30, 0.86)),
            (1, rgb(0.13, 0.14, 0.50)),
        ]),
        start: CGPoint(x: shapeRect.minX, y: shapeRect.minY),
        end: CGPoint(x: shapeRect.maxX, y: shapeRect.maxY), options: []
    )
    // A dome of light at the top, which is what makes it read as glass.
    ctx.drawRadialGradient(
        gradient([
            (0, rgb(1, 1, 1, 0.22)),
            (1, rgb(1, 1, 1, 0)),
        ]),
        startCenter: CGPoint(x: shapeRect.midX, y: shapeRect.minY - shapeSize * 0.1), startRadius: 0,
        endCenter: CGPoint(x: shapeRect.midX, y: shapeRect.minY - shapeSize * 0.1), endRadius: shapeSize * 0.75,
        options: []
    )
    ctx.restoreGState()

    // The rail: two cards behind, one in front. The finest details go at the
    // sizes where they would only be noise.
    let detailed = pixels >= 64
    let centre = CGPoint(x: canvas / 2, y: canvas / 2 + 8)
    let front = CGSize(width: 344, height: 450)
    let behind = CGSize(width: front.width * 0.86, height: front.height * 0.86)
    drawCard(ctx, centre: CGPoint(x: centre.x - 196, y: centre.y + 6), size: behind, rotation: -12,
             prominence: 0.35, detailed: detailed)
    drawCard(ctx, centre: CGPoint(x: centre.x + 196, y: centre.y + 6), size: behind, rotation: 12,
             prominence: 0.35, detailed: detailed)
    drawCard(ctx, centre: centre, size: front, rotation: 0, prominence: 1, detailed: detailed)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "RenderIcon", code: 1)
    }
    try data.write(to: url)
}

// MARK: - Main

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resources = here.deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("Recents-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(render(pixels: pixels), to: iconset.appendingPathComponent(name))
    }
}

let icns = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try writePNG(render(pixels: 1024), to: preview)
    print("wrote \(preview.path)")
}
