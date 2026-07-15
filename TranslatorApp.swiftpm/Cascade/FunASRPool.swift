import Foundation
import AVFoundation

/// Cloud STT pool: Alibaba Bailian's `fun-asr-realtime` dialect model
/// (晋语/Jin incl. the Datong area — docs/DATONG-STT.md) behind the
/// STTPool seam.
///
/// Shape mirrors AnalyzerPool's per-utterance slot discipline. Each slot
/// owns a persistent WebSocket reused across utterances via
/// run-task/finish-task cycles (the API docs bless connection reuse after
/// task-finished; after task-failed the connection is unusable and is
/// dropped). A dead socket is rebuilt on the next acquire, so a network
/// blip costs one utterance's text, not the conversation: the engine's
/// bounded settle already tolerates a resultless utterance, and the lane
/// recovers on the next grant. Sustained failure latches acquire shut
/// (nil grants → lanes surface .failed) with a half-open retry every
/// cooldown, mirroring the MT stage's latch discipline (§14.1).
///
/// Wire protocol (captured 2026-07-15 from the Bailian WebSocket API
/// reference — endpoints/auth, client events, server events):
///  - connect `wss://…/api-ws/v1/inference`, `Authorization: Bearer key`
///    (validated at the WS handshake: bad key = HTTP 401/403 refusal)
///  - → run-task {task_group: audio, task: asr, function: recognition,
///    model, parameters: {format: pcm, sample_rate, language_hints?},
///    input: {}} — ← task-started, then binary mono PCM16 frames flow
///  - ← result-generated {output.sentence: {text, sentence_end,
///    heartbeat, sentence_id}, usage.duration (billed s, finals only)}.
///    Partial text is the CURRENT sentence's accumulated replacement —
///    exactly the volatile semantics the engine's replace-path renders —
///    and a mid-capture sentence_end final maps onto the engine's
///    sub-segment release (per-sentence finals, stream continues).
///  - → finish-task → trailing finals → ← task-finished
///
/// Two contract adaptations to AnalyzerPool's field-proven semantics:
///  - The engine settles on the FIRST final after a close, and Apple
///    flushes exactly one cumulative final — so during the finish flush
///    this pool HOLDS sentence finals and emits ONE merged final at task
///    end (a second trailing final would be epoch-dropped and its text
///    lost).
///  - finish-task is never sent before task-started: the pre-start
///    audio backlog must flush first, or the server finishes a task
///    that heard nothing (the entire first utterance on a fresh socket).
///
/// Threading: actor-confined. Sends are chained (each awaits its
/// predecessor) because parallel Tasks would reorder audio frames; every
/// await a lane worker can block on is bounded (STTPool contract).
actor FunASRPool: STTPool {

    struct Config {
        let apiKey: String
        /// Regional inference endpoint (AppSettings.DashScopeRegion).
        let endpoint: URL
        let model: String
        /// Two-letter hint ("zh") when the source language is one the
        /// model lists; nil lets the model auto-detect.
        let languageHint: String?
        /// Dollars flow here per finished task once the rate is known;
        /// wired at construction (CascadeContext) so no billing can
        /// precede the sink. nil = seconds counted and logged only.
        let costSink: (@Sendable (Double) -> Void)?
    }

    /// Per-second list price — UNKNOWN until the owner confirms it with
    /// Alibaba (docs/DATONG-STT.md §2.1). nil = billed seconds are
    /// counted and logged but no dollars flow to the CostMeter; set this
    /// to light the meter up.
    static let dollarsPerBilledSecond: Double? = nil

    /// The wire format (and the seam's analyzerFormat): 16 kHz mono
    /// PCM16. One constant — the silence math, byte caps, and run-task
    /// JSON must never disagree about the rate.
    private static let sampleRate = 16_000
    private static let bytesPerSecond = sampleRate * MemoryLayout<Int16>.size

    /// Sustained-failure latch: after this many consecutive failed tasks
    /// acquire returns nil (lanes go .failed like a dead AnalyzerPool)
    /// except one half-open probe grant per cooldown; any finished task
    /// un-latches.
    private static let failureLatchThreshold = 3
    private static let halfOpenCooldownSeconds: TimeInterval = 10

    private final class Slot {
        var socket: URLSessionWebSocketTask?
        var reader: Task<Void, Never>?
        /// Order-preserving send chain: created under actor isolation,
        /// each link awaits its predecessor.
        var sendChain: Task<Void, Never>?
        var owner: (@Sendable (STTResultEvent) -> Void)?
        var taskID = ""
        /// run-task sent, terminal state (finished/failed/abandoned) not
        /// yet reached.
        var taskActive = false
        /// task-started received: audio flows directly. Before it, audio
        /// queues in `pending` (the run-task round trip is ≥1 RTT; the
        /// utterance's opening frames land here).
        var started = false
        var pending: [Data] = []
        var pendingBytes = 0
        /// finishAndRetire ran before task-started: send finish-task
        /// right after the backlog flush, never before it.
        var finishPending = false
        /// The finish flush is underway: sentence finals are HELD (see
        /// heldFinals) and merged into one final at task end.
        var finishing = false
        var heldFinals: [String] = []
        /// Owned by a lane (acquire → finishAndRetire/release cleanup).
        var busy = false
        var finishWaiter: ResumeOnce?
        /// usage.duration of the task's latest final — task-cumulative
        /// per the API doc, so only the last value counts.
        var taskBilledSeconds = 0
    }

    private var slots: [Slot] = []
    private var freeSlots: [Int] = []
    /// FIFO waiters; resumed with a slot index, or nil at teardown.
    private var waiters: [CheckedContinuation<Int?, Never>] = []
    private(set) var analyzerFormat: AVAudioFormat?
    private(set) var poolSize = 0
    private var tornDown = false
    private let config: Config
    private let session = URLSession(configuration: .default)
    /// Conversation-total billed seconds (from usage.duration) and task
    /// failures, for the teardown log line and field diagnosis.
    private var billedSeconds = 0
    private var taskFailures = 0
    /// Failure latch state (see failureLatchThreshold).
    private var consecutiveFailures = 0
    private var lastHalfOpenProbeAt: Date?

    /// ~60 s of wire audio — matches the lane buffer's cap intent;
    /// drop-oldest beyond it (an unstarted task this far behind is dead
    /// anyway).
    private static let pendingBytesCap = 60 * bytesPerSecond

    init(config: Config) {
        self.config = config
    }

    // MARK: - Resume-once (bounded awaits; same primitive as AnalyzerPool)

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
        /// True when THIS call won the race (so losers can skip their
        /// logging — a timeout arm firing after success is not news).
        @discardableResult
        func resume(_ value: Bool) -> Bool {
            lock.lock()
            let taken = continuation
            continuation = nil
            lock.unlock()
            taken?.resume(returning: value)
            return taken != nil
        }
    }

    // MARK: - Build (Start) — auth/reachability probe

    /// `locale` is unused (the language hint travels in Config): the
    /// model auto-detects language/dialect within the hint.
    func build(locale: Locale, cap: Int) async -> Int {
        guard slots.isEmpty, !tornDown else { return poolSize }
        guard !config.apiKey.isEmpty else {
            Log.error("[funasr] no DashScope API key — STT stage unavailable")
            return 0
        }
        // One throwaway task proves the key and endpoint before Start
        // goes green: a cloud STT stage that cannot reach its server must
        // fail Start (readiness), not the first utterance.
        guard await probe() else { return 0 }
        // A Stop can land during the probe; slots built on a torn-down
        // pool would report a live pool for a dead conversation
        // (AnalyzerPool.makeSlot re-checks for the same race).
        guard !tornDown else { return 0 }
        analyzerFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(Self.sampleRate),
            channels: 1, interleaved: true
        )
        let size = max(1, cap)
        slots = (0..<size).map { _ in Slot() }
        freeSlots = Array(0..<size)
        poolSize = size
        Log.info("[funasr] \(size) slot(s) ready (\(config.model) @ \(config.endpoint.host ?? "?"))")
        return size
    }

    /// Connect + run-task + await task-started, bounded. Auth failures
    /// surface here as a handshake refusal (receive throws).
    private func probe() async -> Bool {
        let socket = session.webSocketTask(with: makeRequest())
        socket.resume()
        let taskID = UUID().uuidString
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                do {
                    try await socket.send(.string(Self.runTaskJSON(taskID: taskID, config: self.config)))
                    while true {
                        let message = try await socket.receive()
                        guard case .string(let text) = message,
                              let event = Self.parseEvent(text) else { continue }
                        if event.name == "task-started" { once.resume(true); return }
                        if event.name == "task-failed" {
                            if once.resume(false) {
                                Log.error("[funasr] probe task failed: \(event.errorCode ?? "?") — \(event.errorMessage ?? "?")")
                            }
                            return
                        }
                    }
                } catch {
                    // Post-success cancellation lands here too — only the
                    // race winner reports.
                    if once.resume(false) {
                        Log.error("[funasr] probe failed: \(error.localizedDescription) — check the DashScope key/region")
                    }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if once.resume(false) {
                    Log.warn("[funasr] probe timed out after 8 s")
                }
            }
        }
        socket.cancel(with: .normalClosure, reason: nil)
        return ok
    }

    // MARK: - Acquisition (per utterance)

    func acquire(onResult: @escaping @Sendable (STTResultEvent) -> Void) async -> Int? {
        guard !tornDown, poolSize > 0 else { return nil }
        // Sustained-failure latch: fail fast (lanes surface .failed, the
        // AnalyzerPool dead-pool contract) instead of silently eating
        // every utterance, but let one probe grant through per cooldown —
        // a successful task un-latches (endTask .finished).
        if consecutiveFailures >= Self.failureLatchThreshold {
            let now = Date()
            if let last = lastHalfOpenProbeAt,
               now.timeIntervalSince(last) < Self.halfOpenCooldownSeconds {
                return nil
            }
            lastHalfOpenProbeAt = now
            Log.warn("[funasr] \(consecutiveFailures) consecutive task failures — granting a half-open probe slot")
        }
        if let free = freeSlots.first {
            freeSlots.removeFirst()
            beginUtterance(free, onResult: onResult)
            return free
        }
        let index: Int? = await withCheckedContinuation { waiters.append($0) }
        guard let index, !tornDown else { return nil }
        beginUtterance(index, onResult: onResult)
        return index
    }

    private func beginUtterance(_ index: Int, onResult: @escaping @Sendable (STTResultEvent) -> Void) {
        let slot = slots[index]
        slot.owner = onResult
        slot.busy = true
        slot.taskID = UUID().uuidString
        slot.taskActive = true
        slot.started = false
        slot.pending = []
        slot.pendingBytes = 0
        slot.finishPending = false
        slot.finishing = false
        slot.heldFinals = []
        slot.taskBilledSeconds = 0
        ensureSocket(index)
        chainSend(index, .string(Self.runTaskJSON(taskID: slot.taskID, config: config)))
    }

    private func ensureSocket(_ index: Int) {
        let slot = slots[index]
        guard slot.socket == nil else { return }
        let socket = session.webSocketTask(with: makeRequest())
        slot.socket = socket
        slot.sendChain = nil
        socket.resume()
        slot.reader = Task { await self.readLoop(index: index, socket: socket) }
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Audio in

    func feed(slotIndex: Int, buffer: AVAudioPCMBuffer) {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let slot = slots[slotIndex]
        guard slot.busy, slot.taskActive else { return }
        // The engine converts to analyzerFormat (16 kHz mono int16); a
        // non-int16 buffer here is a converter bug — drop loudly.
        guard let channel = buffer.int16ChannelData else {
            Log.warn("[funasr] non-int16 buffer reached feed — dropped")
            return
        }
        let data = Data(bytes: channel[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        if slot.started {
            chainSend(slotIndex, .data(data))
        } else {
            slot.pending.append(data)
            slot.pendingBytes += data.count
            while slot.pendingBytes > Self.pendingBytesCap, !slot.pending.isEmpty {
                slot.pendingBytes -= slot.pending.removeFirst().count
            }
        }
    }

    /// Deliberate no-op. The pad is an Apple-finalize artifact (the
    /// analyzer needs post-boundary input to flush finals); Fun-ASR's
    /// finish-task flushes trailing finals by protocol, and shipping the
    /// pad would only add billed silence and finish latency per
    /// utterance.
    func feedSilence(slotIndex: Int, seconds: Double) {}

    /// Order-preserving send: each link awaits its predecessor. A failed
    /// send kills the socket (its task can't complete anyway); the engine
    /// settles the utterance empty and the next acquire reconnects.
    private func chainSend(_ index: Int, _ message: URLSessionWebSocketTask.Message) {
        let slot = slots[index]
        guard let socket = slot.socket else { return }
        let previous = slot.sendChain
        slot.sendChain = Task { [weak self] in
            if let previous { await previous.value }
            do {
                try await socket.send(message)
            } catch {
                Log.warn("[funasr] send failed on slot \(index): \(error.localizedDescription)")
                await self?.socketDied(index: index, socket: socket)
            }
        }
    }

    // MARK: - Server events

    private func readLoop(index: Int, socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard slots.indices.contains(index), slots[index].socket === socket else { return }
                if case .string(let text) = message { handleEvent(index: index, text: text) }
            } catch {
                socketDied(index: index, socket: socket)
                return
            }
        }
    }

    private func handleEvent(index: Int, text: String) {
        guard let event = Self.parseEvent(text) else { return }
        let slot = slots[index]
        guard event.taskID == slot.taskID else { return }  // stale task's straggler
        switch event.name {
        case "task-started":
            slot.started = true
            let backlog = slot.pending
            slot.pending = []
            slot.pendingBytes = 0
            for data in backlog { chainSend(index, .data(data)) }
            // A finish requested before the task started waits for the
            // backlog flush — finish-task ahead of the audio would end a
            // task that heard nothing (the whole first utterance).
            if slot.finishPending {
                slot.finishPending = false
                chainSend(index, .string(Self.finishTaskJSON(taskID: slot.taskID)))
            }
        case "result-generated":
            guard slot.taskActive, let sentence = event.sentence, !sentence.heartbeat else { return }
            if sentence.isFinal, let duration = event.billedSeconds {
                slot.taskBilledSeconds = duration
            }
            if sentence.isFinal, slot.finishing {
                // Finish flush: hold sentence finals and emit ONE merged
                // final at task end — the engine settles on the first
                // post-close final, so a second one would be epoch-
                // dropped and its text lost.
                if !sentence.text.isEmpty { slot.heldFinals.append(sentence.text) }
            } else {
                slot.owner?(STTResultEvent(text: sentence.text, isFinal: sentence.isFinal))
            }
        case "task-finished":
            endTask(index, outcome: .finished)
        case "task-failed":
            Log.warn("[funasr] task failed on slot \(index): \(event.errorCode ?? "?") — \(event.errorMessage ?? "?")")
            endTask(index, outcome: .failed)
            // Doc rule: the connection is unusable after task-failed.
            dropSocket(index)
        default:
            break
        }
    }

    private enum TaskOutcome {
        case finished
        /// Failed or timed out — counts toward the failure latch.
        case failed
        /// Deliberately abandoned (virgin release): affects neither the
        /// latch nor its recovery.
        case abandoned
    }

    /// Terminal task state: emit the merged finish-flush final, settle
    /// billing, update the failure latch, and wake the finish waiter.
    private func endTask(_ index: Int, outcome: TaskOutcome) {
        let slot = slots[index]
        guard slot.taskActive else { return }
        slot.taskActive = false
        slot.started = false
        slot.finishPending = false
        if !slot.heldFinals.isEmpty {
            slot.owner?(STTResultEvent(text: slot.heldFinals.joined(), isFinal: true))
            slot.heldFinals = []
        }
        if slot.taskBilledSeconds > 0 {
            billedSeconds += slot.taskBilledSeconds
            if let rate = Self.dollarsPerBilledSecond {
                config.costSink?(Double(slot.taskBilledSeconds) * rate)
            }
            slot.taskBilledSeconds = 0
        }
        switch outcome {
        case .finished:
            consecutiveFailures = 0
            lastHalfOpenProbeAt = nil
        case .failed:
            taskFailures += 1
            consecutiveFailures += 1
            if consecutiveFailures == Self.failureLatchThreshold {
                Log.warn("[funasr] \(consecutiveFailures) consecutive task failures — latching acquire shut (half-open retry every \(Int(Self.halfOpenCooldownSeconds)) s)")
            }
        case .abandoned:
            break
        }
        slot.finishWaiter?.resume(outcome == .finished)
        slot.finishWaiter = nil
    }

    /// The one place a slot's connection state is dropped: reader,
    /// socket, and send chain go together (a stale send chain against a
    /// dead socket is a wedged slot in the field).
    private func dropSocket(_ index: Int, closeCode: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        let slot = slots[index]
        guard let socket = slot.socket else { return }
        slot.reader?.cancel()
        slot.reader = nil
        slot.socket = nil
        slot.sendChain = nil
        socket.cancel(with: closeCode, reason: nil)
    }

    private func socketDied(index: Int, socket: URLSessionWebSocketTask) {
        guard slots.indices.contains(index) else { return }
        let slot = slots[index]
        guard slot.socket === socket else { return }
        dropSocket(index)
        if slot.taskActive {
            Log.warn("[funasr] socket died mid-task on slot \(index) — utterance settles from volatile text")
            endTask(index, outcome: .failed)
        }
    }

    // MARK: - End of utterance

    /// finish-task (deferred past the backlog flush when the task hasn't
    /// started yet), then a bounded wait for task-finished: trailing
    /// finals arrive merged through the owner callback DURING this call,
    /// exactly like AnalyzerPool's finish flush. On timeout the socket is
    /// dropped (task state unknown) — the slot itself survives and
    /// reconnects.
    func finishAndRetire(slotIndex: Int) async {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let slot = slots[slotIndex]
        guard slot.busy else { return }
        if slot.taskActive {
            slot.finishing = true
            if slot.started {
                chainSend(slotIndex, .string(Self.finishTaskJSON(taskID: slot.taskID)))
            } else {
                // Not started yet: the handshake/run-task round trip is
                // still in flight and ALL audio sits in pending —
                // finish-task goes out right after the flush at
                // task-started (or never, if the socket dies; the wait
                // below is bounded either way).
                slot.finishPending = true
            }
            // 4 s: covers a slow start + backlog flush + finish round
            // trip abroad; the engine's own settle timer is shorter, so
            // this bound only protects the lane worker, never latency.
            let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = ResumeOnce(continuation)
                slot.finishWaiter = once
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    once.resume(false)
                }
            }
            // Stop can interleave during the await: teardown emptied the
            // pool and there is nothing to recycle.
            guard !tornDown, slots.indices.contains(slotIndex) else { return }
            if !finished, slot.taskActive {
                Log.warn("[funasr] finish timed out on slot \(slotIndex) — dropping the socket")
                // Through endTask, not a bare flag flip: the timed-out
                // task's billed seconds and held finals must not vanish.
                endTask(slotIndex, outcome: .failed)
                dropSocket(slotIndex)
            }
        }
        recycle(slotIndex)
    }

    /// Return a slot that never received audio. Synchronous and instant
    /// (the AnalyzerPool contract a waiting lane depends on): the virgin
    /// task is abandoned by dropping its socket — the server reaps the
    /// task with the connection, and the next utterance on this slot
    /// reconnects. Politely finishing the task instead would hold the
    /// slot hostage to a network round trip.
    func release(slotIndex: Int) {
        guard slots.indices.contains(slotIndex), !tornDown else { return }
        let slot = slots[slotIndex]
        guard slot.busy else { return }
        if slot.taskActive {
            endTask(slotIndex, outcome: .abandoned)
            dropSocket(slotIndex)
        }
        recycle(slotIndex)
    }

    private func recycle(_ index: Int) {
        guard !tornDown, slots.indices.contains(index) else { return }
        let slot = slots[index]
        slot.owner = nil
        slot.busy = false
        slot.finishWaiter = nil
        slot.finishing = false
        slot.heldFinals = []
        slot.pending = []
        slot.pendingBytes = 0
        if waiters.isEmpty {
            freeSlots.append(index)
        } else {
            // The waiter's acquire path re-binds owner/task state.
            waiters.removeFirst().resume(returning: index)
        }
    }

    // MARK: - Teardown (Stop)

    func teardown() async {
        tornDown = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
        for (index, slot) in slots.enumerated() {
            slot.finishWaiter?.resume(false)
            slot.finishWaiter = nil
            slot.owner = nil
            dropSocket(index, closeCode: .goingAway)
        }
        slots.removeAll()
        freeSlots.removeAll()
        poolSize = 0
        // URLSession retains internal resources until invalidated —
        // one leaked session per conversation otherwise (the
        // RealtimeTranslationClient learned this the same way).
        session.invalidateAndCancel()
        Log.info("[funasr] torn down — \(billedSeconds) s billed, \(taskFailures) task failure(s) this conversation")
    }

    // MARK: - Wire format

    private static func runTaskJSON(taskID: String, config: Config) -> String {
        var parameters: [String: Any] = ["format": "pcm", "sample_rate": sampleRate]
        if let hint = config.languageHint {
            parameters["language_hints"] = [hint]
        }
        let object: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": config.model,
                "parameters": parameters,
                "input": [String: Any]()
            ]
        ]
        return jsonString(object)
    }

    private static func finishTaskJSON(taskID: String) -> String {
        let object: [String: Any] = [
            "header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
            "payload": ["input": [String: Any]()]
        ]
        return jsonString(object)
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct ServerEvent {
        let name: String
        let taskID: String
        let errorCode: String?
        let errorMessage: String?
        let sentence: (text: String, isFinal: Bool, heartbeat: Bool)?
        let billedSeconds: Int?
    }

    private static func parseEvent(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let name = header["event"] as? String else { return nil }
        let payload = object["payload"] as? [String: Any]
        var sentence: (String, Bool, Bool)?
        var billed: Int?
        if let output = payload?["output"] as? [String: Any],
           let raw = output["sentence"] as? [String: Any],
           let sentenceText = raw["text"] as? String {
            sentence = (
                sentenceText,
                raw["sentence_end"] as? Bool ?? false,
                raw["heartbeat"] as? Bool ?? false
            )
        }
        if let usage = payload?["usage"] as? [String: Any] {
            billed = usage["duration"] as? Int
        }
        return ServerEvent(
            name: name,
            taskID: header["task_id"] as? String ?? "",
            errorCode: header["error_code"] as? String,
            errorMessage: header["error_message"] as? String,
            sentence: sentence,
            billedSeconds: billed
        )
    }
}
