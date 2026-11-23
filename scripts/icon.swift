import AppKit
// Renders the app iconset from assets/serein-icon.svg; 16 and 32 pixel slots use the heavier serein-icon-small.svg.
let path=CommandLine.arguments[1]
let assets=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets")
guard let full=NSImage(contentsOf:assets.appendingPathComponent("serein-icon.svg")),let small=NSImage(contentsOf:assets.appendingPathComponent("serein-icon-small.svg")) else { fatalError("missing icon SVGs in \(assets.path)") }
try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
for (pixels,label) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    (pixels<=32 ? small : full).draw(in:NSRect(x:0,y:0,width:pixels,height:pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path).appendingPathComponent("icon_\(label).png"))
}
