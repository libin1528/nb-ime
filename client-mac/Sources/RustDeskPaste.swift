import Cocoa

struct RustDeskPasteSession: Equatable {
    let peer: String
    let platform: String
    let swapped: Bool
    var useControl: Bool { (platform != "Mac OS") != swapped }
}

enum RustDeskPaste {
    static func current(pid: pid_t) -> RustDeskPasteSession? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?, title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let title = title as? String else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.carriez.RustDesk/peers")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var matches: [RustDeskPasteSession] = []
        for file in files where file.pathExtension == "toml" {
            let name = file.deletingPathExtension().lastPathComponent
            let peer: String
            if name.hasPrefix("base64_") {
                guard let data = Data(base64Encoded: String(name.dropFirst(7))), let decoded = String(data: data, encoding: .utf8) else { continue }
                peer = decoded
            } else { peer = name }
            guard Self.matches(title: title, peer: peer), let config = try? String(contentsOf: file, encoding: .utf8),
                  let session = parse(peer: peer, config: config) else { continue }
            matches.append(session)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func matches(title: String, peer: String) -> Bool {
        !peer.isEmpty && (title.hasPrefix(peer + "@") || title.hasPrefix(peer + " - "))
    }

    /// 只读取所需的三个字段；不把文件里的密码等内容写进日志。
    static func parse(peer: String, config: String) -> RustDeskPasteSession? {
        var section = "", swapped: Bool?, platform: String?
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if section.isEmpty, pair[0] == "allow_swap_key" {
                let value = pair[1].split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
                if value == "true" { swapped = true }
                if value == "false" { swapped = false }
            }
            if section == "[info]", pair[0] == "platform" {
                for name in ["Windows", "Mac OS", "Linux"] where pair[1] == "'\(name)'" || pair[1] == "\"\(name)\"" { platform = name }
            }
        }
        guard let platform, let swapped else { return nil }
        return RustDeskPasteSession(peer: peer, platform: platform, swapped: swapped)
    }
}
