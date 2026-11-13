import AppKit
import SwiftUI

/// A Phosphor icon (the web Console's icon set), drawn natively: its path data becomes an SVG that AppKit
/// renders as a template image, so it is crisp at any size and takes the surrounding foreground color.
struct PhosphorIcon: View {
    enum Weight: String { case regular, fill }

    let name: String
    var weight: Weight = .regular
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Self.image(name, weight))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ name: String, _ weight: Weight) -> NSImage {
        let key = name + "." + weight.rawValue
        if let cached = cache[key] { return cached }
        let paths = PhosphorPaths.all[name]?[weight.rawValue] ?? []
        assert(!paths.isEmpty, "no Phosphor icon \(key): add it to scripts/phosphor.py and regenerate")
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">"#
            + paths.map { #"<path fill="black" d="\#($0)"/>"# }.joined() + "</svg>"
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

extension NSImage {
    /// A copy at the menu bar's 18 pt, still a template so it follows the bar's color.
    var menuBarSized: NSImage {
        let copy = (self.copy() as? NSImage) ?? self
        copy.size = NSSize(width: 18, height: 18)
        copy.isTemplate = true
        return copy
    }
}
