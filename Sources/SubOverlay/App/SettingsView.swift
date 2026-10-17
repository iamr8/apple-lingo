import KeyboardShortcuts
import SubOverlayCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(model: model) }
            Tab("Providers", systemImage: "key") { ProvidersSettings(model: model) }
            Tab("Translations", systemImage: "text.bubble") { TranslationsSettings(model: model) }
        }
        .frame(width: 480)
        .onAppear(perform: bringSettingsToFront)
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(Preferences.secondaryLanguageKey) private var secondary = TranslationPlan.Settings.automatic
    @AppStorage(Preferences.defaultTargetKey) private var target = "fa"

    var body: some View {
        Form {
            Section {
                LabeledContent("Primary", value: primary)
                Picker("Secondary", selection: $secondary) {
                    Text("Automatic").tag(TranslationPlan.Settings.automatic)
                    Text("Same as primary").tag(TranslationPlan.Settings.sameAsMain)
                    Divider()
                    ForEach(Languages.all, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
                Picker("Target", selection: $target) {
                    ForEach(Languages.all, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("The primary is the movie or episode's main language. The secondary's lines give the timing of yours, and its text guides the translation; a language close to the target's grammar works best.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Timing") {
                KeyboardShortcuts.Recorder("Earlier by 0.1 s", name: .offsetMinusSmall)
                KeyboardShortcuts.Recorder("Later by 0.1 s", name: .offsetPlusSmall)
                KeyboardShortcuts.Recorder("Earlier by 0.5 s", name: .offsetMinusLarge)
                KeyboardShortcuts.Recorder("Later by 0.5 s", name: .offsetPlusLarge)
            }
            Section("Position") {
                KeyboardShortcuts.Recorder("Move up", name: .nudgeUp)
                KeyboardShortcuts.Recorder("Move down", name: .nudgeDown)
            }
        }
        .formStyle(.grouped)
        .onChange(of: secondary) { model.settingsChanged() }
        .onChange(of: target) { model.settingsChanged() }
    }

    /// The playing title's main language when one is captured.
    private var primary: String {
        guard let meta = model.entry?.meta, let track = TranslationPlan.primary(apple: meta.appleLanguages, original: meta.originalLanguage)
        else { return "The title's main language" }
        return Languages.name(track)
    }
}

/// Translations: the running and queued ones, each with Cancel, the failed ones with their
/// reason and Retry, and the saved ones, each with Delete, so a title is translated once.
private struct TranslationsSettings: View {
    struct Row: Identifiable {
        var entry: SubtitleLibrary.Entry
        var language: String
        var id: String { entry.directory.path + "|" + language }
    }

    let model: AppModel
    @State private var rows: [Row] = []
    @State private var pending: Row?

    var body: some View {
        Form {
            if let running = model.queue.running {
                Section("In progress") {
                    job(running, status: "Translating into \(Languages.name(running.target)) · \(Int((running.progress * 100).rounded()))%")
                    ForEach(model.queue.queued) { job($0, status: "Waiting · \(Languages.name($0.target))") }
                }
            }
            if !model.failures.isEmpty {
                Section("Failed") {
                    ForEach(model.failures) { failure in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(failure.title)
                                Text(failure.reason).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Retry") { model.retry(key: failure.key) }
                        }
                    }
                }
            }
            Section {
                if rows.isEmpty {
                    Text("No translations yet.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.entry.meta.title)
                            Text(detail(row)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { pending = row }
                    }
                }
            } footer: {
                Text("Translations are kept in ~/Library/Application Support/SubOverlay.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .confirmationDialog("Delete this translation?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { row in
            Button("Delete \(Languages.name(row.language))", role: .destructive) {
                model.deleteTranslation(row.entry, language: row.language)
                reload()
            }
        } message: { row in
            Text("\(row.entry.meta.title) will need a new translation to show \(Languages.name(row.language)) subtitles.")
        }
    }

    private func job(_ job: TranslationQueue.Job, status: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(job.title)
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") {
                model.cancelTranslation(key: job.key)
                reload()
            }
        }
    }

    private func reload() {
        rows = model.translatedEntries().flatMap { entry in entry.translations.map { Row(entry: entry, language: $0) } }
    }

    private func detail(_ row: Row) -> String {
        var parts = [row.entry.meta.album, Languages.name(row.language)].filter { !$0.isEmpty }
        if let date = row.entry.saved(row.language) { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

private struct ProvidersSettings: View {
    let model: AppModel
    @AppStorage(ProviderChoice.selectedKey) private var selected = ProviderChoice.gemini.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Translate with", selection: $selected) {
                    ForEach(ProviderChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            ForEach(ProviderChoice.allCases) { ProviderKeySection(choice: $0, keychain: model.keychain, changed: model.settingsChanged) }
        }
        .formStyle(.grouped)
        .onChange(of: selected) { model.settingsChanged() }
    }
}

private struct ProviderKeySection: View {
    let choice: ProviderChoice
    let keychain: Keychain
    /// Called when the saved key or the model changes.
    let changed: () -> Void
    @AppStorage private var model: String
    @State private var key = ""
    @State private var models: [String] = []
    @State private var message: String?
    @State private var busy = false

    init(choice: ProviderChoice, keychain: Keychain, changed: @escaping () -> Void) {
        self.choice = choice
        self.keychain = keychain
        self.changed = changed
        _model = AppStorage(wrappedValue: "", choice.modelKey)
    }

    var body: some View {
        Section(choice.title) {
            SecureField("API key", text: $key)
                .onSubmit(authenticate)
            Picker("Model", selection: $model) {
                Text(choice.automaticModel).tag("")
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                if let message { Text(message).foregroundStyle(.secondary) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Authenticate", action: authenticate).disabled(key.isEmpty || busy)
            }
        }
        .onAppear {
            key = (try? keychain.get(choice.account)) ?? ""
            loadModels()
        }
        .onChange(of: model) { changed() }
    }

    /// Lists the saved key's models; this does not use generation quota.
    private func loadModels() {
        guard !key.isEmpty, models.isEmpty else { return }
        let key = key, choice = choice
        Task {
            if let list = try? await choice.listModels(key: key) { models = list }
        }
    }

    /// The key's models, plus the saved model before the list is loaded.
    private var choices: [String] {
        models.contains(model) || model.isEmpty ? models : [model] + models
    }

    /// Sends one tiny request to the chosen model (or finds the newest automatic model that
    /// answers), then saves the key. A key that fails is not saved.
    private func authenticate() {
        guard !key.isEmpty, !busy else { return }
        busy = true
        message = nil
        let key = key, model = model, choice = choice
        Task {
            defer { busy = false }
            do {
                let result = try await choice.authenticate(key: key, model: model)
                try keychain.set(key, for: choice.account)
                models = result.models
                message = "Verified with \(result.model). Key saved."
                changed()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
