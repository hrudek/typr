import UIKit

/// The 3-slot top bar above the keys, matching Apple's iOS 26 suggestion strip:
/// two 1 pt vertical hairlines between the slots when idle or suggesting, replaced by
/// a status message when needed. Dictation feedback has its own panel (`TyprFeedbackPanel`).
@MainActor
final class KeyboardStripView: UIView {
    var palette = FullKeyboardPalette(isDark: false) { didSet { if palette != oldValue { applyPalette() } } }
    /// Hosted extensions sit inside iOS 26's +17 pt Liquid Glass crown above `bounds.minY`,
    /// so nudge the strip's visual centre slightly upward within `bounds` to align with Apple's bar.
    var inSystemPlatter = true {
        didSet {
            guard inSystemPlatter != oldValue else { return }
            for button in slotButtons { button.inSystemPlatter = inSystemPlatter }
            setNeedsLayout()
            setNeedsDisplay()
        }
    }
    var onSelectSuggestion: ((KeyboardSuggestion) -> Void)?
    /// Where the three slots sit; nil spreads them over the whole strip.
    var slotsFrame: CGRect? {
        didSet {
            guard slotsFrame != oldValue else { return }
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    private let statusLabel = UILabel()
    private let slotButtons: [SlotButton] = [SlotButton(), SlotButton(), SlotButton()]
    private var currentSuggestions: [KeyboardSuggestion] = []
    private var statusText: String?
    private var selection = KeyboardSuggestionSelection()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw

        statusLabel.font = .systemFont(ofSize: 13.5)
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.isHidden = true
        addSubview(statusLabel)

        for (index, button) in slotButtons.enumerated() {
            button.tag = index
            button.addTarget(self, action: #selector(handleSlotDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(handleSlotTap(_:)), for: .touchUpInside)
            button.addTarget(self, action: #selector(handleSlotCancel(_:)), for: [.touchCancel, .touchUpOutside])
            button.onAccessibilityActivate = { [weak self] in self?.activateSlot(index) ?? false }
            button.isHidden = true
            addSubview(button)
        }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(suggestions: [KeyboardSuggestion], statusText: String?) {
        guard suggestions != currentSuggestions || statusText != self.statusText else { return }
        currentSuggestions = suggestions
        if suggestions.isEmpty { selection = KeyboardSuggestionSelection() }
        self.statusText = statusText

        if let statusText, suggestions.isEmpty {
            statusLabel.text = statusText
            statusLabel.isHidden = false
            slotButtons.forEach { $0.isHidden = true }
        } else {
            statusLabel.isHidden = true
            for (idx, button) in slotButtons.enumerated() {
                if idx < suggestions.count {
                    button.configure(with: suggestions[idx], palette: palette)
                    button.isHidden = false
                } else {
                    button.isHidden = true
                }
            }
        }
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func applyPalette() {
        statusLabel.textColor = palette.textMuted
        for (idx, button) in slotButtons.enumerated() where idx < currentSuggestions.count {
            button.configure(with: currentSuggestions[idx], palette: palette)
        }
        setNeedsDisplay()
    }

    private var contentCenterY: CGFloat {
        inSystemPlatter ? bounds.height * 0.42 : bounds.height * 0.50
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let midY = contentCenterY
        statusLabel.frame = CGRect(x: 16, y: max(0, midY - 12), width: max(0, bounds.width - 32), height: 24)
        let slots = slotsRect
        let slotW = slots.width / 3
        for (idx, button) in slotButtons.enumerated() {
            button.inSystemPlatter = inSystemPlatter
            button.frame = CGRect(x: slots.minX + CGFloat(idx) * slotW, y: 0, width: slotW, height: bounds.height)
        }
    }

    private var slotsRect: CGRect {
        slotsFrame.map { CGRect(x: $0.minX, y: 0, width: $0.width, height: bounds.height) } ?? bounds
    }

    override func draw(_ rect: CGRect) {
        let slots = slotsRect
        guard statusLabel.isHidden, slots.width > 60 else { return }
        // Hide the divider adjacent to a highlighted primary pill, matching Apple's strip.
        let primaryHighlighted = currentSuggestions.count > 1 && currentSuggestions[1].willAutoReplace
        guard !primaryHighlighted else { return }

        let scale = max(1, traitCollection.displayScale)
        let hairline = 1 / scale
        // 18.5 pt dividers, as in the owner's 2026-11-11 reference.
        let lineH: CGFloat = min(18.5, bounds.height * 0.56)
        let y = max(1, contentCenterY - lineH / 2)
        let slotW = slots.width / 3

        palette.separator.setFill()
        UIRectFill(CGRect(x: (slots.minX + slotW).rounded() - hairline / 2, y: y, width: hairline, height: lineH))
        UIRectFill(CGRect(x: (slots.minX + slotW * 2).rounded() - hairline / 2, y: y, width: hairline, height: lineH))
    }

    @objc private func handleSlotDown(_ sender: SlotButton) {
        selection.begin(slot: sender.tag, suggestions: currentSuggestions)
    }

    @objc private func handleSlotTap(_ sender: SlotButton) {
        guard let suggestion = selection.finish(slot: sender.tag) else { return }
        onSelectSuggestion?(suggestion) // Engine revalidates its original token/field ownership.
    }

    @objc private func handleSlotCancel(_ sender: SlotButton) {
        selection.cancel(slot: sender.tag)
    }

    private func activateSlot(_ slot: Int) -> Bool {
        guard currentSuggestions.indices.contains(slot) else { return false }
        selection.cancel(slot: slot)
        onSelectSuggestion?(currentSuggestions[slot])
        return true
    }

    private final class SlotButton: UIControl {
        var onAccessibilityActivate: (() -> Bool)?
        var inSystemPlatter = true { didSet { if inSystemPlatter != oldValue { setNeedsDisplay() } } }
        private var suggestion: KeyboardSuggestion?
        private var palette = FullKeyboardPalette(isDark: false)

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            contentMode = .redraw
            isAccessibilityElement = true
            accessibilityTraits = .button
            addTarget(self, action: #selector(redraw), for: [.touchDown, .touchDragEnter, .touchDragExit, .touchCancel, .touchUpInside, .touchUpOutside])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isHighlighted: Bool { didSet { if isHighlighted != oldValue { setNeedsDisplay() } } }

        func configure(with suggestion: KeyboardSuggestion, palette: FullKeyboardPalette) {
            self.suggestion = suggestion
            self.palette = palette
            accessibilityLabel = suggestion.displayText
            setNeedsDisplay()
        }

        override func accessibilityActivate() -> Bool {
            onAccessibilityActivate?() ?? false
        }

        @objc private func redraw() { setNeedsDisplay() }

        override func draw(_ rect: CGRect) {
            guard let suggestion else { return }
            let midY = inSystemPlatter ? bounds.height * 0.42 : bounds.height * 0.50
            let pillH = min(26, max(22, bounds.height - 6))
            let pillInset = CGRect(
                x: 5,
                y: max(0.5, midY - pillH / 2),
                width: max(0, bounds.width - 10),
                height: pillH
            )
            if isHighlighted {
                palette.keyPressedFill.setFill()
                UIBezierPath(roundedRect: pillInset, cornerRadius: 8).fill()
            } else if suggestion.willAutoReplace {
                palette.selectFill.setFill()
                UIBezierPath(roundedRect: pillInset, cornerRadius: 8).fill()
            }

            let isLiteral = suggestion.kind == .keepLiteral
            let font = UIFont.systemFont(
                ofSize: 15.5,
                weight: suggestion.willAutoReplace ? .medium : .regular
            )
            let ink = isLiteral && !suggestion.willAutoReplace ? palette.textBase.withAlphaComponent(0.88) : palette.textBase
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
            ]
            let maxTextW = max(20, pillInset.width - 12)
            var drawString = suggestion.displayText
            var size = (drawString as NSString).size(withAttributes: attributes)
            if size.width > maxTextW {
                let smallAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13.5, weight: suggestion.willAutoReplace ? .medium : .regular),
                    .foregroundColor: ink,
                ]
                size = (drawString as NSString).size(withAttributes: smallAttrs)
                let drawRect = CGRect(
                    x: bounds.midX - min(maxTextW, size.width) / 2,
                    y: midY - size.height / 2,
                    width: min(maxTextW, size.width),
                    height: size.height
                )
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                style.alignment = .center
                var truncatedAttrs = smallAttrs
                truncatedAttrs[.paragraphStyle] = style
                (drawString as NSString).draw(in: drawRect, withAttributes: truncatedAttrs)
                return
            }
            drawString = suggestion.displayText
            (drawString as NSString).draw(
                at: CGPoint(x: bounds.midX - size.width / 2, y: midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}
