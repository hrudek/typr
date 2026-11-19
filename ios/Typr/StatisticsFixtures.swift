import Foundation

/// Synthetic, in-memory presentation inputs. Never seed shared preferences or files.
enum StatisticsFixture: String {
    case empty, sparse, populated, unavailable

    static let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func launchFixture(arguments: [String]) -> Self? {
        guard let index = arguments.firstIndex(of: "--snap-state"), index + 1 < arguments.count else { return nil }
        let prefix = "settings-statistics-"
        let scene = arguments[index + 1]
        guard scene.hasPrefix(prefix) else { return nil }
        return Self(rawValue: String(scene.dropFirst(prefix.count)))
    }

    @MainActor
    func snapshots() -> (UsageStatisticsSnapshot?, KeyboardLearningSnapshot?) {
        guard self != .unavailable else { return (nil, nil) }
        let date = Self.referenceDate
        let zone = TimeZone(secondsFromGMT: 0)!
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -89, to: date)!
        var usage = UsageStatisticsSnapshot(now: self == .populated ? start : date, timeZone: zone)
        if self == .populated {
            for offset in 0..<90 where offset % 6 != 4 {
                let day = usage.calendar.date(byAdding: .day, value: -offset, to: date)!
                var totals = UsageTotals()
                totals.directGraphemes = UInt64(400 + offset * 20)
                totals.timedGraphemes = totals.directGraphemes - 10
                totals.completedWords = UInt64(70 + offset * 3)
                totals.typingSeconds = Double(120 + offset * 4)
                totals.deletions = UInt64(5 + offset)
                if offset % 3 != 1 {
                    totals.dictations = UInt64(1 + offset % 4)
                    totals.dictatedWords = UInt64(150 + offset * 5)
                    totals.recordingSeconds = Double(65 + offset * 2)
                }
                usage.add(totals, day: usage.dayID(day))
            }
        } else if self == .sparse {
            var totals = UsageTotals()
            totals.directGraphemes = 10; totals.timedGraphemes = 8
            totals.completedWords = 2; totals.typingSeconds = 3
            totals.dictations = 1; totals.dictatedWords = 6; totals.recordingSeconds = 4
            usage.add(totals, day: usage.dayID(date))
        }
        var state = PersonalTypingModel.State()
        if self != .empty {
            let layout = KeyboardLayout(width: 392)
            let signature = KeyboardLayoutSignature(layout)
            var keys: [String: PersonalTypingModel.TouchStats] = [:]
            for (index, letter) in "qwertyuiopasdfghjklzxcvbnm".enumerated() {
                if self == .sparse && letter != "a" { continue }
                keys[String(letter)] = .init(n: self == .sparse ? 3 : 64,
                    meanX: Double(index % 5 - 2) * 0.07, meanY: 0.08,
                    varianceX: 0.035, varianceY: 0.025, covarianceXY: 0.008)
            }
            state.layouts[signature.id] = .init(signature: signature, lastUpdated: date, keys: keys)
            var heat = UsageHeat(layout: signature, geometryVersion: 1,
                                 cells: Array(repeating: 0, count: UsageHeat.columns * UsageHeat.rows), updatedAt: date)
            for key in layout.keys where key.character != nil {
                guard self != .sparse || key.character == "a" else { continue }
                let x = Int(key.frame.midX / layout.width * CGFloat(UsageHeat.columns))
                let y = Int(key.frame.midY / layout.totalHeight * CGFloat(UsageHeat.rows))
                heat.cells[y * UsageHeat.columns + x] = self == .sparse ? 1 : 24
            }
            usage.heat = [heat]
        }
        let learning = KeyboardLearningSnapshot(model: PersonalTypingModel.summarize(state),
            diagnostics: KeyboardDiagnostics(), learningFile: .init(bytes: nil, modifiedAt: nil),
            diagnosticsFile: .init(bytes: nil, modifiedAt: nil), isPersistent: true)
        return (usage, learning)
    }
}
