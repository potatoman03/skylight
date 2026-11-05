import AppKit
import Metal
import QuartzCore
import SkylightBrowser
import SkylightCore
import SwiftUI

/// The window's ground: the theme's sky, with light falling through it.
///
/// The default theme is a pale morning sky in light mode and twilight in dark mode, in the active
/// Space's color. The rays drift slowly at 30 fps and stop when the window is in the background,
/// when Reduce Motion is on, or when they're turned off.
///
/// A theme with a picture shows that instead, with the same light falling across it. A theme can
/// also lay a field of drifting characters over either.
struct SkyBackdrop: View {
    let palette: ThemePalette
    var rays = true
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let image = palette.image
        let url = image.flatMap { browser.preferences.url(for: $0) }
        ZStack {
            // Drawn underneath in case Metal isn't available, or until the picture is up.
            LinearGradient(colors: [Color(palette.sky), Color(palette.horizon)], startPoint: .top, endPoint: .bottom)
                .motion(Motion.hue, value: palette)
            if let image, let url {
                ThemeImageView(url: url, image: image)
                    .id(url)
                    .transition(.opacity)
                if palette.ascii != nil || palette.rays > 0 && rays && !Motion.reduceMotion {
                    SkyMetalView(palette: palette, dark: scheme == .dark, rays: rays, overlay: true)
                }
            } else {
                SkyMetalView(palette: palette, dark: scheme == .dark, rays: rays, overlay: false)
            }
        }
        .motion(Motion.hue, value: url)
        .ignoresSafeArea()
    }
}

/// The active Space's theme, behind the whole window.
struct ThemeBackdrop: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let space = browser.store.state.activeSpace
        let palette = browser.preferences.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue)
        SkyBackdrop(palette: palette, rays: browser.preferences.godRays)
    }
}

extension EnvironmentValues {
    /// Where the window's backdrop is, so anything repeating it can line up with it.
    @Entry var backdropFrame: CGRect = .zero
    /// What reads on the window's tint: white on a deep accent, black on a pale one.
    @Entry var onTint: Color = .white
}

extension ThemePalette {
    /// Has something worth seeing on an empty page.
    var fillsNewTab: Bool { image != nil || ascii != nil }
}

/// What's behind a page with nothing on it: the theme's picture or characters, lined up with the rest of the
/// window so the page seems to open onto it, or else `fallback`.
struct PageGround<Fallback: View>: View {
    @ViewBuilder let fallback: () -> Fallback
    @Environment(Browser.self) private var browser
    @Environment(\.backdropFrame) private var backdrop
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let prefs = browser.preferences
        let space = browser.store.state.activeSpace
        if prefs.skyBackdrop, prefs.sceneOnNewTab, backdrop != .zero,
           prefs.theme(for: space).palette(dark: scheme == .dark, spaceHue: space.hue).fillsNewTab {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                ThemeBackdrop()
                    .frame(width: backdrop.width, height: backdrop.height)
                    .offset(x: backdrop.minX - frame.minX, y: backdrop.minY - frame.minY)
            }
            .clipped()
        } else {
            fallback()
        }
    }
}

/// A theme's picture, cropped to fill, with its adjustments. `scale` shrinks the blur for
/// previews, where the picture is drawn small.
struct ThemeImageView: View {
    let url: URL
    let image: ThemeImage
    var scale: CGFloat = 1
    var thumbnail = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            ImageLayer(url: url, image: image, scale: scale, thumbnail: thumbnail)
            if image.fade > 0 {
                (scheme == .dark ? Color.black : Color.white).opacity(image.fade)
            }
        }
    }
}

private struct ImageLayer: NSViewRepresentable {
    let url: URL
    let image: ThemeImage
    let scale: CGFloat
    let thumbnail: Bool

    func makeNSView(context: Context) -> BackdropImageView { BackdropImageView() }

    func updateNSView(_ view: BackdropImageView, context: Context) {
        view.show(url, thumbnail: thumbnail, focus: CGPoint(x: image.focusX, y: image.focusY), zoom: image.zoom, blur: image.blur * scale)
    }
}

/// Small copies of themes' pictures, for the gallery.
@MainActor
private enum Thumbnails {
    private static var images: [URL: NSImage] = [:]

    static func image(_ url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let image else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        images[url] = result
        return result
    }
}

/// An image cropped to fill the view. `NSImageView` because it plays GIFs, which stop when the
/// window can't be seen and when Reduce Motion is on.
final class BackdropImageView: NSView {
    private let imageView = NSImageView()
    private var url: URL?
    private var focus = CGPoint(x: 0.5, y: 0.5)
    private var zoom: CGFloat = 1
    private var blur: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layerUsesCoreImageFilters = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    func show(_ url: URL, thumbnail: Bool, focus: CGPoint, zoom: CGFloat, blur: CGFloat) {
        self.focus = focus
        self.zoom = zoom
        if url != self.url {
            self.url = url
            if thumbnail {
                Task { [weak self] in
                    let image = await Thumbnails.image(url)
                    guard let self, self.url == url else { return }
                    self.imageView.image = image
                    self.needsLayout = true
                }
            } else {
                imageView.image = NSImage(contentsOf: url)
            }
        }
        if blur != self.blur {
            self.blur = blur
            imageView.layer?.filters = blur > 0 ? [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": blur])].compactMap { $0 } : nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        // Past the edges by the blur's reach, which would otherwise fade them out.
        let area = bounds.insetBy(dx: -blur * 2, dy: -blur * 2)
        let fill = max(area.width / size.width, area.height / size.height) * max(zoom, 1)
        let width = size.width * fill, height = size.height * fill
        imageView.frame = CGRect(x: area.minX + (area.width - width) * focus.x, y: area.minY + (area.height - height) * focus.y,
                                 width: width, height: height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        updateAnimates()
        guard let window else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAnimates() }
        })
    }

    private func updateAnimates() {
        imageView.animates = !Motion.reduceMotion && window?.occlusionState.contains(.visible) == true
    }
}

private struct SkyMetalView: NSViewRepresentable {
    let palette: ThemePalette
    let dark: Bool
    let rays: Bool
    let overlay: Bool

    func makeNSView(context: Context) -> SkyView { SkyView() }

    func updateNSView(_ view: SkyView, context: Context) {
        view.update(palette: palette, dark: dark, rays: rays, overlay: overlay)
    }
}

final class SkyView: NSView {
    private struct Uniforms {
        var top: SIMD4<Float>
        var bottom: SIMD4<Float>
        var glow: SIMD4<Float>
        var sunlight: SIMD4<Float>
        var ink: SIMD4<Float>
        var size: SIMD2<Float>
        var cell: SIMD2<Float>
        var time: Float
        var dark: Float
        var rays: Float
        var strength: Float
        var overlay: Float
        var pattern: Float
    }

    /// The sky's colors, as the shader takes them.
    private struct Colors: Equatable {
        var top, bottom, glow, sunlight, ink: SIMD4<Float>
        var strength: Float

        init(_ p: ThemePalette) {
            func v(_ c: RGB) -> SIMD4<Float> { SIMD4(Float(c.r), Float(c.g), Float(c.b), 1) }
            top = v(p.sky)
            bottom = v(p.horizon)
            glow = v(p.glow)
            sunlight = v(p.sunlight)
            ink = p.ascii.map { SIMD4(Float($0.color.r), Float($0.color.g), Float($0.color.b), Float($0.opacity)) } ?? .zero
            strength = Float(p.rays) * 0.5
        }

        func approached(_ target: Colors, _ k: Float) -> Colors {
            var c = self
            c.top += (target.top - top) * k
            c.bottom += (target.bottom - bottom) * k
            c.glow += (target.glow - glow) * k
            c.sunlight += (target.sunlight - sunlight) * k
            c.ink += (target.ink - ink) * k
            c.strength += (target.strength - strength) * k
            return c
        }

        func distance(to other: Colors) -> Float {
            let pairs: [(SIMD4<Float>, SIMD4<Float>)] = [(top, other.top), (bottom, other.bottom), (glow, other.glow), (ink, other.ink)]
            let colorDistance = pairs.map { pair -> Float in let d = pair.0 - pair.1; return max(abs(d.x), abs(d.y), abs(d.z)) }.max() ?? 0
            return colorDistance + abs(strength - other.strength)
        }
    }

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private lazy var pipeline: MTLRenderPipelineState? = makePipeline()
    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var observers: [NSObjectProtocol] = []

    // Colors and ray strength ease toward their targets frame by frame, so a Space or theme
    // switch glides through the sky instead of jumping.
    private var colors = Colors(SkyTheme.standard.light)
    private var targetColors = Colors(SkyTheme.standard.light)
    private var dark: Float = 0
    private var targetDark: Float = 0
    private var rays: Float = 1
    private var targetRays: Float = 1
    private var overlay: Float = 0
    private var pattern: AsciiPattern?
    private var atlas: MTLTexture?
    /// One character cell, in points.
    private static let cell = SIMD2<Float>(9, 16)
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

    /// `overlay` draws only the light, with the rest clear, to fall across a picture underneath.
    func update(palette: ThemePalette, dark: Bool, rays: Bool, overlay: Bool) {
        self.overlay = overlay ? 1 : 0
        if palette.ascii?.pattern != pattern {
            pattern = palette.ascii?.pattern
            updateResolution()
        }
        targetColors = Colors(palette)
        targetDark = dark ? 1 : 0
        targetRays = rays && !Motion.reduceMotion ? 1 : 0
        if !configured {
            configured = true
            colors = targetColors
            self.dark = targetDark
            self.rays = targetRays
        }
        updateRunning()
        if link == nil { settle() }
        draw()
    }

    /// Without animation, jump straight to where the sky is headed.
    private func settle() {
        colors = targetColors
        dark = targetDark
        rays = targetRays
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        updateResolution()
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
        updateResolution()
        draw()
    }

    /// The sky is soft enough for one pixel a point; characters need the screen's own resolution.
    private func updateResolution() {
        guard let metalLayer else { return }
        let scale = pattern == nil ? 1 : window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    }

    /// Animate only while there's something to see.
    private func updateRunning() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        let settling = colors.distance(to: targetColors) > 0.002 || abs(dark - targetDark) > 0.01 || abs(rays - targetRays) > 0.01
        let drifting = pattern != nil && !Motion.reduceMotion
        let animating = visible && ((targetRays > 0 || drifting) && NSApp.isActive || settling)
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
        colors = colors.approached(targetColors, 0.16)
        dark += (targetDark - dark) * 0.18
        rays += (targetRays - rays) * 0.08
        draw()
        if targetRays == 0 || !NSApp.isActive { updateRunning() }
    }

    private func draw() {
        guard let metalLayer, let queue, let pipeline, bounds.width > 1, bounds.height > 1,
              let drawable = metalLayer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = Float(metalLayer.contentsScale)
        var uniforms = Uniforms(top: colors.top, bottom: colors.bottom, glow: colors.glow, sunlight: colors.sunlight, ink: colors.ink,
                                size: SIMD2(Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height)),
                                cell: Self.cell * scale, time: Float(CACurrentMediaTime() - start), dark: dark, rays: rays, strength: colors.strength, overlay: overlay,
                                pattern: Float(pattern.flatMap { AsciiPattern.allCases.firstIndex(of: $0) } ?? 0))
        if pattern != nil, atlas == nil { atlas = makeAtlas() }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Every pattern's characters in a grid, a row each, for the shader to stamp into cells.
    private func makeAtlas() -> MTLTexture? {
        let tile = (width: 32, height: 56), columns = 8, rows = AsciiPattern.allCases.count
        let width = tile.width * columns, height = tile.height * rows
        guard let device, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 36, weight: .regular), .foregroundColor: NSColor.white]
        for (row, pattern) in AsciiPattern.allCases.enumerated() {
            for (column, glyph) in pattern.glyphs.enumerated() {
                let text = NSAttributedString(string: String(glyph), attributes: attributes)
                let size = text.size()
                text.draw(at: CGPoint(x: CGFloat(column * tile.width) + (CGFloat(tile.width) - size.width) / 2,
                                      y: CGFloat(height - (row + 1) * tile.height) + (CGFloat(tile.height) - size.height) / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor), let bytes = context.data else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: context.bytesPerRow)
        return texture
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

    struct Uniforms { float4 top; float4 bottom; float4 glow; float4 sunlight; float4 ink; float2 size; float2 cell; float time; float dark; float rays; float strength; float overlay; float pattern; };
    struct Out { float4 position [[position]]; float2 uv; };

    vertex Out skyVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        Out o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
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

    static float blotch(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash(i), b = hash(i + float2(1, 0)), c = hash(i + float2(0, 1)), d = hash(i + float2(1, 1));
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    static float clouds(float2 p) {
        // Each layer turned against the last, so the grid the noise is built on doesn't show.
        float2x2 turn = float2x2(0.8, 0.6, -0.6, 0.8);
        float a = blotch(p);
        p = turn * p * 2.1 + 3.1;
        float b = blotch(p);
        p = turn * p * 2.1 + 7.7;
        return a * 0.5 + b * 0.3 + blotch(p) * 0.2;
    }

    /// How strong a character cell is, and which of the pattern's characters it shows (both 0...1).
    /// `c` is the cell, `grid` how many there are.
    static float2 field(int pattern, float2 c, float2 grid, float t) {
        float2 p = c / grid;
        float h = hash(c);
        if (pattern == 0) { // Stars: a few that twinkle, in faint drifts of dust.
            if (h > 0.975) return float2(0.35 + 0.65 * (0.5 + 0.5 * sin(t * (0.4 + h * 3.0) + h * 90.0)), fract(h * 37.0));
            float dust = smoothstep(0.52, 0.72, clouds(p * float2(3.0, 2.0) + t * 0.01));
            return float2(dust * 0.28 * step(0.8, hash(c + 3.0)), 0.1);
        }
        if (pattern == 1) { // Mist: slow banks of cloud.
            float2 q = float2(p.x * 2.6 + t * 0.025, p.y * 4.0 - t * 0.01);
            q += 0.7 * float2(blotch(q + t * 0.02), blotch(q * 1.3 - t * 0.015));
            float n = smoothstep(0.42, 0.78, clouds(q)) * (0.55 + 0.45 * h);
            return float2(n * 0.7, n);
        }
        if (pattern == 2) { // Hearts: sparkles rising, each column at its own moment.
            float2 risen = float2(c.x, c.y + floor(t * 1.2 + hash(float2(c.x, 1.0)) * 50.0));
            float r = hash(risen);
            if (r > 0.972) return float2(0.45 + 0.55 * (0.5 + 0.5 * sin(t * 1.5 + r * 60.0)), 0.4 + fract(r * 53.0) * 0.6);
            return float2(step(0.965, hash(risen + 5.0)) * 0.18, 0.1);
        }
        if (pattern == 3) { // Meadow: grass along the foot, swaying, with pollen above.
            float height = 1.0 - p.y;
            float top = 0.14 + 0.2 * clouds(float2(p.x * 5.0, 2.0)) + sin(t * 0.8 + p.x * 9.0 + height * 6.0) * 0.012;
            float depth = top - height;
            if (depth > 0.0) return float2(clamp(0.3 + depth * 4.0, 0.0, 1.0) * (0.6 + 0.4 * h), hash(float2(c.x, floor(c.y / 2.0))));
            return float2(step(0.992, hash(c + floor(t * 0.5))) * 0.35, 0.1);
        }
        if (pattern == 5) { // Petals: drifting down and across.
            float2 fallen = float2(c.x + floor(t * 0.5), c.y - floor(t * 1.0 + hash(float2(c.x, 3.0)) * 50.0));
            float r = hash(fallen);
            if (r > 0.974) return float2(0.5 + 0.5 * (0.5 + 0.5 * sin(t + r * 40.0)), 0.5 + fract(r * 41.0) * 0.5);
            return float2(step(0.97, hash(fallen + 2.0)) * 0.2, 0.2);
        }
        if (pattern == 6) { // Waves: swells rolling across the lower part of the window.
            float s = sin(p.x * 14.0 + t * 0.6 + p.y * 9.0) + sin(p.x * 5.0 - t * 0.4 + p.y * 22.0);
            float n = smoothstep(0.3, 1.5, s) * smoothstep(0.2, 0.75, p.y) * (0.6 + 0.4 * h);
            return float2(n, n);
        }
        if (pattern == 7) { // Snow: falling straight down, near flakes faster than far ones.
            float depth = hash(float2(c.x, 6.0));
            float2 fallen = float2(c.x, c.y - floor(t * (0.7 + depth * 2.2) + depth * 70.0));
            float r = hash(fallen);
            return float2(step(0.968, r) * (0.4 + 0.6 * depth), 0.3 + depth * 0.7);
        }
        if (pattern == 8) { // Embers: sparks rising from the foot, dying out as they climb.
            float2 risen = float2(c.x, c.y + floor(t * (1.8 + hash(float2(c.x, 7.0)) * 2.5) + hash(float2(c.x, 8.0)) * 60.0));
            float r = hash(risen);
            float fire = smoothstep(0.1, 1.0, p.y);
            float flicker = 0.7 + 0.3 * sin(t * 6.0 + r * 80.0);
            return float2(step(0.985 - fire * 0.07, r) * (0.25 + 0.75 * fire) * flicker, fire * 0.8 + r * 0.2);
        }
        if (pattern == 9) { // Retro grid: a floor racing toward you, under a banded sun.
            float aspect = (grid.x * 9.0) / (grid.y * 16.0);
            float horizon = 0.58;
            if (p.y > horizon) {
                float z = 1.0 / (p.y - horizon + 0.03);
                float across = fract((p.x - 0.5) * z * 2.2);
                float along = fract(z * 0.9 + t * 0.35);
                float fade = smoothstep(0.0, 0.12, p.y - horizon);
                if (across < 0.1) return float2(0.75 * fade, 0.8);
                if (along < 0.12) return float2(0.6 * fade, 0.45);
                return float2(0.0, 0.0);
            }
            float2 d = float2((p.x - 0.5) * aspect, p.y - 0.38);
            if (length(d) < 0.2 && fract(p.y * 34.0) > p.y * 0.8) return float2(0.8, 0.95);
            return float2(step(0.985, h) * 0.4, 0.1);
        }
        if (pattern == 10) { // Halftone: every other cell, swelling and fading in slow waves.
            float n = clouds(p * float2(3.0, 2.0) + float2(t * 0.02, -t * 0.012));
            float on = step(fmod(c.x, 2.0), 0.5) * step(fmod(c.y, 2.0), 0.5);
            float s = smoothstep(0.34, 0.72, n);
            return float2(on * (0.15 + 0.65 * s), s);
        }
        if (pattern == 11) { // Dust: a few fine specks, barely drifting.
            float2 drifted = float2(c.x + floor(t * 0.1 + hash(float2(c.y, 11.0)) * 40.0), c.y);
            float r = hash(drifted);
            return float2(step(0.95, r) * (0.3 + 0.7 * fract(r * 61.0)), fract(r * 29.0));
        }
        if (pattern == 12) { // Weave: a fine cloth, its grain showing in broad, slow patches.
            float n = smoothstep(0.34, 0.74, clouds(p * float2(2.0, 1.4) + float2(t * 0.008, t * 0.005)));
            float on = step(0.5, fmod(c.x + c.y, 2.0));
            return float2(on * (0.1 + 0.55 * n) * step(fmod(c.y, 2.0), 0.5), n * 0.5 + 0.5 * h);
        }
        if (pattern == 13) { // Contour lines: the rings of a map, shifting very slowly.
            float height = clouds(p * float2(1.6, 1.2) + float2(t * 0.005, -t * 0.003)) * 9.0;
            float n = 1.0 - smoothstep(0.03, 0.1, abs(fract(height) - 0.5));
            return float2(n * (0.6 + 0.4 * h), h);
        }
        // Code rain: columns falling at their own speed, changing as they go.
        float speed = 0.05 + hash(float2(c.x, 2.0)) * 0.13;
        float head = fract(t * speed + hash(float2(c.x, 9.0)));
        float tail = pow(1.0 - fract(head - p.y), 8.0);
        return float2(tail * step(0.35, hash(float2(c.x, 4.0))), hash(c + floor(t * 5.0)));
    }

    /// How much of the character in this pixel's cell covers it.
    static float characters(float2 uv, constant Uniforms& u, texture2d<float> atlas, float t) {
        if (u.ink.a < 0.002) return 0.0;
        constexpr sampler s(filter::linear);
        float2 grid = floor(u.size / u.cell);
        float2 position = uv * u.size / u.cell;
        float2 cell = floor(position);
        float2 f = field(int(u.pattern), cell, grid, t);
        if (f.x < 0.01) return 0.0;
        float2 tile = float2(floor(clamp(f.y, 0.0, 0.999) * 8.0), u.pattern) + fract(position);
        // Quieter in the middle, where the search field sits on a new tab.
        float calm = mix(0.2, 1.0, smoothstep(0.18, 0.5, length((uv - float2(0.58, 0.32)) * float2(1.0, 1.4))));
        return atlas.sample(s, tile / float2(8.0, \(AsciiPattern.allCases.count).0)).r * f.x * u.ink.a * calm;
    }

    fragment float4 skyFragment(Out in [[stage_in]], constant Uniforms& u [[buffer(0)]], texture2d<float> atlas [[texture(0)]]) {
        float2 uv = in.uv;
        float aspect = u.size.x / max(u.size.y, 1.0);
        float t = u.time;

        float3 sky = mix(u.top.rgb, u.bottom.rgb, smoothstep(0.0, 1.0, uv.y));

        // A second color drifting in from the right keeps the sky from looking flat.
        float drift = 0.5 + 0.5 * sin(t * 0.05);
        sky = mix(sky, u.glow.rgb, smoothstep(0.35, 1.25, uv.x + (1.0 - uv.y) * 0.3) * (0.35 + 0.15 * drift));

        float2 source = float2(0.42 * aspect, -0.32);
        float2 p = float2(uv.x * aspect, uv.y);
        float2 d = p - source;
        float dist = length(d);
        float angle = atan2(d.y, d.x);

        float3 sunlight = u.sunlight.rgb;
        float fall = exp(-dist * mix(0.9, 1.5, u.dark));
        float light = shafts(angle, t) * fall * smoothstep(0.0, 0.25, dist);
        float glow = exp(-dist * 2.6) * 0.55 + exp(-dist * 7.0) * 0.35;
        float strength = u.rays * u.strength;

        float ink = characters(uv, u, atlas, t);

        if (u.overlay > 0.5) {
            float3 added = clamp(sunlight * (light * strength + glow * 0.3 * u.rays * u.strength), 0.0, 1.0);
            return float4(mix(added, u.ink.rgb, ink), max(max(added.r, max(added.g, added.b)), ink));
        }

        float3 color = sky;
        color += sunlight * light * strength;
        color += sunlight * glow * mix(0.45, 0.35, u.dark) * (0.6 + 0.4 * u.rays) * smoothstep(0.0, 0.1, u.strength);

        // Soft vignette at the bottom corners keeps the edges grounded.
        float vignette = smoothstep(1.5, 0.4, length((uv - float2(0.5, 0.35)) * float2(1.0, 1.3)));
        color *= mix(0.94, 1.0, vignette);
        color = mix(color, u.ink.rgb, ink);

        // Dither so the long gradients don't band.
        color += (hash(uv * u.size + fract(t)) - 0.5) / 255.0;
        return float4(clamp(color, 0.0, 1.0), 1.0);
    }
    """
}
