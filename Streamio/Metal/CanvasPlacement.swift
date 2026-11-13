//
//  CanvasPlacement.swift
//  Streamio
//
//  Where a source lands on the canvas for each layout. Foundation-only so the
//  geometry is checked by scripts/verify-protocol.sh on any platform.
//

import Foundation

nonisolated public struct CanvasPlacement: Equatable, Sendable {
    /// Viewport on the canvas, in canvas pixels, origin top-left.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Part of the source that is sampled, in normalised texture coordinates.
    public var cropX: Float = 0
    public var cropY: Float = 0
    public var cropWidth: Float = 1
    public var cropHeight: Float = 1

    public init(x: Double, y: Double, width: Double, height: Double,
                cropX: Float = 0, cropY: Float = 0, cropWidth: Float = 1, cropHeight: Float = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
    }

    /// Largest rectangle with the content's aspect ratio that fits, centred.
    public static func aspectFit(contentWidth: Int, contentHeight: Int, canvasWidth: Int, canvasHeight: Int) -> CanvasPlacement {
        let content = (Double(max(contentWidth, 1)), Double(max(contentHeight, 1)))
        let target = (Double(max(canvasWidth, 1)), Double(max(canvasHeight, 1)))
        let scale = min(target.0 / content.0, target.1 / content.1)
        let width = content.0 * scale
        let height = content.1 * scale
        return CanvasPlacement(x: (target.0 - width) / 2, y: (target.1 - height) / 2, width: width, height: height)
    }

    /// Placement plus the overlay options: a square crop for square-ish shapes and a nudge.
    public static func make(layout: SourceLayout, pipScale: Double, contentWidth: Int, contentHeight: Int,
                            canvasWidth: Int, canvasHeight: Int, squareCrop: Bool, offsetX: Double, offsetY: Double) -> CanvasPlacement {
        var placement = make(layout: layout, pipScale: pipScale, contentWidth: contentWidth, contentHeight: contentHeight,
                             canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let canvasW = Double(max(canvasWidth, 1)), canvasH = Double(max(canvasHeight, 1))
        if squareCrop, layout.isPictureInPicture {
            let sourceAspect = Double(max(contentWidth, 1)) / Double(max(contentHeight, 1))
            let scale = min(max(pipScale, 0.05), 1)
            let side = min(canvasW * scale, canvasH * min(1, scale * 1.8))
            let margin = canvasW * 0.025
            let left = layout == .topLeft || layout == .bottomLeft
            let top = layout == .topLeft || layout == .topRight
            placement = CanvasPlacement(x: left ? margin : canvasW - margin - side, y: top ? margin : canvasH - margin - side,
                                        width: side, height: side)
            if sourceAspect > 1 {
                placement.cropWidth = Float(1 / sourceAspect)
                placement.cropX = (1 - placement.cropWidth) / 2
            } else {
                placement.cropHeight = Float(sourceAspect)
                placement.cropY = (1 - placement.cropHeight) / 2
            }
        }
        // The nudge may not push the overlay off the canvas.
        placement.x = min(max(placement.x + offsetX * canvasW, 0), max(0, canvasW - placement.width))
        placement.y = min(max(placement.y + offsetY * canvasH, 0), max(0, canvasH - placement.height))
        return placement
    }

    public static func make(layout: SourceLayout, pipScale: Double, contentWidth: Int, contentHeight: Int,
                            canvasWidth: Int, canvasHeight: Int) -> CanvasPlacement {
        let sourceWidth = Double(max(contentWidth, 1)), sourceHeight = Double(max(contentHeight, 1))
        let targetWidth = Double(max(canvasWidth, 1)), targetHeight = Double(max(canvasHeight, 1))
        let full = CanvasPlacement(x: 0, y: 0, width: targetWidth, height: targetHeight)

        switch layout {
        case .fit:
            return aspectFit(contentWidth: contentWidth, contentHeight: contentHeight,
                             canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        case .stretch:
            return full
        case .fill:
            var placement = full
            let sourceAspect = sourceWidth / sourceHeight
            let targetAspect = targetWidth / targetHeight
            if sourceAspect > targetAspect {
                placement.cropWidth = Float(targetAspect / sourceAspect)
                placement.cropX = (1 - placement.cropWidth) / 2
            } else {
                placement.cropHeight = Float(sourceAspect / targetAspect)
                placement.cropY = (1 - placement.cropHeight) / 2
            }
            return placement
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let scale = min(max(pipScale, 0.05), 1)
            var width = targetWidth * scale
            var height = width * sourceHeight / sourceWidth
            let maxHeight = targetHeight * min(1, scale * 1.8)
            if height > maxHeight {
                // Tall sources (portrait phones) are bounded by height instead.
                height = maxHeight
                width = height * sourceWidth / sourceHeight
            }
            let margin = targetWidth * 0.025
            let left = layout == .topLeft || layout == .bottomLeft
            let top = layout == .topLeft || layout == .topRight
            return CanvasPlacement(x: left ? margin : targetWidth - margin - width,
                                   y: top ? margin : targetHeight - margin - height,
                                   width: width, height: height)
        }
    }
}
