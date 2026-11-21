import SwiftUI

struct StatisticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: StatisticsModel

    init(fixture: StatisticsFixture? = nil, section: StatisticsSection = .overview) {
        _model = State(initialValue: StatisticsModel(fixture: fixture))
        _section = State(initialValue: section)
    }
    @State private var section: StatisticsSection
    @State private var range: StatisticsRange = .week
    @State private var metric: ActivityMetric = .words
    @State private var layoutID: String?
    @State private var mode: TapDisplayMode = .heat
    @State private var selected: String?
    @State private var confirmingReset = false

    private var signature: KeyboardLayoutSignature? {
        model.signatures.first { $0.id == layoutID } ?? model.signatures.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionPicker
                Text(section.rawValue).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let problem = model.problem {
                    card {
                        Label("Statistics unavailable", systemImage: "exclamationmark.triangle")
                        Text(problem).font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                        Button("Try again") { model.refresh() }.frame(minHeight: 44)
                    }
                }
                if section == .taps {
                    if model.learning == nil {
                        Text("Saved touch model unavailable.").font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                    }
                    if let signature {
                        let taps = model.taps(for: signature)
                        summary(taps)
                        card {
                            Picker("Keyboard layout", selection: Binding(get: { signature.id }, set: { layoutID = $0; selected = nil })) {
                                ForEach(model.signatures, id: \.id) { item in
                                    Text(item.statisticsTitle).tag(item.id)
                                }
                            }
                            .pickerStyle(.menu)
                            Picker("Display", selection: $mode) {
                                ForEach(TapDisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            TapStatisticsBoard(taps: taps, mode: mode, selected: $selected)
                            Text(legend).font(.caption).foregroundStyle(TyprTheme.textMuted)
                            if mode == .heat {
                                if model.usage == nil {
                                    Text("Measured heat unavailable.").font(.subheadline)
                                } else {
                                    Text("\(taps.heatSamples) measured touches · relative density")
                                        .font(.subheadline).monospacedDigit()
                                    if taps.heatSamples == 0 { Text("No measured heat for this layout yet.").font(.subheadline) }
                                }
                            }
                            Picker("Key details", selection: $selected) {
                                Text("Choose a key").tag(String?.none)
                                ForEach(taps.letters, id: \.self) { letter in
                                    Text(letter.uppercased()).tag(Optional(letter))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minHeight: 44)
                        }
                        if let selected { detail(selected, taps: taps) }
                        card {
                            Text("Keyboard halves").font(.headline)
                            ViewThatFits(in: .horizontal) {
                                HStack { half("Left", share: taps.half(left: true)); Spacer(); half("Right", share: taps.half(left: false)) }
                                VStack(alignment: .leading, spacing: 12) { half("Left", share: taps.half(left: true)); half("Right", share: taps.half(left: false)) }
                            }
                            Text("Estimated on target · saved model").font(.caption).foregroundStyle(TyprTheme.textMuted)
                        }
                        card {
                            Text("Common deviations").font(.headline)
                            if taps.commonDeviations.isEmpty {
                                Text("Not enough model evidence for neighboring keys.").font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                            } else {
                                ForEach(taps.commonDeviations, id: \.from) { item in
                                    HStack { Text("\(item.from.uppercased()) → \(item.to.uppercased())"); Spacer(); Text(TapStatistics.percent(item.share)) }
                                }
                                Text("Largest estimated neighboring share per key, not counted mistakes.")
                                    .font(.caption).foregroundStyle(TyprTheme.textMuted)
                            }
                        }
                    } else if model.problem == nil {
                        card {
                            Label("No tap data yet", systemImage: "keyboard")
                                .font(.headline)
                            Text("Use the Typr letter keyboard to collect heat. Enable learning in Keyboard settings to build a saved aim model.")
                                .font(.subheadline).foregroundStyle(TyprTheme.textMuted)
                        }
                    }
                    card {
                        Text("About this data").font(.headline)
                        Text("Heat is measured separately from the saved learning model. Model counts are capped effective samples, not lifetime taps.")
                        Text("Recent learning points stay in keyboard memory and are not available in this app. No recent trend is calculated.")
                        Text("Layouts use 8-pt width buckets at zero inset; geometry is reconstructed at the bucket midpoint. Aim projects the saved pitch-normalized model onto that layout; older samples do not record inset.")
                        if let usage = model.usage {
                            Text("Usage collection since \(usage.startedAt.formatted(date: .abbreviated, time: .omitted)) · \(usage.timeZone)")
                        }
                    }
                    .font(.caption).foregroundStyle(TyprTheme.textMuted)
                } else if let usage = model.usage {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ActivityStatisticsView(snapshot: usage, section: section,
                                               now: model.presentationDate(at: context.date), range: $range, metric: $metric)
                    }
                }
                Button("Reset statistics", role: .destructive) { confirmingReset = true }
                    .frame(minHeight: 44)
                if let problem = model.resetProblem { Text(problem).foregroundStyle(TyprTheme.danger) }
            }
            .frame(maxWidth: 600)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(TyprTheme.bgDeep)
        .foregroundStyle(TyprTheme.textBase)
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .confirmationDialog("Reset statistics?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset statistics", role: .destructive) { model.reset() }
        } message: {
            Text("Clears usage totals and measured heat. Saved learning and its aim estimates remain. Reset learning separately in Keyboard settings.")
        }
        .onAppear { model.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
        .onChange(of: signature?.id) { _, _ in selected = nil }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(StatisticsSection.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Text(item.rawValue).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(section == item ? TyprTheme.layer02 : TyprTheme.bgBase, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? [.isSelected] : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Statistics sections")
    }

    private var legend: String {
        switch mode {
        case .heat: "Orange: measured concentration, low to high. Not intended-key accuracy."
        case .aim: "White: key center. Orange: saved aim. Blue: one-sigma model spread, not individual taps."
        case .accuracy: "Estimated on target: green ≥90%, orange ≥70%, red <70%. — means fewer than 20 effective samples."
        }
    }
    private func summary(_ taps: TapStatistics) -> some View {
        card {
            Text(TapStatistics.percent(taps.onTarget)).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Estimated on target").font(.headline)
            if let share = taps.onTarget {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        TyprTheme.success.frame(width: proxy.size.width * share)
                        TyprTheme.warmMic
                    }
                }
                .frame(height: 8).clipShape(Capsule()).accessibilityHidden(true)
                Text("\(TapStatistics.percent(share)) on target · \(TapStatistics.percent(1 - share)) elsewhere")
                    .font(.caption)
            } else {
                Text("At least 20 effective samples per key are needed for an estimate.").font(.caption)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    sampleCount(taps)
                    Spacer(minLength: 0)
                    driftValue(taps)
                }
                VStack(alignment: .leading, spacing: 12) { sampleCount(taps); driftValue(taps) }
            }
            Text("Saved model · \(taps.keys.filter { $0.onTarget != nil }.count) of 26 keys eligible · not a measured error rate")
                .font(.caption).foregroundStyle(TyprTheme.textMuted)
        }
    }
    private func sampleCount(_ taps: TapStatistics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(taps.effectiveSamples)").font(.title2.weight(.semibold)).monospacedDigit()
            Text("effective learned samples").font(.caption)
        }
    }
    private func driftValue(_ taps: TapStatistics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(taps.meanDrift.map { String(format: "%.1f pt", $0) } ?? "—")
                .font(.title2.weight(.semibold)).monospacedDigit()
            Text("mean center offset").font(.caption)
        }
    }
    private func half(_ title: String, share: Double?) -> some View {
        VStack(alignment: .leading) { Text(title).font(.subheadline); Text(TapStatistics.percent(share)).font(.title2).monospacedDigit() }
    }
    private func detail(_ letter: String, taps: TapStatistics) -> some View {
        card {
            Text("\(letter.uppercased()) · saved model").font(.headline)
            if let key = taps.layout.key(.character(letter)), let stats = taps.keys.first(where: { $0.letter == letter }) {
                TapKeyDetailGlyph(key: key, stats: stats)
                Text("\(stats.samples) effective samples · \(TapStatistics.percent(stats.onTarget)) estimated on target")
                let dx = Double(stats.center.x - key.frame.midX), dy = Double(stats.center.y - key.frame.midY)
                Text(String(format: "%.1f pt %@ · %.1f pt %@", abs(dx), dx < 0 ? "left" : "right", abs(dy), dy < 0 ? "up" : "down"))
                Text(String(format: "Spread: %.1f × %.1f pt (one sigma)", sqrt(stats.xx), sqrt(stats.yy)))
                ForEach(Array(stats.neighbors.prefix(3)), id: \.letter) { item in
                    Text("Toward \(item.letter.uppercased()): \(TapStatistics.percent(item.share)) estimated")
                }
                Text("Dashed: hit region. Blue: model spread. Orange: aim offset.").font(.caption).foregroundStyle(TyprTheme.textMuted)
            } else {
                Text("No saved learning samples for this key.").foregroundStyle(TyprTheme.textMuted)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(TyprTheme.bgBase, in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius))
    }
}
