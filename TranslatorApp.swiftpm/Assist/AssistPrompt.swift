import Foundation

/// Builds the system/user messages and strict JSON schemas for the four
/// co-pilot tasks: ambient suggest, scoped reply, compose, explain.
/// Everything the model needs to know lives in the prompt — there is no
/// client-side thread tracking (docs/REPLY-FLOW.md §5).
enum AssistPrompt {

    // MARK: - Shared persona

    /// The base system prompt. The load-bearing facts: suggestions are
    /// SPOKEN ALOUD BY THE USER (never played by a machine), and the level
    /// rule is a hard cap, not a style hint.
    static func systemPrompt() -> String {
        let name = AppSettings.userName
        let bio = AppSettings.userBio.trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = AppSettings.sceneContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = AppSettings.mandarinLevel
        let tone = AppSettings.suggestionTone
        let language = languageName(AppSettings.replyLanguage)

        let pronunciationAid = AppSettings.replyLanguage == "zh"
            ? "hanzi with tone-marked pinyin"
            : "the \(language) text with a Latin-letter pronunciation aid"
        var lines: [String] = []
        lines.append("""
        You are a real-time conversation co-pilot for \(name), an English speaker \
        at a \(language)-speaking table. Everything you suggest will be READ ALOUD \
        BY \(name) THEMSELVES from a cue card — \(pronunciationAid) — \
        never played by a machine. Suggestions must therefore be natural spoken \
        \(language), sayable in one breath.
        """)
        if !bio.isEmpty { lines.append("About \(name): \(bio)") }
        if !scene.isEmpty { lines.append("Scene right now: \(scene)") }
        lines.append("Language level (HARD CAP, never exceed it): \(level.promptRule).")
        switch tone {
        case "casual": lines.append("Tone: keep it casual.")
        case "polite": lines.append("Tone: keep it polite/formal.")
        default: lines.append("Tone: match the register of the conversation.")
        }
        lines.append("""
        Field rules: `gloss` is a short English description of what saying it \
        accomplishes (e.g. "Ask how long the drive was"); `hanzi` is the exact \
        \(language) line to say; `pinyin` is its pronunciation aid \
        (tone-marked pinyin for Mandarin, romanization otherwise); `register` \
        is "casual" or "polite"; `reply_to` is the name of the person/thread \
        it responds to, or "table" for a general contribution, or null.
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: - Transcript serialization

    static func transcriptSection(_ window: [AssistEngine.TranscriptLine]) -> String {
        guard !window.isEmpty else { return "The conversation has not started yet." }
        let lines = window.map { line in
            let speaker = line.isUser ? "\(line.speaker) (the user, said aloud)" : line.speaker
            let source = line.source.isEmpty ? "(no transcript)" : line.source
            let translation = line.translation.isEmpty ? "" : " — \(line.translation)"
            return "[\(speaker)] \(source)\(translation)"
        }
        return "Recent conversation, oldest first:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Task prompts

    /// Ambient batch. Includes the current tray for carry-over and the
    /// engagement signal for thread bias (docs/REPLY-FLOW.md §3).
    static func ambientUserMessage(
        window: [AssistEngine.TranscriptLine],
        tray: [AssistEngine.Suggestion],
        engagedThread: String?
    ) -> String {
        var parts: [String] = [transcriptSection(window)]
        if !tray.isEmpty {
            // Real JSON serialization: glosses are model output and often
            // contain quotes — hand-interpolated pseudo-JSON corrupts the
            // tray section the keep/carry-over mechanism reads ids from.
            let chips: [[String: Any]] = tray.map { chip in
                ["id": chip.id, "gloss": chip.gloss, "reply_to": chip.replyTo ?? "table", "pinned": chip.pinned]
            }
            if let data = try? JSONSerialization.data(withJSONObject: chips),
               let json = String(data: data, encoding: .utf8) {
                parts.append("Current suggestion tray (JSON):\n" + json)
            }
        }
        if let engagedThread {
            parts.append("The user most recently engaged with: \(engagedThread).")
        }
        parts.append("""
        Task: identify the conversation threads currently active, then return 2-3 \
        things the user could say out loud RIGHT NOW. Bias toward the thread the \
        user is engaged with; include at most one option from a different thread. \
        If a current tray suggestion is still among the best options, return it \
        UNCHANGED with `keep` set to its id — otherwise `keep` is null. Never \
        duplicate a pinned tray suggestion as a new entry.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// Scoped reply: the long-press "reply to this" gesture.
    static func scopedUserMessage(
        window: [AssistEngine.TranscriptLine],
        speaker: String,
        source: String,
        translation: String
    ) -> String {
        """
        \(transcriptSection(window))

        The user wants to respond to THIS specific utterance:
        [\(speaker)] \(source)\(translation.isEmpty ? "" : " — \(translation)")

        Task: return 2-3 direct responses to it, all with `reply_to` = "\(speaker)" \
        and `keep` = null.
        """
    }

    /// Compose: turn the user's typed draft into one sayable line.
    static func composeUserMessage(window: [AssistEngine.TranscriptLine], draft: String) -> String {
        """
        \(transcriptSection(window))

        The user typed this draft of what they want to say (English, or mixed):
        "\(draft)"

        Task: return exactly 1 suggestion — the most natural spoken rendering of \
        the draft that fits the conversation and the level cap. Preserve the \
        user's intent exactly; do not add content. `keep` = null; `reply_to` = \
        the thread it fits, or "table".
        """
    }

    /// Explain: nuance + key phrases for one utterance (never enters the
    /// transcript; docs/REPLY-FLOW.md §9.3).
    static func explainUserMessage(speaker: String, source: String, translation: String) -> String {
        """
        Explain this utterance from a live conversation to the user:
        [\(speaker)] \(source)\(translation.isEmpty ? "" : " — \(translation)")

        Task: `explanation` is 1-3 sentences on what it really means — nuance, \
        idiom, cultural subtext — beyond the literal translation. `key_phrases` \
        is the 1-3 most useful phrases inside it, each with hanzi, tone-marked \
        pinyin, and meaning. Dinner-table sized, not a lesson.
        """
    }

    // MARK: - Schemas (strict: every property required, no extras)

    static func suggestionsSchema(maxItems: Int) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["suggestions"],
            "properties": [
                "suggestions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": maxItems,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["keep", "gloss", "hanzi", "pinyin", "register", "reply_to"],
                        "properties": [
                            "keep": ["type": ["string", "null"]],
                            "gloss": ["type": "string"],
                            "hanzi": ["type": "string"],
                            "pinyin": ["type": "string"],
                            "register": ["type": "string", "enum": ["casual", "polite"]],
                            "reply_to": ["type": ["string", "null"]]
                        ]
                    ]
                ]
            ]
        ]
    }

    static func explanationSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["explanation", "key_phrases"],
            "properties": [
                "explanation": ["type": "string"],
                "key_phrases": [
                    "type": "array",
                    "minItems": 0,
                    "maxItems": 3,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["hanzi", "pinyin", "meaning"],
                        "properties": [
                            "hanzi": ["type": "string"],
                            "pinyin": ["type": "string"],
                            "meaning": ["type": "string"]
                        ]
                    ]
                ]
            ]
        ]
    }

    /// Human name for a reply-language code, for the prompt.
    static func languageName(_ code: String) -> String {
        switch code {
        case "zh": return "Mandarin"
        case "en": return "English"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "ar": return "Arabic"
        default: return code
        }
    }
}
