//
//  MetalPipeline.swift
//  Streamio
//
//  GPU canvas compositor. Every tick, each visible source of the scene is drawn onto an
//  output-sized canvas (fit, fill, stretch or picture-in-picture) with its filter baked in;
//  the same canvas feeds the encoder, the recorder and the preview, so what you see is
//  exactly what goes out.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalKit

/// Must match `ShaderParams` in MetalShaderSource (all 4-byte fields, same order).
nonisolated private struct ShaderParams {
    var brightness: Float = 0
    var contrast: Float = 1
    var saturation: Float = 1
    var intensity: Float = 1
    var filterType: UInt32 = 0
    var uvX: Float = 0
    var uvY: Float = 0
    var uvWidth: Float = 1
    var uvHeight: Float = 1
    var mirror: UInt32 = 0
    var opacity: Float = 1
    var shape: UInt32 = 0
    var viewWidth: Float = 1
    var viewHeight: Float = 1
    var borderWidth: Float = 0
    var borderRed: Float = 1
    var borderGreen: Float = 1
    var borderBlue: Float = 1
}

/// One source frame to draw onto the canvas.
nonisolated public struct CanvasLayer: @unchecked Sendable {
    public var source: CVPixelBuffer
    public var layout: SourceLayout
    public var pipScale: Double
    public var isMirrored: Bool
    public var opacity: Float
    public var filter: FilterType
    public var params: FilterParameters
    public var shape: SourceShape
    public var borderWidth: Double
    public var borderColor: SourceColor
    public var offsetX: Double
    public var offsetY: Double

    public init(source: CVPixelBuffer, layout: SourceLayout, pipScale: Double, isMirrored: Bool, opacity: Float,
                filter: FilterType, params: FilterParameters, shape: SourceShape = .rectangle, borderWidth: Double = 0,
                borderColor: SourceColor = .white, offsetX: Double = 0, offsetY: Double = 0) {
        self.shape = shape
        self.borderWidth = borderWidth
        self.borderColor = borderColor
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.source = source
        self.layout = layout
        self.pipScale = pipScale
        self.isMirrored = isMirrored
        self.opacity = opacity
        self.filter = filter
        self.params = params
    }
}

nonisolated public final class MetalPipeline: @unchecked Sendable {
    public static let shared = MetalPipeline()

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var textureCache: CVMetalTextureCache?

    private let poolLock = NSLock()
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var blankFrame: CVPixelBuffer?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Streamio requires a Metal-capable Mac.")
        }
        self.device = device
        commandQueue = queue

        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess {
            textureCache = cache
        }

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: sampler)

        do {
            let library = try device.makeLibrary(source: MetalShaderSource.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "videoVertexShader")
            descriptor.fragmentFunction = library.makeFunction(name: "videoFragmentShader")
            // Premultiplied "over" blending so PNG logos, chroma key and PiP layers stack correctly.
            if let attachment = descriptor.colorAttachments[0] {
                attachment.pixelFormat = .bgra8Unorm
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            renderPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Metal shader compilation failed: \(error)")
        }
    }

    // MARK: - Canvas composition

    /// Composites `layers` (bottom first) onto a fresh `width`×`height` black canvas.
    /// The result always comes from Streamio's own pool, never from a capture device's pool,
    /// so a camera never runs out of buffers while the encoder or preview holds frames.
    public func composeCanvas(layers: [CanvasLayer], width: Int, height: Int) -> CVPixelBuffer? {
        guard !layers.isEmpty else { return blankCanvas(width: width, height: height) }
        guard let destination = makeCanvasBuffer(width: width, height: height),
              let destinationTexture = makeTexture(from: destination),
              let pipeline = renderPipelineState, let sampler = samplerState,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destinationTexture.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)

        var textures: [TextureHandle] = []
        for layer in layers {
            guard let texture = makeTexture(from: layer.source) else { continue }
            textures.append(texture)
            let placement = CanvasPlacement.make(
                layout: layer.layout, pipScale: layer.pipScale,
                contentWidth: CVPixelBufferGetWidth(layer.source), contentHeight: CVPixelBufferGetHeight(layer.source),
                canvasWidth: width, canvasHeight: height,
                squareCrop: layer.shape.cropsToSquare, offsetX: layer.offsetX, offsetY: layer.offsetY
            )
            var shaderParams = ShaderParams(
                brightness: layer.params.brightness, contrast: layer.params.contrast,
                saturation: layer.params.saturation, intensity: layer.params.intensity,
                filterType: layer.filter.shaderCode,
                uvX: placement.cropX, uvY: placement.cropY,
                uvWidth: placement.cropWidth, uvHeight: placement.cropHeight,
                mirror: layer.isMirrored ? 1 : 0, opacity: layer.opacity,
                shape: layer.shape.shaderCode,
                viewWidth: Float(placement.width), viewHeight: Float(placement.height),
                borderWidth: Float(layer.borderWidth),
                borderRed: Float(layer.borderColor.red), borderGreen: Float(layer.borderColor.green),
                borderBlue: Float(layer.borderColor.blue)
            )
            encoder.setViewport(Self.viewport(placement))
            encoder.setFragmentTexture(texture.texture, index: 0)
            encoder.setFragmentBytes(&shaderParams, length: MemoryLayout<ShaderParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // Keep the CVMetalTextures alive until the GPU is done with them.
        withExtendedLifetime((textures, destinationTexture)) {}
        return destination
    }

    // MARK: - Preview

    /// Presents a canvas frame into the preview's drawable, letterboxed to fit.
    public func present(_ canvas: CVPixelBuffer, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let texture = makeTexture(from: canvas),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = view.drawableSize
        let viewport = Self.aspectFitViewport(
            content: (CVPixelBufferGetWidth(canvas), CVPixelBufferGetHeight(canvas)),
            target: (Int(drawableSize.width), Int(drawableSize.height))
        )
        guard encodeDraw(into: commandBuffer, pass: pass, texture: texture.texture, viewport: viewport) else { return }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(texture) {}
        }
        commandBuffer.commit()
    }

    // MARK: - Images

    /// Loads a still image into a BGRA, Metal-compatible pixel buffer (premultiplied alpha).
    public static func makePixelBuffer(contentsOf url: URL) -> CVPixelBuffer? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
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
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Helpers

    private struct TextureHandle: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    private func encodeDraw(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: MTLTexture,
                            viewport: MTLViewport) -> Bool {
        guard let pipeline = renderPipelineState, let sampler = samplerState,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var shaderParams = ShaderParams()
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&shaderParams, length: MemoryLayout<ShaderParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> TextureHandle? {
        guard let textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return TextureHandle(cvTexture: cvTexture, texture: texture)
    }

    private func makeCanvasBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        poolLock.withLock {
            if pixelBufferPool == nil || poolSize != (width, height) {
                let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 8]
                let bufferAttributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: width,
                    kCVPixelBufferHeightKey: height,
                    kCVPixelBufferMetalCompatibilityKey: true,
                    kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
                ]
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &pool)
                pixelBufferPool = pool
                poolSize = (width, height)
                blankFrame = nil
            }
            guard let pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer)
            return buffer
        }
    }

    /// A cached black canvas (never mutated after creation, so sharing it is safe).
    private func blankCanvas(width: Int, height: Int) -> CVPixelBuffer? {
        if let cached = poolLock.withLock({ blankFrame }),
           CVPixelBufferGetWidth(cached) == width, CVPixelBufferGetHeight(cached) == height {
            return cached
        }
        guard let buffer = makeCanvasBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            // BGRA black with opaque alpha.
            let pixels = base.bindMemory(to: UInt32.self, capacity: bytesPerRow / 4 * height)
            for index in 0..<(bytesPerRow / 4 * height) {
                pixels[index] = 0xFF00_0000
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        poolLock.withLock { blankFrame = buffer }
        return buffer
    }

    static func viewport(_ placement: CanvasPlacement) -> MTLViewport {
        MTLViewport(originX: placement.x, originY: placement.y, width: placement.width, height: placement.height,
                    znear: 0, zfar: 1)
    }

    static func aspectFitViewport(content: (Int, Int), target: (Int, Int)) -> MTLViewport {
        viewport(CanvasPlacement.aspectFit(contentWidth: content.0, contentHeight: content.1,
                                           canvasWidth: target.0, canvasHeight: target.1))
    }
}
