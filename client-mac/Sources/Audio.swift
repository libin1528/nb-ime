// 录音（转成 16kHz 单声道 float32）、能录音的设备、提示音、粘贴。

import AudioToolbox
import AVFoundation
import Cocoa
import CoreAudio

final class Recorder {
    private var engine = AVAudioEngine()
    private var engineDevice: AudioDeviceID?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var running = false
    var onSamples: (([Float]) -> Void)?

    /// AVAudioEngine 只认建它时的设备，系统换了默认麦克风也不跟。对一下现在该用哪个，换了就重建一个，显式指定设备。
    /// 建引擎要一两秒（无线麦尤其慢），启动时和设备变了时先做，免得按下快捷键时卡住主线程、热键钩子被系统停掉
    func prepare() throws {
        guard !running else { return }
        guard let dev = InputDevices.current() else {
            throw NSError(domain: "NBIME", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有能录音的设备"])
        }
        guard dev.id != engineDevice else { return }
        engine = AVAudioEngine()
        var id = dev.id
        let st = AudioUnitSetProperty(engine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        _ = engine.inputNode.outputFormat(forBus: 0)
        Log.w(st == noErr ? "录音设备换成 \(dev.name)" : "录音设备换不过去（\(st)），用系统默认的")
        engineDevice = dev.id
    }

    func start() throws {
        try prepare()
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

    /// 录音用的设备名字
    static var deviceName: String { InputDevices.current()?.name ?? "麦克风" }

    /// 一段采样的音量，映射到 0…1（-55 dB 以下算 0，-15 dB 以上算 1）
    static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples { sum += x * x }
        let db = 10 * log10(max(sum / Float(samples.count), 1e-12))
        return min(1, max(0, (db + 55) / 40))
    }
}

// MARK: - 能录音的设备

extension Notification.Name {
    static let inputDevicesChanged = Notification.Name("NBInputDevicesChanged")
}

struct InputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum InputDevices {
    /// 所有有输入通道的设备，按系统给的顺序
    static func all() -> [InputDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    static var systemDefault: InputDevice? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return all().first { $0.id == id }
    }

    /// 录音实际用的：设置里选了而且还连着就用它，否则用系统默认的
    static func current() -> InputDevice? {
        let uid = Settings.current.micUID
        return (uid.isEmpty ? nil : all().first { $0.uid == uid }) ?? systemDefault
    }

    /// 插拔设备、系统换默认麦克风时发 .inputDevicesChanged
    static func watch() {
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
                NotificationCenter.default.post(name: .inputDevicesChanged, object: nil)
            }
        }
    }

    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
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
