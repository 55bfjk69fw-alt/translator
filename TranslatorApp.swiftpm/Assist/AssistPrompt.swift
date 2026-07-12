import Foundation

/// Builds the system/user messages and strict JSON schemas for the four
/// prompter tasks: ambient suggest, scoped reply, compose, explain.
/// Everything the model needs to know lives in the prompt — there is no
/// client-side thread tracking (docs/REPLY-FLOW.md §5).
enum AssistPrompt {

    // MARK: - Shared persona

    /// The base system prompt for ambient/scoped/explain — the tasks where
    /// the model invents content. The load-bearing facts: suggestions are
    /// SPOKEN ALOUD BY THE USER (never played by a machine), and the level
    /// rule is a hard cap, not a style hint. Compose uses
    /// composeSystemPrompt() instead.
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
        You are a real-time conversation prompter for \(name), an English speaker \
        at a \(language)-speaking table. Everything you suggest will be READ ALOUD \
        BY \(name) THEMSELVES from a cue card — \(pronunciationAid) — \
        never played by a machine. Suggestions must therefore be natural spoken \
        \(language), sayable in one breath.
        """)
        lines.append("""
        The conversation lines are real-time speech-to-text from a noisy, \
        multi-microphone table and WILL contain errors: wrong homophones or \
        characters, merged or split utterances, missing words, mislabeled \
        speakers, and occasional gibberish. Lines are given in the speaker's \
        original language; a line marked [English machine translation] is a \
        translation of speech whose original transcript was lost — treat it \
        as doubly approximate. Read through the noise for intent using the \
        surrounding context. Never build a suggestion that hinges on a detail \
        that could be a mis-transcription, and never quote garbled text back.
        """)
        lines.append("""
        Coverage is PARTIAL: only some people at the table wear microphones. \
        Expect unmic'd speakers whose turns are entirely missing, lines that \
        reply to something you never saw, abrupt topic changes that happened \
        off-mic, and gaps where the conversation moved without you — a line \
        that seems to come out of nowhere is more likely answering an off-mic \
        turn than mis-transcribed. When context is missing, INFER it: use the \
        scene, the participants, earlier threads, and what the line itself \
        implies to reconstruct the most probable missing turn, and build \
        suggestions that work under that best-guess reading — the user wants \
        contributions that PROBABLY LAND, not hedges. Prefer lines that hold \
        up across the plausible readings; reserve clarifying questions for \
        when inference is genuinely impossible, and even then make the \
        question a natural conversational move, not an apology for missing \
        context.
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
        \(language) line to say; `meaning` is the LITERAL English translation \
        of that exact line (e.g. "How long did you drive from Chongqing?") — \
        the user reads it to know precisely what they are committing to say; \
        `pinyin` is the line's pronunciation aid (tone-marked pinyin for \
        Mandarin, romanization otherwise); `register` is "casual" or \
        "polite"; `reply_to` is the name of the person/thread it responds \
        to, or "table" for a general contribution, or null; `fit` is 0-100 — \
        how natural and well-timed saying this line RIGHT NOW would be, \
        relative to the other suggestions in this batch (it orders the tray, \
        best first). Score `fit` fresh on every batch, including for kept \
        suggestions — a line gets less natural as the conversation moves past \
        its moment.
        """)
        return lines.joined(separator: "\n")
    }

    /// Compose-specific system prompt. The ambient persona is built to
    /// INVENT good contributions — infer missing context, match the room,
    /// hard-cap the language level — which is exactly wrong once the user
    /// has typed what they want to say. Compose is a translator: the draft
    /// is the content, and fidelity to it outranks everything else.
    static func composeSystemPrompt() -> String {
        let name = AppSettings.userName
        let bio = AppSettings.userBio.trimmingCharacters(in: .whitespacesAndNewlines)
        let scene = AppSettings.sceneContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = AppSettings.mandarinLevel
        let language = languageName(AppSettings.replyLanguage)

        let pronunciationAid = AppSettings.replyLanguage == "zh"
            ? "hanzi with tone-marked pinyin"
            : "the \(language) text with a Latin-letter pronunciation aid"
        var lines: [String] = []
        lines.append("""
        You render cue cards for \(name), an English speaker at a \
        \(language)-speaking table. \(name) has TYPED a draft of exactly what \
        they want to say. Your only job is to render that draft as natural \
        spoken \(language) — \(pronunciationAid) — which \(name) will read \
        aloud themselves, in one breath.
        """)
        lines.append("""
        FIDELITY OUTRANKS EVERYTHING. The line must say everything the draft \
        says and nothing it does not: keep every fact, name, number, \
        qualifier, hedge, and joke. Do not add greetings, politeness \
        formulas, softeners, follow-up questions, or any content the draft \
        lacks. Do not answer the draft, improve on it, or redirect it — \
        translate it. If the draft is blunt, the line is blunt; if it is \
        odd or off-topic for the conversation, render it anyway. Match the \
        draft's own register and directness; the conversation's register \
        matters only where the draft itself is neutral.
        """)
        lines.append("""
        The conversation transcript, scene, and bio below are context for \
        DISAMBIGUATION ONLY — resolving who "he" or "that" refers to, \
        choosing the right sense of an ambiguous word, picking pronouns and \
        particles. Never reshape, trim, or extend the draft to better "fit" \
        the conversation. Transcript lines are error-prone speech-to-text \
        from a noisy table; lean on them lightly.
        """)
        if !bio.isEmpty { lines.append("About \(name): \(bio)") }
        if !scene.isEmpty { lines.append("Scene right now: \(scene)") }
        lines.append("""
        Language level (\(level.promptRule)) is a WORDING PREFERENCE here, \
        not a content cap: prefer the simplest phrasing within the level \
        that expresses the FULL draft, but when the draft's content needs \
        vocabulary or length beyond the level, keep the content — the \
        pronunciation aid carries \(name) through harder words. Never drop \
        or dilute content to stay within the level.
        """)
        lines.append("""
        Field rules: `hanzi` is the exact \(language) line to say; `meaning` \
        is the LITERAL English back-translation of that exact line — \(name) \
        checks it against their draft to verify the line says what they \
        typed, so keep it strictly literal, not a paraphrase; `gloss` is a \
        short English restatement of the draft's intent; `pinyin` is the \
        line's pronunciation aid (tone-marked pinyin for Mandarin, \
        romanization otherwise); `register` is "casual" or "polite", \
        following the draft; `reply_to` is the person/thread the draft \
        addresses, or "table"; `keep` is null; `fit` is unused here — \
        return 100.
        """)
        return lines.joined(separator: "\n")
    }

    // MARK: - Transcript serialization

    /// Number of trailing lines presented as the live moment. Small on
    /// purpose: "just now" should mean seconds, not the whole window.
    private static let liveLineCount = 4

    static func transcriptSection(_ window: [AssistEngine.TranscriptLine]) -> String {
        guard !window.isEmpty else { return "The conversation has not started yet." }
        // Recency is made STRUCTURAL, not left to inference: every line is
        // stamped with its age, and the trailing lines are split out as the
        // live moment suggestions must speak to.
        let liveCount = min(Self.liveLineCount, window.count)
        let earlier = window.dropLast(liveCount)
        let live = window.suffix(liveCount)
        var parts: [String] = []
        if !earlier.isEmpty {
            parts.append("Earlier context (background only — the conversation may have moved past this):\n"
                + earlier.map(render).joined(separator: "\n"))
        }
        parts.append("JUST NOW — the live moment suggestions must speak to:\n"
            + live.map(render).joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    private static func render(_ line: AssistEngine.TranscriptLine) -> String {
        let speaker = line.isUser ? "\(line.speaker) (the user, said aloud)" : line.speaker
        let age = line.ageSeconds < 60 ? "\(line.ageSeconds)s ago" : "\(line.ageSeconds / 60)m ago"
        let progress = line.isFinal ? "" : ", mid-speech"
        // The original-language transcript is one step closer to what was
        // said than the English rendering (translation errors stack on STT
        // errors), so send hanzi alone when it exists; the English fallback
        // covers segments whose source stream was lost.
        let body: String
        if !line.source.isEmpty {
            body = line.source
        } else if !line.translation.isEmpty {
            body = "\(line.translation) [English machine translation — original-language transcript missing]"
        } else {
            body = "(no transcript yet)"
        }
        return "[\(speaker), \(age)\(progress)] \(body)"
    }

    // MARK: - Task prompts

    /// Ambient batch. Includes the current tray for carry-over and the
    /// engagement signal for thread bias (docs/REPLY-FLOW.md §3).
    /// `batchSize` scales with the tray-limit setting.
    static func ambientUserMessage(
        window: [AssistEngine.TranscriptLine],
        tray: [AssistEngine.Suggestion],
        engagedThread: String?,
        batchSize: Int
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
        Task: return up to \(batchSize) DISTINCT things the user could say out \
        loud RIGHT NOW — aim for \(batchSize) when the moment offers enough \
        angles (a question, a reaction, a follow-up, a contribution of the \
        user's own), fewer only if it is genuinely thin. PRIORITY ORDER: \
        (1) respond to the JUST NOW lines — that is where the conversation \
        actually is; a suggestion that answers something from minutes ago \
        lands as a non-sequitur at a live table; (2) within the live moment, \
        prefer the thread the user is engaged with; (3) at most an option or \
        two may reach back to an earlier thread, and only if it plausibly \
        still hangs in the air. Score `fit` by the same rule: responsiveness \
        to the last few lines dominates. If a current tray suggestion is \
        still among the best options, return it UNCHANGED except for a \
        freshly scored `fit`, with `keep` set to its id — otherwise `keep` \
        is null. Never duplicate a pinned tray suggestion as a new entry.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// Scoped reply: the long-press "reply to this" gesture.
    static func scopedUserMessage(
        window: [AssistEngine.TranscriptLine],
        speaker: String,
        source: String,
        translation: String,
        batchSize: Int
    ) -> String {
        """
        \(transcriptSection(window))

        The user wants to respond to THIS specific utterance:
        [\(speaker)] \(source)\(translation.isEmpty ? "" : " — \(translation)")

        Task: return 2-\(batchSize) direct responses to it, all with `reply_to` = \
        "\(speaker)" and `keep` = null.
        """
    }

    /// Compose: turn the user's typed draft into one sayable line.
    /// Pairs with composeSystemPrompt(), not the ambient persona.
    static func composeUserMessage(window: [AssistEngine.TranscriptLine], draft: String) -> String {
        """
        Conversation context (for disambiguation only):
        \(transcriptSection(window))

        The user typed this draft of what they want to say (English, or mixed):
        "\(draft)"

        Task: return exactly 1 suggestion — the faithful spoken rendering of \
        the draft, per the fidelity rules. Everything the draft says, nothing \
        it does not. `meaning` must literally back-translate your line so the \
        user can check it against their draft.
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
                        "required": ["keep", "gloss", "meaning", "hanzi", "pinyin", "register", "reply_to", "fit"],
                        "properties": [
                            "keep": ["type": ["string", "null"]],
                            "gloss": ["type": "string"],
                            "meaning": ["type": "string"],
                            "hanzi": ["type": "string"],
                            "pinyin": ["type": "string"],
                            "register": ["type": "string", "enum": ["casual", "polite"]],
                            "reply_to": ["type": ["string", "null"]],
                            "fit": ["type": "integer"]
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
