import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject private var chat = ChatService.shared
    @ObservedObject private var pet = PetStore.shared

    @AppStorage(Pref.model) private var model = Pref.defaultModel
    @AppStorage(Pref.maxSearches) private var maxSearches = 3
    @AppStorage(Pref.soundOn) private var soundOn = true
    @AppStorage(Pref.volume) private var volume = 0.35

    @AppStorage(Pref.brain) private var brain = Brain.auto.rawValue
    @AppStorage(Pref.geminiModel) private var geminiModel = Pref.defaultGeminiModel
    @AppStorage(Pref.freeSearch) private var freeSearch = true

    @State private var geminiDraft = ""
    @State private var claudeDraft = ""
    @State private var showClaude = false
    @State private var nameDraft = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false

    private struct ModelOption: Hashable {
        let id: String
        let label: String
    }

    private let models: [ModelOption] = [
        ModelOption(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5 — fastest & cheapest"),
        ModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6 — smarter"),
        ModelOption(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5 — smartest, costs more"),
    ]

    private var activeText: String {
        switch chat.activeBrain {
        case .apple?: return "Apple Intelligence (on your Mac)"
        case .gemini?: return "Google Gemini"
        case .claude?: return "Claude"
        default: return "None yet — add a free Gemini key below"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Brain", selection: $brain) {
                    ForEach(Brain.allCases) { b in
                        Text(b.label).tag(b.rawValue)
                    }
                }
                LabeledContent("Thinking with", value: activeText)
                LabeledContent("Apple Intelligence", value: AppleBrain.statusText)
                Toggle("Search the web for answers (free: DuckDuckGo + Wikipedia)", isOn: $freeSearch)
            } header: {
                Text("Brain")
            } footer: {
                Text("Automatic uses Apple's free on-device AI when your Mac has it (macOS 26 + Apple Intelligence), otherwise a free Google Gemini key.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                KeyEditor(hasKey: chat.hasGeminiKey, masked: chat.maskedGeminiKey,
                          placeholder: "AIza…", draft: $geminiDraft,
                          save: { chat.setGeminiKey($0) })
                TextField("Model", text: $geminiModel)
                    .font(.system(.body, design: .monospaced))
                if let working = UserDefaults.standard.string(forKey: Pref.geminiWorkingModel) {
                    LabeledContent("Last working model", value: working)
                }
                Link("Get a free key at aistudio.google.com →",
                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            } header: {
                Text("Google Gemini (free key)")
            } footer: {
                Text("Free, no credit card: sign in with a Google account and click Create API key. Leave Model on \"auto\" and Pip picks a free model that works. The free tier has a daily limit. Don't add billing if you want it to stay free. Stored only in your Keychain.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                DisclosureGroup("Claude (paid, optional)", isExpanded: $showClaude) {
                    KeyEditor(hasKey: chat.hasClaudeKey, masked: chat.maskedClaudeKey,
                              placeholder: "sk-ant-…", draft: $claudeDraft,
                              save: { chat.setClaudeKey($0) })
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                        if !models.contains(where: { $0.id == model }) {
                            Text(model).tag(model)
                        }
                    }
                    Stepper("Max web searches per question: \(maxSearches)", value: $maxSearches, in: 1...8)
                    Text("Costs money per question on your Anthropic account. Only used if you pick Claude as the brain (or have no free option).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("Pet") {
                HStack {
                    TextField("Name", text: $nameDraft)
                        .onSubmit { pet.rename(nameDraft) }
                    Button("Rename") { pet.rename(nameDraft) }
                        .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                LabeledContent("Stage", value: "\(pet.stage.label) · \(pet.ageText)")
                LabeledContent("Questions answered", value: "\(pet.pet.questionsAnswered)")
                LabeledContent("Generation", value: "\(pet.pet.generation)")
                Button("Start over with a new egg…", role: .destructive) { confirmReset = true }
            }

            Section("App") {
                Toggle("Sounds", isOn: $soundOn)
                Slider(value: $volume, in: 0...1) { Text("Volume") }
                    .disabled(!soundOn)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                Text("Hover the notch to peek · click to open · Esc to close. Click \(pet.pet.name) to poke (3× fast = dizzy), stroke with your cursor to pat, drop a file on the notch to ask about it.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 620)
        .onAppear { nameDraft = pet.pet.name }
        .confirmationDialog("Say goodbye to \(pet.pet.name) and hatch a new egg?", isPresented: $confirmReset) {
            Button("Hatch a new egg", role: .destructive) { pet.newEgg() }
        }
    }
}

/// Paste / replace / remove a key.
private struct KeyEditor: View {
    let hasKey: Bool
    let masked: String
    let placeholder: String
    @Binding var draft: String
    let save: (String) -> Void
    @State private var saved = false

    var body: some View {
        if hasKey {
            LabeledContent("Current key", value: masked)
        }
        SecureField(placeholder, text: $draft)
        HStack {
            Button(hasKey ? "Replace key" : "Save key") {
                save(draft)
                draft = ""
                saved = true
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            if hasKey {
                Button("Remove key", role: .destructive) { save(""); saved = false }
            }
            Spacer()
            if saved { Text("Saved ✓").foregroundColor(.green).font(.caption) }
        }
    }
}
