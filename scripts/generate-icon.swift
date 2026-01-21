#!/usr/bin/env swift
// Generates Retain app icon as PNG for iconset creation

import AppKit
import Foundation

/// Generate the Retain app icon
func generateIcon(size: Int) -> NSImage {
    let nsSize = NSSize(width: size, height: size)
    let image = NSImage(size: nsSize, flipped: false) { rect in
        NSGraphicsContext.current?.imageInterpolation = .high

        // Background gradient (blue to purple)
        let gradient = NSGradient(colors: [
            NSColor(red: 0.35, green: 0.55, blue: 0.95, alpha: 1.0),
            NSColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1.0)
        ])
        let inset = CGFloat(size) * 0.04  // 4% inset
        let radius = CGFloat(size) * 0.195  // 19.5% corner radius
        let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius)
        gradient?.draw(in: bgPath, angle: -45)

        // Draw the brain symbol in white
        if let symbol = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil) {
            let pointSize = CGFloat(size) * 0.47  // 47% of total size
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
                .applying(.init(paletteColors: [.white]))
            let configuredSymbol = symbol.withSymbolConfiguration(config) ?? symbol

            let symbolSize = NSSize(width: CGFloat(size) * 0.585, height: CGFloat(size) * 0.585)
            let symbolRect = NSRect(
                x: (rect.width - symbolSize.width) / 2,
                y: (rect.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )
            configuredSymbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        return true
    }
    return image
}

/// Save image as PNG
func savePNG(_ image: NSImage, to path: String) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"])
    }
    try pngData.write(to: URL(fileURLWithPath: path))
}

// Main
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: generate-icon.swift <output-directory>")
    exit(1)
}

let outputDir = args[1]

// Create iconset directory
let iconsetDir = "\(outputDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Generate all required sizes for macOS app icon
let sizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

do {
    for (name, size) in sizes {
        let image = generateIcon(size: size)
        let path = "\(iconsetDir)/\(name).png"
        try savePNG(image, to: path)
        print("Generated: \(name).png (\(size)x\(size))")
    }
    print("Iconset created at: \(iconsetDir)")
} catch {
    print("Error: \(error)")
    exit(1)
}
