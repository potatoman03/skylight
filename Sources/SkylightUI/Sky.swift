import AppKit
import Metal
import QuartzCore
import SwiftUI

/// The window's ground: a sky in the active Space's hue, with light falling through it.
///
/// Light mode is a pale morning sky; dark mode is twilight. The rays drift slowly at 30 fps and stop
/// when the window is in the background, when Reduce Motion is on, or when they're turned off.
struct SkyBackdrop: View {
    let hue: Double
    var rays = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // Drawn underneath in case Metal isn't available.
            LinearGradient(colors: [Theme.skyTop(hue, scheme), Theme.skyBottom(hue, scheme)], startPoint: .top, endPoint: .bottom)
                .motion(Motion.hue, value: hue)
            SkyMetalView(hue: hue, dark: scheme == .dark, rays: rays)
        }
        .ignoresSafeArea()
    }
}

private struct SkyMetalView: NSViewRepresentable {
    let hue: Double
    let dark: Bool
    let rays: Bool

    func makeNSView(context: Context) -> SkyView { SkyView() }

    func updateNSView(_ view: SkyView, context: Context) {
        view.update(hue: hue, dark: dark, rays: rays)
    }
}

final class SkyView: NSView {
    private struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var hue: Float
        var dark: Float
        var rays: Float
    }

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = makePipeline()
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var observers: [NSObjectProtocol] = []

    // Hue and ray strength ease toward their targets frame by frame, so a Space switch
    // glides through the sky instead of jumping.
    private var hue: Float = 0.58
    private var targetHue: Float = 0.58
    private var dark: Float = 0
    private var targetDark: Float = 0
    private var rays: Float = 1
    private var targetRays: Float = 1
    private var configured = false

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
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.needsDisplayOnBoundsChange = true
        // The sky is soft; a lower resolution costs nothing visible and saves the GPU.
        layer.contentsScale = 1
        return layer
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(hue: Double, dark: Bool, rays: Bool) {
        targetHue = Float(hue - floor(hue))
        targetDark = dark ? 1 : 0
        targetRays = rays && !Motion.reduceMotion ? 1 : 0
        if !configured {
            configured = true
            self.hue = targetHue
            self.dark = targetDark
            self.rays = targetRays
        }
        updateRunning()
        if link == nil { settle() }
        draw()
    }

    /// Without animation, jump straight to where the sky is headed.
    private func settle() {
        hue = targetHue
        dark = targetDark
        rays = targetRays
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return stop() }
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
        updateRunning()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer?.drawableSize = CGSize(width: max(1, newSize.width), height: max(1, newSize.height))
        draw()
    }

    /// Animate only while there's something to see.
    private func updateRunning() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let settling = abs(hue - targetHue) > 0.001 || abs(dark - targetDark) > 0.01 || abs(rays - targetRays) > 0.01
        let animating = visible && (targetRays > 0 && NSApp.isActive || settling)
        if animating, link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if !animating {
            stop()
        }
    }

    private func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        settle()
        draw()
    }

    @objc private func tick() {
        hue = Self.approachHue(hue, targetHue)
        dark += (targetDark - dark) * 0.18
        rays += (targetRays - rays) * 0.08
        draw()
        if targetRays == 0 || !NSApp.isActive { updateRunning() }
    }

    /// Moves along the shorter way round the color wheel.
    private static func approachHue(_ from: Float, _ to: Float) -> Float {
        var delta = to - from
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        if abs(delta) < 0.001 { return to }
        let next = from + delta * 0.2
        return next - floor(next)
    }

    private func draw() {
        guard let metalLayer, let queue, let pipeline, bounds.width > 1, bounds.height > 1,
              let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
                                time: Float(CACurrentMediaTime() - start), hue: hue, dark: dark, rays: rays)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func makePipeline() -> MTLRenderPipelineState? {
        guard let device, let library = try? device.makeLibrary(source: Self.shader, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "skyVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Compiled at launch, so the project builds without the Metal toolchain.
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 size; float time; float hue; float dark; float rays; };
    struct Out { float4 position [[position]]; float2 uv; };

    vertex Out skyVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Out o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    static float3 hsv(float h, float s, float v) {
        float3 k = fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0;
        return v * mix(float3(1.0), clamp(abs(k) - 1.0, 0.0, 1.0), s);
    }

    static float hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    static float noise(float x) {
        float i = floor(x), f = fract(x);
        float a = fract(sin(i * 91.17) * 43758.5453), b = fract(sin((i + 1.0) * 91.17) * 43758.5453);
        return mix(a, b, f * f * (3.0 - 2.0 * f));
    }

    /// Shafts fanning out from a light above the top-left corner. Each layer is a band of
    /// angles that slowly breathes, so the light never looks like it's on a loop.
    static float shafts(float angle, float t) {
        float r = 0.0;
        r += pow(noise(angle * 9.0 + t * 0.045), 3.0) * 0.55;
        r += pow(noise(angle * 23.0 - t * 0.03 + 7.0), 4.0) * 0.45;
        r += pow(noise(angle * 47.0 + t * 0.06 + 13.0), 6.0) * 0.30;
        r *= 0.65 + 0.35 * sin(t * 0.21 + angle * 3.0);
        return r;
    }

    fragment float4 skyFragment(Out in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float aspect = u.size.x / max(u.size.y, 1.0);
        float t = u.time;

        // Morning: pale, airy, almost white at the horizon. Twilight: deep and calm.
        float3 dayTop = hsv(u.hue, 0.42, 0.98);
        float3 dayBottom = hsv(u.hue + 0.06, 0.16, 1.0);
        float3 duskTop = hsv(u.hue + 0.02, 0.55, 0.40);
        float3 duskBottom = hsv(u.hue + 0.09, 0.50, 0.16);
        float3 top = mix(dayTop, duskTop, u.dark);
        float3 bottom = mix(dayBottom, duskBottom, u.dark);
        float3 sky = mix(top, bottom, smoothstep(0.0, 1.0, uv.y));

        // A second hue drifting in from the right keeps the sky from looking flat.
        float3 accent = mix(hsv(u.hue - 0.08, 0.22, 1.0), hsv(u.hue - 0.06, 0.55, 0.28), u.dark);
        float drift = 0.5 + 0.5 * sin(t * 0.05);
        sky = mix(sky, accent, smoothstep(0.35, 1.25, uv.x + (1.0 - uv.y) * 0.3) * (0.35 + 0.15 * drift));

        float2 source = float2(0.42 * aspect, -0.32);
        float2 p = float2(uv.x * aspect, uv.y);
        float2 d = p - source;
        float dist = length(d);
        float angle = atan2(d.y, d.x);

        float3 sunlight = mix(float3(1.0, 0.985, 0.94), hsv(u.hue + 0.12, 0.35, 1.0), u.dark);
        float fall = exp(-dist * mix(0.9, 1.5, u.dark));
        float light = shafts(angle, t) * fall * smoothstep(0.0, 0.25, dist);
        float glow = exp(-dist * 2.6) * 0.55 + exp(-dist * 7.0) * 0.35;
        float strength = u.rays * mix(0.55, 0.30, u.dark);

        float3 color = sky;
        color += sunlight * light * strength;
        color += sunlight * glow * mix(0.45, 0.35, u.dark) * (0.6 + 0.4 * u.rays);

        // Soft vignette at the bottom corners keeps the edges grounded.
        float vignette = smoothstep(1.5, 0.4, length((uv - float2(0.5, 0.35)) * float2(1.0, 1.3)));
        color *= mix(0.94, 1.0, vignette);

        // Dither so the long gradients don't band.
        color += (hash(uv * u.size + fract(t)) - 0.5) / 255.0;
        return float4(clamp(color, 0.0, 1.0), 1.0);
    }
    """
}
