// 只读取当前 RustDesk 会话；用与输入法相同的应用签名运行以验证辅助功能权限。
import Cocoa
@main enum RustDeskTargetProbe {
    static func main() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.carriez.rustdesk").first,
              let session = RustDeskPaste.current(pid: app.processIdentifier) else {
            print("无法读取当前 RustDesk 会话"); exit(1)
        }
        print("platform=\(session.platform) swapped=\(session.swapped) paste=\(session.useControl ? "Control+V" : "Command+V")")
    }
}
