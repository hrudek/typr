import CoreGraphics

nonisolated enum KeyboardLayer: Equatable, Hashable, Sendable {
    case letters
    case numbers
    case symbols
}

/// The kind of text field, as far as the key rows care.
nonisolated enum KeyboardFieldKind: Equatable, Sendable {
    case text
    /// Adds `.` and `/` right of space.
    case url
    /// Adds `@` and `.` right of space, matching Apple's iOS 26 email layout.
    case email
}

nonisolated enum KeyboardOrientation: Equatable, Sendable {
    case portrait
    case landscape
}

/// The bottom row's globe where iOS needs one: a key that switches keyboards, an inert spacer
/// left of 123, or nothing. As a spacer or hidden, holding the 123/ABC key switches keyboards.
nonisolated enum GlobeKey: String, CaseIterable, Sendable {
    case switches
    case spacer
    case hidden
}

nonisolated enum KeyKind: Equatable, Hashable, Sendable {
    /// Inserts its text (letters are stored lowercase; shift decides the case).
    case character(String)
    case shift
    case layerSwitch(KeyboardLayer)
    case delete
    case space
    case returnKey
    case typr
    case globe
    /// Settings' globe spacer: drawn dimmed, does nothing when tapped.
    case globeSpacer
}

nonisolated struct KeyboardKey: Equatable, Sendable {
    let kind: KeyKind
    let row: Int
    /// The drawn keycap.
    let frame: CGRect
    /// The touch target. Hit frames tile the whole key area with no gaps.
    var hitFrame: CGRect
    let label: String

    var character: String? {
        if case .character(let text) = kind { return text }
        return nil
    }
}

/// The pop-up balloon over a pressed key: a wider bubble joined to the key by a neck.
nonisolated struct KeyBalloon: Equatable, Sendable {
    static let bubbleHeight: CGFloat = 46
    static let neck: CGFloat = 8
    static let extraWidth: CGFloat = 20

    /// How far an in-place balloon reaches above its key.
    static let inlineLift: CGFloat = 8

    let keyFrame: CGRect
    let bubble: CGRect

    /// Bubble centre minus key centre; nonzero when an edge key's bubble is pushed inward.
    var offsetX: CGFloat { bubble.midX - keyFrame.midX }
    /// No room above the key (top row without the suggestion bar): the bubble is a widened key in place.
    var isInline: Bool { bubble.maxY >= keyFrame.maxY }
    /// The balloon's whole outline, bubble through key.
    var bounds: CGRect { bubble.union(keyFrame) }
}

nonisolated struct KeyboardMetrics: Equatable, Sendable {
    let side: CGFloat
    let gap: CGFloat
    let rowGap: CGFloat
    let keyHeight: CGFloat
    let stripTop: CGFloat
    let stripHeight: CGFloat
    let stripBottom: CGFloat
    let keysTop: CGFloat
    let keysBottom: CGFloat
    let cornerRadius: CGFloat

    /// Matches iOS 26 portrait keyboard geometry inside the system's +17 pt Liquid Glass crown:
    /// 35 pt strip area + 218 pt of keys (4 × 45 pt + 3 × 11 pt + 5 pt) = 253 pt extension height.
    static let portrait = KeyboardMetrics(
        side: 6.5, gap: 6, rowGap: 11, keyHeight: 45,
        stripTop: 0, stripHeight: 33, stripBottom: 2,
        keysTop: 0, keysBottom: 5, cornerRadius: 8.5
    )

    /// Matches iOS 26 landscape keyboard geometry inside the system's +10 pt Liquid Glass crown:
    /// 39 pt strip area + 137 pt of keys (4 × 27.5 pt + 3 × 8 pt + 3 pt) = 176 pt extension height.
    static let landscape = KeyboardMetrics(
        side: 4, gap: 6, rowGap: 8, keyHeight: 27.5,
        stripTop: 0, stripHeight: 33, stripBottom: 6,
        keysTop: 0, keysBottom: 3, cornerRadius: 7.5
    )

    /// Height of a panel's header row (recording, feedback), with or without the suggestion bar.
    static let headerHeight: CGFloat = 33

    /// Typr: `showsStrip: false` drops the suggestion bar; the keys move up to a small top margin.
    static func `for`(
        _ orientation: KeyboardOrientation,
        innerWidth: CGFloat? = nil,
        showsStrip: Bool = true
    ) -> KeyboardMetrics {
        let metrics = withStrip(orientation, innerWidth: innerWidth)
        return showsStrip ? metrics : metrics.withoutStrip(orientation)
    }

    private func withoutStrip(_ orientation: KeyboardOrientation) -> KeyboardMetrics {
        KeyboardMetrics(
            side: side, gap: gap, rowGap: rowGap, keyHeight: keyHeight,
            stripTop: 0, stripHeight: 0, stripBottom: 0,
            keysTop: orientation == .portrait ? 6 : 4, keysBottom: keysBottom, cornerRadius: cornerRadius
        )
    }

    private static func withStrip(_ orientation: KeyboardOrientation, innerWidth: CGFloat?) -> KeyboardMetrics {
        guard orientation == .portrait else { return .landscape }
        guard let innerWidth else { return .portrait }
        let side: CGFloat = if innerWidth >= 390 {
            6.5
        } else if innerWidth >= 370 {
            4.5
        } else {
            3.0
        }
        if side == KeyboardMetrics.portrait.side { return .portrait }
        return KeyboardMetrics(
            side: side,
            gap: KeyboardMetrics.portrait.gap,
            rowGap: KeyboardMetrics.portrait.rowGap,
            keyHeight: KeyboardMetrics.portrait.keyHeight,
            stripTop: KeyboardMetrics.portrait.stripTop,
            stripHeight: KeyboardMetrics.portrait.stripHeight,
            stripBottom: KeyboardMetrics.portrait.stripBottom,
            keysTop: KeyboardMetrics.portrait.keysTop,
            keysBottom: KeyboardMetrics.portrait.keysBottom,
            cornerRadius: KeyboardMetrics.portrait.cornerRadius
        )
    }

    var stripArea: CGFloat { stripTop + stripHeight + stripBottom }
    var keysArea: CGFloat { keysTop + 4 * keyHeight + 3 * rowGap + keysBottom }
    var totalHeight: CGFloat { stripArea + keysArea }
}

/// Pure geometry of the full keyboard: every key's frame and touch target for one width,
/// layer and field kind. Coordinates are in the keyboard view, strip included.
nonisolated struct KeyboardLayout: Equatable, Sendable {
    /// Matches Apple's 50 pt shift/delete beside 37.3 pt letters on 440 pt Pro Max (`50 / 37.3 = 1.34`).
    static let modifierWidthRatio: CGFloat = 1.34
    static let bottomSwitchWidthRatio: CGFloat = 1.56
    static let returnWidthRatio: CGFloat = 2.40
    static let compactReturnWidthRatio: CGFloat = 2.18

    let width: CGFloat
    let orientation: KeyboardOrientation
    let layer: KeyboardLayer
    let field: KeyboardFieldKind
    let showsGlobe: Bool
    let globeKey: GlobeKey
    let horizontalInset: CGFloat
    /// Typr: whether the suggestion bar sits above the keys.
    let showsStrip: Bool
    let metrics: KeyboardMetrics
    let keys: [KeyboardKey]

    init(
        width: CGFloat,
        orientation: KeyboardOrientation = .portrait,
        layer: KeyboardLayer = .letters,
        field: KeyboardFieldKind = .text,
        showsGlobe: Bool = false,
        globeKey: GlobeKey = .switches,
        horizontalInset: CGFloat = 0,
        showsStrip: Bool = true
    ) {
        self.width = width
        self.orientation = orientation
        self.layer = layer
        self.field = field
        self.showsGlobe = showsGlobe
        self.globeKey = globeKey
        self.horizontalInset = max(0, horizontalInset)
        self.showsStrip = showsStrip
        let innerWidth = width - 2 * self.horizontalInset
        let metrics = KeyboardMetrics.for(orientation, innerWidth: innerWidth, showsStrip: showsStrip)
        self.metrics = metrics
        self.keys = Self.buildKeys(
            width: width,
            metrics: metrics,
            layer: layer,
            field: field,
            globe: showsGlobe ? globeKey : .hidden,
            inset: self.horizontalInset
        )
    }

    static func height(for orientation: KeyboardOrientation, showsStrip: Bool = true) -> CGFloat {
        KeyboardMetrics.for(orientation, showsStrip: showsStrip).totalHeight
    }

    var totalHeight: CGFloat { metrics.totalHeight }

    /// Where the suggestion strip sits (zero height when hidden).
    var stripFrame: CGRect {
        CGRect(x: horizontalInset, y: metrics.stripTop, width: width - 2 * horizontalInset, height: metrics.stripHeight)
    }

    var keysAreaFrame: CGRect {
        CGRect(x: 0, y: metrics.stripArea, width: width, height: metrics.keysArea)
    }

    var letterWidth: CGFloat {
        Self.letterWidth(innerWidth: width - 2 * horizontalInset, metrics: metrics)
    }

    var showsBalloons: Bool { orientation == .portrait }

    /// iOS needs a way to the next keyboard and the globe key does not switch: holding 123/ABC does.
    var layerKeyHoldSwitchesKeyboard: Bool { showsGlobe && globeKey != .switches }

    func key(_ kind: KeyKind) -> KeyboardKey? {
        keys.first { $0.kind == kind }
    }

    func hitTest(_ point: CGPoint) -> KeyboardKey? {
        keys.first { $0.hitFrame.contains(point) }
    }

    /// The balloon for a character key, kept inside the keyboard's bounds. `nil` for keys
    /// without one (space, modifiers) and in landscape, where there is no room above row 1.
    func balloon(for key: KeyboardKey) -> KeyBalloon? {
        guard showsBalloons, key.character != nil else { return nil }
        let bubbleWidth = key.frame.width + KeyBalloon.extraWidth
        let raisedY = key.frame.minY - KeyBalloon.neck - KeyBalloon.bubbleHeight
        let minX = max(0, horizontalInset + 2)
        let maxX = max(minX, width - horizontalInset - 2 - bubbleWidth)
        var x = key.frame.midX - bubbleWidth / 2
        x = max(minX, min(maxX, x))
        // Typr: without the suggestion bar the top row has no room above it; widen the key in place.
        if raisedY < -KeyBalloon.bubbleHeight / 2 {
            let top = max(0, key.frame.minY - KeyBalloon.inlineLift)
            return KeyBalloon(
                keyFrame: key.frame,
                bubble: CGRect(x: x, y: top, width: bubbleWidth, height: key.frame.maxY - top)
            )
        }
        let bubble = CGRect(
            x: x,
            y: max(0, raisedY),
            width: bubbleWidth,
            height: KeyBalloon.bubbleHeight
        )
        return KeyBalloon(keyFrame: key.frame, bubble: bubble)
    }

    // MARK: - Building

    static func letterWidth(innerWidth: CGFloat, metrics: KeyboardMetrics) -> CGFloat {
        (innerWidth - 2 * metrics.side - 9 * metrics.gap) / 10
    }

    static func characterRows(for layer: KeyboardLayer) -> [[String]] {
        let punctuation = [".", ",", "?", "!", "'"]
        switch layer {
        case .letters:
            return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
        case .numbers:
            return [
                "1234567890".map(String.init),
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
                punctuation,
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                punctuation,
            ]
        }
    }

    private static func buildKeys(
        width: CGFloat,
        metrics m: KeyboardMetrics,
        layer: KeyboardLayer,
        field: KeyboardFieldKind,
        globe: GlobeKey,
        inset: CGFloat
    ) -> [KeyboardKey] {
        let innerWidth = width - 2 * inset
        let lw = letterWidth(innerWidth: innerWidth, metrics: m)
        let modW = lw * modifierWidthRatio
        let rows = characterRows(for: layer)
        let left = inset + m.side
        let right = width - inset - m.side

        func rowY(_ row: Int) -> CGFloat {
            m.stripArea + m.keysTop + CGFloat(row) * (m.keyHeight + m.rowGap)
        }

        var drawn: [(KeyKind, Int, CGRect, String)] = []

        func add(_ kind: KeyKind, row: Int, x: CGFloat, w: CGFloat, label: String) {
            drawn.append((kind, row, CGRect(x: x, y: rowY(row), width: w, height: m.keyHeight), label))
        }

        func addCharacters(_ chars: [String], row: Int, startX: CGFloat, keyWidth: CGFloat) {
            var x = startX
            for ch in chars {
                add(.character(ch), row: row, x: x, w: keyWidth, label: ch)
                x += keyWidth + m.gap
            }
        }

        func centredStart(count: Int, keyWidth: CGFloat) -> CGFloat {
            let total = CGFloat(count) * keyWidth + CGFloat(count - 1) * m.gap
            return inset + (innerWidth - total) / 2
        }

        // Rows 1 and 2.
        for row in 0..<2 {
            let chars = rows[row]
            addCharacters(chars, row: row, startX: centredStart(count: chars.count, keyWidth: lw), keyWidth: lw)
        }

        // Row 3: shift (or the symbol-page switch), the middle keys, delete.
        switch layer {
        case .letters:
            add(.shift, row: 2, x: left, w: modW, label: "shift")
        case .numbers:
            add(.layerSwitch(.symbols), row: 2, x: left, w: modW, label: "#+=")
        case .symbols:
            add(.layerSwitch(.numbers), row: 2, x: left, w: modW, label: "123")
        }
        let middle = rows[2]
        if layer == .letters {
            addCharacters(middle, row: 2, startX: centredStart(count: middle.count, keyWidth: lw), keyWidth: lw)
        } else {
            // Apple's punctuation row: five wide keys aligned to the s..k columns between modifiers.
            let edgeGap = 1.5 * (lw + m.gap) - modW
            let count = CGFloat(middle.count)
            let middleW = (innerWidth - 2 * m.side - 2 * modW - 2 * edgeGap - (count - 1) * m.gap) / count
            addCharacters(middle, row: 2, startX: left + modW + edgeGap, keyWidth: middleW)
        }
        add(.delete, row: 2, x: right - modW, w: modW, label: "delete")

        let isCompactBottomRow = globe != .hidden || field != .text
        let switchW = isCompactBottomRow ? modW : lw * bottomSwitchWidthRatio
        let returnW = isCompactBottomRow ? (lw * compactReturnWidthRatio) : (lw * returnWidthRatio + m.gap)
        var leading: [(KeyKind, CGFloat, String)] = [
            layer == .letters
                ? (.layerSwitch(.numbers), switchW, "123")
                : (.layerSwitch(.letters), switchW, "ABC"),
        ]
        switch globe {
        case .switches: leading.append((.globe, modW, "globe"))
        case .spacer: leading.insert((.globeSpacer, modW, "globe"), at: 0)
        case .hidden: break
        }
        var trailing: [(KeyKind, CGFloat, String)] = []
        switch field {
        case .text:
            break
        case .url:
            trailing.append((.character("."), lw, "."))
            trailing.append((.character("/"), lw, "/"))
        case .email:
            trailing.append((.character("@"), lw, "@"))
            trailing.append((.character("."), lw, "."))
        }
        trailing.append((.typr, modW, "typr"))
        trailing.append((.returnKey, returnW, "return"))

        let fixed = (leading + trailing).reduce(0) { $0 + $1.1 }
        let itemCount = CGFloat(leading.count + trailing.count + 1)
        let spaceW = max(lw, (right - left) - fixed - (itemCount - 1) * m.gap)
        var x = left
        for (kind, w, label) in leading {
            add(kind, row: 3, x: x, w: w, label: label)
            x += w + m.gap
        }
        add(.space, row: 3, x: x, w: spaceW, label: "space")
        x += spaceW + m.gap
        for (kind, w, label) in trailing {
            add(kind, row: 3, x: x, w: w, label: label)
            x += w + m.gap
        }

        // Touch targets: split every gap down the middle; outer keys reach the edges.
        let top = m.stripArea
        let bottom = m.totalHeight
        var keys: [KeyboardKey] = []
        for row in 0..<4 {
            let rowKeys = drawn.filter { $0.1 == row }.sorted { $0.2.minX < $1.2.minX }
            let y0 = row == 0 ? top : rowY(row) - m.rowGap / 2
            let y1 = row == 3 ? bottom : rowY(row + 1) - m.rowGap / 2
            for (i, item) in rowKeys.enumerated() {
                let x0 = i == 0 ? 0 : (rowKeys[i - 1].2.maxX + item.2.minX) / 2
                let x1 = i == rowKeys.count - 1 ? width : (item.2.maxX + rowKeys[i + 1].2.minX) / 2
                keys.append(KeyboardKey(
                    kind: item.0,
                    row: row,
                    frame: item.2,
                    hitFrame: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0),
                    label: item.3
                ))
            }
        }
        return keys
    }
}
