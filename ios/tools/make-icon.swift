import AppKit

// Original vector mark drawn into a fixed-size, opaque Core Graphics surface.
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
context.setFillColor(color(0.31, 0.27, 0.90))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
for (index, y) in [620.0, 427.0, 234.0].enumerated() {
    context.setFillColor(color(0.97, 0.97, 1.0))
    context.addPath(CGPath(roundedRect: CGRect(x: 194, y: y, width: 636, height: 144), cornerWidth: 36, cornerHeight: 36, transform: nil)); context.fillPath()
    context.setFillColor(color(0.54, 0.36, 0.92))
    context.fillEllipse(in: CGRect(x: 244, y: y + 44, width: 56, height: 56))
    context.setFillColor(color(0.31, 0.27, 0.90))
    context.addPath(CGPath(roundedRect: CGRect(x: 342, y: y + 58, width: index == 1 ? 302 : 374, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil)); context.fillPath()
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Verified-size original app icon: 1024 x 1024")
