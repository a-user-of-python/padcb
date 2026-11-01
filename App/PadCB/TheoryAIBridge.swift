import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The OPTIONAL on-device AI tier of the theory checker (part 5).
///
/// Everything here runs through Apple's Foundation Models
/// framework: the model is ON the device, the summary text is
/// generated locally from the decrypted connection table + board
/// model, and nothing is sent anywhere — there is no network code
/// in this file at all. When the framework or the model isn't
/// available (older OS, Apple Intelligence off, model not ready),
/// `availability` says so plainly and the deterministic theory
/// heuristics remain the checker.
enum PCBTheoryAI {

    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(reason: "This device isn't eligible for Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable(reason: "Apple Intelligence is turned off in Settings.")
                case .modelNotReady:
                    return .unavailable(reason: "The on-device model isn't ready yet (it may still be downloading).")
                @unknown default:
                    return .unavailable(reason: "The on-device model is unavailable.")
                }
            }
        } else {
            return .unavailable(reason: "On-device AI needs iOS 26 or later.")
        }
        #else
        return .unavailable(reason: "This build has no on-device AI framework.")
        #endif
    }

    /// Ask the on-device model to review a board summary. Returns
    /// the model's plain-text suggestions, or a plain explanation
    /// of why it couldn't run. Advisory only — the deterministic
    /// checks are the authority; this text is labelled experimental
    /// wherever it is shown.
    static func review(summary: String) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                return "The on-device model isn't available right now."
            }
            // The on-device context window is small; keep the
            // summary compact (it is built compact — see
            // BoardSummaryText — and hard-capped here).
            let capped = String(summary.prefix(6000))
            let session = LanguageModelSession(instructions: """
                You are reviewing a printed circuit board design for a \
                hobbyist. You are given a factual summary of the board: \
                its components, nets, routing state and automated check \
                results. Point out likely design mistakes or risks a \
                human should double-check, in at most six short bullet \
                lines. Do not invent components, nets or values that \
                are not in the summary. If the summary shows no \
                problems, say so briefly.
                """)
            do {
                let response = try await session.respond(to: capped)
                return response.content
            } catch {
                return "The on-device AI pass failed: \(error.localizedDescription)"
            }
        } else {
            return "On-device AI needs iOS 26 or later."
        }
        #else
        return "This build has no on-device AI framework."
        #endif
    }
}
