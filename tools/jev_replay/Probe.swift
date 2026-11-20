// Headless replay and production polish for the Jev experiment.
import AVFoundation
import Foundation
import Speech

// The experiment supplies its own tunnel and never loads the app's user settings.
struct Settings {
    static let current = Settings()
    let tunnelHost = "experiment"
    let serverHost = "127.0.0.1"
    let polishProvider = Polish.Provider.local
    let transcribePort = 6018
    let transcribeLocalPort = 16018
    let polishPort = 6017
    let polishLocalPort = Int(ProcessInfo.processInfo.environment["NB_EXPERIMENT_POLISH_PORT"] ?? "") ?? 16017
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

private func emit<Value: Encodable>(_ value: Value) throws {
    let data = try JSONEncoder().encode(value)
    FileHandle.standardOutput.write(data + Data([10]))
}

private struct ConfidenceRun: Codable {
    let text: String
    let confidence: Double?
}

private struct Candidate: Codable {
    let text: String
    let runs: [ConfidenceRun]

    init(_ value: AttributedString) {
        text = String(value.characters)
        runs = value.runs.map {
            let score = $0.transcriptionConfidence
            return ConfidenceRun(text: String(value.characters[$0.range]),
                                 confidence: score.flatMap { $0.isFinite ? $0 : nil })
        }
    }
}

private struct Segment: Codable {
    let start: Double
    let end: Double
    let primary: Candidate
    let alternatives: [Candidate]
}

private struct Capture: Encodable {
    let id: String
    let enriched: Bool
    let text: String
    let segments: [Segment]
    let release_ms: Double
    let finalize_ms: Double
}

private struct PreviewSnapshot: Encodable {
    let event = "preview"
    let text: String
    let segments: [Segment]
}

private struct ReplayEvent: Encodable {
    let event: String
    let id: String
    var capture: Capture? = nil
    var wall_time: Double? = nil
}

private func replaceSegment(_ segment: Segment, in segments: inout [Segment]) {
    segments.removeAll { $0.start >= segment.start || $0.end > segment.start }
    segments.append(segment)
}

private struct PolishInput: Decodable {
    struct Rule: Decodable {
        let from: String
        let to: String
    }

    let text: String
    let hotwords: [String]
    let rules: [Rule]
}

private struct PolishOutput: Encodable {
    let text: String
    let prepared: String
    let replace_hits: [String]
    let note: String
    let ms: Double
}

private enum ProbeError: Error {
    case noLocale, unexpectedFormat, noArgument
}

@main enum Probe {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first else { throw ProbeError.noArgument }
        if mode == "polish" {
            while let line = readLine() {
                let item = try JSONDecoder().decode(PolishInput.self, from: Data(line.utf8))
                let start = uptime()
                let result: (String, String)
                let prepared: String
                let hits: [String]
                switch HotwordEcho.resolve(item.text, words: item.hotwords, retry: false) {
                case .accept(let accepted):
                    let rules = item.rules.map { ReplaceRule(from: [$0.from], to: $0.to) }
                    let replaced = Replace.apply(Signfix.apply(accepted), rules)
                    prepared = Hotfix.apply(replaced.text, item.hotwords)
                    hits = replaced.hits
                    result = await withCheckedContinuation { continuation in
                        Polish.run(prepared, clean: .mid, format: .mid,
                                   hotwords: item.hotwords, source: .localStream) { output, note in
                            continuation.resume(returning: (output, note))
                        }
                    }
                case .reread, .reject:
                    prepared = item.text
                    hits = []
                    result = (item.text, "热词判定要求走远端重认")
                }
                try emit(PolishOutput(text: result.0, prepared: prepared, replace_hits: hits,
                                      note: result.1, ms: (uptime() - start) * 1_000))
            }
            return
        }

        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")),
              await SpeechTranscriber.installedLocales.contains(locale) else {
            throw ProbeError.noLocale
        }
        // Alternate the order so one arm does not always get the warmer recognizer.
        for (index, path) in args.dropFirst().enumerated() {
            let url = URL(fileURLWithPath: path)
            let id = url.deletingPathExtension().lastPathComponent
            let samples = try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            if mode == "preview" {
                // Wait for the evaluator before starting to feed the next recording.
                if index > 0, readLine() == nil { return }
                try emit(ReplayEvent(event: "begin", id: id))
                let record = try await capture(samples, id: id, locale: locale, enriched: true, publishPreview: true)
                try emit(ReplayEvent(event: "final", id: id, capture: record))
                continue
            }
            for enriched in (index.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let record = try await capture(samples, id: id, locale: locale, enriched: enriched)
                try emit(record)
            }
        }
    }

    @MainActor private static func capture(_ samples: [Int16], id: String, locale: Locale,
                                           enriched: Bool, publishPreview: Bool = false) async throws -> Capture {
        let options: Set<SpeechTranscriber.ReportingOption> = enriched
            ? [.volatileResults, .fastResults, .alternativeTranscriptions] : [.volatileResults, .fastResults]
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: options,
                                           attributeOptions: enriched ? [.transcriptionConfidence] : [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              format.sampleRate == 16_000, format.channelCount == 1, format.commonFormat == .pcmFormatInt16 else {
            throw ProbeError.unexpectedFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(100))
        let reader = Task { () throws -> [Segment] in
            var segments: [Segment] = [], preview: [Segment] = []
            for try await result in transcriber.results where result.isFinal || publishPreview {
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                let segment = Segment(start: start, end: end, primary: Candidate(result.text),
                                      alternatives: result.alternatives.map(Candidate.init))
                if result.isFinal { replaceSegment(segment, in: &segments) }
                if publishPreview {
                    replaceSegment(segment, in: &preview)
                    try emit(PreviewSnapshot(text: preview.map(\.primary.text).joined(), segments: preview))
                }
            }
            return segments
        }
        try await analyzer.start(inputSequence: stream)

        func feed(_ data: ArraySlice<Int16>) async throws {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(data.count)),
                  let channel = buffer.int16ChannelData else { throw ProbeError.unexpectedFormat }
            buffer.frameLength = UInt32(data.count)
            for (index, sample) in data.enumerated() { channel[0][index] = sample }
            if case .dropped = input.yield(AnalyzerInput(buffer: buffer)) { throw ProbeError.unexpectedFormat }
            try await Task.sleep(for: .microseconds(Int64(data.count) * 1_000_000 / 16_000))
        }

        for offset in stride(from: 0, to: samples.count, by: 1_600) {
            try await feed(samples[offset..<min(offset + 1_600, samples.count)])
        }
        let released = uptime()
        if publishPreview { try emit(ReplayEvent(event: "release", id: id, wall_time: Date().timeIntervalSince1970)) }
        let tail = Array(repeating: Int16(0), count: 4_000)
        for offset in stride(from: 0, to: tail.count, by: 1_600) {
            try await feed(tail[offset..<min(offset + 1_600, tail.count)])
        }
        let finish = uptime()
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let segments = try await reader.value
        let ended = uptime()
        return Capture(id: id, enriched: enriched, text: segments.map(\.primary.text).joined(),
                       segments: segments, release_ms: (ended - released) * 1_000,
                       finalize_ms: (ended - finish) * 1_000)
    }
}
