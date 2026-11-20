// 描述要从正式识别缓冲区取出的试听范围。每次只等一个草稿，松键即失效。
import Foundation

struct DictationPreview {
    private(set) var samples = 0
    private var start = 0
    private var lastRequest = 0
    private var lastVoice = 0
    private var prefix = ""
    private var lastDisplay = ""
    private var pending: (id: String, end: Int, boundary: Bool)?
    private var enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    mutating func stop() {
        enabled = false
        pending = nil
    }

    mutating func append(_ pcm: [Float], task: String) -> [String: Any]? {
        samples += pcm.count
        guard enabled else { return nil }
        if stride(from: 0, to: pcm.count, by: 8).contains(where: { abs(pcm[$0]) > 0.002 }) {
            lastVoice = samples
        }
        guard pending == nil else { return nil }
        let paused = samples - lastVoice >= 4_800
        // 草稿已经覆盖最后一个有声帧时，停顿直接确定这一段，无需再推理。
        if paused, lastVoice <= lastRequest, lastRequest - start >= 64_000, !lastDisplay.isEmpty {
            start = lastRequest
            prefix = lastDisplay
        }
        guard lastVoice > lastRequest, samples - start >= 19_200 else { return nil }
        let duration = samples - start
        let boundary = (paused && duration >= 64_000) || duration >= 144_000
        guard lastRequest == start || boundary || samples - lastRequest >= 25_600 else { return nil }
        let id = "\(task)/preview/\(samples)"
        pending = (id, samples, boundary)
        lastRequest = samples
        return ["id": id, "start": start, "end": samples]
    }

    func expects(_ id: String) -> Bool { pending?.id == id }

    mutating func accept(_ id: String, text: String) -> String? {
        guard let request = pending, request.id == id else { return nil }
        pending = nil
        lastDisplay = ""
        guard !text.isEmpty else { return nil }
        let space = prefix.last?.isASCII == true && text.first?.isASCII == true ? " " : ""
        let display = prefix + space + text
        lastDisplay = display
        if request.boundary {
            prefix = display
            start = request.end
        }
        return display
    }
}
