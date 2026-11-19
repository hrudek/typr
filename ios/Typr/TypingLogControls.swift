import Foundation
import Observation
import SwiftUI

/// Exports and deletes the keyboard's typing log; the export adds the touch calibration for replay.
@MainActor @Observable
final class TypingLogSettingsModel {
    private(set) var wordCount: Int?
    private(set) var isExporting = false
    private(set) var exportURL: URL?
    private(set) var problem: String?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let store: TypingLogStore?

    init(directory: URL? = KeyboardLearningStore.sharedDirectory) {
        self.directory = directory
        store = directory.map { TypingLogStore(directory: $0) }
    }

    func refresh() {
        guard let store else { return }
        Task {
            let count = await Task.detached { try? store.wordCount() }.value
            wordCount = count
        }
    }

    func export() {
        guard let store, !isExporting else { return }
        isExporting = true
        problem = nil
        let touchModel = KeyboardLearningStore(directory: directory).learnedWords()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        Task {
            let result = await Task.detached {
                try store.export(touchModel: touchModel, appBuild: build, into: FileManager.default.temporaryDirectory)
            }.result
            isExporting = false
            switch result {
            case .success(let url): exportURL = url
            case .failure: problem = "The typing log could not be prepared. Try again."
            }
        }
    }

    func finishSharing() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil
    }

    func delete() {
        guard let store else { return }
        do {
            try store.delete()
            problem = nil
            wordCount = 0
        } catch {
            problem = "The typing log could not be deleted. Try again."
        }
    }
}

struct TypingLogControls: View {
    @State private var model = TypingLogSettingsModel()
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSection(title: "Typing log") {
                VStack(alignment: .leading, spacing: 12) {
                    Button(model.isExporting ? "Preparing typing log…" : "Export typing log") { model.export() }
                        .disabled(model.isExporting || model.wordCount == 0)
                        .frame(minHeight: 44, alignment: .leading)
                    SettingsDivider()
                    Button("Delete typing log", role: .destructive) { confirmDelete = true }
                        .frame(minHeight: 44, alignment: .leading)
                    if let problem = model.problem {
                        Text(problem).font(.footnote).foregroundStyle(TyprTheme.danger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            SettingsFooter(footer)
        }
        .confirmationDialog("Delete typing log?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete typing log", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every recorded word and tap from this iPhone. Learning and exports you already shared stay.")
        }
        .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { if !$0 { model.finishSharing() } })) {
            if let url = model.exportURL { DictationJSONShareSheet(url: url) { model.finishSharing() } }
        }
        .onAppear { model.refresh() }
    }

    private var footer: String {
        let saved = model.wordCount.map { " \($0.formatted()) words saved." } ?? ""
        return "While learning is on, Typr keeps your most recent 10,000 to 20,000 typed words with their taps and corrections on this iPhone, never from passwords, web addresses or email addresses. Export them as JSON to compare hit areas." + saved
    }
}
