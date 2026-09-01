import Darwin
import ImageIO
import SwiftUI

/// A digital life rendered as a hybrid: an AI-generated luminous creature artwork for the
/// body (a round translucent sprite with glowing eyes, a leafy antenna, and ribbon tails),
/// brought to life by procedural layers — breathing scale, a gentle vertical float with a
/// hint of sway, ambient aura, a depth-layered memory particle field, quiet orbit rings, a
/// soft awareness glow, and per-state structural marks. If the artwork cannot be loaded,
/// every procedural layer remains and the body falls back to a fully vector-drawn fluid orb.
struct DigitalLifeView: View {
    var state: DigitalLifeState
    var size: CGFloat = 128
    var interactionRevision: Int = 0
    var onAction: ((DigitalLifeAction) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var pointerLocation: CGPoint?
    @State private var touchPulse = 0
    @State private var currentArtworkKey: String?
    @State private var previousArtworkKey: String?
    @State private var artworkTransitionStart: TimeInterval?
    @State private var isInteractionBoosted = false
    @State private var interactionBoostTask: Task<Void, Never>?

    var body: some View {
        // `.animation` is synchronized to the display link. Even with a large
        // `minimumInterval`, SwiftUI may keep the render graph attached to the
        // screen refresh cycle. A periodic schedule creates real idle gaps
        // between frames, which is essential for an always-on desktop life.
        TimelineView(
            .periodic(
                from: .now,
                by: reduceMotion ? 3_600 : animationMinimumInterval
            )
        ) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, colorMode: .extendedLinear, rendersAsynchronously: true) { context, canvasSize in
                draw(
                    in: &context,
                    size: canvasSize,
                    time: time,
                    configuration: configuration,
                    pointer: pointerLocation,
                    reduceMotion: reduceMotion
                )
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle().inset(by: -size * 0.08))
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                pointerLocation = location
                isHovered = true
            case .ended:
                pointerLocation = nil
                isHovered = false
            }
        }
        .onTapGesture {
            touchPulse &+= 1
            brieflyBoostAnimation()
            onAction?(.touched)
        }
        .onAppear {
            currentArtworkKey = Self.artworkKey(for: state)
        }
        .onChange(of: state) { _, newState in
            let newKey = Self.artworkKey(for: newState)
            let oldKey = currentArtworkKey ?? newKey
            guard newKey != oldKey else {
                currentArtworkKey = newKey
                return
            }
            previousArtworkKey = oldKey
            currentArtworkKey = newKey
            artworkTransitionStart = Date.timeIntervalSinceReferenceDate
        }
        .onDisappear {
            interactionBoostTask?.cancel()
            interactionBoostTask = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AgentOne 数字生命")
        .accessibilityValue(state.accessibilityDescription)
        .accessibilityAddTraits(onAction == nil ? [] : .isButton)
    }

    /// The companion is deliberately not a continuously animated wallpaper. A calm life state
    /// only needs a few frames per second to retain its breathing presence, while states where the
    /// user is actively looking at or touching it can briefly render more often. Keeping this
    /// schedule below 15 FPS prevents the always-on floating window from competing with typing,
    /// scrolling, video playback, or local model work.
    private var animationMinimumInterval: TimeInterval {
        if isHovered || isInteractionBoosted {
            return 1 / 8
        }

        switch state {
        case .curious, .thinking:
            return 1 / 2
        case .celebrating, .distraction:
            return 1 / 4
        case .focused, .concealingSurprise:
            return 1
        case .resting, .energySaver:
            return 2
        }
    }

    private func brieflyBoostAnimation() {
        interactionBoostTask?.cancel()
        isInteractionBoosted = true
        interactionBoostTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            isInteractionBoosted = false
            interactionBoostTask = nil
        }
    }

    private var configuration: VisualConfiguration {
        var value = VisualConfiguration.make(for: state)
        if isHovered {
            value.coreScale *= 1.05
            value.particleBrightness += 0.12
        }
        let revision = interactionRevision &+ touchPulse
        value.touchPhase = Double(revision % 12) * 0.37
        return value
    }

    /// Which generated artwork renders the body for a given state. States without a dedicated
    /// piece reuse the base creature and differentiate through the procedural layers instead.
    private static func artworkKey(for state: DigitalLifeState) -> String {
        switch state {
        case .curious: "life_curious"
        case .thinking: "life_thinking"
        case .distraction: "life_distraction"
        case .celebrating: "life_celebrating"
        case .resting: "life_resting"
        case .focused, .energySaver, .concealingSurprise: "life_base"
        }
    }

    /// How much ornament the current canvas size can carry before it turns to mush.
    private enum RenderDetail {
        case minimal // < 64pt: aura, artwork, state marks only — particles would just blur
        case reduced // 64–95pt: one orbit, fewer particles
        case full

        static func make(for side: CGFloat) -> Self {
            if side < 64 { return .minimal }
            // The always-on 126pt companion does not benefit visually from the
            // full particle/orbit budget, but the extra layers materially raise
            // its persistent GPU and WindowServer cost. Reserve full detail for
            // large showcase/onboarding renders.
            if side < 168 { return .reduced }
            return .full
        }

        var particleCap: Int {
            switch self {
            case .minimal: 0
            case .reduced: 12
            case .full: .max
            }
        }

        var orbitCount: Int {
            switch self {
            case .minimal: 0
            case .reduced: 1
            case .full: 2
            }
        }
    }

    private enum ParticlePass {
        case background // far, dim layer drawn behind the body
        case foreground // mid and near layers drawn over the body
    }

    private func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        configuration config: VisualConfiguration,
        pointer: CGPoint?,
        reduceMotion: Bool
    ) {
        let shortestSide = min(size.width, size.height)
        let detail = RenderDetail.make(for: shortestSide)
        let baseRadius = shortestSide * 0.215
        let breath = 1 + sin(time * config.breathSpeed + config.touchPhase) * config.breathAmount
        // A slow vertical bob (~0.35Hz) that makes the creature feel afloat.
        let floatY = sin(time * .pi * 2 * 0.35 + config.touchPhase) * shortestSide * 0.018
        let reminderJitter = state.normalizedDistractionLevel
        let jitter = CGPoint(
            x: sin(time * 15.7) * shortestSide * 0.009 * reminderJitter,
            y: cos(time * 18.1) * shortestSide * 0.006 * reminderJitter
        )
        let defaultCenter = CGPoint(
            x: size.width * (0.5 + config.centerOffset.width),
            y: size.height * (0.5 + config.centerOffset.height)
        )
        let center = attractedCenter(
            defaultCenter: defaultCenter,
            pointer: pointer,
            size: size,
            attraction: config.pointerAttraction,
            jitter: jitter
        )

        let artworkKey = currentArtworkKey ?? Self.artworkKey(for: state)
        let artwork = LifeFormArtwork.image(named: artworkKey)

        // A wide, soft glow keeps the life readable over arbitrary desktop wallpapers.
        let glowRadius = shortestSide * 0.62
        let glowRect = CGRect(
            x: center.x - glowRadius,
            y: center.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(
                Path(ellipseIn: glowRect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: config.primary.opacity(config.auraOpacity * 0.5), location: 0),
                        .init(color: config.primary.opacity(config.auraOpacity * 0.2), location: 0.55),
                        .init(color: .clear, location: 1)
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: glowRadius
                )
            )
        }

        if let artwork {
            // A shaped aura hugs the body and gives the creature its presence.
            let auraRadius = baseRadius * breath * config.coreScale * 1.2
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: shortestSide * 0.16))
                layer.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - auraRadius,
                        y: center.y + floatY - auraRadius,
                        width: auraRadius * 2,
                        height: auraRadius * 2
                    )),
                    with: .color(config.primary.opacity(config.auraOpacity))
                )
            }

            if detail.orbitCount > 0 {
                drawOrbits(in: &context, center: center, radius: baseRadius, time: time, config: config, detail: detail)
            }
            drawMemoryParticles(
                in: &context, center: center, radius: baseRadius, time: time,
                config: config, detail: detail, pass: .background
            )

            drawArtwork(
                in: &context,
                artwork: artwork,
                center: center,
                diameter: shortestSide * 0.92,
                scale: breath * config.coreScale,
                floatY: floatY,
                time: time,
                config: config,
                reduceMotion: reduceMotion
            )

            drawMemoryParticles(
                in: &context, center: center, radius: baseRadius, time: time,
                config: config, detail: detail, pass: .foreground
            )
            drawAwarenessCore(in: &context, center: center, radius: baseRadius, time: time, config: config)
            drawStateSpecificDetails(in: &context, center: center, radius: baseRadius, time: time, config: config)
            return
        }

        // Fallback: no bundled artwork available — draw the fully procedural fluid orb.
        let blob = blobPath(
            center: center,
            radius: baseRadius * breath * config.coreScale,
            time: time,
            distortion: config.distortion,
            stretch: config.stretch
        )

        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: shortestSide * 0.16))
            layer.fill(blob, with: .color(config.primary.opacity(config.auraOpacity)))
        }

        if detail.orbitCount > 0 {
            drawOrbits(in: &context, center: center, radius: baseRadius, time: time, config: config, detail: detail)
        }
        drawMemoryParticles(
            in: &context, center: center, radius: baseRadius, time: time,
            config: config, detail: detail, pass: .background
        )

        // Volumetric body: bright inner core, soft mid tone, deep rim, lit from the upper left.
        let bodyFill = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(config.coreBrightness), location: 0),
                .init(color: config.secondary.opacity(0.95), location: 0.22),
                .init(color: config.primary.opacity(0.82), location: 0.56),
                .init(color: config.deep.opacity(0.9), location: 0.86),
                .init(color: config.deep.opacity(0.16), location: 1)
            ]),
            center: CGPoint(x: center.x - baseRadius * 0.16, y: center.y - baseRadius * 0.22),
            startRadius: 0,
            endRadius: baseRadius * 1.35
        )
        context.fill(blob, with: bodyFill)

        if detail != .minimal {
            // Top highlight: a soft sheen that sells the sphere.
            let highlightRect = CGRect(
                x: center.x - baseRadius * 0.42,
                y: center.y - baseRadius * 0.8,
                width: baseRadius * 0.84,
                height: baseRadius * 0.48
            )
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: baseRadius * 0.16))
                layer.fill(
                    Path(ellipseIn: highlightRect),
                    with: .color(.white.opacity(0.24 * config.coreBrightness))
                )
            }

            // Rim light along the lower edge, as if the glow below bounces back up.
            let rim = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: config.secondary.opacity(0.5), location: 0.85),
                    .init(color: .white.opacity(0.45), location: 1)
                ]),
                startPoint: CGPoint(x: center.x, y: center.y - baseRadius),
                endPoint: CGPoint(x: center.x, y: center.y + baseRadius * 1.12)
            )
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.stroke(blob, with: rim, lineWidth: max(shortestSide * 0.009, 0.9))
            }
        }

        drawMemoryParticles(
            in: &context, center: center, radius: baseRadius, time: time,
            config: config, detail: detail, pass: .foreground
        )
        drawAwarenessCore(in: &context, center: center, radius: baseRadius, time: time, config: config)
        drawStateSpecificDetails(in: &context, center: center, radius: baseRadius, time: time, config: config)
    }

    /// Draws the generated creature artwork, breathing and bobbing vertically so it feels
    /// afloat, with a hint of pendulum sway. State changes cross-fade the previous piece into
    /// the new one over ~0.4s. The creature is never spun — that would tip it onto its side.
    private func drawArtwork(
        in context: inout GraphicsContext,
        artwork: CGImage,
        center: CGPoint,
        diameter: CGFloat,
        scale: CGFloat,
        floatY: CGFloat,
        time: TimeInterval,
        config: VisualConfiguration,
        reduceMotion: Bool
    ) {
        // A tiny ±1.5° sway over ~7s, like a floating body shifting its balance.
        let sway = sin(time * (.pi * 2 / 7)) * (.pi / 120)
        // The state's stretch doubles as body language (curious leans forward, resting settles).
        let scaleX = scale * config.stretch.width
        let scaleY = scale * config.stretch.height
        // coreBrightness doubles as the artwork's dimmer (energySaver fades the creature).
        let brightness = 0.35 + 0.65 * config.coreBrightness

        var progress = 1.0
        if !reduceMotion,
           let previousArtworkKey,
           previousArtworkKey != currentArtworkKey,
           let start = artworkTransitionStart {
            progress = min(1, max(0, (time - start) / 0.4))
        }

        if progress < 1,
           let previousArtworkKey,
           let previous = LifeFormArtwork.image(named: previousArtworkKey) {
            drawArtworkImage(
                in: &context,
                image: previous,
                center: center,
                diameter: diameter,
                scaleX: scaleX,
                scaleY: scaleY,
                sway: sway,
                floatY: floatY,
                opacity: brightness * (1 - progress)
            )
        }
        drawArtworkImage(
            in: &context,
            image: artwork,
            center: center,
            diameter: diameter,
            scaleX: scaleX,
            scaleY: scaleY,
            sway: sway,
            floatY: floatY,
            opacity: brightness * progress
        )
    }

    private func drawArtworkImage(
        in context: inout GraphicsContext,
        image: CGImage,
        center: CGPoint,
        diameter: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat,
        sway: Double,
        floatY: CGFloat,
        opacity: Double
    ) {
        guard opacity > 0.001 else { return }
        context.drawLayer { layer in
            // The artwork now carries real alpha, so plain source-over compositing is correct
            // on any backdrop; additive blending would only blow out the glow and haze it grey.
            layer.translateBy(x: center.x, y: center.y + floatY)
            layer.rotate(by: Angle.radians(sway))
            layer.scaleBy(x: scaleX, y: scaleY)
            layer.opacity = opacity
            layer.draw(
                Image(decorative: image, scale: 1),
                in: CGRect(
                    x: -diameter / 2,
                    y: -diameter / 2,
                    width: diameter,
                    height: diameter
                )
            )
        }
    }

    private func attractedCenter(
        defaultCenter: CGPoint,
        pointer: CGPoint?,
        size: CGSize,
        attraction: Double,
        jitter: CGPoint
    ) -> CGPoint {
        guard let pointer else {
            return CGPoint(x: defaultCenter.x + jitter.x, y: defaultCenter.y + jitter.y)
        }
        let dx = (pointer.x - defaultCenter.x) * attraction
        let dy = (pointer.y - defaultCenter.y) * attraction
        return CGPoint(
            x: defaultCenter.x + dx + jitter.x,
            y: defaultCenter.y + dy + jitter.y
        )
    }

    /// A fluid closed silhouette: a handful of control points modulated by two low-frequency
    /// harmonics, interpolated with a closed Catmull-Rom spline so the edge stays glassy smooth
    /// instead of looking like a jittering polygon. Used only by the no-artwork fallback.
    private func blobPath(
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        distortion: Double,
        stretch: CGSize
    ) -> Path {
        let controlCount = 10
        var points: [CGPoint] = []
        points.reserveCapacity(controlCount)
        for index in 0..<controlCount {
            let angle = Double(index) / Double(controlCount) * .pi * 2
            let wobble = 1
                + sin(angle * 2 + time * 0.42) * distortion * 0.62
                + sin(angle * 3 - time * 0.27 + 1.3) * distortion * 0.38
            let x = center.x + CGFloat(cos(angle) * radius * wobble) * stretch.width
            let y = center.y + CGFloat(sin(angle) * radius * wobble) * stretch.height
            points.append(CGPoint(x: x, y: y))
        }
        return closedCatmullRom(points: points)
    }

    private func closedCatmullRom(points: [CGPoint]) -> Path {
        var path = Path()
        let count = points.count
        guard count > 2 else { return path }
        path.move(to: points[0])
        for index in 0..<count {
            let p0 = points[(index - 1 + count) % count]
            let p1 = points[index]
            let p2 = points[(index + 1) % count]
            let p3 = points[(index + 2) % count]
            let control1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let control2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: control1, control2: control2)
        }
        path.closeSubpath()
        return path
    }

    /// Two quiet rings at most, sharing one unified tilt; only the outer ring is dashed.
    private func drawOrbits(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        config: VisualConfiguration,
        detail: RenderDetail
    ) {
        for index in 0..<detail.orbitCount {
            let growth = CGFloat(index) * radius * 0.5
            let rect = CGRect(
                x: center.x - radius * 1.3 - growth,
                y: center.y - radius * 0.58 - growth * 0.28,
                width: radius * 2.6 + growth * 2,
                height: radius * 1.16 + growth * 0.56
            )
            var ellipse = Path(ellipseIn: rect)
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
            transform = transform.rotated(by: config.orbitTilt + CGFloat(sin(time * 0.07)) * 0.05)
            transform = transform.translatedBy(x: -center.x, y: -center.y)
            ellipse = ellipse.applying(transform)
            let opacity = config.orbitOpacity * (1 - Double(index) * 0.35)
            context.stroke(
                ellipse,
                with: .color(config.secondary.opacity(opacity)),
                style: StrokeStyle(lineWidth: max(radius * 0.014, 0.5), dash: index == 1 ? [2, 6] : [])
            )
        }
    }

    /// Memory fragments arranged in three depth layers that share a single orbital plane.
    /// Far fragments are small and dim and sit behind the body; near fragments are larger,
    /// brighter, and drift over it. Flicker is low-frequency and phase-offset per particle so
    /// the field shimmers instead of blinking in unison.
    private func drawMemoryParticles(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        config: VisualConfiguration,
        detail: RenderDetail,
        pass: ParticlePass
    ) {
        let count = min(config.particleCount, detail.particleCap)
        guard count > 0 else { return }
        let depthScale = [0.55, 0.78, 1.0]
        let depthOpacity = [0.32, 0.52, 0.78]
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for index in 0..<count {
                let depth = index % 3
                guard (pass == .background) == (depth == 0) else { continue }
                let seed = Double(index) * 2.399963229728653 + 0.7
                let direction = index.isMultiple(of: 2) ? 1.0 : -0.72
                var angle = seed * 2.1 + time * config.orbitSpeed * direction / (0.75 + Double(depth) * 0.3)

                if config.particleGather > 0 {
                    let target = -.pi / 2 + sin(seed) * 0.4
                    angle = mixedAngle(angle, target, amount: config.particleGather)
                }

                let laneRadius = radius * (1.32 + Double(depth) * 0.42 + sin(seed * 2.3) * 0.07)
                let rawX = cos(angle) * laneRadius
                let rawY = sin(angle) * laneRadius * 0.52
                // One unified tilt for every depth layer.
                let rotation = Double(config.orbitTilt)
                let x = center.x + rawX * cos(rotation) - rawY * sin(rotation)
                let y = center.y + rawX * sin(rotation) + rawY * cos(rotation)

                // Desynchronized, low-frequency shimmer.
                let shimmerSpeed = 0.5 + seed.truncatingRemainder(dividingBy: 1.3)
                let flicker = 0.74 + sin(time * shimmerSpeed + seed * 3.1) * 0.26
                let opacity = min(1, flicker * depthOpacity[depth] + config.particleBrightness * 0.5)
                let particleRadius = radius * (0.026 + 0.022 * Double(depth) * depthScale[depth])
                    * (1 + config.particleBrightness * 0.2)
                let rect = CGRect(
                    x: x - particleRadius,
                    y: y - particleRadius,
                    width: particleRadius * 2,
                    height: particleRadius * 2
                )
                // Near fragments carry a faint halo so they read as closer to the viewer.
                if depth == 2 {
                    let haloRect = rect.insetBy(dx: -particleRadius * 1.4, dy: -particleRadius * 1.4)
                    layer.fill(
                        Path(ellipseIn: haloRect),
                        with: .color(config.particleColor.opacity(opacity * 0.22))
                    )
                }
                layer.fill(
                    Path(ellipseIn: rect),
                    with: .color(config.particleColor.opacity(max(0.08, opacity)))
                )
            }
        }
    }

    /// A soft, slow-breathing glow at the creature's center. The artwork already carries
    /// glowing eyes and a bright core, so this layer only lifts the middle — it must never
    /// resolve into a discernible dot that could read as a third eye.
    private func drawAwarenessCore(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        config: VisualConfiguration
    ) {
        let pulse = 1
            + sin(time * config.awarenessPulseSpeed) * 0.05
            + sin(time * config.awarenessPulseSpeed * 0.41 + 1.7) * 0.03
        let glowRadius = radius * 0.52 * pulse
        let glowRect = CGRect(
            x: center.x - glowRadius,
            y: center.y - glowRadius,
            width: glowRadius * 2,
            height: glowRadius * 2
        )
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.addFilter(.blur(radius: radius * 0.2))
            layer.fill(Path(ellipseIn: glowRect), with: .color(config.secondary.opacity(0.26)))
            layer.fill(
                Path(ellipseIn: glowRect.insetBy(dx: glowRadius * 0.35, dy: glowRadius * 0.35)),
                with: .color(.white.opacity(0.16 * config.coreBrightness))
            )
        }
    }

    private func drawStateSpecificDetails(
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        config: VisualConfiguration
    ) {
        switch state {
        case .curious:
            // A slender feeler reaching straight out from the creature's right side — kept
            // low and horizontal so it never crosses the leafy antenna on its head.
            let sway = sin(time * 1.1) * 0.06
            let probe = CGPoint(
                x: center.x + radius * (1.4 + sway),
                y: center.y + radius * 0.02
            )
            var tether = Path()
            tether.move(to: CGPoint(x: center.x + radius * 0.62, y: center.y + radius * 0.08))
            tether.addQuadCurve(
                to: probe,
                control: CGPoint(x: center.x + radius * 1.05, y: center.y - radius * 0.18)
            )
            context.stroke(
                tether,
                with: .color(config.secondary.opacity(0.38)),
                style: StrokeStyle(lineWidth: max(radius * 0.03, 0.8), lineCap: .round)
            )
            let tip = radius * 0.09
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: radius * 0.05))
                layer.fill(
                    Path(ellipseIn: CGRect(x: probe.x - tip, y: probe.y - tip, width: tip * 2, height: tip * 2)),
                    with: .color(.white.opacity(0.85))
                )
            }
            let dot = radius * 0.045
            context.fill(
                Path(ellipseIn: CGRect(x: probe.x - dot, y: probe.y - dot, width: dot * 2, height: dot * 2)),
                with: .color(.white.opacity(0.95))
            )

        case .celebrating:
            // Short-lived rays of light, each breathing on its own phase.
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                for index in 0..<10 {
                    let angle = Double(index) / 10 * .pi * 2 + time * 0.22
                    let cosine = CGFloat(Darwin.cos(angle))
                    let sine = CGFloat(Darwin.sin(angle))
                    let inner = radius * 1.32
                    let outer = radius * (1.62 + sin(time * 1.8 + Double(index) * 1.7) * 0.14)
                    var ray = Path()
                    ray.move(to: CGPoint(x: center.x + cosine * inner, y: center.y + sine * inner))
                    ray.addLine(to: CGPoint(x: center.x + cosine * outer, y: center.y + sine * outer))
                    let rayOpacity = 0.3 + 0.3 * abs(sin(time * 1.5 + Double(index) * 2.1))
                    layer.stroke(
                        ray,
                        with: .color(config.particleColor.opacity(rayOpacity)),
                        style: StrokeStyle(lineWidth: max(radius * 0.032, 0.8), lineCap: .round)
                    )
                }
            }

        case .concealingSurprise:
            // A warm spark tucked against the back of the silhouette.
            let orbit = time * 0.42
            let cosine = CGFloat(Darwin.cos(orbit))
            let sine = CGFloat(Darwin.sin(orbit))
            let secret = CGPoint(
                x: center.x - cosine * radius * 0.88,
                y: center.y - sine * radius * 0.34 + radius * 0.26
            )
            let sparkRadius = radius * (0.09 + sin(time * 1.8) * 0.015)
            let sparkRect = CGRect(
                x: secret.x - sparkRadius,
                y: secret.y - sparkRadius,
                width: sparkRadius * 2,
                height: sparkRadius * 2
            )
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.addFilter(.blur(radius: radius * 0.06))
                layer.fill(
                    Path(ellipseIn: sparkRect.insetBy(dx: -sparkRadius, dy: -sparkRadius)),
                    with: .color(Color(red: 1, green: 0.78, blue: 0.42).opacity(0.5))
                )
            }
            context.fill(
                Path(ellipseIn: sparkRect),
                with: .color(Color(red: 1, green: 0.82, blue: 0.5).opacity(0.85))
            )

        case let .distraction(level) where level >= 3:
            let safeLevel = min(max(level, 1), 4)
            let arcRadius = radius * (1.45 + CGFloat(safeLevel) * 0.08)
            let start = Angle.radians(-.pi * 0.16 + sin(time * 2.6) * 0.08)
            let end = Angle.radians(.pi * (0.86 + Double(safeLevel) * 0.06))
            var arc = Path()
            arc.addArc(center: center, radius: arcRadius, startAngle: start, endAngle: end, clockwise: false)
            context.stroke(
                arc,
                with: .color(config.particleColor.opacity(0.5)),
                style: StrokeStyle(lineWidth: max(radius * 0.05, 1.1), lineCap: .round)
            )

        default:
            break
        }
    }

    private func mixedAngle(_ source: Double, _ target: Double, amount: Double) -> Double {
        let difference = atan2(sin(target - source), cos(target - source))
        return source + difference * amount
    }
}

/// Lazily loads and permanently caches the generated life-form artwork from the module bundle.
/// Returns nil when the bundle or files are unavailable (e.g. bare harness environments),
/// which sends the renderer down its fully procedural fallback path.
private enum LifeFormArtwork {
    private static let cache: [String: CGImage] = load()

    static func image(named key: String) -> CGImage? {
        cache[key]
    }

    private static func load() -> [String: CGImage] {
        let keys = [
            "life_base",
            "life_curious",
            "life_thinking",
            "life_distraction",
            "life_celebrating",
            "life_resting"
        ]
        var result: [String: CGImage] = [:]
        for key in keys {
            // SwiftPM flattens processed resources into the bundle root, so look in the
            // LifeForm subdirectory first and fall back to the root.
            let url = Bundle.module.url(forResource: key, withExtension: "png", subdirectory: "LifeForm")
                ?? Bundle.module.url(forResource: key, withExtension: "png")
            guard let url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { continue }
            result[key] = image
        }
        return result
    }
}

private struct VisualConfiguration {
    var primary: Color
    var secondary: Color
    var deep: Color
    var particleColor: Color
    var auraOpacity: Double
    var coreBrightness: Double
    var coreScale: Double
    var breathSpeed: Double
    var breathAmount: Double
    var awarenessPulseSpeed: Double
    var distortion: Double
    var orbitSpeed: Double
    var orbitTilt: CGFloat
    var orbitOpacity: Double
    var particleCount: Int
    var particleBrightness: Double
    var particleGather: Double
    var pointerAttraction: Double
    var centerOffset: CGSize
    var stretch: CGSize
    var touchPhase: Double = 0

    static func make(for state: DigitalLifeState) -> Self {
        // Deep-jewel baseline: a violet-blue glow over a near-black indigo depth, with cool
        // starlight particles. Every state retunes from this shared color temperature.
        var value = Self(
            primary: Color(red: 0.46, green: 0.36, blue: 0.96),
            secondary: Color(red: 0.44, green: 0.64, blue: 1),
            deep: Color(red: 0.07, green: 0.06, blue: 0.2),
            particleColor: Color(red: 0.68, green: 0.86, blue: 1),
            auraOpacity: 0.3,
            coreBrightness: 0.9,
            coreScale: 1,
            breathSpeed: 1,
            breathAmount: 0.028,
            awarenessPulseSpeed: 1.15,
            distortion: 0.055,
            orbitSpeed: 0.36,
            orbitTilt: -0.2,
            orbitOpacity: 0.15,
            particleCount: 18,
            particleBrightness: 0,
            particleGather: 0,
            pointerAttraction: 0.045,
            centerOffset: .zero,
            stretch: CGSize(width: 1, height: 1)
        )

        switch state {
        case .focused:
            // Violet-blue, settled and dim, breathing slowly.
            value.auraOpacity = 0.24
            value.coreBrightness = 0.82
            value.breathSpeed = 0.62
            value.breathAmount = 0.018
            value.awarenessPulseSpeed = 0.8
            value.orbitSpeed = 0.15
            value.orbitOpacity = 0.11
            value.particleCount = 12
            value.pointerAttraction = 0.018

        case .curious:
            // Cyan-blue, leaning forward, stretched toward the point of interest.
            value.primary = Color(red: 0.32, green: 0.68, blue: 0.98)
            value.secondary = Color(red: 0.5, green: 0.92, blue: 0.98)
            value.particleColor = Color(red: 0.72, green: 0.95, blue: 1)
            value.distortion = 0.08
            value.orbitSpeed = 0.5
            value.particleBrightness = 0.08
            value.pointerAttraction = 0.13
            value.centerOffset = CGSize(width: 0.025, height: -0.025)
            value.stretch = CGSize(width: 1.14, height: 0.92)

        case .thinking:
            // Pink-violet, contracted, particles gathering into one region.
            value.primary = Color(red: 0.66, green: 0.46, blue: 0.96)
            value.secondary = Color(red: 0.88, green: 0.62, blue: 1)
            value.particleColor = Color(red: 0.93, green: 0.76, blue: 1)
            value.coreScale = 0.92
            value.breathSpeed = 1.5
            value.distortion = 0.04
            value.orbitSpeed = 0.65
            value.orbitOpacity = 0.22
            value.particleCount = 22
            value.particleGather = 0.72
            value.pointerAttraction = 0.02

        case let .distraction(level):
            // Green-cyan, brightening and quickening across levels 1–4. Never red.
            let amount = Double(min(max(level, 1), 4) - 1) / 3
            value.primary = Color(
                red: 0.36 - amount * 0.06,
                green: 0.82 - amount * 0.04,
                blue: 0.72 + amount * 0.23
            )
            value.secondary = Color(
                red: 0.46 - amount * 0.02,
                green: 0.92 - amount * 0.03,
                blue: 0.86 + amount * 0.14
            )
            value.particleColor = Color(
                red: 0.6 - amount * 0.04,
                green: 0.96 - amount * 0.04,
                blue: 0.9 + amount * 0.1
            )
            value.auraOpacity = 0.3 + amount * 0.14
            value.breathSpeed = 1.3 + amount * 1.8
            value.breathAmount = 0.03 + amount * 0.035
            value.awarenessPulseSpeed = 1.6 + amount * 2.2
            value.distortion = 0.06 + amount * 0.05
            value.orbitSpeed = 0.42 + amount * 0.55
            value.orbitOpacity = 0.16 + amount * 0.14
            value.particleCount = 16 + Int(amount * 8)
            value.particleBrightness = amount * 0.2
            value.pointerAttraction = 0.07 + amount * 0.045

        case .celebrating:
            // Violet body with golden sparks and rays.
            value.primary = Color(red: 0.6, green: 0.4, blue: 0.96)
            value.secondary = Color(red: 0.8, green: 0.62, blue: 1)
            value.particleColor = Color(red: 1, green: 0.8, blue: 0.42)
            value.auraOpacity = 0.42
            value.coreScale = 1.07
            value.breathSpeed = 2.2
            value.breathAmount = 0.06
            value.distortion = 0.08
            value.orbitSpeed = 1
            value.orbitOpacity = 0.26
            value.particleCount = 26
            value.particleBrightness = 0.24

        case .resting:
            // Desaturated blue-grey, settled low, wide and slow.
            value.primary = Color(red: 0.44, green: 0.52, blue: 0.74)
            value.secondary = Color(red: 0.58, green: 0.68, blue: 0.84)
            value.particleColor = Color(red: 0.74, green: 0.82, blue: 0.92)
            value.auraOpacity = 0.16
            value.coreBrightness = 0.66
            value.coreScale = 0.94
            value.breathSpeed = 0.4
            value.breathAmount = 0.04
            value.awarenessPulseSpeed = 0.5
            value.distortion = 0.04
            value.orbitSpeed = 0.07
            value.orbitOpacity = 0.09
            value.particleCount = 9
            value.pointerAttraction = 0.008
            value.centerOffset = CGSize(width: 0, height: 0.07)
            value.stretch = CGSize(width: 1.2, height: 0.78)

        case .energySaver:
            // Very dark, very small, very slow — conserving, not suffering.
            value.primary = Color(red: 0.26, green: 0.3, blue: 0.48)
            value.secondary = Color(red: 0.38, green: 0.48, blue: 0.62)
            value.particleColor = Color(red: 0.56, green: 0.65, blue: 0.74)
            value.auraOpacity = 0.1
            value.coreBrightness = 0.5
            value.coreScale = 0.78
            value.breathSpeed = 0.26
            value.breathAmount = 0.018
            value.awarenessPulseSpeed = 0.32
            value.distortion = 0.026
            value.orbitSpeed = 0.035
            value.orbitOpacity = 0.06
            value.particleCount = 5
            value.pointerAttraction = 0.004

        case .concealingSurprise:
            // Quiet violet-blue glow with faintly warm, yellow-tinged sparks.
            value.primary = Color(red: 0.52, green: 0.38, blue: 0.92)
            value.secondary = Color(red: 0.46, green: 0.76, blue: 1)
            value.particleColor = Color(red: 1, green: 0.85, blue: 0.55)
            value.auraOpacity = 0.22
            value.coreScale = 0.96
            value.breathSpeed = 0.85
            value.distortion = 0.07
            value.orbitSpeed = 0.24
            value.orbitOpacity = 0.14
            value.particleCount = 15
            value.particleGather = 0.18
            value.centerOffset = CGSize(width: -0.02, height: 0.01)
            value.stretch = CGSize(width: 0.94, height: 1.04)
        }
        return value
    }
}
