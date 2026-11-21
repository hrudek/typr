import SwiftUI

nonisolated enum TapDisplayMode: String, CaseIterable {
    case heat = "Heat", aim = "Aim", accuracy = "Accuracy"
}

struct TapStatisticsBoard: View {
    let taps: TapStatistics
    let mode: TapDisplayMode
    @Binding var selected: String?

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / taps.layout.width
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    for key in taps.layout.keys {
                        let rect = key.frame
                        let stats = taps.keys.first { $0.letter == key.character }
                        let color = mode == .accuracy ? accuracyColor(stats?.onTarget) : TyprTheme.layer02
                        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color))
                        if key.character == selected {
                            context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(TyprTheme.agentBlue), lineWidth: 2)
                        }
                        let label = key.character?.uppercased() ?? key.label
                        context.draw(Text(label).font(.system(size: 14, weight: .medium)).foregroundColor(TyprTheme.textBase),
                                     at: CGPoint(x: rect.midX, y: rect.midY - (mode == .accuracy && key.character != nil ? 6 : 0)))
                        if mode == .accuracy, key.character != nil {
                            context.draw(Text(TapStatistics.percent(stats?.onTarget)).font(.system(size: 12)).foregroundColor(.white),
                                         at: CGPoint(x: rect.midX, y: rect.midY + 9))
                        }
                        if mode == .aim, let stats, key == taps.layout.key(key.kind) {
                            drawAim(&context, key: key, stats: stats)
                        }
                    }
                    if mode == .heat, let heat = taps.heat {
                        let peak = heat.cells.max() ?? 0
                        if peak > 0 {
                            for (index, count) in heat.cells.enumerated() where count > 0 {
                                let width = taps.layout.width / CGFloat(UsageHeat.columns)
                                let height = taps.layout.totalHeight / CGFloat(UsageHeat.rows)
                                let rect = CGRect(x: CGFloat(index % UsageHeat.columns) * width,
                                                  y: CGFloat(index / UsageHeat.columns) * height, width: width, height: height)
                                let intensity = log1p(Double(count)) / log1p(Double(peak))
                                context.fill(Path(ellipseIn: rect.insetBy(dx: -width / 3, dy: -height / 3)),
                                             with: .color(TyprTheme.warmMic.opacity(0.15 + 0.70 * intensity)))
                            }
                        }
                    }
                }
                .accessibilityHidden(true)
                ForEach(taps.layout.keys.indices, id: \.self) { index in
                    let key = taps.layout.keys[index]
                    if let letter = key.character {
                        Button { selected = letter } label: { Color.clear.contentShape(Rectangle()) }
                            .frame(width: key.hitFrame.width * scale, height: key.hitFrame.height * scale)
                            .offset(x: key.hitFrame.minX * scale, y: key.hitFrame.minY * scale)
                            .accessibilityLabel(letter.uppercased())
                            .accessibilityValue("\(TapStatistics.percent(taps.keys.first { $0.letter == letter }?.onTarget)) estimated on target")
                            .accessibilityHint("Shows saved model details")
                    }
                }
            }
        }
        .aspectRatio(taps.layout.width / taps.layout.totalHeight, contentMode: .fit)
    }

    private func accuracyColor(_ share: Double?) -> Color {
        guard let share else { return TyprTheme.layer02 }
        return share >= 0.9 ? TyprTheme.success.opacity(0.55)
            : share >= 0.7 ? TyprTheme.warmMic.opacity(0.55) : TyprTheme.danger.opacity(0.55)
    }

    private func drawAim(_ context: inout GraphicsContext, key: KeyboardKey, stats: TapStatistics.Key) {
        let origin = CGPoint(x: key.frame.midX, y: key.frame.midY)
        var line = Path(); line.move(to: origin); line.addLine(to: stats.center)
        context.stroke(line, with: .color(TyprTheme.warmMic), lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: origin.x - 2, y: origin.y - 2, width: 4, height: 4)), with: .color(.white))
        context.stroke(Self.ellipse(stats), with: .color(TyprTheme.agentBlue), lineWidth: 1)
        context.fill(Path(ellipseIn: CGRect(x: stats.center.x - 2, y: stats.center.y - 2, width: 4, height: 4)),
                     with: .color(TyprTheme.warmMic))
    }

    /// One-sigma covariance contour, not observed taps or a confidence interval.
    static func ellipse(_ stats: TapStatistics.Key) -> Path {
        let l11 = sqrt(stats.xx), l21 = stats.xy / l11
        let l22 = sqrt(max(0, stats.yy - l21 * l21))
        return Path { path in
            for i in 0...64 {
                let angle = Double(i) * 2 * .pi / 64
                let point = CGPoint(x: Double(stats.center.x) + l11 * cos(angle),
                                    y: Double(stats.center.y) + l21 * cos(angle) + l22 * sin(angle))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}

struct TapKeyDetailGlyph: View {
    let key: KeyboardKey
    let stats: TapStatistics.Key
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / (key.frame.width * 3), size.height / (key.frame.height * 3))
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -key.frame.midX, y: -key.frame.midY)
            context.fill(Path(roundedRect: key.frame, cornerRadius: 5), with: .color(TyprTheme.layer02))
            context.stroke(Path(key.hitFrame), with: .color(TyprTheme.textMuted), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.stroke(TapStatisticsBoard.ellipse(stats), with: .color(TyprTheme.agentBlue), lineWidth: 2)
            var vector = Path(); vector.move(to: CGPoint(x: key.frame.midX, y: key.frame.midY)); vector.addLine(to: stats.center)
            context.stroke(vector, with: .color(TyprTheme.warmMic), lineWidth: 2)
            context.fill(Path(ellipseIn: CGRect(x: stats.center.x - 3, y: stats.center.y - 3, width: 6, height: 6)),
                         with: .color(TyprTheme.warmMic))
        }
        .frame(height: 160)
        .clipped()
        .accessibilityHidden(true)
    }
}
