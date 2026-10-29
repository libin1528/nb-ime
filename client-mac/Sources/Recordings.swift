// 最近 20 段录音存成 wav（16kHz 单声道，送去识别的就是这份）。识别错了可以在历史里回听，分清是收音的问题还是模型的问题。
// 只存在这台 Mac 的数据文件夹里（recordings/），文件名是「时间-任务号前 8 位」，和日志里的任务号对得上。

import Foundation

enum Recordings {
    static let limit = 20
    static var dir: URL { Settings.dir.appendingPathComponent("recordings") }
    private static let queue = DispatchQueue(label: "nbime.recordings")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// 存一段录音，返回文件名；超过 20 段删掉最旧的。写文件在后台做
    static func save(_ samples: [Float], id: String) -> String? {
        guard !samples.isEmpty else { return nil }
        let name = "\(stamp.string(from: Date()))-\(id.prefix(8)).wav"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? wav(samples).write(to: url(name))
            let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            for old in all.dropLast(limit) { try? fm.removeItem(at: url(old)) }
        }
        return name
    }

    /// 16 位 PCM
    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1))              // PCM、单声道
        put(UInt32(16000)); put(UInt32(32000))      // 采样率、每秒字节数
        put(UInt16(2)); put(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); put(bytes)
        for x in samples { put(Int16(max(-1, min(1, x)) * 32767)) }
        return d
    }
}
