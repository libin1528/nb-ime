import Foundation

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NBIME.log")
    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func w(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
        if isatty(2) != 0 { FileHandle.standardError.write(data) }
    }
}
