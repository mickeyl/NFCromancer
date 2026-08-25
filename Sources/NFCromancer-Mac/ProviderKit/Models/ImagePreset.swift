import AppKit

/// A handful of built-in 8×8 pixel-art bitmaps for the Image mock-tag kind.
/// Type 2 tags carry so little memory (NTAG213: 144 bytes) that picking a
/// file from the filesystem is mostly a way to pick something too big to
/// fit — these are hand-sized to actually work.
struct ImagePreset: Identifiable {
    let id: String
    let name: String
    let color: NSColor
    /// 8×8 grid, `#` = foreground pixel, anything else = transparent.
    let pixels: [String]

    static let size = 8

    /// PNG-encoded, rendered on demand from the pixel grid.
    var pngData: Data? {
        let n = Self.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ), let buffer = rep.bitmapData else { return nil }

        let rgb = color.usingColorSpace(.deviceRGB) ?? .black
        let r = UInt8(rgb.redComponent * 255), g = UInt8(rgb.greenComponent * 255), b = UInt8(rgb.blueComponent * 255)
        let stride = rep.bytesPerRow
        for (y, row) in pixels.enumerated() {
            for (x, ch) in row.enumerated() {
                let offset = y * stride + x * 4
                if ch == "#" {
                    buffer[offset] = r; buffer[offset + 1] = g; buffer[offset + 2] = b; buffer[offset + 3] = 255
                } else {
                    buffer[offset] = 0; buffer[offset + 1] = 0; buffer[offset + 2] = 0; buffer[offset + 3] = 0
                }
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    static let all: [ImagePreset] = [
        ImagePreset(id: "heart", name: "Heart", color: .systemRed, pixels: [
            ".##..##.",
            "########",
            "########",
            "########",
            ".######.",
            "..####..",
            "...##...",
            "........",
        ]),
        ImagePreset(id: "star", name: "Star", color: .systemYellow, pixels: [
            "...##...",
            "...##...",
            "..####..",
            ".######.",
            "########",
            "..#..#..",
            ".#....#.",
            "........",
        ]),
        ImagePreset(id: "check", name: "Check", color: .systemGreen, pixels: [
            "........",
            "......#.",
            ".....##.",
            "#...##..",
            "##.##...",
            ".###....",
            "..#.....",
            "........",
        ]),
        ImagePreset(id: "cross", name: "Cross", color: .systemRed, pixels: [
            "#......#",
            ".#....#.",
            "..#..#..",
            "...##...",
            "...##...",
            "..#..#..",
            ".#....#.",
            "#......#",
        ]),
        ImagePreset(id: "dot", name: "Dot", color: .systemBlue, pixels: [
            "........",
            "..####..",
            ".######.",
            "########",
            "########",
            ".######.",
            "..####..",
            "........",
        ]),
        ImagePreset(id: "bolt", name: "Bolt", color: .systemOrange, pixels: [
            "....##..",
            "...##...",
            "..##....",
            ".######.",
            "....##..",
            "...##...",
            "..##....",
            ".##.....",
        ]),
    ]
}
