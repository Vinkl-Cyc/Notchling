import Foundation
import Security
import PDFKit

// MARK: - Keychain (API key never touches disk in plain text)

enum Keychain {
    static let service = "Notchling"
    static let apiKeyAccount = "anthropic-api-key"
    static let geminiAccount = "gemini-api-key"

    static func save(_ value: String, account: String = apiKeyAccount) {
        delete(account: account)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(account: String = apiKeyAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String = apiKeyAccount) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Settings keys (UserDefaults)

enum Pref {
    static let brain = "brain"
    static let model = "model"
    static let geminiModel = "geminiModel"
    static let maxSearches = "maxSearches"
    static let freeSearch = "freeSearch"
    static let soundOn = "soundOn"
    static let volume = "volume"

    static let defaultModel = "claude-haiku-4-5-20251001"
    static let defaultGeminiModel = "auto"
    static let geminiWorkingModel = "geminiWorkingModel"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            brain: Brain.auto.rawValue,
            model: defaultModel,
            geminiModel: defaultGeminiModel,
            maxSearches: 3,
            freeSearch: true,
            soundOn: true,
            volume: 0.35,
        ])
    }
}

/// Which AI does the thinking.
enum Brain: String, CaseIterable, Identifiable {
    case auto, apple, gemini, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic — best free option (recommended)"
        case .apple: return "Apple Intelligence — free, on your Mac"
        case .gemini: return "Google Gemini — free key"
        case .claude: return "Claude — paid key, smartest search"
        }
    }
}

// MARK: - Chat

struct ChatSource: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
}

struct ChatMessage: Identifiable {
    enum Role { case user, pet }
    let id = UUID()
    let role: Role
    var text: String
    var sources: [ChatSource] = []
    var isError = false
    var attachmentName: String? = nil
}

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var attachment: URL? = nil
    @Published private(set) var hasClaudeKey = false
    @Published private(set) var hasGeminiKey = false

    /// Called when an answer lands while the island is closed.
    var onAnswer: (() -> Void)?

    /// Claude keeps its own rich history (search results etc.).
    private var apiMessages: [[String: Any]] = []
    /// Plain-text history for the free brains.
    private var turns: [(user: String, pet: String)] = []
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private var claudeKey: String?
    private var geminiKey: String?

    private init() {
        claudeKey = Keychain.load(account: Keychain.apiKeyAccount)
        geminiKey = Keychain.load(account: Keychain.geminiAccount)
        hasClaudeKey = !(claudeKey ?? "").isEmpty
        hasGeminiKey = !(geminiKey ?? "").isEmpty
    }

    // MARK: Brains & keys

    var chosenBrain: Brain {
        Brain(rawValue: UserDefaults.standard.string(forKey: Pref.brain) ?? "") ?? .auto
    }

    /// The brain that will actually answer, or nil if none is usable yet.
    var activeBrain: Brain? {
        switch chosenBrain {
        case .auto:
            if AppleBrain.isAvailable { return .apple }
            if hasGeminiKey { return .gemini }
            if hasClaudeKey { return .claude }
            return nil
        case .apple: return AppleBrain.isAvailable ? .apple : nil
        case .gemini: return hasGeminiKey ? .gemini : nil
        case .claude: return hasClaudeKey ? .claude : nil
        }
    }

    var isReady: Bool { activeBrain != nil }

    var setupHint: String {
        switch chosenBrain {
        case .apple: return "Apple Intelligence isn't available here (\(AppleBrain.statusText)). Pick another brain in ⚙︎ Settings."
        case .claude: return "Add a Claude API key in ⚙︎ Settings, or switch to a free brain."
        default: return "To answer questions I need a brain! Open ⚙︎ Settings and paste a free Google Gemini key — it takes a minute."
        }
    }

    func setClaudeKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(clean, account: Keychain.apiKeyAccount)
        claudeKey = clean
        hasClaudeKey = !clean.isEmpty
    }

    func setGeminiKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.save(clean, account: Keychain.geminiAccount)
        geminiKey = clean
        hasGeminiKey = !clean.isEmpty
    }

    func masked(_ key: String?) -> String {
        guard let k = key, k.count > 12 else { return "saved" }
        return String(k.prefix(6)) + "…" + String(k.suffix(4))
    }
    var maskedClaudeKey: String { masked(claudeKey) }
    var maskedGeminiKey: String { masked(geminiKey) }

    func clear() {
        messages.removeAll()
        apiMessages.removeAll()
        turns.removeAll()
        attachment = nil
    }

    // MARK: Attachments

    private enum FileContent {
        case text(String)
        case pdf(Data, text: String)
        case image(Data, mime: String)
    }

    /// Returns an error message if the file can't be used.
    func attach(_ url: URL) -> String? {
        guard let content = readFile(url) else {
            return "I can't digest that kind of file. Try a PDF, image or text file (images under 5 MB)."
        }
        if case .image = content, activeBrain == .apple {
            return "My on-device brain can't see pictures yet. Try a PDF or text file, or use a Gemini key."
        }
        attachment = url
        return nil
    }

    private func readFile(_ url: URL) -> FileContent? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let imageTypes = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
                          "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"]
        if ext == "pdf" {
            guard data.count <= 20_000_000 else { return nil }
            let text = PDFDocument(data: data)?.string ?? ""
            return .pdf(data, text: text)
        }
        if let mime = imageTypes[ext] {
            guard data.count <= 5_000_000 else { return nil }
            return .image(data, mime: mime)
        }
        guard data.count <= 200_000, let text = String(data: data, encoding: .utf8) else { return nil }
        return .text(text)
    }

    // MARK: Sending

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isThinking, !text.isEmpty || attachment != nil else { return }
        let pet = PetStore.shared

        guard let brain = activeBrain else {
            messages.append(ChatMessage(role: .pet, text: setupHint, isError: true))
            return
        }
        if pet.pet.ranAway || pet.stage == .egg {
            messages.append(ChatMessage(role: .pet,
                text: pet.stage == .egg ? "(the egg wobbles… it can't talk yet!)" : "(no one is home…)",
                isError: true))
            return
        }

        let fileURL = attachment
        let file = fileURL.flatMap { readFile($0) }
        attachment = nil
        let question = text.isEmpty ? "Please take a look at this file and tell me what's in it." : text

        messages.append(ChatMessage(role: .user, text: text.isEmpty ? "(what's in this file?)" : text,
                                    attachmentName: fileURL?.lastPathComponent))
        isThinking = true
        pet.beginThinking()

        Task { @MainActor in
            do {
                let result: (String, [ChatSource])
                if brain == .claude {
                    result = try await self.askClaude(question, file: file, fileName: fileURL?.lastPathComponent)
                } else {
                    result = try await self.askFree(question, brain: brain, file: file,
                                                    fileName: fileURL?.lastPathComponent)
                }
                let sources = result.1
                var reply = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
                if reply.isEmpty { reply = "Hmm… I couldn't come up with an answer. Try asking another way?" }
                self.messages.append(ChatMessage(role: .pet, text: reply, sources: sources))
                self.isThinking = false
                PetStore.shared.finishedAnswer(success: true)
            } catch {
                self.messages.append(ChatMessage(role: .pet, text: error.localizedDescription, isError: true))
                self.isThinking = false
                PetStore.shared.finishedAnswer(success: false)
            }
            self.onAnswer?()
        }
    }

    private var todayText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        return formatter.string(from: Date())
    }

    // MARK: Free brains (Apple on-device / Gemini) + free search

    /// Small talk doesn't need a web search.
    private func wantsSearch(_ q: String) -> Bool {
        let lower = q.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count <= 2 {
            let chit: Set<String> = ["hi", "hello", "hey", "yo", "thanks", "thank", "ty", "ok", "okay",
                                     "lol", "bye", "gn", "morning", "night", "love", "cute", "good"]
            if words.allSatisfy({ chit.contains(String($0)) }) { return false }
        }
        if lower.hasPrefix("how are you") || lower.hasPrefix("who are you") || lower.hasPrefix("what's your name") {
            return false
        }
        return UserDefaults.standard.bool(forKey: Pref.freeSearch)
    }

    private func askFree(_ question: String, brain: Brain, file: FileContent?, fileName: String?)
        async throws -> (String, [ChatSource]) {
        let small = brain == .apple  // ~4k token context on-device
        let hits = wantsSearch(question) ? await FreeSearch.search(question, limit: small ? 4 : 6) : []

        var context = ""
        for (i, hit) in hits.enumerated() {
            let snippet = String(hit.snippet.prefix(small ? 350 : 700))
            context += "[\(i + 1)] \(hit.title) (\(hit.url.host ?? "")): \(snippet)\n"
        }

        var fileText = ""
        switch file {
        case .text(let t)?: fileText = t
        case .pdf(_, let t)?: fileText = t
        default: break
        }
        if !fileText.isEmpty {
            fileText = String(fileText.prefix(small ? 2500 : 30_000))
        }

        let pet = PetStore.shared
        let instructions = """
        You are \(pet.pet.name), a tiny cute virtual pet living in the notch of the user's Mac. \
        \(small ? "" : pet.personaForChat + " ")\
        Answer the user's question accurately and helpfully. Web search results may be provided; \
        prefer them over your own memory for anything recent, and never invent facts. If the results \
        don't answer it and you aren't sure, say so honestly. Keep answers short (under about 100 words), \
        plain text, no markdown or asterisks. A small cute touch is fine but the answer must be clear. \
        Reply in the user's language. Today is \(todayText).
        """

        var prompt = ""
        let history = turns.suffix(small ? 1 : 3)
        if !history.isEmpty {
            prompt += "Earlier in this chat:\n"
            for t in history {
                prompt += "User: \(t.user.prefix(small ? 200 : 600))\nYou: \(t.pet.prefix(small ? 300 : 800))\n"
            }
            prompt += "\n"
        }
        if !context.isEmpty { prompt += "Web search results:\n\(context)\n" }
        if !fileText.isEmpty { prompt += "The user shared a file named \(fileName ?? "file"):\n\(fileText)\n\n" }
        prompt += "User's question: \(question)"

        let answer: String
        if brain == .apple {
            answer = try await AppleBrain.respond(instructions: instructions, prompt: prompt)
        } else {
            var image: (Data, String)? = nil
            if case .image(let d, let m)? = file { image = (d, m) }
            if case .pdf(let d, let t)? = file, t.isEmpty { image = (d, "application/pdf") } // scanned PDF
            answer = try await askGemini(instructions: instructions, prompt: prompt, inline: image)
        }

        turns.append((question, answer))
        if turns.count > 6 { turns.removeFirst(turns.count - 6) }

        let sources = hits.prefix(3).map { hit in
            ChatSource(title: hit.title.count > 40 ? String(hit.title.prefix(38)) + "…" : hit.title, url: hit.url)
        }
        return (answer, Array(sources))
    }

    // MARK: Gemini

    /// Google renames/retires models often, so by default we ask Google which models this key can
    /// use and pick the newest free "Flash" one, remembering whichever worked last.
    private func geminiCandidates(key: String) async -> [String] {
        let defaults = UserDefaults.standard
        let setting = (defaults.string(forKey: Pref.geminiModel) ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "models/", with: "")
        var list: [String] = []
        if !setting.isEmpty && setting.lowercased() != "auto" { list.append(setting) }
        if let last = defaults.string(forKey: Pref.geminiWorkingModel), !last.isEmpty { list.append(last) }
        list += await listGeminiModels(key: key)
        list += ["gemini-flash-latest", "gemini-flash-lite-latest"]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private func listGeminiModels(key: String) async -> [String] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }

        let banned = ["image", "tts", "audio", "live", "embedding", "native", "exp", "computer",
                      "robotics", "thinking", "customtools", "learnlm", "veo", "imagen", "gemma", "nano"]
        struct Cand { let id: String; let version: Double; let lite: Bool; let preview: Bool }
        var cands: [Cand] = []
        for m in models {
            guard let name = m["name"] as? String,
                  let methods = m["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { continue }
            let id = name.replacingOccurrences(of: "models/", with: "")
            let low = id.lowercased()
            guard low.hasPrefix("gemini"), low.contains("flash"),
                  !banned.contains(where: { low.contains($0) }) else { continue }
            var version = 0.0
            if let r = low.range(of: #"gemini-(\d+(\.\d+)?)"#, options: .regularExpression) {
                version = Double(low[r].replacingOccurrences(of: "gemini-", with: "")) ?? 0
            }
            cands.append(Cand(id: id, version: version, lite: low.contains("lite"), preview: low.contains("preview")))
        }
        // Stable before preview, newest first, full Flash before Flash-Lite.
        cands.sort {
            if $0.preview != $1.preview { return !$0.preview }
            if $0.version != $1.version { return $0.version > $1.version }
            if $0.lite != $1.lite { return !$0.lite }
            return $0.id < $1.id
        }
        return cands.map { $0.id }
    }

    private enum GeminiOutcome { case ok(String), tryNext(String) }

    private func askGemini(instructions: String, prompt: String, inline: (Data, String)?) async throws -> String {
        guard let key = geminiKey, !key.isEmpty else { throw brainError(setupHint) }
        let candidates = await geminiCandidates(key: key)
        var lastProblem = "No Gemini model is available for this key."
        for model in candidates.prefix(6) {
            switch try await geminiRequest(model: model, key: key, instructions: instructions,
                                           prompt: prompt, inline: inline) {
            case .ok(let text):
                UserDefaults.standard.set(model, forKey: Pref.geminiWorkingModel)
                return text
            case .tryNext(let why):
                lastProblem = why
                if UserDefaults.standard.string(forKey: Pref.geminiWorkingModel) == model {
                    UserDefaults.standard.removeObject(forKey: Pref.geminiWorkingModel)
                }
            }
        }
        throw brainError(lastProblem)
    }

    private func geminiRequest(model: String, key: String, instructions: String, prompt: String,
                               inline: (Data, String)?) async throws -> GeminiOutcome {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            return .tryNext("That Gemini model name looks wrong. Set Model to auto in Settings ⚙︎")
        }
        var parts: [[String: Any]] = []
        if let inline = inline {
            parts.append(["inline_data": ["mime_type": inline.1, "data": inline.0.base64EncodedString()]])
        }
        parts.append(["text": prompt])

        var generation: [String: Any] = ["temperature": 0.6]
        if model.contains("2.5-flash") {
            generation["maxOutputTokens"] = 900
            generation["thinkingConfig"] = ["thinkingBudget": 0]  // faster, saves free quota
        } else {
            generation["maxOutputTokens"] = 4096  // newer models may "think" first
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": generation,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw brainError("I can't reach the internet right now. Check your connection? 📡")
        }
        let (data, response) = result
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let apiMsg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Unknown error"
            let low = apiMsg.lowercased()
            if status == 401 || (status == 400 && (low.contains("api key") || low.contains("credential"))) {
                throw brainError("That Gemini key didn't work. Check it in Settings ⚙︎ (\(apiMsg))")
            }
            switch status {
            case 404:
                return .tryNext("Gemini couldn't find a model to use (\(apiMsg))")
            case 403, 400:
                return .tryNext("Gemini said: \(apiMsg)")
            case 429:
                return .tryNext("I've used up today's free thinking quota 😴 Try again later (it resets daily).")
            case 500, 503:
                return .tryNext("Gemini is very busy right now. Try again shortly!")
            default:
                throw brainError("Something went wrong (\(status)): \(apiMsg)")
            }
        }
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        let parts2 = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts2.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        if text.isEmpty, (candidate?["finishReason"] as? String) == "SAFETY" {
            throw brainError("Gemini's safety filter blocked that one. Try rewording it?")
        }
        return .ok(text)
    }

    // MARK: Claude (paid, optional) — uses Anthropic's own web search tool

    private func askClaude(_ question: String, file: FileContent?, fileName: String?)
        async throws -> (String, [ChatSource]) {
        guard let key = claudeKey, !key.isEmpty else { throw brainError(setupHint) }
        var content: [[String: Any]] = []
        switch file {
        case .pdf(let d, _)?:
            content.append(["type": "document",
                            "source": ["type": "base64", "media_type": "application/pdf", "data": d.base64EncodedString()]])
        case .image(let d, let m)?:
            content.append(["type": "image", "source": ["type": "base64", "media_type": m, "data": d.base64EncodedString()]])
        case .text(let t)?:
            content.append(["type": "text", "text": "Contents of the file \(fileName ?? "file"):\n\n\(t)"])
        case nil:
            break
        }
        content.append(["type": "text", "text": question])
        apiMessages.append(["role": "user", "content": content])
        while apiMessages.count > 7 { apiMessages.removeFirst(2) }

        do {
            let (answer, sources, assistant) = try await runClaude(history: apiMessages, key: key)
            apiMessages.append(["role": "assistant", "content": assistant])
            return (answer, sources)
        } catch {
            // Drop the unanswered question so history stays user/assistant alternating.
            if let last = apiMessages.last, (last["role"] as? String) == "user" { apiMessages.removeLast() }
            throw error
        }
    }

    private func claudeSystemPrompt() -> String {
        let pet = PetStore.shared
        return """
        You are a tiny virtual pet who lives in the notch at the top of the user's Mac. \
        \(pet.personaForChat)

        Your job is to answer the user's questions accurately and helpfully. \
        Use web search whenever the answer depends on current events, prices, schedules, \
        recent facts or anything you're not sure about. Never make up facts or sources.

        Style: stay in character lightly — a short cute touch at the start or end is enough; \
        the answer itself must be clear and correct. Keep answers short (under about 120 words) \
        unless the user asks for more detail. Plain text only: no markdown, no headings, \
        no bullet symbols, no asterisks. Reply in the user's language.

        Today's date is \(todayText).
        """
    }

    private func runClaude(history: [[String: Any]], key: String)
        async throws -> (String, [ChatSource], [[String: Any]]) {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: Pref.model) ?? Pref.defaultModel
        let maxUses = max(1, min(10, defaults.integer(forKey: Pref.maxSearches)))
        let system = claudeSystemPrompt()

        var assistantContent: [[String: Any]] = []
        var texts: [String] = []
        var sources: [ChatSource] = []

        // "pause_turn" means a long search turn was paused; send it back to let it continue.
        for _ in 0..<4 {
            var convo = history
            if !assistantContent.isEmpty {
                convo.append(["role": "assistant", "content": assistantContent])
            }
            let tools: [[String: Any]] = [
                ["type": "web_search_20250305", "name": "web_search", "max_uses": maxUses],
            ]
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 1500,
                "system": system,
                "messages": convo,
                "tools": tools,
            ]
            let json = try await callClaude(body: body, key: key)
            let content = json["content"] as? [[String: Any]] ?? []
            assistantContent.append(contentsOf: content)
            collect(content, texts: &texts, sources: &sources)
            if (json["stop_reason"] as? String) != "pause_turn" { break }
        }
        return (texts.joined(), sources, assistantContent)
    }

    private func collect(_ content: [[String: Any]], texts: inout [String], sources: inout [ChatSource]) {
        for block in content where (block["type"] as? String) == "text" {
            if let t = block["text"] as? String { texts.append(t) }
            for cite in block["citations"] as? [[String: Any]] ?? [] {
                guard let s = cite["url"] as? String, let url = URL(string: s),
                      !sources.contains(where: { $0.url == url }) else { continue }
                let title = (cite["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (url.host ?? s)
                sources.append(ChatSource(title: title, url: url))
            }
        }
    }

    private func callClaude(body: [String: Any], key: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            throw brainError("I can't reach the internet right now. Check your connection? 📡")
        }
        let (data, response) = result
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let apiMsg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "Unknown error"
            switch status {
            case 401: throw brainError("That Claude API key didn't work. Check it in Settings ⚙︎")
            case 429: throw brainError("I'm being asked too much at once — try again in a minute. (\(apiMsg))")
            case 529, 503: throw brainError("Claude is very busy right now. Try again shortly!")
            default: throw brainError("Something went wrong (\(status)): \(apiMsg)")
            }
        }
        return json
    }
}
