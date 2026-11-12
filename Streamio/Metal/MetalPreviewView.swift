//
//  MetalPreviewView.swift
//  Streamio
//

import SwiftUI
import MetalKit
import CoreVideo

public struct MetalPreviewView: NSViewRepresentable {
    public class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalPreviewView
        var currentPixelBuffer: CVPixelBuffer?
        private let lock = NSLock()

        init(parent: MetalPreviewView) {
            self.parent = parent
        }

        public func updateFrame(_ pixelBuffer: CVPixelBuffer) {
            lock.lock()
            self.currentPixelBuffer = pixelBuffer
            lock.unlock()
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            lock.lock()
            let buffer = currentPixelBuffer
            lock.unlock()

            guard let pixelBuffer = buffer else { return }

            MetalPipeline.shared.renderToView(
                pixelBuffer: pixelBuffer,
                mtkView: view,
                filter: parent.filter,
                params: parent.filterParams
            )
        }
    }

    public var filter: FilterType
    public var filterParams: FilterParameters
    public weak var previewRendererDelegate: MetalPreviewRendererDelegate?

    public init(filter: FilterType,
                filterParams: FilterParameters,
                previewRendererDelegate: MetalPreviewRendererDelegate? = nil) {
        self.filter = filter
        self.filterParams = filterParams
        self.previewRendererDelegate = previewRendererDelegate
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(parent: self)
        previewRendererDelegate?.registerPreviewCoordinator(coordinator)
        return coordinator
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: MetalPipeline.shared.device)
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.parent = self
    }
}

public protocol MetalPreviewRendererDelegate: AnyObject {
    func registerPreviewCoordinator(_ coordinator: MetalPreviewView.Coordinator)
}

