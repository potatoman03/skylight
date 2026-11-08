import AppKit
import Metal
import QuartzCore
import SkylightCore
import SwiftUI

/// The theme's picture again, cropped exactly as the window's backdrop crops it, with its
/// ribbons flowing: waves run along them, up and to the right. It comes in moving and slows, and
/// is at rest on the still picture by `stillBy` seconds from `start`, or soon after `calm`, so
/// the backdrop under it can take over without a seam. A change of picture crossfades.
///
/// The welcome's opening uses it over the backdrop. It doesn't play GIFs or blurred pictures;
/// leave those to the backdrop.
struct FlowingPicture: NSViewRepresentable {
    let url: URL
    let image: ThemeImage
    let dark: Bool
    /// When the flow started.
    let start: Date
    /// Seconds from `start` when it's still.
    let stillBy: Double
    let calm: Bool

    static func shows(_ image: ThemeImage) -> Bool { !image.isAnimated && image.blur == 0 }

    func makeNSView(context: Context) -> FlowView { FlowView() }

    func updateNSView(_ view: FlowView, context: Context) {
        view.update(url: url, image: image, dark: dark, start: start, stillBy: stillBy, calm: calm)
    }
}

final class FlowView: NSView {
    private struct Uniforms {
        var size: SIMD2<Float>
        var origin: SIMD2<Float>
        var shown: SIMD2<Float>
        var previousOrigin: SIMD2<Float>
        var previousShown: SIMD2<Float>
        var scale: Float
        var time: Float
        var amplitude: Float
        var mix: Float
        var fade: SIMD4<Float>
        var previousFade: SIMD4<Float>
    }

    private struct Picture {
        let url: URL
        let texture: MTLTexture
        let size: CGSize
        var focus: CGPoint
        var zoom: CGFloat
        /// What it fades toward, and how far.
        var fade: SIMD4<Float>
    }

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = makePipeline()
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    /// Asks for a frame only when there's a drawable free, so the main thread never waits on
    /// one: a screen recording or screen share can hold them for a while.
    private var link: CAMetalDisplayLink?

    private var picture: Picture?
    private var previous: Picture?
    private var changedAt: CFTimeInterval = 0
    private var started: CFTimeInterval = CACurrentMediaTime()
    private var calmedAt: CFTimeInterval?
    private var stillBy: Double = 0

    private static var textures: [URL: (MTLTexture, CGSize)] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // The pictures are sRGB, sampled as stored, so they match the backdrop's to the pixel.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.needsDisplayOnBoundsChange = true
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(url: URL, image: ThemeImage, dark: Bool, start: Date, stillBy: Double, calm: Bool) {
        self.stillBy = stillBy
        started = CACurrentMediaTime() - Date.now.timeIntervalSince(start)
        if calm, calmedAt == nil { calmedAt = CACurrentMediaTime() }
        if !calm { calmedAt = nil }
        let fade = dark ? SIMD4<Float>(0, 0, 0, Float(image.fade)) : SIMD4<Float>(1, 1, 1, Float(image.fade))
        if picture?.url != url, let device, let (texture, size) = Self.texture(url, device: device) {
            // A picture still coming in when the next one's chosen leaves from where it got to.
            if picture != nil, mixAmount(at: CACurrentMediaTime()) >= 0.5 { previous = picture }
            if picture == nil { previous = nil }
            picture = Picture(url: url, texture: texture, size: size, focus: CGPoint(x: image.focusX, y: image.focusY),
                              zoom: image.zoom, fade: fade)
            changedAt = previous == nil ? 0 : CACurrentMediaTime()
            updateResolution()
        } else {
            picture?.focus = CGPoint(x: image.focusX, y: image.focusY)
            picture?.zoom = image.zoom
            picture?.fade = fade
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil, let metalLayer else { return }
        updateResolution()
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateResolution()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateResolution()
    }

    /// While it moves, as sharp as the picture itself, which is fewer pixels than the screen's;
    /// a screen share or recording can hold full-size drawables long enough to stall it. As it
    /// comes to rest, the screen's own resolution, the one the backdrop is drawn at, so it matches
    /// that to the pixel when it hands over.
    private var sharp = false

    private func updateResolution() {
        guard let metalLayer else { return }
        let screen = window?.backingScaleFactor ?? 2
        var scale = screen
        if !sharp, let picture, picture.size.width > 0, picture.size.height > 0 {
            let fill = max(bounds.width / picture.size.width, bounds.height / picture.size.height) * max(picture.zoom, 1)
            if fill > 0 { scale = min(screen, max(1, (1 / fill * 1.15 * 4).rounded(.up) / 4)) }
        }
        // The layer stretches whatever size it's given to fill itself, so only the drawables change.
        metalLayer.contentsScale = screen
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    private func mixAmount(at now: CFTimeInterval) -> Double {
        guard previous != nil else { return 1 }
        return Self.smooth((now - changedAt) / 0.6)
    }

    /// Where the picture sits: filling the view, cropped about its focus, as `BackdropImageView` lays it out.
    private func frame(of picture: Picture) -> (SIMD2<Float>, SIMD2<Float>) {
        let size = picture.size
        guard size.width > 0, size.height > 0 else { return (.zero, .one) }
        let fill = max(bounds.width / size.width, bounds.height / size.height) * max(picture.zoom, 1)
        let width = size.width * fill, height = size.height * fill
        let origin = SIMD2(Float((bounds.width - width) * picture.focus.x), Float((bounds.height - height) * picture.focus.y))
        return (origin, SIMD2(Float(width), Float(height)))
    }

    fileprivate func draw(into drawable: CAMetalDrawable) {
        guard let metalLayer, let queue, let pipeline, bounds.width > 0, bounds.height > 0,
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let now = CACurrentMediaTime()
        if let picture {
            let mix = mixAmount(at: now)
            if mix >= 1 { previous = nil }
            let t = max(0, now - started)
            // It comes in moving, quicker and wider, slows, and over its last second and a half
            // comes to rest.
            let phase = t + 4.0 * (1 - exp(-t / 1.6))
            var amplitude = Double(bounds.height) * 0.016 * (1 + 1.0 * exp(-t / 2.4))
            amplitude *= 1 - Self.smooth((t - (stillBy - 1.5)) / 1.5)
            if let calmedAt { amplitude *= 1 - Self.smooth((now - calmedAt) / 0.65) }
            let resting = t > stillBy - 0.5 || calmedAt.map { now - $0 > 0.4 } ?? false
            if resting != sharp {
                sharp = resting
                updateResolution()
            }
            let (origin, shown) = frame(of: picture)
            let (previousOrigin, previousShown) = previous.map(frame) ?? (origin, shown)
            var uniforms = Uniforms(size: SIMD2(Float(bounds.width), Float(bounds.height)), origin: origin, shown: shown,
                                    previousOrigin: previousOrigin, previousShown: previousShown,
                                    scale: Float(CGFloat(drawable.texture.width) / bounds.width), time: Float(phase), amplitude: Float(amplitude),
                                    mix: Float(mix), fade: picture.fade, previousFade: previous?.fade ?? picture.fade)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(picture.texture, index: 0)
            encoder.setFragmentTexture(previous?.texture ?? picture.texture, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// The picture's pixels as they're stored, in sRGB.
    private static func texture(_ url: URL, device: MTLDevice) -> (MTLTexture, CGSize)? {
        if let cached = textures[url] { return cached }
        guard let image = CGImage.upright(at: url), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        let result = (texture, CGSize(width: width, height: height))
        textures[url] = result
        return result
    }

    private func makePipeline() -> MTLRenderPipelineState? {
        guard let device, let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "flowVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "flowFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;
        float2 origin;
        float2 shown;
        float2 previousOrigin;
        float2 previousShown;
        float scale;
        float time;
        float amplitude;
        float mix;
        float4 fade;
        float4 previousFade;
    };

    struct Out { float4 position [[position]]; };

    vertex Out flowVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Out out;
        out.position = float4(p * 2 - 1, 0, 1);
        return out;
    }

    // How far a point of the window is carried, in points. Waves run along the ribbons, which
    // rise to the right, and bend them across; a second set, shorter and slower, keeps it from
    // repeating. Nothing moves at the window's edges, so nothing smears in from past them.
    float2 flow(float2 p, constant Uniforms &u) {
        float2 q = p / u.size.y;
        float2 along = normalize(float2(1.0, -0.62));
        float2 across = float2(-along.y, along.x);
        float s = dot(q, along), r = dot(q, across), t = u.time;
        float bend = sin(s * 3.1 - t * 0.75 + r * 1.4) * 0.5
                   + sin(s * 5.3 - t * 1.15 - r * 2.6 + 1.3) * 0.22
                   + sin(s * 1.7 - t * 0.45 + r * 0.9 + 2.1) * 0.4;
        float drift = sin(r * 2.4 + t * 0.55 + s * 0.8) * 0.3;
        float2 edge2 = min(p, u.size - p) / u.size.y;
        float edge = smoothstep(0.0, 0.07, min(edge2.x, edge2.y));
        return (across * bend + along * drift) * u.amplitude * edge;
    }

    fragment float4 flowFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> picture [[texture(0)]], texture2d<float> previous [[texture(1)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        float2 p = in.position.xy / u.scale;
        float2 at = p - flow(p, u);
        float3 color = picture.sample(linear, (at - u.origin) / u.shown).rgb;
        color = mix(color, u.fade.rgb, u.fade.a);
        if (u.mix < 1.0) {
            float3 before = previous.sample(linear, (at - u.previousOrigin) / u.previousShown).rgb;
            before = mix(before, u.previousFade.rgb, u.previousFade.a);
            color = mix(before, color, u.mix);
        }
        return float4(color, 1.0);
    }
    """
}

extension FlowView: CAMetalDisplayLinkDelegate {
    // The link runs on the main run loop.
    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        nonisolated(unsafe) let drawable = update.drawable
        MainActor.assumeIsolated { draw(into: drawable) }
    }
}
