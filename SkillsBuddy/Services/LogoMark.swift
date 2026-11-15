//
//  LogoMark.swift
//  SkillsBuddy
//
//  A logo as a one-color mark, for icons drawn as templates (the sidebar's).
//  Most favicons are a tile (white, black, a brand color) with the mark on it,
//  lighter or darker than the tile; the mark is whatever is lighter (or
//  darker) than the tile's border, as strongly as it is, so a white ghost on
//  purple keeps its dark eyes as holes. A logo on transparency is its own
//  mark. The result is cropped to the mark, so every logo fills its icon about
//  the same. A tile that's a gradient or a photo has no clear mark.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum LogoMark {
    /// The side of the square a logo is read at, and the mark is drawn at.
    private static let side = 64
    /// A logo this opaque is a tile with a background; less is a mark on
    /// transparency.
    private static let tileCoverage = 0.6
    /// The tile's edge (its outline, antialiasing, a drop shadow) is this many
    /// pixels wide and isn't part of the mark.
    private static let tileEdge = 3
    /// Lightness this close to the tile's is background, or more if its
    /// border is noisy; `markRamp` further on, it's all mark.
    private static let minimumTolerance = 0.04
    private static let markRamp = 0.2
    /// A border whose lightness spreads more than this (median deviation)
    /// isn't one background (a gradient, a photo).
    private static let maximumBorderSpread = 0.15
    /// Fainter ink than this, after the strongest is made full, is noise.
    private static let noiseFloor = 0.15
    /// A mark covering more than this is a block with nothing on it.
    private static let maximumCoverage = 0.7

    /// A tile's lightness and how far from it still counts as background.
    private struct Background {
        let lightness: Double
        let tolerance: Double
    }

    /// A PNG of the logo's mark (black, the mark in its alpha), or nil when the
    /// logo can't be read or has no clear mark.
    static func markPNG(fromLogo data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let logo = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let mark = mark(from: logo) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, mark, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The logo's mark, or nil when it has none: nothing differs from the
    /// background, or the "mark" is the whole square.
    static func mark(from logo: CGImage) -> CGImage? {
        guard let pixels = pixels(of: logo) else { return nil }
        var ink: [Double]
        let coverage = pixels.reduce(0) { $0 + $1.alpha } / Double(pixels.count)
        if coverage < tileCoverage {
            ink = pixels.map(\.alpha)
        } else {
            guard let background = tileBackground(in: pixels) else { return nil }
            let inner = erodedTile(pixels)
            // Signed: how much lighter (or darker) than the tile, past the tolerance.
            let contrast = pixels.indices.map { index -> Double in
                guard inner[index] else { return 0 }
                let difference = pixels[index].lightness - background.lightness
                let beyond = max(abs(difference) - background.tolerance, 0)
                return (difference < 0 ? -1 : 1) * pixels[index].alpha * min(beyond / markRamp, 1)
            }
            // The mark is lighter or darker than the tile, whichever is most of it.
            let lighter = contrast.filter { $0 > 0 }.reduce(0, +)
            let darker = -contrast.filter { $0 < 0 }.reduce(0, +)
            ink = contrast.map { lighter >= darker ? max($0, 0) : max(-$0, 0) }
        }
        // A faint mark (gray on dark gray) still draws at full strength.
        guard let strongest = ink.max(), strongest > 0.05 else { return nil }
        ink = ink.map { strength in
            let normalized = min(strength / strongest, 1)
            return normalized < noiseFloor ? 0 : normalized
        }
        guard ink.reduce(0, +) / Double(ink.count) < maximumCoverage else { return nil }
        return croppedImage(of: ink)
    }

    // MARK: - Pixels

    nonisolated struct Pixel {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        /// Relative luminance's weights on the sRGB values: close enough to
        /// tell a mark from its tile.
        var lightness: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    /// The logo drawn at `side`×`side`, unpremultiplied, top row first.
    private static func pixels(of image: CGImage) -> [Pixel]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let alpha = Double(bytes[offset + 3]) / 255
            guard alpha > 0 else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
            return Pixel(
                red: Double(bytes[offset]) / 255 / alpha,
                green: Double(bytes[offset + 1]) / 255 / alpha,
                blue: Double(bytes[offset + 2]) / 255 / alpha,
                alpha: alpha
            )
        }
    }

    /// The lightness the tile's border shares, read just inside the tile's
    /// edge, or nil when it's mixed (a gradient, a photo).
    private static func tileBackground(in pixels: [Pixel]) -> Background? {
        let inset = tileEdge, last = side - 1 - tileEdge
        var ring: [Pixel] = []
        for x in inset...last { ring += [pixels[inset * side + x], pixels[last * side + x]] }
        for y in (inset + 1)..<last { ring += [pixels[y * side + inset], pixels[y * side + last]] }
        let opaque = ring.filter { $0.alpha > 0.9 }.map(\.lightness)
        guard opaque.count * 2 > ring.count else { return nil }

        // Medians, so noise along part of the border (a textured tile) doesn't count.
        let lightness = opaque.sorted()[opaque.count / 2]
        let spread = opaque.map { abs($0 - lightness) }.sorted()[opaque.count / 2]
        guard spread <= maximumBorderSpread else { return nil }
        return Background(lightness: lightness, tolerance: max(minimumTolerance, spread * 3))
    }

    /// The tile without its outer `tileEdge` pixels: opaque, and opaque all
    /// around within that distance.
    private static func erodedTile(_ pixels: [Pixel]) -> [Bool] {
        let opaque = pixels.map { $0.alpha > 0.5 }
        return pixels.indices.map { index in
            let x = index % side, y = index / side
            guard x >= tileEdge, y >= tileEdge, x < side - tileEdge, y < side - tileEdge else { return false }
            for neighborY in (y - tileEdge)...(y + tileEdge) {
                for neighborX in (x - tileEdge)...(x + tileEdge) where !opaque[neighborY * side + neighborX] {
                    return false
                }
            }
            return true
        }
    }

    // MARK: - Output

    /// The ink as black with that alpha, cropped to a square around the mark.
    private static func croppedImage(of ink: [Double]) -> CGImage? {
        var minimumX = side, minimumY = side, maximumX = -1, maximumY = -1
        for index in ink.indices where ink[index] > 0.08 {
            let x = index % side, y = index / side
            minimumX = min(minimumX, x); maximumX = max(maximumX, x)
            minimumY = min(minimumY, y); maximumY = max(maximumY, y)
        }
        guard maximumX >= minimumX else { return nil }

        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for index in ink.indices { bytes[index * 4 + 3] = UInt8((ink[index] * 255).rounded()) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let full = bytes.withUnsafeMutableBytes({ buffer in
            CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: bitmapInfo)?.makeImage()
        }), let output = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)
        else { return nil }

        // Scale the mark's square (plus a pixel each side for its
        // antialiasing) up to the output, centered. Rows run top down in
        // `ink` but bottom up in Core Graphics.
        let markSide = Double(max(maximumX - minimumX, maximumY - minimumY) + 1)
        let scale = Double(side) / (markSide + 2)
        let centerX = Double(minimumX + maximumX + 1) / 2
        let centerY = Double(side) - Double(minimumY + maximumY + 1) / 2
        output.interpolationQuality = .high
        output.draw(full, in: CGRect(
            x: Double(side) / 2 - centerX * scale,
            y: Double(side) / 2 - centerY * scale,
            width: Double(side) * scale,
            height: Double(side) * scale
        ))
        return output.makeImage()
    }
}
