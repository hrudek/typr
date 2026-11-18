import SwiftUI

struct DictationHistoryDay: Identifiable, Equatable {
    let id: Date
    let title: String
    let rows: [DictationLogMetadata]

    /// Newest day first, newest dictation first within a day.
    static func group(_ rows: [DictationLogMetadata], now: Date, calendar: Calendar = .current) -> [Self] {
        let byDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { day in
            Self(id: day, title: title(for: day, now: now, calendar: calendar),
                 rows: byDay[day, default: []].sorted { $0.date > $1.date })
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { style = style.year() }
        return day.formatted(style)
    }
}

@MainActor
struct DictationHistoryView: View {
    let store: DictationLogStore
    let router: TyprFeedbackRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var rateAfterDictating = TyprSettings().dictationFeedbackStrip
    @State private var openEntry: UUID?
    @State private var focusesNote = false
    @State private var confirmingDeleteAll = false
    @State private var exportRequested = false
    @State private var sharedURL: URL?

    var body: some View {
        List {
            settingsSection
            if store.isLoading && store.metadata.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if store.metadata.isEmpty {
                Section { emptyState }
            }
            ForEach(DictationHistoryDay.group(store.metadata, now: Date())) { day in
                Section(day.title) {
                    ForEach(day.rows) { row in historyRow(row) }
                }
            }
        }
        .navigationTitle("History & feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .primaryAction) { actionsMenu } }
        .navigationDestination(item: $openEntry) { id in
            DictationLogDetail(store: store, entryID: id, focusesNote: focusesNote).id(id)
        }
        .confirmationDialog("Delete all dictations?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { store.clear() }
        } message: {
            Text("Removes every saved dictation and its feedback from this iPhone. Exports you already shared are not affected.")
        }
        .onChange(of: store.preparedJSON(for: nil)) { _, url in
            guard exportRequested, let url else { return }
            exportRequested = false
            sharedURL = url
        }
        .sheet(isPresented: Binding(get: { sharedURL != nil }, set: { if !$0 { releaseShared() } })) {
            if let sharedURL { DictationJSONShareSheet(url: sharedURL) { releaseShared() } }
        }
        .onAppear {
            refresh()
            openRequestedEntry()
        }
        .onChange(of: router.requestedEntry) { _, _ in openRequestedEntry() }
        .onChange(of: openEntry) { _, id in if id == nil { focusesNote = false } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private var settingsSection: some View {
        Section {
            SettingsToggle(title: "Rate after dictating",
                           detail: "Show Good and Problem in the keyboard after it inserts a dictation.",
                           isOn: $rateAfterDictating)
                .listRowInsets(EdgeInsets())
                .onChange(of: rateAfterDictating) { _, enabled in
                    TyprSettings().dictationFeedbackStrip = enabled
                    store.feedbackSettingsChanged()
                }
            if let notice = store.keyboardFeedbackNotice {
                Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(TyprTheme.warmMic)
                Button("Retry keyboard feedback", systemImage: "arrow.clockwise") { store.retryKeyboardFeedback() }
            }
            SettingsToggle(title: "Keep dictation history",
                           detail: "Saves the text of each dictation and your feedback on this iPhone. No audio.",
                           isOn: Binding(get: { store.isEnabled }, set: { store.setEnabled($0) }))
                .listRowInsets(EdgeInsets())
            if let problem = store.storageProblem {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(TyprTheme.warmMic)
                Button("Retry storage", systemImage: "arrow.clockwise") { store.retry() }
            }
            if let problem = store.exportProblem {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(TyprTheme.warmMic)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.isEnabled {
            ContentUnavailableView("No dictations yet", systemImage: "waveform",
                description: Text("Your dictations appear here so you can review and rate them."))
        } else {
            ContentUnavailableView("History is off", systemImage: "clock.badge.xmark",
                description: Text("Turn on Keep dictation history to review and rate your dictations."))
        }
    }

    private func historyRow(_ row: DictationLogMetadata) -> some View {
        Button { openEntry = row.id } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.preview.isEmpty ? row.status.label : row.preview)
                        .lineLimit(2)
                        .foregroundStyle(TyprTheme.textBase)
                    Text(row.status == .finished
                         ? row.date.formatted(date: .omitted, time: .shortened)
                         : "\(row.date.formatted(date: .omitted, time: .shortened)) · \(row.status.label)")
                        .font(.footnote).foregroundStyle(TyprTheme.textMuted)
                }
                Spacer(minLength: 0)
                DictationRatingBadge(rating: row.rating)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(row.id) }
        }
        .swipeActions(edge: .leading) {
            Button("Good", systemImage: "hand.thumbsup") { store.rate(row.id, rating: "good") }.tint(TyprTheme.success)
            Button("Problem", systemImage: "hand.thumbsdown") { store.rate(row.id, rating: "bad") }.tint(.orange)
        }
        .accessibilityAction(named: "Good") { store.rate(row.id, rating: "good") }
        .accessibilityAction(named: "Problem") { store.rate(row.id, rating: "bad") }
        .accessibilityAction(named: "Delete") { store.delete(row.id) }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Export full log (JSON)", systemImage: "square.and.arrow.up") {
                exportRequested = true
                store.prepareJSON()
            }
            .disabled(store.exporting || store.isLoading || store.metadata.isEmpty)
            Button("Delete all", systemImage: "trash", role: .destructive) { confirmingDeleteAll = true }
                .disabled(store.metadata.isEmpty)
        } label: {
            if store.exporting { ProgressView() } else { Label("History actions", systemImage: "ellipsis.circle") }
        }
    }

    private func refresh() {
        store.setEnabled(TyprSettings().dictationLog)
        rateAfterDictating = TyprSettings().dictationFeedbackStrip
    }

    private func releaseShared() {
        if let sharedURL { store.releaseJSON(sharedURL) }
        sharedURL = nil
    }

    private func openRequestedEntry() {
        guard let id = router.consume() else { return }
        focusesNote = true
        openEntry = id
    }
}

struct DictationRatingBadge: View {
    let rating: String

    var body: some View {
        switch rating {
        case "good":
            Image(systemName: "hand.thumbsup.fill").foregroundStyle(TyprTheme.success)
                .accessibilityLabel("Rated good")
        case "bad":
            Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.orange)
                .accessibilityLabel("Rated problem")
        default:
            EmptyView()
        }
    }
}
