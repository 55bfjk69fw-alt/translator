import Foundation
import AVFoundation
import Speech

/// On-device STT for one lane via the iOS 26 SpeechAnalyzer stack:
/// continuous 24 kHz PCM16 in, volatile + finalized transcript results out.
///
/// ⚠️ API-surface note: this file is written against the SpeechAnalyzer /
/// SpeechTranscriber / AssetInventory surface shown in WWDC25 session
/// "Bring advanced speech-to-text to your app" and its sample code. It is
/// the one place in the staged pipeline that talks to the iOS 26 speech
/// SDK — if names shifted between the beta and the shipping SDK, fix them
/// here (build on-device in Swift Playgrounds; the rest of the pipeline
/// doesn't touch these types).
@available(iOS 26.0, *)
final class SpeechTranscriberStage {

    struct Result {
        let text: String
        let isFinal: Bool
    }

    private let locale: Locale
    private let label: String

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var forwardTask: Task<Void, Never>?

    /// The staged client's fixed input format (matches StreamResampler's
    /// output and the realtime wire format).
    private static let pcm16Format = StreamResampler.targetFormat

    init(localeIdentifier: String, label: String) {
        self.locale = Locale(identifier: localeIdentifier)
        self.label = label
    }

    /// Ensure locale support + model assets, build the analyzer, and return
    /// the transcript stream. Asset download (first use of a language) can
    /// take a while — the caller shows this as the lane's "connecting"
    /// state.
    func start() async throws -> AsyncThrowingStream<Result, Error> {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        try await Self.ensureAssets(for: transcriber, locale: locale, label: label)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "SpeechTranscriberStage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No compatible audio format for on-device transcription (\(locale.identifier))"
            ])
        }
        analyzerFormat = format
        if format != Self.pcm16Format {
            guard let converter = AVAudioConverter(from: Self.pcm16Format, to: format) else {
                throw NSError(domain: "SpeechTranscriberStage", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot convert 24 kHz PCM16 to the analyzer format \(format)"
                ])
            }
            self.converter = converter
        }
        Log.info("[\(label)] on-device STT ready: \(locale.identifier), analyzer format \(Int(format.sampleRate)) Hz")

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = inputBuilder
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)

        // Re-emit the transcriber's results as a plain-struct stream so the
        // rest of the pipeline stays decoupled from the Speech types.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        continuation.yield(Result(text: text, isFinal: result.isFinal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.forwardTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Append 24 kHz mono PCM16 LE audio. Cheap: one buffer wrap plus an
    /// optional format conversion, then a stream yield.
    func append(pcm16: Data) {
        guard let inputContinuation else { return }
        guard let buffer = Self.buffer(fromPCM16: pcm16) else { return }
        if let converter, let analyzerFormat {
            guard let converted = Self.convert(buffer, with: converter, to: analyzerFormat) else { return }
            inputContinuation.yield(AnalyzerInput(buffer: converted))
        } else {
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Stop accepting audio and let the analyzer finalize whatever is
    /// pending. Deliberately does NOT cancel the forwarding task: the last
    /// finalized result may still be draining out of transcriber.results,
    /// and the stream finishes on its own once the analyzer ends — the
    /// speaker's final words must reach the assembler's flush. (The staged
    /// client's bounded close drain is the backstop if it never ends.)
    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.warn("[\(label)] STT finalize failed: \(error.localizedDescription)")
        }
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Assets

    private static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale, label: String) async throws {
        let wanted = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw NSError(domain: "SpeechTranscriberStage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "On-device transcription doesn't support \(locale.identifier) — pick another spoken language or the Realtime pipeline"
            ])
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == wanted }) { return }
        Log.info("[\(label)] downloading on-device speech model for \(locale.identifier)…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
            Log.info("[\(label)] speech model for \(locale.identifier) installed")
        }
    }

    // MARK: - Buffer plumbing

    private static func buffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm16Format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let target = buffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            target.update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        return buffer
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else {
            if let error { Log.warn("STT input conversion failed: \(error.localizedDescription)") }
            return nil
        }
        return output
    }
}
