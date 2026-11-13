// AVAudioEngine 的硬件边界；Recorder 负责断流检测、设备变化及恢复。
import AudioToolbox
import AVFoundation
import CoreAudio

struct RecordingFormat: Equatable {
    let rate: Double
    let channels: UInt32
}

protocol RecordingEngine: AnyObject {
    var format: RecordingFormat { get }
    var isRunning: Bool { get }
    var notificationObject: AnyObject { get }
    func selectDevice(_ id: AudioDeviceID) throws
    /// 回调在主线程；包括静音采样，用于区分安静与断流。
    func start(_ onSamples: @escaping ([Float]) -> Void) throws
    func stop()
}

final class SystemRecordingEngine: RecordingEngine {
    private let engine = AVAudioEngine()
    private var tapped = false
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    var notificationObject: AnyObject { engine }
    var isRunning: Bool { engine.isRunning }
    var format: RecordingFormat {
        let f = engine.inputNode.inputFormat(forBus: 0)
        return RecordingFormat(rate: f.sampleRate, channels: f.channelCount)
    }

    func selectDevice(_ id: AudioDeviceID) throws {
        // 默认设备交给引擎建立输入/输出组合，不把共享 IO 单元改绑到仅输入的设备。
        guard id != InputDevices.systemDefault?.id else { return }
        guard let unit = engine.inputNode.audioUnit else {
            throw NSError(domain: "NBIME", code: 1, userInfo: [NSLocalizedDescriptionKey: "拿不到麦克风音频单元"])
        }
        var device = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func start(_ onSamples: @escaping ([Float]) -> Void) throws {
        let hw = engine.inputNode.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw NSError(domain: "NBIME", code: 1, userInfo: [NSLocalizedDescriptionKey: "拿不到麦克风"])
        }
        let out = out
        let box = ConverterBox()
        // 用输入设备自己的采样率，避免混入输出设备格式导致 installTap 崩溃。
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hw.sampleRate / 20), format: hw) { buf, _ in
            let input = buf.format
            guard input.sampleRate > 0, buf.frameLength > 0 else { return }
            if box.converter?.inputFormat != input { box.converter = AVAudioConverter(from: input, to: out) }
            guard let converter = box.converter else { return }
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * 16000 / input.sampleRate + 64)
            guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: dst, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard error == nil, dst.frameLength > 0, let channel = dst.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(dst.frameLength)))
            DispatchQueue.main.async { onSamples(samples) }
        }
        tapped = true
        engine.prepare()
        do { try engine.start() }
        catch { stop(); throw error }
    }

    func stop() {
        // 先停 IO 再拆 tap，避免音频线程访问已移除的回调。
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    }

    private final class ConverterBox { var converter: AVAudioConverter? }
}
