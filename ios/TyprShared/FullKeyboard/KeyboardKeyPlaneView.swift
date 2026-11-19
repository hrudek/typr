import UIKit

/// Draws the keys and turns touches into `FullKeyboardEngine` calls. The Typr and globe
/// keys are real controls laid over their slots by `FullKeyboardView`; this view only
/// draws the globe's keycap and the shared space/Typr background.
@MainActor
final class KeyboardKeyPlaneView: UIView {
    let engine: FullKeyboardEngine
    var typrPressed = false { didSet { if typrPressed != oldValue { setNeedsDisplay() } } }
    var palette = FullKeyboardPalette(isDark: false) { didSet {
        guard palette != oldValue else { return }
        trailLayer.strokeColor = palette.actionFill.withAlphaComponent(0.35).cgColor
        setNeedsDisplay()
    } }
    var returnLabel = "return" { didSet { if returnLabel != oldValue { setNeedsDisplay() } } }
    var returnSymbol: String? = "return" { didSet { if returnSymbol != oldValue { setNeedsDisplay() } } }
    var returnIsAction = false { didSet { if returnIsAction != oldValue { setNeedsDisplay() } } }
    var returnIsEnabled = true { didSet { if returnIsEnabled != oldValue { setNeedsDisplay() } } }
    /// Called on every key going down, for clicks and haptics.
    var onKeyDown: ((KeyKind) -> Void)?
    /// Called when long-press accents open.
    var onAccentMenuOpened: (() -> Void)?
    var onNextKeyboard: (() -> Void)?

    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0
    private var deleteTimer: Timer?
    private var deleteStartedAt: TimeInterval = 0
    private var holdWork: [Int: DispatchWorkItem] = [:]
    /// The swipe trail: its own layer so a swipe redraws a path, not every key.
    private let trailLayer = CAShapeLayer()

    init(engine: FullKeyboardEngine) {
        self.engine = engine
        super.init(frame: .zero)
        trailLayer.fillColor = nil
        trailLayer.lineWidth = 5
        trailLayer.lineCap = .round
        trailLayer.lineJoin = .round
        trailLayer.strokeColor = palette.actionFill.withAlphaComponent(0.35).cgColor
        layer.addSublayer(trailLayer)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        engine.layout.keysAreaFrame.contains(point)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let layout = engine.layout
        let isPhoneLandscape = layout.orientation == .landscape
        let radius = layout.metrics.cornerRadius
        let pressed = engine.pressedKinds
        let preview = layout.showsBalloons ? engine.previewKey?.kind : nil
        // Like Apple's spacebar trackpad, key glyphs blank out while sliding the cursor.
        let hideGlyphs = engine.isTrackpadActive
        let isMechanical = palette.design == .mechanical
        let labelWeight: UIFont.Weight = isMechanical ? .medium : .regular
        let symbolWeight: UIImage.SymbolWeight = isMechanical ? .medium : .regular

        let joined = JoinedSpaceKeycap(layout: layout)
        joined?.draw(in: context, palette: palette, spacePressed: pressed.contains(.space), typrPressed: typrPressed)

        for key in layout.keys {
            guard key.frame.intersects(rect) else { continue }
            switch key.kind {
            case .typr:
                continue
            case .character:
                // The pressed key is drawn by its balloon in portrait.
                if key.kind == preview { continue }
                let fill = pressed.contains(key.kind) ? palette.keyPressedFill : palette.keyFill
                context.fillKeycap(key.frame, palette: palette, fill: fill, radius: radius)
                guard !hideGlyphs else { continue }
                let label = engine.displayLabel(for: key)
                let isWidePunctuation = key.frame.width > layout.letterWidth * 1.2
                let isUpperLetter = layout.layer == .letters && engine.isUppercase && label.first?.isUppercase == true
                let baseSize: CGFloat = if isPhoneLandscape {
                    isUpperLetter ? 18 : 19
                } else if isWidePunctuation || isUpperLetter {
                    21
                } else {
                    22.5
                }
                let fontSize = isMechanical ? baseSize * 0.93 : baseSize
                let yOffset: CGFloat = isUpperLetter ? 0 : (isPhoneLandscape ? -0.5 : -1)
                drawText(
                    label,
                    in: inkFrame(key.frame),
                    font: .systemFont(ofSize: fontSize, weight: labelWeight),
                    color: palette.keyLabel,
                    yOffset: yOffset
                )
            case .space:
                if joined != nil { continue }
                let fill = pressed.contains(.space) ? palette.keyPressedFill : palette.keyFill
                context.fillKeycap(key.frame, palette: palette, fill: fill, radius: radius)
            case .returnKey:
                let isPressed = pressed.contains(.returnKey) && returnIsEnabled
                let activeAction = returnIsAction && returnIsEnabled && !hideGlyphs
                let fill: UIColor = activeAction
                    ? (isPressed ? palette.actionPressedFill : palette.actionFill)
                    : (isPressed ? palette.keyPressedFill : palette.keyFill)
                let ink: UIColor = if !returnIsEnabled {
                    palette.textMuted
                } else if activeAction {
                    .white
                } else {
                    palette.keyGlyph
                }
                context.fillKeycap(key.frame, palette: palette, fill: fill, radius: radius)
                guard !hideGlyphs else { continue }
                if let symbol = returnSymbol {
                    drawSymbol(
                        symbol,
                        in: inkFrame(key.frame),
                        color: ink,
                        pointSize: isPhoneLandscape ? 15.5 : 17.5,
                        weight: activeAction ? .medium : symbolWeight
                    )
                } else {
                    drawText(returnLabel, in: inkFrame(key.frame), font: .systemFont(ofSize: isPhoneLandscape ? 14.5 : 15.5, weight: labelWeight), color: ink)
                }
            case .shift:
                let state = engine.shift.state
                let isPressed = pressed.contains(.shift)
                context.fillKeycap(key.frame, palette: palette, fill: isPressed ? palette.keyPressedFill : palette.keyFill, radius: radius)
                guard !hideGlyphs else { continue }
                let symbol = switch state {
                case .off: engine.shift.isHeld ? "shift.fill" : "shift"
                case .on: "shift.fill"
                case .locked: "capslock.fill"
                }
                drawSymbol(symbol, in: inkFrame(key.frame), color: palette.keyGlyph, pointSize: isPhoneLandscape ? 16 : 18, weight: symbolWeight)
            case .delete:
                let lit = pressed.contains(.delete)
                context.fillKeycap(key.frame, palette: palette, fill: lit ? palette.keyPressedFill : palette.keyFill, radius: radius)
                guard !hideGlyphs else { continue }
                let symbol = engine.deleteUndoes ? "arrow.uturn.backward" : lit ? "delete.left.fill" : "delete.left"
                drawSymbol(symbol, in: inkFrame(key.frame), color: palette.keyGlyph, pointSize: isPhoneLandscape ? 16 : 18, weight: symbolWeight)
            case .layerSwitch:
                let lit = pressed.contains(key.kind)
                context.fillKeycap(key.frame, palette: palette, fill: lit ? palette.keyPressedFill : palette.keyFill, radius: radius)
                guard !hideGlyphs else { continue }
                drawText(key.label, in: inkFrame(key.frame), font: .systemFont(ofSize: isPhoneLandscape ? 14.5 : 15.5, weight: labelWeight), color: palette.keyGlyph)
            case .globe:
                let lit = pressed.contains(.globe)
                context.fillKeycap(key.frame, palette: palette, fill: lit ? palette.keyPressedFill : palette.keyFill, radius: radius)
                guard !hideGlyphs else { continue }
                drawSymbol("globe", in: inkFrame(key.frame), color: palette.keyGlyph, pointSize: isPhoneLandscape ? 16 : 18, weight: symbolWeight)
            case .globeSpacer:
                context.fillKeycap(key.frame, palette: palette, fill: palette.keyFill, radius: radius)
                guard !hideGlyphs else { continue }
                drawSymbol("globe", in: inkFrame(key.frame), color: palette.keyGlyph.withAlphaComponent(0.35), pointSize: isPhoneLandscape ? 16 : 18, weight: symbolWeight)
            }
        }
    }

    private func inkFrame(_ frame: CGRect) -> CGRect {
        palette.design == .mechanical ? MechanicalKeycap(isDark: palette.isDark).inkFrame(frame) : frame
    }

    private func drawText(_ text: String, in frame: CGRect, font: UIFont, color: UIColor, yOffset: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + yOffset
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private func drawSymbol(
        _ name: String,
        in frame: CGRect,
        color: UIColor,
        pointSize: CGFloat = 18,
        weight: UIImage.SymbolWeight = .regular
    ) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        image.draw(in: CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    // MARK: - Touches

    private func id(for touch: UITouch, creating: Bool) -> Int? {
        let key = ObjectIdentifier(touch)
        if let id = touchIDs[key] { return id }
        guard creating else { return nil }
        nextTouchID += 1
        touchIDs[key] = nextTouchID
        return nextTouchID
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let id = id(for: touch, creating: true) else { continue }
            let point = touch.location(in: self)
            engine.touchBegan(id: id, at: point, time: touch.timestamp)
            if let kind = engine.touches[id]?.key.kind {
                onKeyDown?(kind)
                if kind == .delete { startDeleteRepeat() }
                if case .character = kind { armAccentTimer(for: id) }
                if case .layerSwitch = kind, engine.layout.layerKeyHoldSwitchesKeyboard { armNextKeyboardTimer(for: id) }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { updateTrail() }
        for touch in touches {
            guard let id = id(for: touch, creating: false) else { continue }
            let previousKey = engine.touches[id]?.key.kind
            // Coalesced samples keep the full 120 Hz path for swipe recognition.
            let samples = (event?.coalescedTouches(for: touch) ?? [touch]).map {
                (point: $0.location(in: self), time: $0.timestamp)
            }
            engine.touchMoved(id: id, to: touch.location(in: self), samples: samples)
            if engine.touches[id]?.isSwipe == true {
                cancelHoldTimer(for: id)
                continue
            }
            let currentKey = engine.touches[id]?.key.kind
            if currentKey != previousKey {
                cancelHoldTimer(for: id)
                if case .character = currentKey {
                    armAccentTimer(for: id)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            cancelHoldTimer(for: id)
            if engine.touches[id]?.key.kind == .delete { stopDeleteRepeat() }
            engine.touchEnded(id: id, at: touch.location(in: self))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            cancelHoldTimer(for: id)
            if engine.touches[id]?.key.kind == .delete { stopDeleteRepeat() }
            engine.touchCancelled(id: id)
        }
    }

    /// Called by the owner after engine changes and after each moved batch.
    func updateTrail() {
        let points = engine.swipeTrail
        guard points.count >= 2 else {
            if trailLayer.path != nil { trailLayer.path = nil }
            return
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trailLayer.path = path
        CATransaction.commit()
    }

    func cancelAllTouches() {
        touchIDs.removeAll()
        for work in holdWork.values { work.cancel() }
        holdWork.removeAll()
        stopDeleteRepeat()
        engine.cancelAllTouches()
    }

    private func armAccentTimer(for id: Int) {
        cancelHoldTimer(for: id)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdWork.removeValue(forKey: id)
                if self.engine.openAccentMenuIfEligible(forTouch: id) {
                    self.onAccentMenuOpened?()
                }
            }
        }
        holdWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FullKeyboardEngine.accentHoldDelay, execute: work)
    }

    private func armNextKeyboardTimer(for id: Int) {
        cancelHoldTimer(for: id)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdWork.removeValue(forKey: id)
                if self.engine.takeNextKeyboardHold(forTouch: id) {
                    self.onNextKeyboard?()
                }
            }
        }
        holdWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FullKeyboardEngine.nextKeyboardHoldDelay, execute: work)
    }

    private func cancelHoldTimer(for id: Int) {
        holdWork.removeValue(forKey: id)?.cancel()
    }

    private func startDeleteRepeat() {
        stopDeleteRepeat()
        deleteStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: FullKeyboardEngine.repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = CACurrentMediaTime() - self.deleteStartedAt
                guard held >= FullKeyboardEngine.repeatDelay else { return }
                self.engine.repeatDelete(heldFor: held)
                self.onKeyDown?(.delete)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
    }

    private func stopDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }
}

/// The pop-up balloon over a pressed key in portrait.
@MainActor
final class KeyCalloutView: UIView {
    var palette = FullKeyboardPalette(isDark: false)
    private var balloon: KeyBalloon?
    private var label = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ balloon: KeyBalloon?, label: String) {
        guard balloon != self.balloon || label != self.label else { return }
        self.balloon = balloon
        self.label = label
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let balloon, let context = UIGraphicsGetCurrentContext() else { return }
        let path = Self.path(for: balloon)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: palette.popupShadow.cgColor)
        context.addPath(path)
        context.setFillColor(palette.popupFill.cgColor)
        context.fillPath()
        context.restoreGState()

        let scale = max(1, traitCollection.displayScale)
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1 / scale)
        context.setStrokeColor(palette.popupBorder.cgColor)
        context.strokePath()
        context.restoreGState()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 33, weight: .light),
            .foregroundColor: palette.textBase,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: CGPoint(x: balloon.bubble.midX - size.width / 2, y: balloon.bubble.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    /// Key at the bottom, wider bubble above, joined by a smooth downward neck.
    static func path(for balloon: KeyBalloon) -> CGPath {
        if balloon.isInline {
            return UIBezierPath(roundedRect: balloon.bubble, cornerRadius: 11).cgPath
        }
        let kr = FullKeyboardPalette.cornerRadius
        let br: CGFloat = 11
        let kl = balloon.keyFrame.minX
        let krt = balloon.keyFrame.maxX
        let kb = balloon.keyFrame.maxY
        let kt = balloon.keyFrame.minY
        let bb = balloon.bubble.maxY
        let bt = balloon.bubble.minY
        let bl = balloon.bubble.minX
        let brt = balloon.bubble.maxX
        let stemTop = min(kb - kr - 2, max(kt + 6, bb + 7))

        let p = CGMutablePath()
        p.move(to: CGPoint(x: bl, y: bt + br))
        p.addQuadCurve(to: CGPoint(x: bl + br, y: bt), control: CGPoint(x: bl, y: bt))
        p.addLine(to: CGPoint(x: brt - br, y: bt))
        p.addQuadCurve(to: CGPoint(x: brt, y: bt + br), control: CGPoint(x: brt, y: bt))
        if brt - br >= krt + 2 {
            p.addLine(to: CGPoint(x: brt, y: bb - br))
            p.addQuadCurve(to: CGPoint(x: brt - br, y: bb), control: CGPoint(x: brt, y: bb))
            p.addLine(to: CGPoint(x: min(brt - br, krt + 6), y: bb))
            p.addCurve(
                to: CGPoint(x: krt, y: stemTop),
                control1: CGPoint(x: krt + 1, y: bb),
                control2: CGPoint(x: krt, y: (bb + stemTop) * 0.5)
            )
        } else {
            p.addLine(to: CGPoint(x: brt, y: bb))
            p.addLine(to: CGPoint(x: krt, y: max(kt + 4, bb + 4)))
        }
        p.addLine(to: CGPoint(x: krt, y: kb - kr))
        p.addQuadCurve(to: CGPoint(x: krt - kr, y: kb), control: CGPoint(x: krt, y: kb))
        p.addLine(to: CGPoint(x: kl + kr, y: kb))
        p.addQuadCurve(to: CGPoint(x: kl, y: kb - kr), control: CGPoint(x: kl, y: kb))
        if bl + br <= kl - 2 {
            p.addLine(to: CGPoint(x: kl, y: stemTop))
            p.addCurve(
                to: CGPoint(x: max(bl + br, kl - 6), y: bb),
                control1: CGPoint(x: kl, y: (bb + stemTop) * 0.5),
                control2: CGPoint(x: kl - 1, y: bb)
            )
            p.addLine(to: CGPoint(x: bl + br, y: bb))
            p.addQuadCurve(to: CGPoint(x: bl, y: bb - br), control: CGPoint(x: bl, y: bb))
        } else {
            p.addLine(to: CGPoint(x: kl, y: max(kt + 4, bb + 4)))
            p.addLine(to: CGPoint(x: bl, y: bb))
        }
        p.closeSubpath()
        return p
    }
}
