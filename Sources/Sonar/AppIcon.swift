import AppKit

/// Draws the app's Dock icon at runtime — a black squircle holding a waveform
/// of rounded equalizer bars, each washed with a green→magenta vertical
/// gradient. The black tone is sampled to match the reference icon.
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

            // Near-black background — a faint top-to-bottom fall-off
            // (~rgb(28,28,30) top → rgb(6,6,7) bottom) so it isn't flat.
            ctx.saveGState()
            ctx.addPath(shape); ctx.clip()
            let bg = CGGradient(colorsSpace: rgb,
                                colors: [NSColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1).cgColor,
                                         NSColor(red: 0.024, green: 0.024, blue: 0.027, alpha: 1).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawLinearGradient(bg,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])

            // Subtle top specular highlight on the black.
            let hlC = CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.20)
            let hl = CGGradient(colorsSpace: rgb,
                                colors: [NSColor(calibratedWhite: 1, alpha: 0.06).cgColor,
                                         NSColor(calibratedWhite: 1, alpha: 0).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawRadialGradient(hl, startCenter: hlC, startRadius: 0,
                                   endCenter: hlC, endRadius: rect.width * 0.40, options: [])

            // A light bevel around the edge — brightest along the top, fading
            // toward the bottom — so the black tile still reads against a dark
            // Dock or page. Stroked inside the clip, so only the inner half shows.
            ctx.addPath(shape)
            ctx.setLineWidth(rect.width * 0.024)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let rim = CGGradient(colorsSpace: rgb,
                                 colors: [NSColor(calibratedWhite: 1, alpha: 0.30).cgColor,
                                          NSColor(calibratedWhite: 1, alpha: 0.05).cgColor] as CFArray,
                                 locations: [0, 1])!
            ctx.drawLinearGradient(rim,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            ctx.restoreGState()

            // Equalizer waveform. Each bar is a rounded (stadium) column with an
            // independent top/bottom expressed as a fraction of the icon height
            // (0 = bottom edge, 1 = top edge; 0.5 = middle). The tallest column
            // sits just left of centre, with the deepest magenta reach below it.
            let bars: [(top: CGFloat, bottom: CGFloat)] = [
                (0.62, 0.38),
                (0.74, 0.27),
                (0.83, 0.15),
                (0.72, 0.28),
                (0.60, 0.40),
            ]

            let barW = rect.width * 0.05
            let pitch = barW * 2                       // bar + equal gap
            let groupW = pitch * CGFloat(bars.count) - (pitch - barW)
            var x = rect.midX - groupW / 2

            // Gradient reused for every bar, mapped to that bar's own extent:
            // bright green at the cap, dusky grey through the middle, vivid
            // magenta at the foot.
            let grad = CGGradient(colorsSpace: rgb,
                                  colors: [NSColor(red: 0.40, green: 0.86, blue: 0.44, alpha: 1).cgColor,
                                           NSColor(red: 0.60, green: 0.62, blue: 0.64, alpha: 1).cgColor,
                                           NSColor(red: 0.83, green: 0.16, blue: 0.74, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.5, 1])!

            for bar in bars {
                let top = rect.minY + rect.height * bar.top
                let bottom = rect.minY + rect.height * bar.bottom
                let barRect = CGRect(x: x, y: bottom, width: barW, height: top - bottom)
                let path = CGPath(roundedRect: barRect,
                                  cornerWidth: barW / 2, cornerHeight: barW / 2,
                                  transform: nil)

                // Soft glow beneath the column.
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: rect.width * 0.02,
                              color: NSColor(red: 0.55, green: 0.35, blue: 0.7, alpha: 0.55).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor)
                ctx.fillPath()
                ctx.restoreGState()

                // Green→magenta wash clipped to the column.
                ctx.saveGState()
                ctx.addPath(path); ctx.clip()
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: 0, y: top),
                                       end: CGPoint(x: 0, y: bottom), options: [])
                ctx.restoreGState()

                x += pitch
            }

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
