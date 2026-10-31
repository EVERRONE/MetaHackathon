import AVFAudio
import Foundation
import PipCore
import UIKit

/// Hands-free conversation: live transcription → look → speech with synced cues.
/// Talking over Pip stops it at once (barge-in); the mute button sends silence instead.
@MainActor
final class GuideModel: ObservableObject {
    enum Phase: Equatable {
        case connecting, listening, hearing, looking, speaking, muted
        case failed(String)

        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .listening: return "Listening"
            case .hearing: return "Hearing you…"
            case .looking: return "Looking…"
            case .speaking: return "Speaking"
            case .muted: return "Muted"
            case .failed(let m): return m
            }
        }
    }

    @Published var phase: Phase = .connecting
    @Published var caption = ""
    @Published var heard = ""
    @Published var markedImage: UIImage?
    @Published var trace: [String] = []
    @Published var muted = false
    @Published var language = "English" {
        didSet {
            configureVoice()
            // Speech recognition already hears both languages: it restarts only for the switch on screen.
            if !languageFromSpeech { restartListening() }
        }
    }
    private var languageFromSpeech = false

    /// Follows the language the user speaks, without reconnecting speech recognition.
    func adoptLanguage(_ spoken: String) {
        languageFromSpeech = true
        language = spoken
        languageFromSpeech = false
    }

    /// ElevenLabs voices: Sharon (Flemish, multilingual) and Alice (British English).
    static let cloudVoices = ["Dutch": "g7B5PNoscIXomLNUmHAb", "English": "Xb7hH8MSUJpSbSDYk0k2"]

    let ar = ARController()
    /// Long-term memory: the room map, places and facts, only with the user's consent.
    let memory = SpaceMemory()
    var awaitingConsent = false
    var pendingPlaces: [SpaceMemory.Place] = []
    var pendingFacts: [(key: String, value: String, source: String)] = []

    // MARK: Visual memory and shopping list (see GuideModel+Find.swift)

    let keyframes = Keyframes()
    /// The 3D map of the home, built while Pip is used (see MapKeeper and GuideModel+Memory).
    let mapKeeper = MapKeeper()
    /// Which frames are clean enough for the map and the visual memory.
    let captureGate = CaptureGate()
    var mapSaveTimer: Timer?
    /// Which places came from which linked piece, so they follow the drift measured against it.
    var linkedPlaces: [UUID: Set<UUID>] = [:]
    /// How well outlines hold: every re-measurement, on this iPhone, to evaluate on the Mac.
    let trackingLog = TrackingLog()
    var foundCount = 0
    /// When the shopping list last changed; basket checks stop after a long quiet spell.
    var listChangedAt = Date.distantPast
    struct ShoppingItem: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var inBasket = false
        var hits = 0
        var wrongHits = 0
    }
    @Published var shopping: [ShoppingItem] = []
    var basketChecking = false
    var basketTimer: Timer?
    private let audio = AudioIO()
    let speaker: Speaker
    let client: PipClient
    private var transcriber: RealtimeTranscriber?
    private var listenTask: Task<Void, Never>?
    var history: [ChatMessage] = []
    var task: Task<Void, Never>?
    /// What Pip said in the current look, as the model gave it (playback may still be going).
    var spokenThisTurn: [String] = []
    /// The look in progress, by number: an older look ending never clears a newer one's flag.
    private var activeLook: Int?
    var lookActive: Bool { activeLook != nil }
    /// When the last look ended: re-measuring outlines stops a while after.
    var lastLookAt = Date.distantPast
    /// Mark numbers restart in every look; an offset per look keeps earlier marks apart, so their
    /// cues can stay on screen.
    private var lookCount = 0

    /// What Pip knows for this session, with where each fact came from.
    struct Fact: Equatable {
        var value: String
        var source: String
    }
    @Published var facts: [String: Fact] = [:]

    // MARK: Guided task (see GuideModel+Task.swift)

    struct StepView: Equatable, Identifiable {
        let id: Int
        var text: String
        var state: String
        var sourceRef: String?
    }
    struct TaskView: Equatable {
        var title: String
        var source: String
        var steps: [StepView]
        var index: Int
        var finished: Bool
        var report: String?
    }
    @Published var taskView: TaskView?
    /// What Pip is doing while it prepares a task ("Reading the manual…").
    @Published var preparing: String?
    var runtime: ProcedureRuntime?
    var sessionLog = SessionLog()
    var offering = false
    /// A yes/no question from the runtime was just asked, with no other talk since.
    var questionFresh = false
    /// The plan being prepared in the background (search, read, compile), and its goal.
    var prepTask: Task<Void, Never>?
    var preparingGoal: String?
    /// Reading mode: the user shows paper instructions page by page.
    var pageReader: PageReader?
    var readingGoal = ""

    // MARK: Watching, following objects, speakers (see GuideModel+Watch.swift)

    /// The speaker label of the person Pip talks with; others are ignored unless they say "Pip".
    var primarySpeaker: String?
    @Published var watching = false
    var watchTimer: Timer?
    var refreshTimer: Timer?
    var watchHits = 0
    /// Consecutive checks that saw the same problem.
    var problemHits = 0
    var lastProblem: StepChecker.Result.Problem = .none
    var watchStep = -1
    var watchChecks = 0
    var checking = false
    var refreshing = false
    /// After a false alarm, mistake checks stay quiet for a while.
    var problemQuietUntil = Date.distantPast
    /// Speech started while Pip was busy; Pip stops once it is clearly the user (see `handle`).
    private var bargeInPending = false
    private var reconnectDelay: TimeInterval = 0.5
    private var warmTimer: Timer?
    private var started = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let base = URL(string: info["PIPBaseURL"] as? String ?? "") ?? URL(string: "https://pip.unveil.be")!
        client = PipClient(baseURL: base, token: info["PIPAppToken"] as? String ?? "")
        speaker = Speaker(engine: audio.engine, player: audio.player)
        configureVoice()
        speaker.onLog = { [weak self] line in self?.log(line) }
        speaker.onSentenceStart = { [weak self] s in
            self?.caption = s.text
        }
        speaker.onCue = { [weak self] c in
            self?.ar.show(c.cue)
            if case .landmark(let mark, let name) = c.cue { self?.rememberPlace(name: name, mark: mark) }
        }
        speaker.onIdle = { [weak self] in
            guard let self, self.phase == .speaking, !self.lookActive else { return }
            self.phase = self.muted ? .muted : .listening
        }
        audio.onRestartFailed = { [weak self] error in
            Task { @MainActor in self?.phase = .failed("Audio unavailable: \(error)") }
        }
    }

    func start() {
        // SwiftUI may call onAppear more than once.
        guard !started else { return }
        started = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        startMap()
        // Every camera frame: the visual memory, the map of the home, and reading mode when it is on.
        captureGate.onTrouble = { [weak self] since in
            self?.keyframes.purge(since: since)
            self?.mapKeeper.purge(since: since)
        }
        ar.onFrame = { [weak self] frame in
            guard let self else { return }
            self.captureGate.update(frame)
            self.keyframes.consider(frame, gate: self.captureGate)
            self.mapKeeper.consider(frame, gate: self.captureGate)
            self.pageReader?.feed(frame)
        }
        // The room map is saved when the app goes to the background, so new places survive.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveRoomNow() }
        }
        startBasketWatch()
        for (key, fact) in memory.facts { facts[key] = Fact(value: fact.value, source: fact.source) }
        // Accurate text recognition unloads after a pause and then takes ~25 s to load: keep it warm.
        Task.detached(priority: .utility) { await Grounder.warmUp() }
        warmTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task.detached(priority: .background) { await Grounder.warmUp() }
        }
        startWatching()
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard granted else { self.phase = .failed("Microphone access is off"); return }
                do { try self.audio.start() } catch { self.phase = .failed("Audio unavailable: \(error)") }
                self.restartListening()
            }
        }
    }

    private func configureVoice() {
        speaker.voice = Speaker.bestVoice(for: language)
        speaker.cloud = Self.cloudVoices[language].map {
            Speaker.CloudVoice(client: client, voiceId: $0, language: language == "Dutch" ? "nl" : "en")
        }
    }

    /// The big button: stop Pip if it is talking, otherwise mute or unmute the microphone.
    func micTapped() {
        if speaker.isSpeaking || lookActive {
            interrupt()
            return
        }
        muted.toggle()
        audio.muted = muted
        phase = muted ? .muted : .listening
    }

    private func interrupt() {
        speaker.stop()
        task?.cancel()
        activeLook = nil
        phase = muted ? .muted : .listening
    }

    private func restartListening() {
        listenTask?.cancel()
        transcriber?.close()
        let asr = RealtimeTranscriber(baseURL: client.baseURL, token: client.token,
                                      languages: language == "Dutch" ? ["Dutch", "English"] : ["English", "Dutch"])
        transcriber = asr
        audio.sink = asr
        // Speaker labels start again in every session.
        primarySpeaker = nil
        if !lookActive && !speaker.isSpeaking { phase = .connecting }
        asr.connect()
        listenTask = Task { [weak self] in
            for await event in asr.events {
                guard let self, !Task.isCancelled else { return }
                // Events from a session that has since been replaced are ignored.
                guard asr === self.transcriber else { return }
                self.handle(event)
            }
        }
    }

    private var busy: Bool { speaker.isSpeaking || lookActive }

    private func handle(_ event: RealtimeTranscriber.Event) {
        switch event {
        case .ready:
            log("listening")
            reconnectDelay = 0.5
            if phase == .connecting { phase = muted ? .muted : .listening }
        case .speechStart:
            guard !muted else { return }
            // Pip stops only once this is clearly the user (a cough or Pip's own echo is not).
            if busy {
                bargeInPending = true
            } else {
                heard = ""
                phase = .hearing
            }
        case .partial(let text):
            guard !muted, !isEcho(text) else { return }
            if bargeInPending, wordCount(text) >= 2 {
                log("barge-in")
                bargeInPending = false
                interrupt()
                phase = .hearing
            }
            if !busy { heard = text }
        case .speechEnd:
            break
        case .final(_, let text, let speaker):
            bargeInPending = false
            guard !muted, text.count >= 2, !isEcho(text), !busy else {
                if phase == .hearing { phase = .listening }
                return
            }
            // Only real user speech chooses who Pip talks with, never its own echo.
            guard acceptSpeaker(speaker, text: text) else { return }
            heard = text
            // The frame the user was looking at when they finished speaking.
            guard let snapshot = ar.snapshot() else { return }
            route(text, snapshot: snapshot)
        case .error(let message):
            log("asr error: \(message)")
        case .closed(let code, let reason):
            log("asr closed \(code) \(reason)")
            // Sessions end after a while: reconnect, waiting longer after each failure.
            let delay = reconnectDelay
            reconnectDelay = min(reconnectDelay * 2, 30)
            let closed = transcriber
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard closed === self.transcriber else { return }
                self.restartListening()
            }
        }
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func wordCount(_ text: String) -> Int { words(text).count }

    /// Pip's own voice picked up despite echo cancellation: while Pip speaks (or just after), the
    /// words are mostly what it is saying. Outside that window the user may repeat Pip's words.
    private func isEcho(_ text: String) -> Bool {
        guard speaker.isSpeaking || Date().timeIntervalSince(speaker.lastSpokeAt) < 2 else { return false }
        let heardWords = Set(words(text))
        guard heardWords.count >= 3 else { return false }
        let spoken = Set(words(speaker.recentText.joined(separator: " ")))
        return Double(heardWords.intersection(spoken).count) / Double(heardWords.count) > 0.8
    }

    /// One look: Pip answers `utterance`, or carries out `directive` (give a step, check a step).
    /// `onState` receives the model's state tag, which a check uses as its evidence.
    func look(_ utterance: String, snapshot: FrameSnapshot, started: Date, directive: String? = nil, onState: (([String: String]) -> Void)? = nil) async {
        lookCount += 1
        let me = lookCount
        activeLook = me
        defer {
            if activeLook == me { activeLook = nil }
            lastLookAt = Date()
        }
        phase = .looking
        spokenThisTurn = []
        // A question from the user: any open yes/no question of the runtime is stale now.
        if directive == nil { questionFresh = false }
        let offset = ARController.markOffset(look: lookCount)
        ar.beginLook(markOffset: offset)
        let recorder = LookRecorder(utterance: utterance, language: language, frame: snapshot.image)
        func note(_ line: String) {
            log(line)
            recorder?.log(line)
        }
        if let directive { recorder?.log("directive: \(directive)") }
        var pendingFind: (what: String, phrase: String)?
        var pendingTask: (goal: String, product: String?)?
        // What the model asked to point at, kept with each mark so Pip can find it again later.
        var specs: [Int: TargetSpec] = [:]
        let pipeline = LookPipeline(client: client, language: language)
        var known = facts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.value) (\($0.value.source == "seen" ? "you saw it" : "the user said so"))" }
        let places = ar.placeDescriptions()
        if !places.isEmpty { known.append("Remembered places (point with m=number): " + places.joined(separator: " | ")) }
        if !shopping.isEmpty {
            known.append("Shopping list: " + shopping.map { "\($0.name) (\($0.inBasket ? "in the basket" : "still to get"))" }.joined(separator: ", "))
        }
        if let goal = preparingGoal {
            known.append("Pip is preparing a step plan for \"\(goal)\" and will offer it in about a minute; do not add another task tag for it.")
        }
        var request = LookRequest(frame: snapshot.image, facts: known, history: history, utterance: utterance, directive: directive)
        request.knownMarks = ar.placeMarks
        if let rt = runtime, rt.isActive, let step = rt.current {
            request.goal = rt.procedure.title
            request.step = PipPrompt.Step(index: rt.index + 1, count: rt.procedure.steps.count, instruction: step.instruction,
                                          expected: step.check.kind == .camera ? step.check.expected : nil)
        }
        var firstWord: Double?
        var raw: String?
        do {
            for try await event in pipeline.run(request) {
                if Task.isCancelled { break }
                switch event {
                case .target(let id, let spec):
                    specs[id] = spec
                    note("target \(id): \(spec.phrase) \(spec.text) @\(Int(spec.x)),\(Int(spec.y))")
                case .grounded(let id, let inst, let method, let seconds):
                    if let inst {
                        let anchoring = ar.addMark(inst.renumbered(id + offset), snapshot: snapshot, spec: specs[id])
                        recorder?.grounded(inst)
                        note(String(format: "grounded %d via %@ in %.1fs, anchored on %@", id, method, seconds, anchoring))
                    } else {
                        note(String(format: "target %d not grounded (%@)", id, method))
                    }
                case .segmented(let s, let marked):
                    for inst in s.instances { ar.addMark(inst.renumbered(inst.id + offset), snapshot: snapshot) }
                    markedImage = UIImage(data: marked)
                case .sentence(var s, let traces):
                    firstWord = firstWord ?? Date().timeIntervalSince(started)
                    phase = .speaking
                    // Remembered places keep their own numbers; this look's marks get the look's offset.
                    s.cues = s.cues.map { TimedCue(cue: $0.cue.mappingMarks { $0 >= ARController.placeMarkBase ? $0 : $0 + offset }, anchor: $0.anchor, raw: $0.raw) }
                    speaker.enqueue(s)
                    spokenThisTurn.append(s.text)
                    note("say: \(s.text)")
                    for t in traces { note("  cue \(t.raw): \(t.decision)") }
                case .sideChannel(.state(let state)):
                    note("side: state \(state)")
                    onState?(state)
                case .sideChannel(.find(let what, let phrase)):
                    note("find: \(what) [\(phrase)]")
                    pendingFind = (what, phrase)
                case .sideChannel(.list(let add, let got, let remove)):
                    note("list: +\(add) ✓\(got) -\(remove)")
                    updateList(add: add, got: got, remove: remove)
                case .sideChannel(.readPages(let goal)):
                    note("reading pages: \(goal)")
                    startReading(goal: goal)
                case .sideChannel(.task(let goal, let product)):
                    note("task: \(goal) · \(product ?? "no product")")
                    if runtime?.isActive != true, preparingGoal == nil, pageReader == nil { pendingTask = (goal, product) }
                case .sideChannel(.remember(let key, let value, let source)):
                    facts[key] = Fact(value: value, source: source)
                    rememberLongTerm(key, value, source: source)
                    note("remember \(key) = \(value) (\(source))")
                case .sideChannel(let cue):
                    note("side: \(cue)")
                case .invalidTag(let e):
                    note("invalid: \(e)")
                case .finished(let summary):
                    raw = summary.rawText
                    note(String(format: "first word %.1fs after you stopped · total %.1fs", firstWord ?? -1, Date().timeIntervalSince(started)))
                    if let u = summary.usage { note("tokens \(u.promptTokens) in (\(u.promptTokensDetails?.cachedTokens ?? 0) cached), \(u.completionTokens) out") }
                }
            }
            // Pip's own silent turns (a false alarm while watching) are not kept.
            if directive == nil || !spokenThisTurn.isEmpty { remember(directive == nil ? utterance : "(Pip's own turn)") }
            if !speaker.isSpeaking, phase == .looking || phase == .speaking { phase = muted ? .muted : .listening }
        } catch {
            note("error: \(error)")
            remember(utterance)
            if !Task.isCancelled { phase = .failed("Look failed: \(error)") }
        }
        recorder?.finish(rawText: raw)
        guard !Task.isCancelled else { return }
        // A plan is prepared in the background; the conversation goes on meanwhile.
        if let pending = pendingTask { startPreparing(goal: pending.goal, product: pending.product) }
        if let find = pendingFind { await findInMemory(find.what, phrase: find.phrase) }
    }

    /// Keeps the recent turns as they were heard, for follow-up questions. The user's words are
    /// always kept, also when Pip was interrupted before answering ("A Mac." must not be lost).
    private func remember(_ utterance: String) {
        let said = spokenThisTurn.joined(separator: " ")
        history.append(.user(utterance))
        history.append(.assistant(said.isEmpty ? "(interrupted before answering)" : said))
        if history.count > 16 { history.removeFirst(history.count - 16) }
    }

    func resetConversation() {
        interrupt()
        prepTask?.cancel()
        prepTask = nil
        preparingGoal = nil
        cancelReading()
        awaitingConsent = false
        shopping = []
        history = []
        facts = [:]
        primarySpeaker = nil
        endTask(silently: true)
        caption = ""
        heard = ""
        ar.clearCues()
    }

    func log(_ line: String) {
        trace.append(line)
        if trace.count > 60 { trace.removeFirst(trace.count - 60) }
        // The map's decisions are kept on the iPhone too (Documents/map.log), to check linking later.
        if line.hasPrefix("map:") { TrackingLog.append(line, to: "map.log") }
    }
}
