//
//  MetalPreviewView.swift
//  Streamio
//
//  The program preview. The MTKView ticks at the canvas frame rate but only encodes
//  GPU work when the pipeline has published a new frame.
//

import MetalKit
import SwiftUI

struct MetalPreviewView: NSViewRepresentable {
    let store: PreviewFrameStore
    let fps: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MetalPipeline.shared.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = fps
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(String(localized: "Program preview"))
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        if view.preferredFramesPerSecond != fps {
            view.preferredFramesPerSecond = fps
        }
        context.coordinator.store = store
    }

    /// MTKView calls its delegate on the main thread.
    final class Coordinator: NSObject, MTKViewDelegate {
        var store: PreviewFrameStore
        private var lastGeneration: UInt64 = 0
        private var needsRedraw = true

        init(store: PreviewFrameStore) {
            self.store = store
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            needsRedraw = true
        }

        func draw(in view: MTKView) {
            // After a resize, redraw the current frame even if it is not new.
            let seen = needsRedraw ? UInt64.max : lastGeneration
            guard let (frame, generation) = store.frame(newerThan: seen) else {
                return // nothing new: the last presented image stays on screen
            }
            needsRedraw = false
            lastGeneration = generation
            MetalPipeline.shared.present(frame, in: view)
        }
    }
}
