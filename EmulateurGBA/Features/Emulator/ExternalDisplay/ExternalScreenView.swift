//
//  ExternalScreenView.swift
//  EmulateurGBA
//
//  The game as it appears on a TV, over AirPlay or a cable.
//
//  PRESENTATION ONLY. `EmulatorMetalView` on the device stays the emulation
//  clock: startRendering() unpauses it, its display link drives draw(in:),
//  and draw(in:) is what advances the core. A view living on an AirPlay
//  screen has no dependable display link, so it must never be given that
//  job. This one only encodes the texture the device view last wrote.
//

import UIKit
import MetalKit

final class ExternalScreenView: MTKView, MTKViewDelegate {
    weak var source: EmulatorMetalView?

    /// TV layout for the DS. Side by side by default: a 16:9 screen fits two
    /// 4:3 panels that way with far less wasted area than stacking them.
    var sideBySide: Bool = true {
        didSet { if sideBySide != oldValue { rebuildVertices() } }
    }

    private var vertexBuffer: MTLBuffer?

    init(source: EmulatorMetalView) {
        super.init(frame: .zero, device: source.device)
        self.source = source
        delegate = self
        framebufferOnly = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        backgroundColor = .black
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        // Non-negotiable: the pipeline states we borrow were compiled against
        // the producer's pixel format, so a different one makes them invalid.
        colorPixelFormat = source.mirrorPixelFormat
        isPaused = false
        rebuildVertices()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildVertices()
    }

    private func rebuildVertices() {
        guard let device = self.device, source?.mirrorIsDualScreen == true else {
            vertexBuffer = nil
            return
        }
        let vertices = EmulatorMetalView.ndsScreenVertices(
            viewW: Float(bounds.width > 0 ? bounds.width : 1280),
            viewH: Float(bounds.height > 0 ? bounds.height : 720),
            sideBySide: sideBySide,
            topScreenRatio: 0.495,
            // The TV always shows the clean layout. A control preset's custom
            // screen rects belong to the phone's dress, not to a television.
            custom: nil,
            swapped: UserDefaults.standard.bool(forKey: "ndsSwapScreens"))
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<EmulatorMetalView.ScreenVertex>.stride * vertices.count,
            options: .storageModeShared)
    }

    func draw(in view: MTKView) {
        // No session, or nothing running: draw nothing and let the idle
        // screen behind us show, rather than freezing on a stale frame.
        guard let source,
              let frame = source.mirrorFrame(),
              let queue = source.mirrorCommandQueue,
              let drawable = currentDrawable,
              let passDesc = currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }

        var uniforms = frame.uniforms
        encoder.setRenderPipelineState(frame.pipeline)
        encoder.setFragmentTexture(frame.texture, index: 0)
        if frame.usesFilterUniforms {
            encoder.setFragmentBytes(&uniforms,
                                     length: MemoryLayout<EmulatorMetalView.FilterUniforms>.stride,
                                     index: 0)
        }

        if frame.isDualScreen {
            if let vertexBuffer {
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12)
            }
        } else {
            // Single-screen games use the fullscreen-quad vertex shader; the
            // letterboxing is done by the view's frame, exactly as on the
            // phone, so the shader path stays untouched.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
