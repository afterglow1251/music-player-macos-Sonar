import AppKit

/// Draws the app's Dock icon at runtime — a black squircle holding three
/// concentric sonar rings, washed diagonally green→grey→magenta. The same mark
/// as the landing page's. The black tone is sampled to match the reference icon.
///
/// A bare SwiftPM binary has no bundle/AppIcon asset, so we set this image on
/// `NSApp.applicationIconImage` at launch instead.
enum AppIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { fullRect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rgb = CGColorSpaceCreateDeviceRGB()

            // macOS icons leave ~8.5% transparent padding around the shape.
            let rect = fullRect.insetBy(dx: fullRect.width * 0.085, dy: fullRect.height * 0.085)
            let shape = squircle(in: rect)

            // Black background — dark gradient sampled from the reference icon
            // (~rgb(40,40,43) top → rgb(16,16,18) bottom).
            ctx.saveGState()
            ctx.addPath(shape); ctx.clip()
            let bg = CGGradient(colorsSpace: rgb,
                                colors: [NSColor(red: 0.157, green: 0.157, blue: 0.169, alpha: 1).cgColor,
                                         NSColor(red: 0.063, green: 0.063, blue: 0.071, alpha: 1).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawLinearGradient(bg,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])

            // Subtle top specular highlight on the black.
            let hlC = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.20)
            let hl = CGGradient(colorsSpace: rgb,
                                colors: [NSColor(calibratedWhite: 1, alpha: 0.10).cgColor,
                                         NSColor(calibratedWhite: 1, alpha: 0).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawRadialGradient(hl, startCenter: hlC, startRadius: 0,
                                   endCenter: hlC, endRadius: rect.width * 0.40, options: [])
            ctx.restoreGState()

            // Sonar rings: three concentric circles, like a ping spreading out —
            // the name, drawn. One diagonal wash runs across all three (bright
            // green top-left, dusky grey through the middle, vivid magenta
            // bottom-right), so each ring shifts colour around its circumference.
            // Proportions match the landing page's mark (radii 19 / 13 / 7 and a
            // 3 stroke on a 64-point tile), leaving the tile some air around them.
            let unit = rect.width / 64
            let rings: [CGFloat] = [19, 13, 7]
            let lineWidth = 3 * unit
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let ringsPath = CGMutablePath()
            for r in rings {
                ringsPath.addEllipse(in: CGRect(x: center.x - r * unit, y: center.y - r * unit,
                                                width: 2 * r * unit, height: 2 * r * unit))
            }
            let stroked = ringsPath.copy(strokingWithWidth: lineWidth, lineCap: .round,
                                         lineJoin: .round, miterLimit: 10)

            let grad = CGGradient(colorsSpace: rgb,
                                  colors: [NSColor(red: 0.40, green: 0.86, blue: 0.44, alpha: 1).cgColor,
                                           NSColor(red: 0.60, green: 0.62, blue: 0.64, alpha: 1).cgColor,
                                           NSColor(red: 0.83, green: 0.16, blue: 0.74, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.5, 1])!
            let outer = rings[0] * unit + lineWidth / 2

            // Soft glow beneath the rings.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: rect.width * 0.03,
                          color: NSColor(red: 0.55, green: 0.35, blue: 0.7, alpha: 0.55).cgColor)
            ctx.addPath(stroked)
            ctx.setFillColor(NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Green→magenta wash clipped to the rings.
            ctx.saveGState()
            ctx.addPath(stroked); ctx.clip()
            ctx.drawLinearGradient(grad,
                                   start: CGPoint(x: center.x - outer, y: center.y + outer),
                                   end: CGPoint(x: center.x + outer, y: center.y - outer), options: [])
            ctx.restoreGState()

            return true
        }
    }

    /// Continuous "squircle" (superellipse) path — iOS-style rounded corners.
    private static func squircle(in rect: NSRect, n: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX, cy = rect.midY
        let a = rect.width / 2, b = rect.height / 2
        let steps = 300
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let px = cx + a * copysign(pow(abs(ct), 2 / n), ct)
            let py = cy + b * copysign(pow(abs(st), 2 / n), st)
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        return path
    }
}
