// NB 输入法：按住快捷键（默认右 Option）说话，松开后文字粘贴进当前输入框。
// 识别跑在局域网 ITX 上的 CapsWriter 服务端（见 server/README.md），各部分：
//   AppController 主控 · Hotkey 热键 · Audio 录音与粘贴 · Network 隧道与 WebSocket
//   Capsule 录音提示 · MenuBar 菜单栏 · SettingsWindow 设置 · Onboarding 首次引导 · Glyph 图标

import Cocoa
import ServiceManagement

if CommandLine.arguments.contains("--enable-login-item") {
    AppController.setLoginItem(true)
    exit(SMAppService.mainApp.status == .enabled ? 0 : 1)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(CommandLine.arguments.contains("--test-file") ? .prohibited : .accessory)
app.run()
