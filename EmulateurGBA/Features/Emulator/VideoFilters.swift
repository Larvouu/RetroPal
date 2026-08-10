//
//  VideoFilters.swift
//  EmulateurGBA
//
//  The display-filter catalog behind the Appearance sheet's Screen tab (all
//  consoles), wave one: 6 single-pass Metal filters + None. Pro feature (the
//  cards preview freely, applying is the unlock — tempt, don't lock).
//
//  ONE look, three surfaces: the live view (EmulatorMetalView), the screenshot
//  card, and the clip card all render through the SAME `filteredFragment`
//  shader — the share cards via `VideoFilterRenderer.apply`, an offscreen
//  pass at the exact rectangle size the frame lands on, so "what you share is
//  what you see" (a hard product requirement, 2026-07-24). Filters are
//  display-space: density derives from the output size, which is why the
//  offscreen pass renders at the destination size instead of filtering the
//  native frame.
//
//  The per-game choice is stored as `videoFilter_<romBasename>`; the EFFECTIVE
//  filter is `.none` for non-Pro users (defense in depth: the UI gates the
//  tap, this gates a lapsed/refunded Pro too).
//

import UIKit
import Metal

enum VideoFilter: String, CaseIterable, Identifiable {
    case none
    case scanlines
    case lcdGrid = "lcd-grid"
    case dotMatrix = "dot-matrix"
    case crt
    case smooth
    case sharp

    var id: String { rawValue }

    /// Mirrors the shader's kFilter* constants — keep in sync.
    var metalIndex: UInt32 {
        switch self {
        case .none: return 0
        case .scanlines: return 1
        case .lcdGrid: return 2
        case .dotMatrix: return 3
        case .crt: return 4
        case .smooth: return 5
        case .sharp: return 6
        }
    }

    /// Localization key of the display name.
    var nameKey: String { "filter.name.\(rawValue)" }

    /// Per-game persistence key, same basename derivation as skins/palettes.
    static func storageKey(forRomBasename romName: String) -> String {
        "videoFilter_\(romName)"
    }

    /// The stored choice (unknown / absent → .none).
    static func stored(forRomBasename romName: String) -> VideoFilter {
        VideoFilter(rawValue: UserDefaults.standard.string(
            forKey: storageKey(forRomBasename: romName)) ?? "") ?? .none
    }

    /// The filter actually rendered: the stored choice for Pro, `.none` otherwise.
    static func effective(forRomBasename romName: String) -> VideoFilter {
        UserDefaults.standard.bool(forKey: "isPro") ? stored(forRomBasename: romName) : .none
    }
}

/// Offscreen twin of the live filter pass: renders a game frame through the
/// same `filteredFragment` shader at a target pixel size and returns the
/// filtered CGImage. Used by the share-card renderers (screenshot + clip) and
/// the Appearance sheet's filter preview cards. Thread-safe (each call encodes
/// its own command buffer); callers on the share-card background queues run
/// sequentially anyway.
enum VideoFilterRenderer {

    private struct FilterUniforms {
        var filterType: UInt32
        var screenCount: UInt32
        var gameSize: SIMD2<Float>
    }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let library = device.makeDefaultLibrary() else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertexShader")
        desc.fragmentFunction = library.makeFunction(name: "filteredFragment")
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        return try? device.makeRenderPipelineState(descriptor: desc)
    }()

    /// Filter `image` at `targetSize` (pixels). Returns the input unchanged for
    /// `.none` and falls back to the unfiltered image on any Metal failure (a
    /// share card must never come out empty because a filter pass failed).
    /// `screenCount` = 2 for a stacked NDS dual-screen image (per-screen CRT).
    static func apply(_ filter: VideoFilter, to image: CGImage,
                      targetSize: CGSize, screenCount: Int = 1) -> CGImage? {
        guard filter != .none else { return image }
        guard let device, let queue, let pipeline else { return image }
        let w = max(1, Int(targetSize.width.rounded()))
        let h = max(1, Int(targetSize.height.rounded()))

        // Input texture: the frame's RGBA bytes (same premultiplied conversion
        // as the card renderers — mGBA frames are RGBX).
        let iw = image.width, ih = image.height
        var inBytes = [UInt8](repeating: 0, count: iw * ih * 4)
        let converted: Bool = inBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: iw, height: ih, bitsPerComponent: 8,
                                      bytesPerRow: iw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
            return true
        }
        guard converted else { return image }

        let inDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: iw, height: ih, mipmapped: false)
        inDesc.usage = .shaderRead
        guard let inTex = device.makeTexture(descriptor: inDesc) else { return image }
        inTex.replace(region: MTLRegionMake2D(0, 0, iw, ih), mipmapLevel: 0,
                      withBytes: inBytes, bytesPerRow: iw * 4)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        outDesc.usage = [.renderTarget]
        outDesc.storageMode = .shared
        guard let outTex = device.makeTexture(descriptor: outDesc) else { return image }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass) else { return image }
        var uniforms = FilterUniforms(filterType: filter.metalIndex,
                                      screenCount: UInt32(max(1, screenCount)),
                                      gameSize: SIMD2(Float(iw), Float(ih)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(inTex, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FilterUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Read back into a CGImage.
        var outBytes = [UInt8](repeating: 0, count: w * h * 4)
        outTex.getBytes(&outBytes, bytesPerRow: w * 4,
                        from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let out: CGImage? = outBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        return out ?? image
    }
}
