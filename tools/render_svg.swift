// Draws an SVG at some sizes with AppKit's own SVG renderer, each as a PNG file:
//
//     swift tools/render_svg.swift design/logo/menubar/MenuBarIcon.imageset/menubar.svg out 16 24
//
// writes out/16.png and out/24.png, square. tools/windows_icon.py runs it for Reqly for Windows'
// notification-area icon, which is the menu-bar icon's glyph.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 3, let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else {
    print("Usage: swift render_svg.swift <file.svg> <folder> <size>...")
    exit(1)
}
let folder = URL(fileURLWithPath: arguments[2])
for size in arguments.dropFirst(3).compactMap({ Int($0) }) {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appending(path: "\(size).png"))
}
