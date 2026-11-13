//
//  SignalSlate.swift
//  Streamio
//
//  The "No signal" card that stands in for a camera that dropped out (a loose USB cable, a
//  hub that reset). The stream and the recording keep running and viewers see this instead
//  of a frozen or black picture.
//

import CoreGraphics
import CoreText
import CoreVideo
import Foundation

nonisolated enum SignalSlate {
    static let title = "NO SIGNAL"
    static let subtitle = "We\u{2019}ll be right back"

    /// A BGRA, Metal-compatible card, drawn once and reused every frame.
    static func makePixelBuffer(width: Int = 1280, height: Int = 720) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        // Deep blue-grey backdrop, lighter toward the middle.
        let colors = [CGColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
                      CGColor(srgbRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0,
                                       endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: w * 0.65, options: .drawsAfterEndLocation)
        }

        // A broken-signal ring above the words.
        let ringCenter = CGPoint(x: w / 2, y: h * 0.64)
        let radius = h * 0.075
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.62, blue: 0.24, alpha: 1))
        context.setLineWidth(h * 0.012)
        context.setLineCap(.round)
        context.addArc(center: ringCenter, radius: radius, startAngle: .pi * 0.15, endAngle: .pi * 1.85, clockwise: false)
        context.strokePath()
        context.move(to: CGPoint(x: ringCenter.x - radius * 0.55, y: ringCenter.y - radius * 0.55))
        context.addLine(to: CGPoint(x: ringCenter.x + radius * 0.55, y: ringCenter.y + radius * 0.55))
        context.strokePath()

        draw(title, size: h * 0.11, weight: .emphasizedSystem, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
             centerX: w / 2, baselineY: h * 0.44, in: context)
        draw(subtitle, size: h * 0.052, weight: .system, color: CGColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1),
             centerX: w / 2, baselineY: h * 0.33, in: context)
        return buffer
    }

    private static func draw(_ text: String, size: CGFloat, weight: CTFontUIFontType, color: CGColor,
                             centerX: CGFloat, baselineY: CGFloat, in context: CGContext) {
        guard let font = CTFontCreateUIFontForLanguage(weight, size, nil) else { return }
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let string = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: centerX - CGFloat(width) / 2, y: baselineY)
        CTLineDraw(line, context)
    }
}
