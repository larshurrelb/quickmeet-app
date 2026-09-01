import AppKit

/// The app's mark, in the two forms the interface needs.
///
/// `Logo.png` is the artwork with no square behind it — the same drawing as the Dock icon,
/// minus the rounded tile. The window uses it as-is. The menu bar cannot: it wants a
/// *template* image, one that carries only a shape so macOS can paint it black on a light
/// menu bar, white on a dark one, and dim it while the menu is open.
enum Branding {
    /// The logo, full colour, transparent outside the drawing. Nil only if the resource is
    /// missing from the bundle, which means the build script did not copy it.
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else {
            Diagnostics.recordError("Logo.png missing from the bundle")
            return nil
        }
        return image
    }()

    /// The logo as a menu bar template, 18 points tall.
    ///
    /// Built from **luminance, not alpha**. Marking the logo itself as a template would
    /// hand macOS its alpha channel, and the alpha channel of this drawing is the whole
    /// silhouette — bubble and waveform together — which paints as one solid blob with no
    /// waveform in it at all. Taking `1 - luminance` instead keeps the dark bubble opaque
    /// and punches the white bars straight through it, so the shape survives at 18 points.
    static let statusIcon: NSImage? = template(from: logo, height: 18)

    private static func template(from image: NSImage?, height: CGFloat) -> NSImage? {
        guard let image else { return nil }

        // Square, and at 2× so it stays crisp on a Retina menu bar.
        let scale = 2
        let side = Int(height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = rep.bitmapData else { return nil }
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            let alpha = CGFloat(pixels[index + 3]) / 255
            // Undo the premultiplication before reading the colour, or every partly
            // transparent edge pixel reads as darker than it is and the logo grows a halo.
            let red = alpha > 0 ? CGFloat(pixels[index]) / 255 / alpha : 0
            let green = alpha > 0 ? CGFloat(pixels[index + 1]) / 255 / alpha : 0
            let blue = alpha > 0 ? CGFloat(pixels[index + 2]) / 255 / alpha : 0

            // Distance from white in the *weakest* channel, not luminance. Luminance reads
            // the logo's red bubble as three-quarters ink, which paints as washed-out grey
            // next to the solid black one; this reads any saturated colour as full ink and
            // still punches white straight through.
            let ink = alpha * (1 - min(red, green, blue))

            // Black, with the ink in the alpha channel, premultiplied — which for black is
            // simply zero in every colour channel.
            pixels[index] = 0
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = UInt8(max(0, min(255, ink * 255)))
        }

        let template = NSImage(size: NSSize(width: height, height: height))
        template.addRepresentation(rep)
        template.isTemplate = true
        return template
    }
}
