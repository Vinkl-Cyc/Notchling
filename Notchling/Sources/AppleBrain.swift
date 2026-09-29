import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's built-in on-device model (Apple Intelligence). Free, private, works offline for the
/// thinking part. Needs macOS 26 (Tahoe) on an Apple Silicon Mac with Apple Intelligence turned on.
enum AppleBrain {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Human-readable status for Settings.
    static var statusText: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "Ready ✓ (free, runs on your Mac)"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "Not supported on this Mac (needs Apple Silicon)"
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in System Settings to use it"
                case .modelNotReady:
                    return "Apple Intelligence is still downloading — try again later"
                @unknown default:
                    return "Not available right now"
                }
            }
        }
        return "Needs macOS 26 Tahoe or newer"
        #else
        return "Not included in this build"
        #endif
    }

    /// Roughly 4k tokens of context, so callers must keep prompts short.
    static func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation:
                    throw brainError("Apple's on-device safety filter blocked that one. Try rewording it?")
                case .exceededContextWindowSize:
                    throw brainError("That was too much for my little brain at once. Try a shorter question or a new chat (↺).")
                default:
                    throw brainError("My on-device brain hiccuped: \(error.localizedDescription)")
                }
            }
        }
        #endif
        throw brainError("Apple's on-device AI isn't available on this Mac.")
    }
}

func brainError(_ text: String) -> NSError {
    NSError(domain: "Notchling", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}
