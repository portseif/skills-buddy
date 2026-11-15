//
//  LogoMarkTests.swift
//  SkillsBuddyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Skills_Buddy

struct LogoMarkTests {
    private static let side = 64

    /// A 64×64 logo: `draw` paints it with Core Graphics (origin bottom left).
    private func logo(_ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: Self.side, height: Self.side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context)
        return context.makeImage()!
    }

    /// The mark's alpha at a point, top-left origin, 0 to 1.
    private func alpha(of image: CGImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Double(pixel[3]) / 255
    }

    private let full = CGRect(x: 0, y: 0, width: 64, height: 64)

    @Test func aMarkOnATileIsWhatDiffersFromTheTile() throws {
        let image = logo { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(full)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); context.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        let mark = try #require(LogoMark.mark(from: image))
        // Cropped to the disc: its center is mark, the square's corners aren't.
        #expect(alpha(of: mark, x: 32, y: 32) > 0.9)
        #expect(alpha(of: mark, x: 2, y: 2) < 0.1)
    }

    @Test func darkDetailOnALightMarkStaysAHole() throws {
        let image = logo { context in
            context.setFillColor(CGColor(red: 0.56, green: 0.27, blue: 1, alpha: 1)); context.fill(full)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 12, y: 12, width: 40, height: 40))
            context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 28, y: 28, width: 8, height: 8))
        }
        let mark = try #require(LogoMark.mark(from: image))
        #expect(alpha(of: mark, x: 8, y: 8) > 0.9)
        #expect(alpha(of: mark, x: 32, y: 32) < 0.1)
    }

    @Test func aGlyphOnTransparencyIsItsOwnMark() throws {
        let image = logo { context in
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
            context.fill(CGRect(x: 24, y: 8, width: 16, height: 48))
        }
        let mark = try #require(LogoMark.mark(from: image))
        #expect(alpha(of: mark, x: 32, y: 32) > 0.9)
        #expect(alpha(of: mark, x: 4, y: 32) < 0.1)
    }

    @Test func aTileWithNothingOnItHasNoMark() {
        let blank = logo { context in
            context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1)); context.fill(full)
        }
        #expect(LogoMark.mark(from: blank) == nil)
        #expect(LogoMark.markPNG(fromLogo: Data("not an image".utf8)) == nil)
    }
}
