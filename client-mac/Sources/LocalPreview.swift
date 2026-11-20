// Apple 本地增量识别的回放实验组件。主线程拥有生命周期。
import AVFoundation
import Speech

final class LocalPreview {
    private struct Transcriber {
        let module: any SpeechModule
        let acceptsHotwords: Bool
        let read: @MainActor ((any SpeechModuleResult, AttributedString) -> Bool) async throws -> Void

        init<Results: AsyncSequence>(module: any SpeechModule, results: Results, acceptsHotwords: Bool,
                                     text: @escaping (Results.Element) -> AttributedString)
        where Results.Element: SpeechModuleResult {
            self.module = module
            self.acceptsHotwords = acceptsHotwords
            read = { receive in
                for try await result in results {
                    guard receive(result, text(result)) else { return }
                }
            }
        }
    }

    private struct Prepared {
        let transcriber: Transcriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }
    private var prepared: Prepared?
    private var active: Prepared?
    private var preparing: Task<Void, Never>?
    private var reader: Task<StreamingTranscript?, Never>?
    private var analysis: Task<Void, Never>?
    private var finalizing: Task<Void, Never>?
    private var onFinish: ((StreamingTranscript?) -> Void)?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var generation = UUID()
    private var preparationID = UUID()
    private var language = "auto"
    private var wantsHotwords = false
    private var lastResult: TimeInterval?
    var onText: ((String) -> Void)?
    var ready: Bool { prepared != nil }
    var isFinishing: Bool { onFinish != nil }
    var hasRecentResult: Bool {
        lastResult.map { ProcessInfo.processInfo.systemUptime - $0 < 3 } ?? false
    }

    func prepare(language: String, wantsHotwords: Bool = false) {
        if self.language != language || self.wantsHotwords != wantsHotwords {
            stop(); prepared = nil; preparing?.cancel(); preparing = nil
            self.language = language
            self.wantsHotwords = wantsHotwords
        }
        guard prepared == nil, preparing == nil, active == nil else { return }
        let requested = language
        let preparationID = UUID()
        self.preparationID = preparationID
        preparing = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.preparationID == preparationID { self.preparing = nil } }
            let locales = ["auto": "zh-CN", "chinese": "zh-CN", "zh": "zh-CN", "english": "en-US", "en": "en-US",
                           "japanese": "ja-JP", "ja": "ja-JP", "cantonese": "zh-HK"]
            let locale = Locale(identifier: locales[requested] ?? requested)
            for dictation in wantsHotwords ? [true, false] : [false] {
                guard !Task.isCancelled else { return }
                guard let transcriber = await Self.makeTranscriber(locale: locale, dictation: dictation),
                      let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module]),
                      format.sampleRate == 16000, format.channelCount == 1, format.commonFormat == .pcmFormatInt16 else { continue }
                let analyzer = SpeechAnalyzer(modules: [transcriber.module])
                do {
                    try await analyzer.prepareToAnalyze(in: format)
                    guard !Task.isCancelled, self.preparationID == preparationID else {
                        await analyzer.cancelAndFinishNow()
                        return
                    }
                    self.prepared = Prepared(transcriber: transcriber, analyzer: analyzer, format: format)
                    let model = dictation ? "听写热词" : "通用"
                    Log.w("本地流式预览已预热：\(locale.identifier)（\(model)）")
                    return
                } catch { Log.w("本地流式预览预热失败：\(error.localizedDescription)") }
            }
            Log.w("本地流式预览：没有可用的语言模型，使用远端预览")
        }
    }

    private static func makeTranscriber(locale: Locale, dictation: Bool) async -> Transcriber? {
        if dictation {
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale),
                  await DictationTranscriber.installedLocales.contains(supported) else { return nil }
            let module = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                              reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            return Transcriber(module: module, results: module.results, acceptsHotwords: true, text: \.text)
        }
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
              await SpeechTranscriber.installedLocales.contains(supported) else { return nil }
        let module = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        return Transcriber(module: module, results: module.results, acceptsHotwords: false, text: \.text)
    }

    @discardableResult func start(language: String, hotwords: [String] = []) -> Bool {
        stop()
        prepare(language: language, wantsHotwords: !hotwords.isEmpty)
        guard let p = prepared else { return false }
        prepared = nil; active = p
        let token = generation
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(100))
        input = continuation
        let began = ProcessInfo.processInfo.systemUptime
        reader = Task { @MainActor [weak self] in
            var transcript = StreamingTranscript(), finalized = StreamingTranscript(), first = true
            do {
                try await p.transcriber.read { result, attributed in
                    guard let self, self.generation == token, !Task.isCancelled else { return false }
                    let start = result.range.start.seconds, end = result.range.end.seconds
                    let phrase = String(attributed.characters)
                    if result.isFinal {
                        let times = p.transcriber.acceptsHotwords ? Self.wordTimes(in: attributed) : []
                        finalized.update(start: start, end: end, text: phrase, times: times)
                    }
                    let text = transcript.update(start: start, end: end, text: phrase)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
                    self.lastResult = ProcessInfo.processInfo.systemUptime
                    if first { Log.w("本地流式首字 \(Int((self.lastResult! - began) * 1000))ms"); first = false }
                    self.onText?(text)
                    return true
                }
                return finalized
            } catch {
                self?.failed(error, token: token)
                return nil
            }
        }
        analysis = Task { @MainActor [weak self] in
            if p.transcriber.acceptsHotwords {
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(hotwords.prefix(100))
                do { try await p.analyzer.setContext(context) }
                catch {
                    guard !Task.isCancelled else { return }
                    Log.w("本地流式识别未能设置热词提示：\(error.localizedDescription)")
                }
            }
            guard !Task.isCancelled else { return }
            do { try await p.analyzer.start(inputSequence: stream) }
            catch { self?.failed(error, token: token) }
        }
        return true
    }

    private static func wordTimes(in text: AttributedString) -> [StreamingTranscript.WordTime] {
        var offset = 0
        return text.runs.compactMap { run in
            let length = String(text.characters[run.range]).utf16.count
            defer { offset += length }
            guard let time = run.audioTimeRange, time.start.seconds.isFinite, time.end.seconds.isFinite,
                  time.start.seconds < time.end.seconds else { return nil }
            return .init(range: NSRange(location: offset, length: length), start: time.start.seconds, end: time.end.seconds)
        }
    }

    func append(_ samples: [Float]) {
        guard let p = active, let input, !samples.isEmpty,
              let b = AVAudioPCMBuffer(pcmFormat: p.format, frameCapacity: UInt32(samples.count)), let channel = b.int16ChannelData else { return }
        b.frameLength = UInt32(samples.count)
        for (i, sample) in samples.enumerated() { channel[0][i] = sample.isFinite ? Int16(max(-1, min(1, sample)) * 32767) : 0 }
        if case .dropped = input.yield(AnalyzerInput(buffer: b)) {
            failed(NSError(domain: "NBIME", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地预览处理落后"]), token: generation)
        }
    }

    /// 关闭输入后等分析器吃完排队的采样，并读完全部定稿结果。
    /// 超时、出错或下一句先开始时，调用方收到 nil，转交完整识别。
    func finish(timeout: TimeInterval, done: @escaping (StreamingTranscript?) -> Void) {
        guard let active, let reader, let input else { return done(nil) }
        let token = generation
        onFinish = done
        self.input = nil
        input.finish()
        finalizing = Task { @MainActor [weak self] in
            do {
                try await active.analyzer.finalizeAndFinishThroughEndOfInput()
                let text = await reader.value
                self?.complete(text, token: token)
            } catch { self?.failed(error, token: token) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.complete(nil, token: token)
        }
    }

    private func complete(_ text: StreamingTranscript?, token: UUID) {
        guard generation == token, let done = onFinish else { return }
        onFinish = nil
        stop()
        done(text)
    }

    func stop() {
        let done = onFinish
        onFinish = nil
        generation = UUID(); lastResult = nil
        input?.finish(); input = nil
        reader?.cancel(); reader = nil
        analysis?.cancel(); analysis = nil
        finalizing?.cancel(); finalizing = nil
        if let active { Task { await active.analyzer.cancelAndFinishNow() } }
        active = nil
        done?(nil)
    }

    private func failed(_ error: Error, token: UUID) {
        guard generation == token else { return }
        Log.w("本地流式预览失败，回退远端：\(error.localizedDescription)")
        stop()
    }
}
