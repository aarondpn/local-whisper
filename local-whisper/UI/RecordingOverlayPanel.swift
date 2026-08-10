import AppKit
import SwiftUI

final class DraggableRootView: NSView {
    var isDraggable: () -> Bool = { false }
    /// The visually occupied rect (the pill/card). Clicks outside it fall through
    /// to whatever is behind the transparent window instead of being swallowed.
    var activeRect: () -> NSRect? = { nil }

    // Intercept hit-testing when drag mode is active so SwiftUI hosting subviews
    // don't swallow the mouseDown event. Fall back to default routing otherwise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isDraggable() {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(localPoint) ? self : super.hitTest(point)
        }
        if let active = activeRect() {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            if !active.insetBy(dx: -8, dy: -8).contains(localPoint) { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isDraggable() {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

final class RecordingOverlayPanel: NSPanel {
    private let appState: AppState
    private var showTime: CFAbsoluteTime = 0
    private let minDisplayDuration: CFTimeInterval = 0.25
    private var isProgrammaticMove = false
    private var isPositioningSession = false
    private weak var draggableRoot: DraggableRootView?

    // Base dimensions at scale = 1.0 (HUDSize.regular). Actual sizes derive
    // by multiplying by `appState.hudSize.scale`.
    private static let basePanelWidth: CGFloat = 260
    private static let basePanelHeight: CGFloat = 54
    private static let baseCornerRadius: CGFloat = 27
    // Live-transcription card the pill morphs into.
    private static let baseCardWidth: CGFloat = 420
    private static let baseCardHeight: CGFloat = 148
    private static let baseCardCornerRadius: CGFloat = 22
    // Wide enough to let any theme's shadow (max radius 28 + 8pt offset + 14pt
    // slide animation) fade to zero before hitting the panel window rectangle,
    // which would otherwise clip the halo into visible rectangular edges.
    private static let slidePadding: CGFloat = 60

    private var slidePadding: CGFloat { Self.slidePadding }
    private var scale: CGFloat { appState.hudSize.scale }
    private var panelWidth: CGFloat { Self.basePanelWidth * scale }
    private var panelHeight: CGFloat { Self.basePanelHeight * scale }
    private var cornerRadius: CGFloat { Self.baseCornerRadius * scale }
    private var cardWidth: CGFloat { Self.baseCardWidth * scale }
    private var cardHeight: CGFloat { Self.baseCardHeight * scale }
    private var cardCornerRadius: CGFloat { Self.baseCardCornerRadius * scale }

    // The window is always sized to hold the fully expanded card (plus shadow
    // padding); it is invisible, only the pill subview renders. The pill→card
    // morph is therefore pure subview animation — the window frame never moves
    // while visible, which would stutter against layer animations.
    private var windowWidth: CGFloat { cardWidth + slidePadding * 2 }
    private var windowHeight: CGFloat { cardHeight + slidePadding * 2 }

    /// Which way the pill grows into the card: away from the nearest screen edge.
    private enum GrowDirection { case up, down, center }
    private var growDirection: GrowDirection = .up
    private var isExpanded = false
    private var expandCapTask: Task<Void, Never>?
    private var lastLiveActive = false

    /// Where the pill sits inside the oversized window, per grow direction.
    private var pillRectInWindow: NSRect {
        NSRect(origin: restingOrigin(for: NSSize(width: panelWidth, height: panelHeight)),
               size: NSSize(width: panelWidth, height: panelHeight))
    }

    private var cardRectInWindow: NSRect {
        NSRect(origin: restingOrigin(for: NSSize(width: cardWidth, height: cardHeight)),
               size: NSSize(width: cardWidth, height: cardHeight))
    }

    private func restingOrigin(for size: NSSize) -> NSPoint {
        let x = (windowWidth - size.width) / 2
        let y: CGFloat
        switch growDirection {
        case .up: y = slidePadding
        case .down: y = windowHeight - slidePadding - size.height
        case .center: y = (windowHeight - size.height) / 2
        }
        return NSPoint(x: x, y: y)
    }

    // Animated root (slide + fade). Holds the shadow; child clips the rounded pill.
    private weak var pillHost: NSView?
    private weak var pill: NSView?
    // Theme-dependent chrome layered behind SwiftUI content.
    private weak var chromeBelow: NSView?
    // Theme-dependent chrome layered above SwiftUI content (border overlay).
    private weak var chromeAbove: NSView?

    private var appliedThemeID: HUDThemeID?
    private var appliedSize: HUDSize?

    init(appState: AppState) {
        self.appState = appState

        let scale = appState.hudSize.scale
        let initialPanelWidth = Self.basePanelWidth * scale
        let initialPanelHeight = Self.basePanelHeight * scale
        let initialCornerRadius = Self.baseCornerRadius * scale
        let pad = Self.slidePadding
        let contentRect = NSRect(
            x: 0, y: 0,
            width: Self.baseCardWidth * scale + pad * 2,
            height: Self.baseCardHeight * scale + pad * 2
        )
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        alphaValue = 1

        // Transparent root — lets the pill slide without window clipping it.
        let root = DraggableRootView(frame: contentRect)
        root.wantsLayer = true

        // Shadow carrier — renders shadow outside the pill's rounded mask.
        // Centered horizontally in the card-capable window; bottom-anchored (the
        // default grow direction) vertically. showOverlay repositions per session.
        let pillFrame = NSRect(
            x: (contentRect.width - initialPanelWidth) / 2,
            y: pad,
            width: initialPanelWidth,
            height: initialPanelHeight
        )
        let shadowHost = NSView(frame: pillFrame)
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -8)
        shadowHost.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: pillFrame.size),
            cornerWidth: initialCornerRadius,
            cornerHeight: initialCornerRadius,
            transform: nil
        )

        // Rounded pill — clips chrome + content to the capsule shape.
        let pill = NSView(frame: NSRect(origin: .zero, size: pillFrame.size))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = initialCornerRadius
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.autoresizingMask = [.width, .height]

        // Chrome below: blur/tint/highlight. Rebuilt on theme change.
        let chromeBelow = NSView(frame: pill.bounds)
        chromeBelow.wantsLayer = true
        chromeBelow.autoresizingMask = [.width, .height]
        pill.addSubview(chromeBelow)

        // SwiftUI host stays mounted across theme swaps, but its body only renders
        // RecordingOverlayView while a visibility flag is set on AppState. That gates
        // all child timers/animations on actual visibility — orderOut(nil) hides the
        // NSPanel without tearing down its view tree, so without this gate the 60 Hz
        // visualization timer, the 10 Hz timer-label TimelineView, and the
        // repeatForever pulse/rotation animations would run for the full app lifetime.
        let overlayView = RecordingOverlayHost().environment(appState)
        let controller = NSHostingController(rootView: overlayView)
        controller.sceneBridgingOptions = []
        let hostingView = controller.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: pill.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        // Chrome above: border hairline. Painted on top of content.
        let chromeAbove = NSView(frame: pill.bounds)
        chromeAbove.wantsLayer = true
        chromeAbove.autoresizingMask = [.width, .height]
        pill.addSubview(chromeAbove)

        shadowHost.addSubview(pill)
        root.addSubview(shadowHost)
        contentView = root

        self.pillHost = shadowHost
        self.pill = pill
        self.chromeBelow = chromeBelow
        self.chromeAbove = chromeAbove
        self.draggableRoot = root

        root.isDraggable = { [weak self] in
            guard let self else { return false }
            return self.appState.overlayPosition == .custom || self.isPositioningSession
        }
        root.activeRect = { [weak self] in self?.pillHost?.frame }

        self.delegate = self

        appliedSize = appState.hudSize
        applyTheme(appState.hudTheme)
        observeState()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Theme + geometry observation

    private func observeState() {
        withObservationTracking {
            _ = appState.hudThemeID
            _ = appState.hudSize
            _ = appState.liveTranscript
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.appliedSize != self.appState.hudSize {
                    self.applyGeometry()
                } else if self.appliedThemeID != self.appState.hudThemeID {
                    self.applyTheme(self.appState.hudTheme)
                }
                self.evaluateLiveExpansion()
                self.observeState()
            }
        }
    }

    /// Expand when the first finalized text arrives — the morph is the payoff
    /// moment — with a 1.2 s cap so slow starters still get the card (showing
    /// the listening caret) before their first sentence lands.
    private func evaluateLiveExpansion() {
        let live = appState.liveTranscript
        let active = live != nil
        if active, !lastLiveActive {
            expandCapTask?.cancel()
            expandCapTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.expandToCard()
            }
        } else if !active {
            expandCapTask?.cancel()
            expandCapTask = nil
        }
        lastLiveActive = active

        if let live, !live.settled.isEmpty {
            expandToCard()
        }
    }

    private func applyGeometry() {
        guard let pillHost, let pill else { return }

        let oldFrame = frame
        let newSize = NSSize(width: windowWidth, height: windowHeight)

        // Recenter the panel window on its current center so the pill doesn't jump.
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2
        )
        isProgrammaticMove = true
        setFrame(NSRect(origin: newOrigin, size: newSize), display: false)
        isProgrammaticMove = false

        contentView?.frame = NSRect(origin: .zero, size: newSize)

        // Resize the animated carrier. Autoresizing cascades to pill → chromes.
        // Size changes only happen from Settings, never mid-session, so always
        // reset to the collapsed pill.
        isExpanded = false
        appState.liveCardExpanded = false
        let pillFrame = pillRectInWindow
        pillHost.frame = pillFrame
        pillHost.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: pillFrame.size),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        pill.layer?.cornerRadius = cornerRadius

        appliedSize = appState.hudSize
        // Force chrome rebuild so gradients/border paths recompute at the new bounds.
        appliedThemeID = nil
        applyTheme(appState.hudTheme)
    }

    private func applyTheme(_ theme: HUDTheme) {
        guard let shadowHost = pillHost,
              let pill,
              let chromeBelow,
              let chromeAbove else { return }

        if appliedThemeID == theme.id { return }
        appliedThemeID = theme.id

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Shadow
        shadowHost.layer?.shadowColor = NSColor(theme.shadowColor).cgColor
        shadowHost.layer?.shadowOpacity = Float(theme.shadowOpacity)
        shadowHost.layer?.shadowRadius = CGFloat(theme.shadowRadius)

        // Tear down prior chrome
        chromeBelow.subviews.forEach { $0.removeFromSuperview() }
        chromeAbove.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }

        let bounds = pill.bounds

        // 1. Backdrop — frosted blur or solid base.
        if let blurCfg = theme.blur {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = blurCfg.material
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: blurCfg.appearance)
            blur.wantsLayer = true
            blur.autoresizingMask = [.width, .height]
            chromeBelow.addSubview(blur)
        } else {
            let solid = NSView(frame: bounds)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.black.cgColor
            solid.autoresizingMask = [.width, .height]
            chromeBelow.addSubview(solid)
        }

        // 2. Tint layer — flat color or diagonal gradient.
        // Gradient layer is oversized well beyond the pill so the visible area
        // only ever shows the interior of the gradient, never its corners.
        let tintView = NSView(frame: bounds)
        tintView.wantsLayer = true
        tintView.autoresizingMask = [.width, .height]
        if let endColor = theme.gradientEnd {
            let grad = CAGradientLayer()
            let oversize = max(bounds.width, bounds.height) * 1.2
            grad.frame = bounds.insetBy(dx: -oversize, dy: -oversize)
            grad.colors = [
                NSColor(theme.tint).withAlphaComponent(theme.tintOpacity).cgColor,
                NSColor(endColor).withAlphaComponent(theme.tintOpacity).cgColor
            ]
            let rad = theme.gradientAngle * .pi / 180
            let dx = cos(rad) * 0.5
            let dy = sin(rad) * 0.5
            grad.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            grad.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
            tintView.layer?.addSublayer(grad)
        } else {
            tintView.layer?.backgroundColor = NSColor(theme.tint).withAlphaComponent(theme.tintOpacity).cgColor
        }
        chromeBelow.addSubview(tintView)

        // 3. Top highlight — catches light from above. Oversized horizontally so
        // the gradient band never shows its horizontal endpoints at the pill edges.
        let highlightView = NSView(frame: bounds)
        highlightView.wantsLayer = true
        highlightView.autoresizingMask = [.width, .height]
        let highlight = CAGradientLayer()
        let hlOversize = bounds.width * 0.5
        highlight.frame = bounds.insetBy(dx: -hlOversize, dy: 0)
        highlight.colors = theme.highlight.map { NSColor($0).cgColor }
        highlight.locations = theme.highlight.count == 2 ? [0.0, 0.55] : nil
        highlight.startPoint = CGPoint(x: 0.5, y: 1.0)
        highlight.endPoint = CGPoint(x: 0.5, y: 0.0)
        highlightView.layer?.addSublayer(highlight)
        chromeBelow.addSubview(highlightView)

        // 4. Border hairline — drawn above content.
        let borderLayer = CAGradientLayer()
        borderLayer.frame = bounds
        borderLayer.colors = theme.border.map { NSColor($0).cgColor }
        if theme.border.count == 3 {
            borderLayer.locations = [0.0, 0.5, 1.0]
        }
        borderLayer.startPoint = CGPoint(x: 0.0, y: 1.0)
        borderLayer.endPoint = CGPoint(x: 1.0, y: 0.0)
        let borderMask = CAShapeLayer()
        let inset: CGFloat = 0.5
        let maskRadius = isExpanded ? cardCornerRadius : cornerRadius
        borderMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: maskRadius - inset,
            cornerHeight: maskRadius - inset,
            transform: nil
        )
        borderMask.lineWidth = 1
        borderMask.strokeColor = NSColor.white.cgColor
        borderMask.fillColor = NSColor.clear.cgColor
        borderLayer.mask = borderMask
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        chromeAbove.layer?.addSublayer(borderLayer)
    }

    // MARK: - Positioning

    /// The pill's desired on-screen origin — the canonical positioning quantity.
    /// The window (oversized to hold the expanded card) is placed around it.
    /// Custom positions persist in the legacy convention (pill-sized window
    /// origin, i.e. pill origin minus slidePadding) so stored values survive.
    private func desiredPillOrigin(for screenFrame: NSRect) -> NSPoint {
        switch appState.overlayPosition {
        case .bottom:
            break
        case .center:
            return NSPoint(x: screenFrame.midX - panelWidth / 2,
                           y: screenFrame.midY - panelHeight / 2)
        case .top:
            return NSPoint(x: screenFrame.midX - panelWidth / 2,
                           y: screenFrame.maxY - 20 - panelHeight)
        case .custom:
            if appState.overlayCustomPositionSet {
                let rawX = CGFloat(appState.overlayCustomX) + slidePadding
                let rawY = CGFloat(appState.overlayCustomY) + slidePadding
                // Visible pill must stay fully on-screen.
                let x = min(max(rawX, screenFrame.minX), screenFrame.maxX - panelWidth)
                let y = min(max(rawY, screenFrame.minY), screenFrame.maxY - panelHeight)
                return NSPoint(x: x, y: y)
            }
        }
        return NSPoint(x: screenFrame.midX - panelWidth / 2, y: screenFrame.minY + 80)
    }

    /// Decide which way the card grows, place the pill, and derive the window origin.
    private func resolvedOrigin(for screenFrame: NSRect) -> NSPoint {
        let pillOrigin = desiredPillOrigin(for: screenFrame)
        switch appState.overlayPosition {
        case .bottom: growDirection = .up
        case .top: growDirection = .down
        case .center: growDirection = .center
        case .custom:
            growDirection = (pillOrigin.y + panelHeight / 2) < screenFrame.midY ? .up : .down
        }
        let offset = pillRectInWindow.origin
        return NSPoint(x: pillOrigin.x - offset.x, y: pillOrigin.y - offset.y)
    }

    /// Shows the panel in a static state for the user to drag into place.
    /// Skips the slide-in animation and stays visible until `endPositioningSession()`.
    func beginPositioningSession() {
        guard let screen = NSScreen.main else { return }
        isPositioningSession = true
        appState.isOverlayPositioningSession = true

        let origin = resolvedOrigin(for: screen.visibleFrame)
        isProgrammaticMove = true
        setFrame(NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)), display: false)
        isProgrammaticMove = false
        orderFrontRegardless()

        if let layer = pillHost?.layer {
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    func endPositioningSession() {
        guard isPositioningSession else { return }
        isPositioningSession = false
        appState.isOverlayPositioningSession = false
        if !appState.isRecording && !appState.isTranscribing {
            orderOut(nil)
        }
    }

    // MARK: - Show / hide

    func showOverlay() {
        guard appState.hudEnabled else { return }
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = resolvedOrigin(for: screenFrame)

        isProgrammaticMove = true
        setFrame(NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)), display: false)
        isProgrammaticMove = false
        resetToPillGeometry()
        orderFrontRegardless()
        showTime = CFAbsoluteTimeGetCurrent()

        guard let layer = pillHost?.layer else { return }

        // Kill any in-flight animations from a previous show/hide cycle.
        layer.removeAllAnimations()

        // Model values land at the final state so the layer rests correctly after animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let duration: CFTimeInterval = 0.42
        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = timing

        // Layer coords on macOS are Y-up: negative y starts the pill below its resting position.
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -14
        slide.toValue = 0
        slide.duration = duration
        slide.timingFunction = timing

        layer.add(fade, forKey: "hud.fadeIn")
        layer.add(slide, forKey: "hud.slideIn")
    }

    func hideOverlay() {
        // Expanded card: settle beat → collapse → fade, as three distinct fast
        // movements rather than one simultaneous mush.
        if isExpanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.collapseToPill { [weak self] in
                    self?.fadeOut()
                }
            }
            return
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - showTime
        let remaining = minDisplayDuration - elapsed
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.fadeOut()
            }
        } else {
            fadeOut()
        }
    }

    private func fadeOut() {
        // A positioning session keeps the overlay visible until the user clicks Done.
        if isPositioningSession { return }
        guard let layer = pillHost?.layer else {
            orderOut(nil)
            return
        }

        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, -8, 0)
        CATransaction.commit()

        let duration: CFTimeInterval = 0.26
        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.9, 1.0)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = timing

        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 0
        slide.toValue = -8
        slide.duration = duration
        slide.timingFunction = timing

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            // Reset model state so the next show starts from a clean slate.
            if let layer = self.pillHost?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            self.resetToPillGeometry()
        }
        layer.add(fade, forKey: "hud.fadeOut")
        layer.add(slide, forKey: "hud.slideOut")
        CATransaction.commit()
    }

    // MARK: - Live-card morph

    private static let morphDuration: CFTimeInterval = 0.38
    private static let morphTiming = CAMediaTimingFunction(controlPoints: 0.2, 1.0, 0.3, 1.0)

    /// Snap back to collapsed pill geometry with no animation (session start/end).
    private func resetToPillGeometry() {
        guard let pillHost, let pill else { return }
        expandCapTask?.cancel()
        expandCapTask = nil
        guard isExpanded || pillHost.frame != pillRectInWindow else { return }
        isExpanded = false
        appState.liveCardExpanded = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillHost.frame = pillRectInWindow
        pillHost.layer?.shadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: pillRectInWindow.size),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )
        pill.layer?.cornerRadius = cornerRadius
        chromeAbove?.alphaValue = 1
        CATransaction.commit()

        appliedThemeID = nil
        applyTheme(appState.hudTheme)
    }

    /// Morph the pill into the live-transcription card. The window is already
    /// sized for the card, so this is pure subview/layer animation.
    func expandToCard() {
        guard !isExpanded, isVisible, appState.hudEnabled,
              appState.liveTranscript != nil,
              let pillHost, let pill else { return }
        isExpanded = true
        expandCapTask?.cancel()
        expandCapTask = nil
        // SwiftUI content crossfades to the card layout in sync with the morph.
        appState.liveCardExpanded = true

        var target = cardRectInWindow
        // Clamp the card's screen rect to the visible frame (custom positions
        // near an edge); the window never moves, only the card's inset shifts.
        if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let screenRect = NSRect(
                x: frame.origin.x + target.origin.x,
                y: frame.origin.y + target.origin.y,
                width: target.width, height: target.height
            )
            let clampedX = min(max(screenRect.origin.x, visible.minX), visible.maxX - target.width)
            let clampedY = min(max(screenRect.origin.y, visible.minY), visible.maxY - target.height)
            target.origin.x += clampedX - screenRect.origin.x
            target.origin.y += clampedY - screenRect.origin.y
        }

        // The hairline border's mask path can't track the resize; fade it out,
        // rebuild at final bounds in the completion, fade back in.
        if let chromeAbove {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                chromeAbove.animator().alphaValue = 0
            }
        }

        animateMorph(to: target, cornerRadius: cardCornerRadius, on: pillHost, pill: pill) { [weak self] in
            guard let self, self.isExpanded else { return }
            self.appliedThemeID = nil
            self.applyTheme(self.appState.hudTheme)
            if let chromeAbove = self.chromeAbove {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    chromeAbove.animator().alphaValue = 1
                }
            }
        }
    }

    /// Morph the card back down to the pill.
    func collapseToPill(completion: (() -> Void)? = nil) {
        guard isExpanded, let pillHost, let pill else {
            completion?()
            return
        }
        isExpanded = false
        appState.liveCardExpanded = false

        if let chromeAbove {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                chromeAbove.animator().alphaValue = 0
            }
        }

        animateMorph(to: pillRectInWindow, cornerRadius: cornerRadius, on: pillHost, pill: pill) { [weak self] in
            guard let self else { completion?(); return }
            if !self.isExpanded {
                self.appliedThemeID = nil
                self.applyTheme(self.appState.hudTheme)
                if let chromeAbove = self.chromeAbove {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        chromeAbove.animator().alphaValue = 1
                    }
                }
            }
            completion?()
        }
    }

    /// Shared morph choreography: frame via implicit animation (autoresizing
    /// carries pill + chrome along), cornerRadius + shadowPath via explicit
    /// CABasicAnimations so the shadow stays glued to the shape throughout.
    private func animateMorph(
        to target: NSRect,
        cornerRadius targetRadius: CGFloat,
        on pillHost: NSView,
        pill: NSView,
        completion: @escaping () -> Void
    ) {
        let fromRadius = pill.layer?.cornerRadius ?? targetRadius
        let fromShadowPath = pillHost.layer?.shadowPath
        let targetShadowPath = CGPath(
            roundedRect: NSRect(origin: .zero, size: target.size),
            cornerWidth: targetRadius, cornerHeight: targetRadius, transform: nil
        )

        // Land the layer model values first, then animate from the old state.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.layer?.cornerRadius = targetRadius
        pillHost.layer?.shadowPath = targetShadowPath
        CATransaction.commit()

        let radiusAnim = CABasicAnimation(keyPath: "cornerRadius")
        radiusAnim.fromValue = fromRadius
        radiusAnim.toValue = targetRadius
        radiusAnim.duration = Self.morphDuration
        radiusAnim.timingFunction = Self.morphTiming
        pill.layer?.add(radiusAnim, forKey: "hud.morphRadius")

        if let fromShadowPath {
            let shadowAnim = CABasicAnimation(keyPath: "shadowPath")
            shadowAnim.fromValue = fromShadowPath
            shadowAnim.toValue = targetShadowPath
            shadowAnim.duration = Self.morphDuration
            shadowAnim.timingFunction = Self.morphTiming
            pillHost.layer?.add(shadowAnim, forKey: "hud.morphShadow")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.morphDuration
            ctx.timingFunction = Self.morphTiming
            ctx.allowsImplicitAnimation = true
            pillHost.animator().frame = target
        }, completionHandler: completion)
    }
}

extension RecordingOverlayPanel: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        guard appState.overlayPosition == .custom || isPositioningSession else { return }
        // Persist in the legacy pill-sized-window convention (see desiredPillOrigin).
        let pillOrigin = NSPoint(
            x: frame.origin.x + pillRectInWindow.origin.x,
            y: frame.origin.y + pillRectInWindow.origin.y
        )
        appState.overlayCustomX = Double(pillOrigin.x - slidePadding)
        appState.overlayCustomY = Double(pillOrigin.y - slidePadding)
        appState.overlayCustomPositionSet = true
    }
}
