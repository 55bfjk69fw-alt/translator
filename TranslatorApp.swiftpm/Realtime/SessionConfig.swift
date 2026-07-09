import Foundation

/// Configuration for one realtime translation session (one per speaker).
struct SessionConfig {
    /// Dedicated live-translation model; continuous audio in -> translated
    /// audio + transcripts out, no turn lifecycle.
    var model: String = "gpt-realtime-translate"
    /// BCP-47 / ISO-639-1 target language ("en" for the DJI channels,
    /// "zh" for the push-to-talk return channel).
    var outputLanguage: String
    /// Source-transcription model enabled inside the translation session so
    /// we get the original-language transcript alongside the translation.
    var transcriptionModel: String = "gpt-realtime-whisper"

    /// Endpoint template; %@ is replaced with the model name. Overridable in
    /// Settings in case OpenAI moves the path.
    static let defaultEndpointTemplate = "wss://api.openai.com/v1/realtime/translations?model=%@"

    func url(endpointTemplate: String) -> URL? {
        URL(string: String(format: endpointTemplate, model))
    }

    /// session.update payload sent right after the socket opens, matching the
    /// GA translation-session shape from OpenAI's realtime translation guide:
    /// output language at session.audio.output.language, source transcription
    /// at session.audio.input.transcription. near_field noise reduction suits
    /// the DJI lav mics. Built as a dictionary (not Codable) so it stays easy
    /// to tweak on-device from DiagnosticsView evidence.
    func sessionUpdateEvent() -> [String: Any] {
        let input: [String: Any] = [
            "transcription": ["model": transcriptionModel],
            "noise_reduction": ["type": "near_field"]
        ]
        let audio: [String: Any] = [
            "input": input,
            "output": ["language": outputLanguage]
        ]
        let session: [String: Any] = ["audio": audio]
        return [
            "type": "session.update",
            "session": session
        ]
    }
}
