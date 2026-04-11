import AppKit
import SwiftUI

@MainActor
final class ErrorToastPanel: NSPanel {
    private let appState: AppState
    private let autoDismissInterval: TimeInterval = 5.0
    private var autoDismissTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var lastTick: Int = 0
    private weak var pillHost: NSView?

    private let panelWidth: CGFloat = 380
    private let panelHeight: CGFloat = 54
    private let cornerRadius: CGFloat = 14
    private let slidePadding: CGFloat = 22

    private var windowWidth: CGFloat { panelWidth + slidePadding * 2 }
    private var windowHeight: CGFloat { panelHeight + slidePadding * 2 }

    init(appState: AppState) {
        self.appState = appState

        let contentRect = NSRect(x: 0, y: 0, width: panelWidth + slidePadding * 2, height: panelHeight + slidePadding * 2)
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

        let root = NSView(frame: contentRect)
        root.wantsLayer = true

        let pillFrame = NSRect(x: slidePadding, y: slidePadding, width: panelWidth, height: panelHeight)
        let shadowHost = NSView(frame: pillFrame)
        shadowHost.wantsLayer = true
        if let layer = shadowHost.layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.5
            layer.shadowOffset = CGSize(width: 0, height: -6)
            layer.shadowRadius = 18
            layer.shadowPath = CGPath(
                roundedRect: NSRect(origin: .zero, size: pillFrame.size),
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        let pill = NSView(frame: NSRect(origin: .zero, size: pillFrame.size))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = cornerRadius
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        pill.autoresizingMask = [.width, .height]

        let blur = NSVisualEffectView(frame: pill.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.autoresizingMask = [.width, .height]
        pill.addSubview(blur)

        let tint = NSView(frame: pill.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = CGColor(red: 0.45, green: 0.05, blue: 0.05, alpha: 0.55)
        tint.autoresizingMask = [.width, .height]
        pill.addSubview(tint)

        let view = ErrorToastView(appState: appState) { [weak self] in
            self?.dismiss()
        }
        let controller = NSHostingController(rootView: view)
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

        shadowHost.addSubview(pill)
        root.addSubview(shadowHost)
        contentView = root
        pillHost = shadowHost
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func beginObserving() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Catch any error that was reported before we began observing.
            self.checkForError()
            while !Task.isCancelled {
                await self.waitForErrorChange()
                guard !Task.isCancelled else { return }
                self.checkForError()
            }
        }
    }

    private func checkForError() {
        if appState.errorMessage != nil, appState.errorTick != lastTick {
            lastTick = appState.errorTick
            present()
        }
    }

    func endObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func waitForErrorChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = self.appState.errorTick
                _ = self.appState.errorMessage
            } onChange: {
                continuation.resume()
            }
        }
    }

    private func present() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.maxY - windowHeight - 20 + slidePadding

        setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: false)
        orderFrontRegardless()

        guard let layer = pillHost?.layer else { return }
        layer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        let duration: CFTimeInterval = 0.34
        let timing = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = timing

        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 14
        slide.toValue = 0
        slide.duration = duration
        slide.timingFunction = timing

        layer.add(fade, forKey: "toast.fadeIn")
        layer.add(slide, forKey: "toast.slideIn")

        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.autoDismissInterval ?? 5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil

        guard let layer = pillHost?.layer else {
            orderOut(nil)
            appState.clearError()
            return
        }

        layer.removeAllAnimations()

        let duration: CFTimeInterval = 0.24
        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.9, 1.0)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, 10, 0)
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = timing

        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 0
        slide.toValue = 10
        slide.duration = duration
        slide.timingFunction = timing

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.appState.clearError()
            if let layer = self.pillHost?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
        layer.add(fade, forKey: "toast.fadeOut")
        layer.add(slide, forKey: "toast.slideOut")
        CATransaction.commit()
    }
}

private struct ErrorToastView: View {
    let appState: AppState
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.35))

            VStack(alignment: .leading, spacing: 2) {
                Text("Transcription Error")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .textCase(.uppercase)
                    .kerning(0.4)
                Text(appState.errorMessage ?? "")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(appState.errorMessage ?? "")")
    }
}
