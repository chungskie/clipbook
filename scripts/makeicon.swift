import AppKit
import CoreGraphics
import Foundation

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
  data: nil,
  width: size,
  height: size,
  bitsPerComponent: 8,
  bytesPerRow: 0,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
  fputs("could not make icon context\n", stderr)
  exit(1)
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func fill(_ rect: CGRect, radius: CGFloat, _ paint: CGColor) {
  context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
  context.setFillColor(paint)
  context.fillPath()
}

context.setFillColor(color(0.15, 0.19, 0.26))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

fill(CGRect(x: 196, y: 168, width: 620, height: 700), radius: 64, color(0.72, 0.74, 0.78))
fill(CGRect(x: 220, y: 150, width: 620, height: 700), radius: 64, color(0.96, 0.95, 0.91))
fill(CGRect(x: 412, y: 790, width: 220, height: 96), radius: 24, color(0.86, 0.40, 0.30))
fill(CGRect(x: 470, y: 812, width: 104, height: 52), radius: 16, color(0.15, 0.19, 0.26, 0.18))
fill(CGRect(x: 292, y: 620, width: 470, height: 34), radius: 10, color(0.20, 0.24, 0.30, 0.28))
fill(CGRect(x: 292, y: 560, width: 320, height: 34), radius: 10, color(0.20, 0.24, 0.30, 0.18))
fill(CGRect(x: 292, y: 300, width: 210, height: 180), radius: 22, color(0.25, 0.48, 0.74))
fill(CGRect(x: 540, y: 390, width: 210, height: 90), radius: 18, color(0.86, 0.40, 0.30, 0.9))

guard let image = context.makeImage() else {
  fputs("could not render icon\n", stderr)
  exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else {
  fputs("could not encode icon\n", stderr)
  exit(1)
}
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
do {
  try png.write(to: URL(fileURLWithPath: output))
} catch {
  fputs("could not write icon: \(error)\n", stderr)
  exit(1)
}
