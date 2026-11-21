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

/// Which keyboard geometry a display gets, picked by `init(container:)` from its size alone.
nonisolated enum KeyboardOrientation: String, Equatable, Sendable {
    case portrait
    case landscape
    /// A display at least `wideShortSide` across held upright: the iPhone Duo's inner display, 669 × 951 pt.
    case widePortrait
    /// The same display sideways, 951 × 669 pt.
    case wideLandscape
    /// `wideLandscape` with Settings › Appearance › Split keyboard on: two halves at the edges, the fold between them.
    case splitLandscape

    /// iPhones are at most 440 pt across and the iPhone Duo's outer display 466 pt; its inner display is 669 pt.
    static let wideShortSide: CGFloat = 540

    /// The geometry for a display (or a page standing in for one) of this size. Size only, never the device
    /// model, idiom or interface orientation: iOS gives keyboard extensions no hinge state, and Apple's own
    /// keyboard lays out a half-open iPhone Duo like an open one. `split` is the Split keyboard setting, which only
    /// the open iPhone Duo held sideways follows.
    init(container: CGSize, split: Bool = false) {
        let isLandscape = container.width > container.height
        let isWide = min(container.width, container.height) >= Self.wideShortSide
        let full: KeyboardOrientation = switch (isWide, isLandscape) {
        case (false, false): .portrait
        case (false, true): .landscape
        case (true, false): .widePortrait
        case (true, true): .wideLandscape
        }
        self = split && full.allowsSplit ? .splitLandscape : full
    }

    var isLandscape: Bool { self == .landscape || self == .wideLandscape || self == .splitLandscape }

    /// Only the iPhone Duo open and sideways offers Apple's split keyboard.
    var allowsSplit: Bool { self == .wideLandscape }

    var glyphs: KeyGlyphSizes {
        switch self {
        case .portrait: .portrait
        case .landscape: .landscape
        case .widePortrait: .widePortrait
        case .wideLandscape, .splitLandscape: .wideLandscape
        }
    }
}

/// Point sizes of what the keys show, before the mechanical design's 0.93.
nonisolated struct KeyGlyphSizes: Equatable, Sendable {
    let letter: CGFloat
    let capital: CGFloat
    /// Punctuation on a key wider than a letter.
    let widePunctuation: CGFloat
    /// How far lowercase letters and punctuation sit above the key's centre.
    let letterLift: CGFloat
    /// Shift, delete and globe.
    let symbol: CGFloat
    let returnSymbol: CGFloat
    /// Worded keys: 123, ABC, return.
    let label: CGFloat
    let balloonLetter: CGFloat

    static let portrait = KeyGlyphSizes(
        letter: 22.5, capital: 21, widePunctuation: 21, letterLift: 1,
        symbol: 18, returnSymbol: 17.5, label: 15.5, balloonLetter: 33
    )

    static let landscape = KeyGlyphSizes(
        letter: 19, capital: 18, widePunctuation: 19, letterLift: 0.5,
        symbol: 16, returnSymbol: 15.5, label: 14.5, balloonLetter: 33
    )

    /// Apple's letters on the inner display are 28 pt upright and 28.5 pt sideways against 23 pt on other iPhones
    /// (iikb docs/design.md, measured in the iOS 27.1 simulator); Typr keeps its 0.5 pt under Apple's and grows the
    /// rest by the same share. The balloon keeps its 46 pt bubble, so its letter grows only as far as that holds.
    static let widePortrait = KeyGlyphSizes(
        letter: 27.5, capital: 25.5, widePunctuation: 25.5, letterLift: 1,
        symbol: 22, returnSymbol: 21.5, label: 19, balloonLetter: 36
    )

    static let wideLandscape = KeyGlyphSizes(
        letter: 28, capital: 26, widePunctuation: 26, letterLift: 1,
        symbol: 22, returnSymbol: 21.5, label: 19, balloonLetter: 36
    )
}

/// The bottom row's globe where iOS needs one: a key that switches keyboards, an inert spacer
/// left of 123, or nothing. As a spacer or hidden, holding the 123/ABC key switches keyboards.
nonisolated enum GlobeKey: String, CaseIterable, Sendable {
    case switches
    case spacer
    case hidden
}

// `arranged` adapted from AVGVSTVS96/iikb
// Packages/KeyboardModules/Sources/KeyboardCore/Typing/CustomKeys.swift (MIT).
/// A key beside the space bar, space among them, in the order Settings › Bottom row arranges.
nonisolated enum BottomKey: String, CaseIterable, Sendable {
    case space
    case period
    case typr

    static let standard: [BottomKey] = [.space, .period, .typr]

    /// `order` with each key once, any missing put where `standard` has them.
    static func arranged(_ order: [BottomKey]) -> [BottomKey] {
        var seen = Set<BottomKey>()
        var keys = order.filter { seen.insert($0).inserted }
        for key in standard where !seen.contains(key) {
            let after = standard.prefix { $0 != key }.last { keys.contains($0) }
            keys.insert(key, at: after.flatMap { keys.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        return keys
    }
}

/// Settings › Bottom row: the keys' order around space, and whether the period key shows.
nonisolated struct BottomRow: Equatable, Sendable {
    var order = BottomKey.standard
    var periodKey = false
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
    /// The number row's key height; zero without one.
    var numberRowHeight: CGFloat = 0
    /// The room between the halves of the split keyboard; zero for one board.
    var splitGap: CGFloat = 0

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

    /// The iPhone Duo's inner display upright, after Apple's keyboard there (18 pt in, keys 9 apart, rows 14 apart,
    /// keys 45.67 pt tall; iikb docs/design.md): 35 + 4 × 46 + 3 × 14 + 5 = 266 pt, 28% of the display's 951 pt.
    static let widePortrait = KeyboardMetrics(
        side: 18, gap: 9, rowGap: 14, keyHeight: 46,
        stripTop: 0, stripHeight: 33, stripBottom: 2,
        keysTop: 0, keysBottom: 5, cornerRadius: 8.5
    )

    /// The inner display sideways, after Apple's (9 pt in, keys 10 apart, rows 13 apart, keys 38.67 pt tall):
    /// 39 + 4 × 39 + 3 × 13 + 4 = 238 pt, 36% of the display's 669 pt.
    static let wideLandscape = KeyboardMetrics(
        side: 9, gap: 10, rowGap: 13, keyHeight: 39,
        stripTop: 0, stripHeight: 33, stripBottom: 6,
        keysTop: 0, keysBottom: 4, cornerRadius: 8.5
    )

    /// The widest letter key on the inner display. iPhone letters are 31–38 pt and an 11-inch iPad's about 54 pt;
    /// wider keyboards widen the side insets instead, so the keys stay centred and in thumb reach.
    static let maxWideLetterWidth: CGFloat = 58

    /// How much of the keyboard's width each split half may take, so a thumb reaches across it.
    static let splitHalfShare: CGFloat = 0.4
    /// Split letters are never narrower than the outer display's (39.9 pt across 466 pt).
    static let minSplitLetterWidth: CGFloat = 40

    /// The inner display sideways, split: `wideLandscape`'s rows at the phone's key gap, the keys as wide as 6.5 key
    /// pitches per half allow within `splitHalfShare`, the rest the gap between halves.
    private static func splitLandscape(innerWidth: CGFloat?) -> KeyboardMetrics {
        var metrics = KeyboardMetrics(
            side: 9, gap: 6, rowGap: 13, keyHeight: 39,
            stripTop: 0, stripHeight: 33, stripBottom: 6,
            keysTop: 0, keysBottom: 4, cornerRadius: 8.5
        )
        guard let innerWidth else { return metrics }
        let pitch = (splitHalfShare * innerWidth - metrics.side + metrics.gap) / 6.5
        let letter = min(maxWideLetterWidth, max(minSplitLetterWidth, pitch - metrics.gap))
        metrics.splitGap = max(0, innerWidth - 10 * letter - 9 * metrics.gap - 2 * metrics.side)
        return metrics
    }

    /// Height of a panel's header row (recording, feedback), with or without the suggestion bar.
    static let headerHeight: CGFloat = 33

    /// Typr: `showsStrip: false` drops the suggestion bar; the keys move up to a small top margin.
    /// `numberRow` adds a row of short keys, 0.8 of a key high like iikb's, above the letters.
    static func `for`(
        _ orientation: KeyboardOrientation,
        innerWidth: CGFloat? = nil,
        showsStrip: Bool = true,
        numberRow: Bool = false
    ) -> KeyboardMetrics {
        var metrics = withStrip(orientation, innerWidth: innerWidth)
        if !showsStrip { metrics = metrics.withoutStrip(orientation) }
        if numberRow { metrics.numberRowHeight = (metrics.keyHeight * 0.8).rounded() }
        return metrics
    }

    private func withoutStrip(_ orientation: KeyboardOrientation) -> KeyboardMetrics {
        KeyboardMetrics(
            side: side, gap: gap, rowGap: rowGap, keyHeight: keyHeight,
            stripTop: 0, stripHeight: 0, stripBottom: 0,
            keysTop: orientation.isLandscape ? 4 : 6, keysBottom: keysBottom, cornerRadius: cornerRadius,
            splitGap: splitGap
        )
    }

    private static func withStrip(_ orientation: KeyboardOrientation, innerWidth: CGFloat?) -> KeyboardMetrics {
        switch orientation {
        case .landscape:
            return .landscape
        case .widePortrait:
            return KeyboardMetrics.widePortrait.centringLetters(in: innerWidth)
        case .wideLandscape:
            return KeyboardMetrics.wideLandscape.centringLetters(in: innerWidth)
        case .splitLandscape:
            return splitLandscape(innerWidth: innerWidth)
        case .portrait:
            guard let innerWidth else { return .portrait }
            let side: CGFloat = if innerWidth >= 390 {
                6.5
            } else if innerWidth >= 370 {
                4.5
            } else {
                3.0
            }
            return KeyboardMetrics.portrait.with(side: side)
        }
    }

    /// Side insets that keep letter keys at most `maxWideLetterWidth` wide across `innerWidth`.
    private func centringLetters(in innerWidth: CGFloat?) -> KeyboardMetrics {
        guard let innerWidth else { return self }
        let centred = (innerWidth - 10 * Self.maxWideLetterWidth - 9 * gap) / 2
        return with(side: max(side, centred))
    }

    private func with(side: CGFloat) -> KeyboardMetrics {
        KeyboardMetrics(
            side: side, gap: gap, rowGap: rowGap, keyHeight: keyHeight,
            stripTop: stripTop, stripHeight: stripHeight, stripBottom: stripBottom,
            keysTop: keysTop, keysBottom: keysBottom, cornerRadius: cornerRadius,
            numberRowHeight: numberRowHeight, splitGap: splitGap
        )
    }

    var stripArea: CGFloat { stripTop + stripHeight + stripBottom }
    /// The number row and the gap below it; zero without one.
    var numberRowArea: CGFloat { numberRowHeight > 0 ? numberRowHeight + rowGap : 0 }
    var keysArea: CGFloat { keysTop + numberRowArea + 4 * keyHeight + 3 * rowGap + keysBottom }
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
    let bottomRow: BottomRow
    /// Settings › Number row: 1 to 0 above the letters. The other pages keep four taller rows.
    let numberRow: Bool
    /// Settings › Aligned columns: the split letters in straight columns. Always false off `.splitLandscape`.
    let splitColumns: Bool
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
        bottomRow: BottomRow = BottomRow(),
        numberRow: Bool = false,
        splitColumns: Bool = false,
        horizontalInset: CGFloat = 0,
        showsStrip: Bool = true
    ) {
        self.width = width
        self.orientation = orientation
        self.layer = layer
        self.field = field
        self.showsGlobe = showsGlobe
        self.globeKey = globeKey
        self.bottomRow = bottomRow
        self.numberRow = numberRow
        self.splitColumns = splitColumns && orientation == .splitLandscape
        self.horizontalInset = max(0, horizontalInset)
        self.showsStrip = showsStrip
        let innerWidth = width - 2 * self.horizontalInset
        let metrics = KeyboardMetrics.for(orientation, innerWidth: innerWidth, showsStrip: showsStrip, numberRow: numberRow)
        self.metrics = metrics
        self.keys = Self.buildKeys(
            width: width,
            metrics: metrics,
            layer: layer,
            field: field,
            globe: showsGlobe ? globeKey : .hidden,
            aroundSpace: BottomKey.arranged(bottomRow.order).filter {
                $0 != .period || Self.showsPeriodKey(bottomRow, layer: layer, field: field)
            },
            inset: self.horizontalInset,
            splitColumns: self.splitColumns
        )
    }

    private static func showsPeriodKey(_ bottomRow: BottomRow, layer: KeyboardLayer, field: KeyboardFieldKind) -> Bool {
        bottomRow.periodKey && layer == .letters && field == .text
    }

    /// The bottom row's period key, whose hold offers more punctuation.
    func isPeriodKey(_ key: KeyboardKey) -> Bool {
        Self.showsPeriodKey(bottomRow, layer: layer, field: field) && key.row == bottomRowIndex && key.kind == .character(".")
    }

    /// The row of space and return: 4 below the number row, else 3.
    var bottomRowIndex: Int { showsNumberRow ? 4 : 3 }

    var showsNumberRow: Bool { numberRow && layer == .letters }

    static func height(for orientation: KeyboardOrientation, showsStrip: Bool = true, numberRow: Bool = false) -> CGFloat {
        KeyboardMetrics.for(orientation, showsStrip: showsStrip, numberRow: numberRow).totalHeight
    }

    var totalHeight: CGFloat { metrics.totalHeight }

    /// Where the suggestion strip sits (zero height when hidden).
    var stripFrame: CGRect {
        CGRect(x: horizontalInset, y: metrics.stripTop, width: width - 2 * horizontalInset, height: metrics.stripHeight)
    }

    /// Where the three suggestions sit, in the strip's coordinates: over the split letters' right half (its letter
    /// rows and delete, on every page), so the right thumb and eye stay there; else the whole strip.
    var suggestionSlotsFrame: CGRect {
        let strip = CGRect(origin: .zero, size: stripFrame.size)
        guard metrics.splitGap > 0 else { return strip }
        let letters = layer == .letters ? self : KeyboardLayout(
            width: width, orientation: orientation, field: field, showsGlobe: showsGlobe, globeKey: globeKey,
            bottomRow: bottomRow, numberRow: numberRow, splitColumns: splitColumns,
            horizontalInset: horizontalInset, showsStrip: showsStrip
        )
        let firstLetterRow = letters.showsNumberRow ? 1 : 0
        let right = letters.keys
            .filter { (firstLetterRow..<letters.bottomRowIndex).contains($0.row) && $0.frame.midX > width / 2 }
            .map(\.frame)
        guard let minX = right.map(\.minX).min(), let maxX = right.map(\.maxX).max() else { return strip }
        return CGRect(x: minX - horizontalInset, y: 0, width: maxX - minX, height: strip.height)
    }

    var keysAreaFrame: CGRect {
        CGRect(x: 0, y: metrics.stripArea, width: width, height: metrics.keysArea)
    }

    var letterWidth: CGFloat {
        Self.letterWidth(innerWidth: width - 2 * horizontalInset, metrics: metrics)
    }

    var showsBalloons: Bool { !orientation.isLandscape }

    /// iOS needs a way to the next keyboard and the globe key does not switch: holding 123/ABC does.
    var layerKeyHoldSwitchesKeyboard: Bool { showsGlobe && globeKey != .switches }

    func key(_ kind: KeyKind) -> KeyboardKey? {
        keys.first { $0.kind == kind }
    }

    /// The copy of `kind` closest to `point`: the split letters have g and v on both halves.
    func key(_ kind: KeyKind, nearest point: CGPoint) -> KeyboardKey? {
        keys.filter { $0.kind == kind }.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }
    }

    func hitTest(_ point: CGPoint) -> KeyboardKey? {
        keys.first { $0.hitFrame.contains(point) }
    }

    /// iikb KeyGrid.reaches (73c2ed9016b802e5bf017a2d595d037d1e748ccf, MIT © 2026 Bassim Shahidy).
    func reaches(_ point: CGPoint, letter: String) -> Bool {
        guard let key = key(.character(letter), nearest: point) else { return false }
        let cell = key.frame.insetBy(dx: -metrics.gap / 2, dy: -metrics.rowGap / 2)
        let dx = max(cell.minX - point.x, 0, point.x - cell.maxX)
        let dy = max(cell.minY - point.y, 0, point.y - cell.maxY)
        return dx <= cell.width / 4 && dy <= cell.height / 4
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
        (innerWidth - metrics.splitGap - 2 * metrics.side - 9 * metrics.gap) / 10
    }

    /// Apple's split keyboard, left half then right half: the rows and where each starts, in key pitches from the half's
    /// first column. The letters repeat g and v, staggered so z sits under s and the right v under g; aligned columns put
    /// shift under a and delete under l. The other pages end in `splitPunctuation`.
    static func splitHalves(_ layer: KeyboardLayer, aligned: Bool) -> [(rows: [[String]], offsets: [CGFloat])] {
        func rows(_ rows: String...) -> [[String]] { rows.map { $0.map(String.init) } }
        switch layer {
        case .letters:
            return [(rows("qwert", "asdfg", "zxcv"), aligned ? [0, 0, 1] : [0, 0.5, 1.5]),
                    (rows("yuiop", "ghjkl", "vbnm"), aligned ? [0, 0, 0] : [0, -0.5, -0.5])]
        case .numbers:
            return [(rows("12345", "-/:;("), [0, 0]), (rows("67890", ")€&@\""), [0, 0])]
        case .symbols:
            return [(rows("[]{}#", "_\\|~<"), [0, 0]), (rows("%^*+=", ">$£¥•"), [0, 0])]
        }
    }

    /// The split numbers and symbols pages' last row: three wide keys per half across four key pitches, from z's column
    /// to a gap past g and from a gap before the right g to m's end; "?" on both halves.
    static let splitPunctuation = [[".", ",", "?"], ["?", "!", "'"]]

    static let numberRowCharacters = "1234567890".map(String.init)

    static func characterRows(for layer: KeyboardLayer) -> [[String]] {
        let punctuation = [".", ",", "?", "!", "'"]
        switch layer {
        case .letters:
            return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
        case .numbers:
            return [
                numberRowCharacters,
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
        aroundSpace: [BottomKey],
        inset: CGFloat,
        splitColumns: Bool
    ) -> [KeyboardKey] {
        let lw = letterWidth(innerWidth: width - 2 * inset, metrics: m)
        let boardWidth = width - 2 * inset - m.splitGap
        let modW = lw * modifierWidthRatio
        let rows = characterRows(for: layer)
        let left = inset + m.side
        let right = width - inset - m.side
        let showsNumberRow = layer == .letters && m.numberRowHeight > 0
        let keyHeight = showsNumberRow ? m.keyHeight : m.keyHeight + m.numberRowArea / 4
        let firstRow = showsNumberRow ? 1 : 0
        let shiftRow = firstRow + 2
        let spaceRow = firstRow + 3

        func rowY(_ row: Int) -> CGFloat {
            let top = m.stripArea + m.keysTop
            guard row >= firstRow else { return top }
            return top + (showsNumberRow ? m.numberRowArea : 0) + CGFloat(row - firstRow) * (keyHeight + m.rowGap)
        }

        func rowHeight(_ row: Int) -> CGFloat {
            row < firstRow ? m.numberRowHeight : keyHeight
        }

        var drawn: [(KeyKind, Int, CGRect, String)] = []

        func add(_ kind: KeyKind, row: Int, x: CGFloat, w: CGFloat, label: String) {
            drawn.append((kind, row, CGRect(x: x, y: rowY(row), width: w, height: rowHeight(row)), label))
        }

        func addCharacters(_ chars: [String], row: Int, startX: CGFloat, keyWidth: CGFloat) {
            var x = startX
            for (index, ch) in chars.enumerated() {
                let shift = index < 5 ? 0 : m.splitGap
                add(.character(ch), row: row, x: x + shift, w: keyWidth, label: ch)
                x += keyWidth + m.gap
            }
        }

        func centredStart(count: Int, keyWidth: CGFloat) -> CGFloat {
            let total = CGFloat(count) * keyWidth + CGFloat(count - 1) * m.gap
            return inset + (boardWidth - total) / 2
        }

        if showsNumberRow {
            addCharacters(numberRowCharacters, row: 0, startX: centredStart(count: 10, keyWidth: lw), keyWidth: lw)
        }

        let shiftRowModW = splitColumns && layer == .letters ? lw : modW
        if m.splitGap > 0 {
            let pitch = lw + m.gap
            let starts = [left, right + m.gap - 5 * pitch]
            for (half, start) in zip(splitHalves(layer, aligned: splitColumns), starts) {
                for (row, chars) in half.rows.enumerated() {
                    for (index, ch) in chars.enumerated() {
                        let x = start + (half.offsets[row] + CGFloat(index)) * pitch
                        add(.character(ch), row: firstRow + row, x: x, w: lw, label: ch)
                    }
                }
            }
            if layer != .letters {
                let w = (4 * pitch - 2 * m.gap) / 3
                for (chars, start) in zip(splitPunctuation, [left + 1.5 * pitch, starts[1] - 0.5 * pitch - m.gap]) {
                    for (index, ch) in chars.enumerated() {
                        add(.character(ch), row: shiftRow, x: start + CGFloat(index) * (w + m.gap), w: w, label: ch)
                    }
                }
            }
        } else {
            for row in 0..<2 {
                let chars = rows[row]
                addCharacters(chars, row: firstRow + row, startX: centredStart(count: chars.count, keyWidth: lw), keyWidth: lw)
            }
            let middle = rows[2]
            if layer == .letters {
                addCharacters(middle, row: shiftRow, startX: centredStart(count: middle.count, keyWidth: lw), keyWidth: lw)
            } else {
                // Apple's punctuation row: five wide keys aligned to the s..k columns between modifiers.
                let edgeGap = 1.5 * (lw + m.gap) - modW
                let count = CGFloat(middle.count)
                let middleW = (boardWidth - 2 * m.side - 2 * modW - 2 * edgeGap - (count - 1) * m.gap) / count
                addCharacters(middle, row: shiftRow, startX: left + modW + edgeGap, keyWidth: middleW)
            }
        }

        switch layer {
        case .letters:
            add(.shift, row: shiftRow, x: left, w: shiftRowModW, label: "shift")
        case .numbers:
            add(.layerSwitch(.symbols), row: shiftRow, x: left, w: modW, label: "#+=")
        case .symbols:
            add(.layerSwitch(.numbers), row: shiftRow, x: left, w: modW, label: "123")
        }
        add(.delete, row: shiftRow, x: right - shiftRowModW, w: shiftRowModW, label: "delete")

        let isCompactBottomRow = globe != .hidden || field != .text || aroundSpace.contains(.period)
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
        func arrangedKey(_ key: BottomKey) -> (KeyKind, CGFloat, String)? {
            switch key {
            case .space: nil
            case .period: (.character("."), lw, ".")
            case .typr: (.typr, modW, "typr")
            }
        }
        let spaceIndex = aroundSpace.firstIndex(of: .space) ?? aroundSpace.endIndex
        leading += aroundSpace[..<spaceIndex].compactMap(arrangedKey)
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
        trailing += aroundSpace[spaceIndex...].compactMap(arrangedKey)
        trailing.append((.returnKey, returnW, "return"))

        var x = left
        for (kind, w, label) in leading {
            add(kind, row: spaceRow, x: x, w: w, label: label)
            x += w + m.gap
        }
        let trailingWidth = trailing.reduce(0) { $0 + $1.1 } + CGFloat(trailing.count) * m.gap
        if m.splitGap > 0 {
            let pitch = lw + m.gap
            let leftSpaceEnd = max(left + 5 * pitch - m.gap, x + 2 * pitch)
            add(.space, row: spaceRow, x: x, w: leftSpaceEnd - x, label: "space")
            let rightSpaceEnd = right - trailingWidth
            let rightSpaceStart = min(left + 5 * pitch + m.splitGap, rightSpaceEnd - 2 * pitch)
            add(.space, row: spaceRow, x: rightSpaceStart, w: rightSpaceEnd - rightSpaceStart, label: "space")
            x = rightSpaceEnd + m.gap
        } else {
            let spaceW = max(lw, right - x - trailingWidth)
            add(.space, row: spaceRow, x: x, w: spaceW, label: "space")
            x += spaceW + m.gap
        }
        for (kind, w, label) in trailing {
            add(kind, row: spaceRow, x: x, w: w, label: label)
            x += w + m.gap
        }

        // Touch targets: split every gap down the middle; outer keys reach the edges. Like Apple's, the split halves'
        // gap types nothing farther than half a key from either half.
        func boundaries(_ a: CGRect, _ b: CGRect) -> (end: CGFloat, start: CGFloat) {
            let middle = (a.maxX + b.minX) / 2
            guard m.splitGap > 0, b.minX - a.maxX > lw else { return (middle, middle) }
            return (min(middle, a.maxX + lw / 2), max(middle, b.minX - lw / 2))
        }
        let top = m.stripArea
        let bottom = m.totalHeight
        var keys: [KeyboardKey] = []
        for row in 0...spaceRow {
            let rowKeys = drawn.filter { $0.1 == row }.sorted { $0.2.minX < $1.2.minX }
            let y0 = row == 0 ? top : rowY(row) - m.rowGap / 2
            let y1 = row == spaceRow ? bottom : rowY(row + 1) - m.rowGap / 2
            for (i, item) in rowKeys.enumerated() {
                let x0 = i == 0 ? 0 : boundaries(rowKeys[i - 1].2, item.2).start
                let x1 = i == rowKeys.count - 1 ? width : boundaries(item.2, rowKeys[i + 1].2).end
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
