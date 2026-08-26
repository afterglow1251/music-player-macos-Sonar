import SwiftUI
import AppKit

enum Palette {
    /// The visualizer always sits on black.
    static let background = Color.black
}

/// A color scheme for the spectrum visualizer: the 16-step bar gradient
/// (bottom → top), the peak marker, and the oscilloscope line.
struct VisualizerTheme: Identifiable, Equatable {
    let name: String
    let colors: [Color]
    let peak: Color
    let oscilloscope: Color
    var id: String { name }

    /// Color for tile `row` (0 = bottom) of a bar `total` rows tall.
    func spectrumColor(row: Int, of total: Int) -> Color {
        guard total > 1 else { return colors.first ?? .green }
        let idx = Int(round(Double(row) / Double(total - 1) * Double(colors.count - 1)))
        return colors[min(max(idx, 0), colors.count - 1)]
    }

    static func == (lhs: VisualizerTheme, rhs: VisualizerTheme) -> Bool { lhs.name == rhs.name }

    // MARK: Themes

    static let all: [VisualizerTheme] = [classic, ice, fire, rainbow, mono,
                                         sunset, ocean, magenta, gold, neon]

    static let classic = VisualizerTheme(
        name: "Classic",
        colors: gradient([(0, 208, 0), (216, 208, 0), (240, 120, 0), (240, 16, 0)]),
        peak: Color(white: 0.75),
        oscilloscope: rgb(36, 222, 61))

    static let ice = VisualizerTheme(
        name: "Ice",
        colors: gradient([(0, 110, 255), (0, 200, 255), (130, 230, 255), (235, 250, 255)]),
        peak: .white,
        oscilloscope: rgb(90, 205, 255))

    static let fire = VisualizerTheme(
        name: "Fire",
        colors: gradient([(150, 0, 0), (240, 70, 0), (255, 170, 0), (255, 240, 140)]),
        peak: .white,
        oscilloscope: rgb(255, 140, 0))

    static let rainbow = VisualizerTheme(
        name: "Rainbow",
        colors: gradient([(148, 0, 211), (0, 60, 255), (0, 200, 0), (255, 235, 0), (255, 0, 0)]),
        peak: .white,
        oscilloscope: rgb(200, 120, 255))

    static let mono = VisualizerTheme(
        name: "Mono",
        colors: gradient([(70, 70, 70), (150, 150, 150), (220, 220, 220), (255, 255, 255)]),
        peak: .white,
        oscilloscope: Color(white: 0.85))

    static let sunset = VisualizerTheme(
        name: "Sunset",
        colors: gradient([(255, 70, 120), (255, 120, 80), (255, 190, 60), (255, 240, 160)]),
        peak: .white,
        oscilloscope: rgb(255, 130, 110))

    static let ocean = VisualizerTheme(
        name: "Ocean",
        colors: gradient([(0, 70, 140), (0, 150, 190), (0, 205, 185), (150, 245, 220)]),
        peak: .white,
        oscilloscope: rgb(0, 205, 190))

    static let magenta = VisualizerTheme(
        name: "Magenta",
        colors: gradient([(110, 0, 130), (200, 0, 190), (255, 60, 200), (255, 185, 240)]),
        peak: .white,
        oscilloscope: rgb(255, 80, 220))

    static let gold = VisualizerTheme(
        name: "Gold",
        colors: gradient([(120, 80, 0), (200, 150, 0), (255, 210, 40), (255, 245, 185)]),
        peak: .white,
        oscilloscope: rgb(255, 210, 60))

    static let neon = VisualizerTheme(
        name: "Neon",
        colors: gradient([(255, 0, 140), (200, 0, 255), (0, 180, 255), (0, 255, 220)]),
        peak: .white,
        oscilloscope: rgb(0, 255, 220))

    // MARK: Builders

    private static func gradient(_ stops: [(Double, Double, Double)], count: Int = 16) -> [Color] {
        guard stops.count > 1 else { return stops.map { rgb($0.0, $0.1, $0.2) } }
        var result: [Color] = []
        for i in 0..<count {
            let t = Double(i) / Double(count - 1) * Double(stops.count - 1)
            let lo = Int(floor(t)), hi = min(lo + 1, stops.count - 1)
            let f = t - Double(lo)
            let a = stops[lo], b = stops[hi]
            result.append(rgb(a.0 + (b.0 - a.0) * f,
                              a.1 + (b.1 - a.1) * f,
                              a.2 + (b.2 - a.2) * f))
        }
        return result
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    // MARK: Album-derived theme

    /// Name used for the theme generated from the current cover, so the settings
    /// UI and persistence can recognise it.
    static let albumName = "Album"

    /// Build a visualizer theme from an album cover: pick the cover's most vibrant
    /// color and fan it into a dark→bright, bottom-to-top gradient — the classic
    /// tile look, tinted to match the artwork. A cover with no usable color (a
    /// black-and-white photo, say) gets the neutral greyscale fan instead: that
    /// still *matches the cover*, whereas falling back to whichever preset was
    /// picked last made "Mixed" look stuck on that preset.
    static func fromArtwork(_ image: NSImage) -> VisualizerTheme {
        guard let accent = image.dominantVibrantColor() else { return neutral }
        return fromAccent(accent)
    }

    /// The cover-derived theme for artwork that carries no hue — Mono's ramp
    /// under the album name, so it reads as "mixed from a grey cover".
    static let neutral = VisualizerTheme(
        name: albumName, colors: mono.colors, peak: mono.peak, oscilloscope: mono.oscilloscope)

    /// Fan a single accent color into the 16-step bottom→top gradient plus a peak
    /// and oscilloscope color, matching the shape of the built-in presets.
    static func fromAccent(_ accent: NSColor) -> VisualizerTheme {
        let base = accent.usingColorSpace(.deviceRGB) ?? accent
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Guarantee a lively base even for muted covers.
        let sat = max(s, 0.55)

        func stop(_ satScale: CGFloat, _ brightness: CGFloat) -> (Double, Double, Double) {
            let col = (NSColor(hue: h, saturation: min(sat * satScale, 1),
                               brightness: brightness, alpha: 1)
                .usingColorSpace(.deviceRGB)) ?? .white
            return (Double(col.redComponent) * 255,
                    Double(col.greenComponent) * 255,
                    Double(col.blueComponent) * 255)
        }

        // Dark & saturated at the bottom → bright & desaturated at the top.
        let stops = [stop(1.0, 0.35), stop(1.0, 0.70), stop(0.85, 1.0), stop(0.35, 1.0)]
        return VisualizerTheme(
            name: albumName,
            colors: gradient(stops),
            peak: Color(hue: Double(h), saturation: 0.12, brightness: 1.0),
            oscilloscope: Color(hue: Double(h), saturation: Double(min(sat, 1)), brightness: 1.0))
    }
}

private extension NSImage {
    /// Downscale to a tiny bitmap and pick the most "vibrant" representative color
    /// — the album's signature hue. Pixels are bucketed by hue and weighted by
    /// saturation×brightness so dull/near-black backgrounds don't dominate.
    func dominantVibrantColor() -> NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var rSum = [Double](repeating: 0, count: bins)
        var gSum = [Double](repeating: 0, count: bins)
        var bSum = [Double](repeating: 0, count: bins)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            NSColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            let vibrancy = Double(sat * sat * bri)   // favor colorful, non-dark pixels
            guard vibrancy > 0.02 else { continue }
            let bin = min(Int(hue * CGFloat(bins)), bins - 1)
            weight[bin] += vibrancy
            rSum[bin] += Double(r) * vibrancy
            gSum[bin] += Double(g) * vibrancy
            bSum[bin] += Double(b) * vibrancy
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0 else { return nil }
        let total = weight[best]
        return NSColor(red: CGFloat(rSum[best] / total), green: CGFloat(gSum[best] / total),
                       blue: CGFloat(bSum[best] / total), alpha: 1)
    }
}
