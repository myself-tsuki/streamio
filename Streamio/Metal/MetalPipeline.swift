//
//  MetalPipeline.swift
//  Streamio
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import CoreImage

struct ShaderParams {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var intensity: Float
    var filterType: UInt32
}

public final class MetalPipeline: NSObject, @unchecked Sendable {
    public static let shared = MetalPipeline()

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var renderPipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var textureCache: CVMetalTextureCache?

    // Pixel buffer pool for filtered frames to be sent to encoder and recorder
    private var pixelBufferPool: CVPixelBufferPool?
    private var currentPoolWidth: Int = 0
    private var currentPoolHeight: Int = 0

    // CIContext fallback / accelerator
    public let ciContext: CIContext

    private override init() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac device.")
        }
        self.device = defaultDevice
        guard let queue = defaultDevice.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue.")
        }
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: defaultDevice)

        super.init()

        setupTextureCache()
        setupSamplerState()
        setupPipeline()
    }

    private func setupTextureCache() {
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if result == kCVReturnSuccess {
            self.textureCache = cache
        }
    }

    private func setupSamplerState() {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: descriptor)
    }

    private func setupPipeline() {
        let library: MTLLibrary
        if let lib = try? device.makeLibrary(source: MetalShaderSource.source, options: nil) {
            library = lib
        } else if let defaultLib = try? device.makeDefaultLibrary() {
            library = defaultLib
        } else {
            print("Warning: Could not create Metal library.")
            return
        }

        let vertexFunction = library.makeFunction(name: "videoVertexShader")
        let fragmentFunction = library.makeFunction(name: "videoFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create Metal pipeline state: \(error)")
        }
    }

    private func getFilterCode(for filter: FilterType) -> UInt32 {
        switch filter {
        case .passthrough: return 0
        case .mono: return 1
        case .sepia: return 2
        case .cyberpunk: return 3
        case .vignette: return 4
        case .comic: return 5
        case .invert: return 6
        case .greenScreen: return 7
        }
    }

    private func ensurePixelBufferPool(width: Int, height: Int) {
        if pixelBufferPool != nil && currentPoolWidth == width && currentPoolHeight == height {
            return
        }
        currentPoolWidth = width
        currentPoolHeight = height

        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, pixelBufferAttributes as CFDictionary, &pool)
        self.pixelBufferPool = pool
    }

    /// Renders a camera frame with active filter into an MTKView drawable
    public func renderToView(pixelBuffer: CVPixelBuffer,
                             mtkView: MTKView,
                             filter: FilterType,
                             params: FilterParameters) {
        guard let currentDrawable = mtkView.currentDrawable,
              let renderPassDesc = mtkView.currentRenderPassDescriptor,
              let pipelineState = renderPipelineState,
              let sampler = samplerState,
              let textureCache = textureCache else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture, let inTexture = CVMetalTextureGetTexture(cvTex) else {
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }

        var shaderParams = ShaderParams(
            brightness: params.brightness,
            contrast: params.contrast,
            saturation: params.saturation,
            intensity: params.filterIntensity,
            filterType: getFilterCode(for: filter)
        )

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(inTexture, index: 0)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.setFragmentBytes(&shaderParams, length: MemoryLayout<ShaderParams>.stride, index: 0)

        // Draw 3 vertices for full-screen triangle
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        renderEncoder.endEncoding()

        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }

    /// Filters a camera frame and returns a new CVPixelBuffer with the Metal filter baked in for encoders/recorders
    public func processFrame(sourcePixelBuffer: CVPixelBuffer,
                             filter: FilterType,
                             params: FilterParameters) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(sourcePixelBuffer)
        let height = CVPixelBufferGetHeight(sourcePixelBuffer)

        ensurePixelBufferPool(width: width, height: height)
        guard let pool = pixelBufferPool else { return sourcePixelBuffer }

        var destinationPixelBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationPixelBuffer)
        guard poolStatus == kCVReturnSuccess, let destBuffer = destinationPixelBuffer else {
            return sourcePixelBuffer
        }

        guard let textureCache = textureCache,
              let pipelineState = renderPipelineState,
              let sampler = samplerState else {
            return sourcePixelBuffer
        }

        var sourceCvTexture: CVMetalTexture?
        let srcStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            sourcePixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &sourceCvTexture
        )

        var destCvTexture: CVMetalTexture?
        let dstStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            destBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &destCvTexture
        )

        guard srcStatus == kCVReturnSuccess, dstStatus == kCVReturnSuccess,
              let srcCv = sourceCvTexture, let dstCv = destCvTexture,
              let srcTexture = CVMetalTextureGetTexture(srcCv),
              let dstTexture = CVMetalTextureGetTexture(dstCv) else {
            return sourcePixelBuffer
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = dstTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return sourcePixelBuffer
        }

        var shaderParams = ShaderParams(
            brightness: params.brightness,
            contrast: params.contrast,
            saturation: params.saturation,
            intensity: params.filterIntensity,
            filterType: getFilterCode(for: filter)
        )

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setFragmentTexture(srcTexture, index: 0)
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        renderEncoder.setFragmentBytes(&shaderParams, length: MemoryLayout<ShaderParams>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        renderEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return destBuffer
    }
}

