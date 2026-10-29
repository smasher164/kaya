// tools/mac/menu-shot.py's compositor: window pictures drawn at their
// screen bounds on a neutral background, so the picture holds nothing but
// the windows it was handed (docs/traps.md, the menu-shot rect capture).
//
//   menu-compose <out.png> (<png> <x> <y> <w> <h>)...   back to front, points

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 6, (args.count - 1) % 5 == 0 else {
    print("menu-compose: usage: <out.png> (<png> <x> <y> <w> <h>)...")
    exit(2)
}
struct Layer { let image: CGImage; let rect: CGRect }
var layers: [Layer] = []
for i in stride(from: 1, to: args.count, by: 5) {
    let nums = args[(i + 1)...(i + 4)].compactMap { Double($0) }
    guard nums.count == 4, nums[2] > 0, nums[3] > 0 else {
        print("menu-compose: \(args[i]): bounds \(args[(i + 1)...(i + 4)].joined(separator: ",")) are not a rect")
        exit(2)
    }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i]) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else {
        print("menu-compose: \(args[i]) is not an image")
        exit(1)
    }
    layers.append(Layer(image: image, rect: CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])))
}
let margin = 16.0
let union = layers.dropFirst().reduce(layers[0].rect) { $0.union($1.rect) }.insetBy(dx: -margin, dy: -margin)
let scale = layers.map { Double($0.image.width) / $0.rect.width }.max() ?? 1
let width = Int((union.width * scale).rounded()), height = Int((union.height * scale).rounded())
guard
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    print("menu-compose: no \(width)x\(height) bitmap context")
    exit(1)
}
ctx.setFillColor(CGColor(srgbRed: 0.88, green: 0.88, blue: 0.88, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
ctx.interpolationQuality = .high
for layer in layers {
    let r = layer.rect
    let x = (r.minX - union.minX) * scale
    let y = (union.maxY - r.maxY) * scale
    ctx.draw(layer.image, in: CGRect(x: x, y: y, width: r.width * scale, height: r.height * scale))
}
guard let out = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: args[0]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    print("menu-compose: could not open \(args[0]) for writing")
    exit(1)
}
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    print("menu-compose: writing \(args[0]) failed")
    exit(1)
}
print("menu-compose: \(args[0]) \(width)x\(height), \(layers.count) window(s)")
