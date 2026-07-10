import Foundation
import SwiftUI
import Translation

/// Apple Translation framework plumbing. The framework only hands out a
/// TranslationSession inside a SwiftUI `.translationTask` closure, and the
/// session must not escape it — so the broker inverts control: translators
/// enqueue requests per language pair, an invisible TranslationBridgeView
/// (mounted at the app root) attaches one `.translationTask` per active
/// pair, and each task's closure pulls requests and serves them for as long
/// as the app lives.
///
/// The broker itself is pure queue plumbing (no Translation API), so it
/// isn't availability-gated — only the bridge views are. That lets AppModel
/// hold it as a plainly-typed stored property on iOS 17.
@MainActor
final class AppleTranslationBroker: ObservableObject {

    struct Pair: Hashable, Identifiable {
        let source: String   // ISO-639-1 ("zh")
        let target: String
        var id: String { "\(source)→\(target)" }
    }

    /// A queued translation with single-resume semantics: whichever comes
    /// first — the bridge's answer or the timeout — wins, the other is a
    /// no-op, and the loser's task is cancelled instead of lingering.
    final class PendingRequest {
        let text: String
        private var continuation: CheckedContinuation<String, Error>?
        private let lock = NSLock()
        /// Cancelled on resume so a served request doesn't leave a sleeping
        /// 30 s task (and the request text) alive.
        var timeoutTask: Task<Void, Never>?

        init(text: String, continuation: CheckedContinuation<String, Error>) {
            self.text = text
            self.continuation = continuation
        }

        var isResolved: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation == nil
        }

        func resume(with result: Result<String, Error>) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            timeoutTask?.cancel()
            continuation?.resume(with: result)
        }
    }

    /// Pairs with at least one request so far; the bridge view renders one
    /// `.translationTask` per entry. Never shrinks — sessions are cheap and
    /// a conversation reuses its pairs constantly.
    @Published private(set) var activePairs: [Pair] = []

    private var pending: [Pair: [PendingRequest]] = [:]
    private var waiters: [Pair: [UUID: CheckedContinuation<PendingRequest?, Never>]] = [:]

    nonisolated init() {}

    /// Translate one utterance. Times out (rather than hanging a lane
    /// worker) if no session serves the pair — language pack not installed
    /// and the download sheet dismissed, typically. Generous because the
    /// clock starts at enqueue: the first use of a pair queues requests
    /// behind the language-pack download.
    nonisolated func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let pair = Pair(source: source, target: target)
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(text: text, continuation: continuation)
            request.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                request.resume(with: .failure(NSError(domain: "AppleTranslationBroker", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Apple Translation timed out — is the \(pair.id) language pack installed?"
                ])))
            }
            Task { @MainActor in
                self.enqueue(request, for: pair)
            }
        }
    }

    /// Bridge side: wait for the pair's next request. Returns nil when the
    /// waiting task is cancelled (its translationTask went away).
    func nextRequest(for pair: Pair) async -> PendingRequest? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PendingRequest?, Never>) in
                if var queue = pending[pair], !queue.isEmpty {
                    let first = queue.removeFirst()
                    pending[pair] = queue
                    continuation.resume(returning: first)
                    return
                }
                waiters[pair, default: [:]][id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters[pair]?.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    private func enqueue(_ request: PendingRequest, for pair: Pair) {
        if !activePairs.contains(pair) {
            Log.info("[translation] Apple Translation pair \(pair.id) activated")
            activePairs.append(pair)
        }
        if var pairWaiters = waiters[pair], let (id, waiter) = pairWaiters.first {
            pairWaiters.removeValue(forKey: id)
            waiters[pair] = pairWaiters
            waiter.resume(returning: request)
        } else {
            pending[pair, default: []].append(request)
        }
    }
}

/// Invisible view carrying one `.translationTask` per active language pair.
/// Mounted once behind ContentView; each task's closure owns its
/// TranslationSession for the app's lifetime and serves the broker's queue.
@available(iOS 18.0, *)
struct TranslationBridgeView: View {
    @ObservedObject var broker: AppleTranslationBroker

    var body: some View {
        ZStack {
            ForEach(broker.activePairs) { pair in
                PairBridge(pair: pair, broker: broker)
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@available(iOS 18.0, *)
private struct PairBridge: View {
    let pair: AppleTranslationBroker.Pair
    let broker: AppleTranslationBroker
    @State private var configuration: TranslationSession.Configuration

    init(pair: AppleTranslationBroker.Pair, broker: AppleTranslationBroker) {
        self.pair = pair
        self.broker = broker
        _configuration = State(initialValue: TranslationSession.Configuration(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target)
        ))
    }

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                do {
                    // Triggers the system language-pack download sheet on
                    // first use of a pair.
                    try await session.prepareTranslation()
                } catch {
                    Log.warn("[translation] prepare \(pair.id) failed: \(error.localizedDescription) — requests will time out until the pack installs")
                }
                while let request = await broker.nextRequest(for: pair) {
                    // A request that already timed out while queued isn't
                    // worth a translate call — skip to live ones.
                    guard !request.isResolved else { continue }
                    do {
                        let response = try await session.translate(request.text)
                        request.resume(with: .success(response.targetText))
                    } catch {
                        request.resume(with: .failure(error))
                    }
                }
            }
    }
}

/// UtteranceTranslator adapter: non-streaming (the framework returns whole
/// results), so the translation arrives as a single delta. On-device: $0.
@available(iOS 18.0, *)
final class AppleTranslationTranslator: UtteranceTranslator {
    private let broker: AppleTranslationBroker

    init(broker: AppleTranslationBroker) {
        self.broker = broker
    }

    func translate(_ text: String, from sourceLanguage: String, to targetLanguage: String,
                   context: [TranslationContextPair]) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let translated = try await broker.translate(text, from: sourceLanguage, to: targetLanguage)
                    continuation.yield(.delta(translated))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
