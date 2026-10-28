// 录音（转成 16kHz 单声道 float32）、提示音、粘贴。

import AVFoundation
import Cocoa

final class Recorder {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var running = false
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "NBIME", code: 1, userInfo: [NSLocalizedDescriptionKey: "拿不到麦克风"])
        }
        let out = outFormat
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inFormat.sampleRate / 20), format: inFormat) { [weak self] buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / inFormat.sampleRate + 64)
            guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: dst, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard dst.frameLength > 0, let ch = dst.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(dst.frameLength)))
            DispatchQueue.main.async { self?.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// 一段采样的音量，映射到 0…1（-55 dB 以下算 0，-15 dB 以上算 1）
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        let db = 10 * log10(max(sum / Float(samples.count), 1e-12))
        return min(1, max(0, (db + 55) / 40))
    }
}

enum Sounds {
    static func start() { if Settings.current.sounds { NSSound(named: "Tink")?.play() } }
    static func stop() { if Settings.current.sounds { NSSound(named: "Pop")?.play() } }
}

enum Paster {
    static func paste(_ text: String, restore: Bool) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // 让剪贴板管理器不记这一条
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ours = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // 9 = V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        guard restore, !saved.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
