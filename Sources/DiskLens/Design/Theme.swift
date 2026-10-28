import SwiftUI

enum Theme {
    /// Ring width shrinks with depth so outer rings stay legible.
    static let holeFraction: CGFloat = 0.32   // inner hole radius / max radius
    static let maxRings = 6

    /// A slice's fill color: hue comes from its top-level ancestor, then we
    /// lighten and slightly desaturate as depth increases so rings read as layers.
    static func color(hue: Double, depth: Int, hovered: Bool) -> Color {
        let sat = max(0.30, 0.68 - Double(depth) * 0.07)
        let bri = min(0.99, 0.74 + Double(depth) * 0.055)
        let base = Color(hue: hue, saturation: hovered ? min(0.95, sat + 0.25) : sat,
                         brightness: hovered ? min(1.0, bri + 0.06) : bri)
        return base
    }

    /// Golden-angle hue rotation keeps neighboring top-level slices distinct.
    static func hue(forIndex i: Int) -> Double {
        (0.08 + Double(i) * 0.61803398875).truncatingRemainder(dividingBy: 1.0)
    }

    /// Accent color for a file kind, used in list rows.
    static func tint(for node: FileNode) -> Color {
        if node.isDirectory { return .accentColor }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp": return .pink
        case "mp4", "mov", "avi", "mkv", "m4v", "webm": return .purple
        case "mp3", "wav", "flac", "aac", "m4a", "aiff": return .orange
        case "pdf", "doc", "docx", "pages", "txt", "md", "rtf": return .blue
        case "zip", "dmg", "gz", "tar", "7z", "rar", "iso": return .brown
        case "app": return .teal
        default: return .gray
        }
    }

    static func icon(for node: FileNode) -> String {
        if node.isDirectory { return "folder.fill" }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp": return "photo.fill"
        case "mp4", "mov", "avi", "mkv", "m4v", "webm": return "film.fill"
        case "mp3", "wav", "flac", "aac", "m4a", "aiff": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "doc", "docx", "pages", "txt", "md", "rtf": return "doc.text.fill"
        case "zip", "dmg", "gz", "tar", "7z", "rar", "iso": return "shippingbox.fill"
        case "app": return "app.fill"
        default: return "doc.fill"
        }
    }
}

extension Int64 {
    /// Human-readable byte count, e.g. "12.4 MB".
    var humanBytes: String {
        if self == 0 { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
