// Apple 本地增量识别只供预览；最终输入仍由完整识别决定。主线程拥有生命周期。
import AVFoundation
import Speech

final class LocalPreview {
    private struct Prepared {
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }
    private var prepared: Prepared?
    private var active: Prepared?
    private var preparing: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var analysis: Task<Void, Never>?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var generation = UUID()
    private var preparationID = UUID()
    private var language = "auto"
    private var lastResult: TimeInterval?
    var onText: ((String) -> Void)?
    var ready: Bool { prepared != nil }
    var hasRecentResult: Bool {
        lastResult.map { ProcessInfo.processInfo.systemUptime - $0 < 3 } ?? false
    }

    func prepare(language: String) {
        if self.language != language {
            stop(); prepared = nil; preparing?.cancel(); preparing = nil
            self.language = language
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
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locales[requested] ?? requested)),
                  await SpeechTranscriber.installedLocales.contains(locale) else {
                Log.w("本地流式预览：语言模型未安装或不支持，使用远端预览")
                return
            }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]),
                  format.sampleRate == 16000, format.channelCount == 1, format.commonFormat == .pcmFormatInt16 else {
                Log.w("本地流式预览：输入格式不兼容，使用远端预览"); return
            }
            let a = SpeechAnalyzer(modules: [t])
            do {
                try await a.prepareToAnalyze(in: format)
                guard !Task.isCancelled, self.preparationID == preparationID, self.language == requested else { await a.cancelAndFinishNow(); return }
                self.prepared = Prepared(transcriber: t, analyzer: a, format: format)
                Log.w("本地流式预览已预热：\(locale.identifier)")
            } catch { Log.w("本地流式预览预热失败：\(error.localizedDescription)") }
        }
    }

    @discardableResult func start() -> Bool {
        stop()
        guard let p = prepared else { prepare(language: language); return false }
        prepared = nil; active = p
        let token = generation
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(100))
        input = continuation
        let began = ProcessInfo.processInfo.systemUptime
        reader = Task { @MainActor [weak self] in
            var transcript = StreamingTranscript(), first = true
            do {
                for try await result in p.transcriber.results {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    let text = transcript.update(start: result.range.start.seconds, end: result.range.end.seconds,
                                                 text: String(result.text.characters))
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    self.lastResult = ProcessInfo.processInfo.systemUptime
                    if first { Log.w("本地流式首字 \(Int((self.lastResult! - began) * 1000))ms"); first = false }
                    self.onText?(text)
                }
            } catch { self?.failed(error, token: token) }
        }
        analysis = Task { @MainActor [weak self] in
            do { try await p.analyzer.start(inputSequence: stream) }
            catch { self?.failed(error, token: token) }
        }
        return true
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

    func stop() {
        generation = UUID(); lastResult = nil
        input?.finish(); input = nil
        reader?.cancel(); reader = nil
        analysis?.cancel(); analysis = nil
        if let active { Task { await active.analyzer.cancelAndFinishNow() } }
        active = nil
    }

    private func failed(_ error: Error, token: UUID) {
        guard generation == token else { return }
        Log.w("本地流式预览失败，回退远端：\(error.localizedDescription)")
        stop()
    }
}
