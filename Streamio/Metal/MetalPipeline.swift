//
//  MetalPipeline.swift
//  Streamio
//
//  GPU canvas compositor. Every source frame is drawn aspect-fit onto an output-sized
//  canvas with the scene's filter baked in; the same canvas feeds the encoder,
//  the recorder and the preview, so what you see is exactly what goes out.
//

import CoreVideo
import Foundation
import Metal
import MetalKit

nonisolated private struct ShaderParams {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var intensity: Float
    var filterType: UInt32
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
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            renderPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Metal shader compilation failed: \(error)")
        }
    }

    // MARK: - Canvas composition

    /// Draws `source` aspect-fit onto a `width`×`height` canvas. A nil source yields black.
    public func composeCanvas(source: CVPixelBuffer?, width: Int, height: Int,
                              filter: FilterType, params: FilterParameters) -> CVPixelBuffer? {
        guard let source else { return blankCanvas(width: width, height: height) }

        // Fast path: source already matches the canvas and needs no processing.
        if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height,
           filter == .passthrough, params.isNeutral {
            return source
        }

        guard let destination = makeCanvasBuffer(width: width, height: height),
              let sourceTexture = makeTexture(from: source),
              let destinationTexture = makeTexture(from: destination),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destinationTexture.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let viewport = Self.aspectFitViewport(
            content: (CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source)),
            target: (width, height)
        )
        guard encodeDraw(into: commandBuffer, pass: pass, texture: sourceTexture.texture,
                         viewport: viewport, filter: filter, params: params) else { return nil }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // Keep the CVMetalTextures alive until the GPU is done with them.
        withExtendedLifetime((sourceTexture, destinationTexture)) {}
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
        guard encodeDraw(into: commandBuffer, pass: pass, texture: texture.texture, viewport: viewport,
                         filter: .passthrough, params: FilterParameters()) else { return }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(texture) {}
        }
        commandBuffer.commit()
    }

    // MARK: - Helpers

    private struct TextureHandle: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
    }

    private func encodeDraw(into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: MTLTexture,
                            viewport: MTLViewport, filter: FilterType, params: FilterParameters) -> Bool {
        guard let pipeline = renderPipelineState, let sampler = samplerState,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var shaderParams = ShaderParams(
            brightness: params.brightness,
            contrast: params.contrast,
            saturation: params.saturation,
            intensity: params.intensity,
            filterType: filter.shaderCode
        )
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
                let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
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

    static func aspectFitViewport(content: (Int, Int), target: (Int, Int)) -> MTLViewport {
        let (contentWidth, contentHeight) = (Double(max(content.0, 1)), Double(max(content.1, 1)))
        let (targetWidth, targetHeight) = (Double(max(target.0, 1)), Double(max(target.1, 1)))
        let scale = min(targetWidth / contentWidth, targetHeight / contentHeight)
        let width = contentWidth * scale
        let height = contentHeight * scale
        return MTLViewport(originX: (targetWidth - width) / 2, originY: (targetHeight - height) / 2,
                           width: width, height: height, znear: 0, zfar: 1)
    }
}
