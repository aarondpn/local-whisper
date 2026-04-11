import AppKit
import SwiftUI

final class DraggableRootView: NSView {
    var isDraggable: () -> Bool = { false }

    // Intercept hit-testing when drag mode is active so SwiftUI hosting subviews
    // don't swallow the mouseDown event. Fall back to default routing otherwise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isDraggable() {
            let localPoint = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(localPoint) ? self : super.hitTest(point)
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
    // Wide enough to let any theme's shadow (max radius 28 + 8pt offset + 14pt
    // slide animation) fade to zero before hitting the panel window rectangle,
    // which would otherwise clip the halo into visible rectangular edges.
    private static let slidePadding: CGFloat = 60

    private var slidePadding: CGFloat { Self.slidePadding }
    private var scale: CGFloat { appState.hudSize.scale }
    private var panelWidth: CGFloat { Self.basePanelWidth * scale }
    private var panelHeight: CGFloat { Self.basePanelHeight * scale }
    private var cornerRadius: CGFloat { Self.baseCornerRadius * scale }

    private var windowWidth: CGFloat { panelWidth + slidePadding * 2 }
    private var windowHeight: CGFloat { panelHeight + slidePadding * 2 }

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
        let contentRect = NSRect(x: 0, y: 0, width: initialPanelWidth + pad * 2, height: initialPanelHeight + pad * 2)
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
        let pillFrame = NSRect(x: pad, y: pad, width: initialPanelWidth, height: initialPanelHeight)
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

        // SwiftUI content hosts once — stays across theme swaps, reactively re-themes itself.
        let overlayView = RecordingOverlayView().environment(appState)
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
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.appliedSize != self.appState.hudSize {
                    self.applyGeometry()
                } else {
                    self.applyTheme(self.appState.hudTheme)
                }
                self.observeState()
            }
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
        let pillFrame = NSRect(x: slidePadding, y: slidePadding, width: panelWidth, height: panelHeight)
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
        borderMask.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: cornerRadius - inset,
            cornerHeight: cornerRadius - inset,
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

    private func resolvedOrigin(for screenFrame: NSRect) -> NSPoint {
        let x: CGFloat
        let y: CGFloat
        switch appState.overlayPosition {
        case .bottom:
            x = screenFrame.midX - windowWidth / 2
            y = screenFrame.minY + 80 - slidePadding
        case .center:
            x = screenFrame.midX - windowWidth / 2
            y = screenFrame.midY - windowHeight / 2
        case .top:
            x = screenFrame.midX - windowWidth / 2
            y = screenFrame.maxY - windowHeight - 20 + slidePadding
        case .custom:
            if appState.overlayCustomPositionSet {
                let rawX = CGFloat(appState.overlayCustomX)
                let rawY = CGFloat(appState.overlayCustomY)
                x = clampCustomX(rawX, screenFrame: screenFrame)
                y = clampCustomY(rawY, screenFrame: screenFrame)
            } else {
                x = screenFrame.midX - windowWidth / 2
                y = screenFrame.minY + 80 - slidePadding
            }
        }
        return NSPoint(x: x, y: y)
    }

    private func clampCustomX(_ rawX: CGFloat, screenFrame: NSRect) -> CGFloat {
        // Visible pill must stay on-screen; the padding frame may extend a bit beyond.
        let minX = screenFrame.minX - slidePadding
        let maxX = screenFrame.maxX - windowWidth + slidePadding
        return min(max(rawX, minX), maxX)
    }

    private func clampCustomY(_ rawY: CGFloat, screenFrame: NSRect) -> CGFloat {
        let minY = screenFrame.minY - slidePadding
        let maxY = screenFrame.maxY - windowHeight + slidePadding
        return min(max(rawY, minY), maxY)
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
        }
        layer.add(fade, forKey: "hud.fadeOut")
        layer.add(slide, forKey: "hud.slideOut")
        CATransaction.commit()
    }
}

extension RecordingOverlayPanel: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        guard appState.overlayPosition == .custom || isPositioningSession else { return }
        appState.overlayCustomX = Double(frame.origin.x)
        appState.overlayCustomY = Double(frame.origin.y)
        appState.overlayCustomPositionSet = true
    }
}
