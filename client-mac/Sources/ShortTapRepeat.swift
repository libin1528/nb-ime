import Foundation

/// 同一快捷键三次完整短按，从首次按下到第三次松开最多一秒。
final class ShortTapRepeat {
    private let now: () -> TimeInterval
    private var key: UInt16?
    private var first = 0.0
    private var pressed: TimeInterval?
    private var count = 0

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    /// 返回 true 时开始新的连击，供调用方捕获原焦点和最近结果。
    func down(_ code: UInt16) -> Bool {
        let time = now()
        if pressed != nil { cancel(); return false }
        if key != code || time - first > 1 { cancel() }
        let began = count == 0
        if began { key = code; first = time }
        pressed = time
        return began
    }

    func up(_ code: UInt16, threshold: TimeInterval) -> Bool {
        let time = now()
        guard key == code, let start = pressed,
              time - start < threshold, time - first <= 1 else { cancel(); return false }
        pressed = nil
        count += 1
        guard count == 3 else { return false }
        cancel()
        return true
    }

    func cancel() { key = nil; pressed = nil; count = 0 }
}
