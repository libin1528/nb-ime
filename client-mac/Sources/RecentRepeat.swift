import Cocoa

/// 三连按只重贴手势开始时的最终结果，并在入队和发键前核对原输入位置。
final class RecentRepeat {
    struct Context {
        let target: PasteTarget
        let element: AXUIElement
        let editable: Bool
        let remote: RetypeFocus.Observation?

        var eligible: Bool {
            guard target.isRustDesk else { return editable }
            guard let remote, remote.target == target, CFEqual(remote.element, element) else { return false }
            return RetypeFocus.capture(remote) != nil
        }

        func matches(_ other: Context?) -> Bool {
            guard let other, eligible, other.eligible, target == other.target,
                  CFEqual(element, other.element) else { return false }
            if target.isRustDesk { return RetypeFocus.capture(remote)?.matches(other.remote) == true }
            return true
        }

        static func current() -> Context? {
            guard let target = PasteTarget.frontmost(), let element = EditWatcher.focused() else { return nil }
            var pid: pid_t = 0, range: CFTypeRef?
            guard AXUIElementGetPid(element, &pid) == .success, pid == target.pid else { return nil }
            let editable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(EditWatcher.role(element))
                || AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
            return Context(target: target, element: element, editable: editable,
                           remote: target.isRustDesk ? RetypeFocus.observe(target: target) : nil)
        }
    }

    private let recent: () -> HistoryEntry?
    private let context: () -> Context?
    private let later: PasteDelivery.Later
    private var prepared: (entry: HistoryEntry, context: Context)?
    private var generation = 0

    init(recent: @escaping () -> HistoryEntry? = { History.items.first },
         context: @escaping () -> Context? = Context.current,
         later: @escaping PasteDelivery.Later = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.recent = recent
        self.context = context
        self.later = later
    }

    func cancel() { generation += 1; prepared = nil }

    func prepare(expectedPID: pid_t? = nil, expectedElement: AXUIElement? = nil) {
        cancel()
        let version = generation
        guard let entry = recent(), !entry.text.isEmpty else { return }
        // 重的 AX 会话读取离开事件钩子回调；正常录音先开始，不等连击判定。
        later(0) { [weak self] in
            guard let self, self.generation == version, let original = self.context(), original.eligible,
                  expectedPID == nil || expectedPID == original.target.pid,
                  expectedElement == nil || CFEqual(expectedElement!, original.element) else { return }
            self.prepared = (entry, original)
        }
    }

    func send(paste: @escaping (String, @escaping RetypeAction.Valid) -> Void, rejected: @escaping () -> Void) {
        let captured = prepared
        generation += 1
        prepared = nil
        later(0.15) { [recent, context] in
            guard let captured else { rejected(); return }
            let valid = {
                let latest = recent()
                return latest?.date == captured.entry.date && latest?.text == captured.entry.text && captured.context.matches(context())
            }
            guard valid() else { rejected(); return }
            paste(captured.entry.text, valid)
        }
    }
}
