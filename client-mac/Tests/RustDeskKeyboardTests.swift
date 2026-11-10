// 与 RustDeskKeyboardProbe.mm 一起编译。只在内存里转换生产按键，不读写剪贴板、不向远端发字。
import Cocoa

@_silgen_name("nbime_rustdesk_keyboard_probe")
func rustDeskKeyboardProbe(_ events: UnsafeRawPointer) -> Int32

@main enum RustDeskKeyboardTests {
    static func convert(_ events: [CGEvent]) -> Int32 {
        let native = events.compactMap { NSEvent(cgEvent: $0) } as NSArray
        return rustDeskKeyboardProbe(Unmanaged.passUnretained(native).toOpaque())
    }

    static func main() {
        let events = PasteDelivery.shortcut()
        let result = convert(events)
        guard result == 31 else {
            print("FAIL: 生产粘贴经过 RustDesk 的 Flutter 后，Command 没有包住 V（状态 \(result)，期望 31）")
            exit(1)
        }
        // 最像的旧实现：独立 Command 事件存在，但只带不区分左右的通用标志。
        let missingSide = events.compactMap { $0.copy() }
        for event in missingSide { event.flags = CGEventFlags(rawValue: event.flags.rawValue & ~0x8) }
        guard convert(missingSide) != 31 else {
            print("FAIL: 未复现缺失左 Command 标志时的退化")
            exit(1)
        }
        let missingSideOnV = events.compactMap { $0.copy() }
        for event in missingSideOnV where event.getIntegerValueField(.keyboardEventKeycode) == 9 {
            event.flags = .maskCommand
        }
        guard convert(missingSideOnV) != 31 else {
            print("FAIL: V 缺少设备位时应复现 Flutter 提前释放 Command")
            exit(1)
        }
        let bareV = Array(events[1...2]).compactMap { $0.copy() }
        for event in bareV { event.flags = .maskCommand }
        guard convert(bareV) != 31 else {
            print("FAIL: 仅 V 带通用 Command 标记不应通过")
            exit(1)
        }
        print("RustDesk Flutter keyboard: 4 passed, 0 failed（真实转换器识别 Command+V，三种错误实现均能复现丢失修饰键）")
    }
}
