#!/usr/bin/env swift
// Build the "Off" menu-bar icon: the normal template icon, plus a diagonal slash.
// Input: assets/HijackMenuTemplate-master.png (1254x1254, black silhouette, transparent background).
// Output: assets/HijackMenuTemplate-Off.png (18x18) and assets/HijackMenuTemplate-Off@2x.png (36x36).
// Run from the repo root: swift scripts/make-off-icon.swift

import AppKit
import CoreGraphics
import ImageIO

let root = FileManager.default.currentDirectoryPath
let masterURL = URL(fileURLWithPath: root).appendingPathComponent("assets/HijackMenuTemplate-master.png")
guard let src = CGImageSourceCreateWithURL(masterURL as CFURL, nil), let master = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("can't load \(masterURL.path)\n".data(using: .utf8)!)
    exit(1)
}

// Draw at exact pixel dimensions (a bitmap context, not lockFocus: lockFocus scales to the screen's backing factor).
func render(_ size: Int) -> CGImage {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("can't create context\n".data(using: .utf8)!); exit(1)
    }
    ctx.interpolationQuality = .high
    // The silhouette, scaled to the full canvas (same framing as the existing idle icon).
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: s, height: s))
    // A diagonal slash, bottom-left to top-right, like the SF Symbol "mic.slash" mark.
    let inset = s * 0.14
    ctx.setLineWidth(s * 0.135)
    ctx.setLineCap(.round)
    ctx.setBlendMode(.copy)   // overwrite the silhouette's alpha where the slash falls, like a real cutout
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.move(to: CGPoint(x: inset, y: inset))
    ctx.addLine(to: CGPoint(x: s - inset, y: s - inset))
    ctx.strokePath()
    return ctx.makeImage()!
}

func write(_ cg: CGImage, _ name: String) {
    let outURL = URL(fileURLWithPath: root).appendingPathComponent("assets/\(name)")
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("can't encode \(name)\n".data(using: .utf8)!); exit(1)
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(outURL.path)")
}

write(render(18), "HijackMenuTemplate-Off.png")
write(render(36), "HijackMenuTemplate-Off@2x.png")
