// 文字借剪贴板输入。RustDesk 需要独立的修饰键事件，也要给远端同步留出时间。
import Cocoa

enum Paster {
    private static let delivery = PasteDelivery()

    static func paste(_ text: String, restore: Bool) { delivery.paste(text, restore: restore) }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct PasteTarget: Equatable {
    let pid: pid_t
    let bundleID: String?
    var rustDeskSession: RustDeskPasteSession? = nil
    var isRustDesk: Bool { bundleID == "com.carriez.rustdesk" }

    static func frontmost() -> PasteTarget? {
        NSWorkspace.shared.frontmostApplication.map {
            PasteTarget(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                        rustDeskSession: $0.bundleIdentifier == "com.carriez.rustdesk" ? RustDeskPaste.current(pid: $0.processIdentifier) : nil)
        }
    }
}

final class PasteDelivery {
    typealias Later = (TimeInterval, @escaping () -> Void) -> Void
    private struct Request {
        let text: String
        let restore: Bool
        let target: PasteTarget?
    }
    private let pb: NSPasteboard
    private let target: () -> PasteTarget?
    private let post: (CGEvent) -> Void
    private let later: Later
    private let log: (String) -> Void
    private var pending: [Request] = []
    private var busy = false

    init(pasteboard: NSPasteboard = .general, target: @escaping () -> PasteTarget? = PasteTarget.frontmost,
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         later: @escaping Later = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
         log: @escaping (String) -> Void = Log.w) {
        pb = pasteboard
        self.target = target
        self.post = post
        self.later = later
        self.log = log
    }

    func paste(_ text: String, restore: Bool) {
        pending.append(Request(text: text, restore: restore, target: target()))
        next()
    }

    /// 完整事件还须带左侧修饰键的设备位；Flutter 用它同步左右修饰键状态。
    /// 见 Flutter macOS KeyCodeMap_Internal.h 的 kModifierFlagMetaLeft。
    static func shortcut(control: Bool = false) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        let command = control ? CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1)
                              : CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
        let modifier: CGKeyCode = control ? 59 : 55
        let keys: [(CGKeyCode, Bool, CGEventFlags)] = [
            (modifier, true, command), (9, true, command),
            (9, false, command), (modifier, false, []),
        ]
        let events = keys.compactMap { code, down, flags -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
            event.flags = flags
            return event
        }
        return events.count == keys.count ? events : []
    }

    private func next() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let request = pending.removeFirst()
        guard target() == request.target else {
            log("取消排队的粘贴：前台应用已切换，文字可从历史复制")
            finish()
            return
        }
        let control = request.target?.rustDeskSession?.useControl == true
        let events = Self.shortcut(control: control)
        guard !events.isEmpty else { log("无法创建粘贴按键，文字可从历史复制"); finish(); return }
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let remote = request.target?.isRustDesk == true
        let item = NSPasteboardItem()
        item.setString(request.text, forType: .string)
        // 本机仍不进剪贴板管理器；远程用普通文本，供同步程序读取。
        if !remote { item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) }
        pb.clearContents()
        guard pb.writeObjects([item]) else { log("写入剪贴板失败，文字可从历史复制"); finish(); return }
        let ours = pb.changeCount
        let restore = { [self] in
            guard request.restore, !saved.isEmpty, pb.changeCount == ours else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
        let send = { [self] in
            guard target() == request.target, pb.changeCount == ours else {
                log("取消延迟的粘贴：前台应用或剪贴板已变，文字可从历史复制")
                restore()
                finish()
                return
            }
            events.forEach(post)
            if remote {
                // 等远端消费后才恢复或写下一句，防止连续输入覆盖尚未同步的文字。
                later(2) { [self] in restore(); finish() }
            } else {
                later(0.8, restore)
                finish()
            }
        }
        if remote {
            log("RustDesk 粘贴：等待 0.7 秒同步剪贴板，再发送带左侧设备标志的 \(control ? "Control" : "Command")+V")
            later(0.7, send)
        } else {
            send()
        }
    }

    private func finish() { busy = false; next() }
}
