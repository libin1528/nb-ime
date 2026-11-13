// --mic-test：只计采样块和长度，不保存音频、不发送识别、不粘贴。
import Cocoa

enum MicrophoneProbe {
    static func run() {
        let recorder = Recorder()
        var frames = 0, blocks = 0, failed = false
        recorder.onSamples = { frames += $0.count; blocks += 1 }
        recorder.onFailure = { error in
            failed = true
            print("MIC FAIL: \(error.localizedDescription)")
        }
        func round(_ step: Int) {
            frames = 0; blocks = 0
            if step == 1 { NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil) }
            if step == 2 { NotificationCenter.default.post(name: .inputDevicesChanged, object: nil) }
            // 让设备变化的准备任务先离开通知栈。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                do { try recorder.start() }
                catch { print("MIC FAIL: \(error.localizedDescription)"); exit(1) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    recorder.stop()
                    print("MIC round=\(step) device=\(Recorder.deviceName) blocks=\(blocks) samples=\(frames)")
                    if frames == 0 { failed = true }
                    if step < 2 { round(step + 1) }
                    else { print(failed ? "MIC FAIL" : "MIC PASS"); exit(failed ? 1 : 0) }
                }
            }
        }
        round(0)
    }
}
