import AppKit

let size = 1024
let frame = NSRect(x: 0, y: 0, width: size, height: size)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSBezierPath(rect: frame).fill()
let tile = NSBezierPath(roundedRect: frame.insetBy(dx: 76, dy: 76), xRadius: 203, yRadius: 203)
let midnight = NSColor(srgbRed: 0.10, green: 0.17, blue: 0.35, alpha: 1)
let ocean = NSColor(srgbRed: 0.22, green: 0.68, blue: 0.74, alpha: 1)
NSGradient(starting: midnight, ending: ocean)?.draw(in: tile, angle: 55)
let glass = NSBezierPath(roundedRect: frame.insetBy(dx: 240, dy: 240), xRadius: 150, yRadius: 150)
NSGradient(starting: .white.withAlphaComponent(0.34),
           ending: .white.withAlphaComponent(0.08))?.draw(in: glass, angle: -75)
NSColor.white.withAlphaComponent(0.5).setStroke()
glass.lineWidth = 4
glass.stroke()
let configuration = NSImage.SymbolConfiguration(pointSize: 320, weight: .medium)
    .applying(.init(paletteColors: [.white]))
guard let symbol = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "MacMTP")?
    .withSymbolConfiguration(configuration) else { fatalError("The app icon symbol is unavailable.") }
let scale = 320 / max(symbol.size.width, symbol.size.height)
let width = symbol.size.width * scale
let height = symbol.size.height * scale
symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("App icon encoding failed.") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
