// 连识别服务：ssh 隧道 + WebSocket。
// 协议见 CapsWriter-Offline core/protocol.py：JSON 文本帧，音频是 16kHz 单声道 float32 的 base64。

import Foundation

// MARK: - ssh 隧道（不用在 ITX 上开防火墙端口）

final class Tunnel {
    private var proc: Process?
    private var stopped = false
    let s: Settings
    var onExit: ((String) -> Void)?   // ssh 退出时的报错，主线程回调

    init(_ s: Settings) { self.s = s }

    /// 上次没退干净的隧道（同样的转发参数）先清掉，不然端口被占
    func killStale() {
        guard !s.tunnelHost.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "127.0.0.1:\(s.localPort):127.0.0.1:\(s.serverPort)"]
        try? p.run()
        p.waitUntilExit()
    }

    func start() {
        guard !s.tunnelHost.isEmpty, !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "ConnectTimeout=8",
            "-L", "127.0.0.1:\(s.localPort):127.0.0.1:\(s.serverPort)", s.tunnelHost,
        ]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] pr in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Log.w("隧道退出 code=\(pr.terminationStatus) \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.async { self?.onExit?(msg) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
        }
        do {
            try p.run()
            proc = p
            Log.w("隧道启动 pid=\(p.processIdentifier) → \(s.tunnelHost)")
        } catch {
            Log.w("隧道启动失败 \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
        }
    }

    func stop() {
        stopped = true
        proc?.terminate()
    }
}

// MARK: - WebSocket 客户端

final class ASRClient: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var reconnectScheduled = false
    private var pingTimer: Timer?
    private var stopped = false
    let url: URL
    let name: String                 // 日志里分清是哪条连接
    var connected = false { didSet { if oldValue != connected { onState?() } } }
    var onState: (() -> Void)?
    var onResult: ((String, Bool, String) -> Void)?   // taskId, isFinal, text
    private(set) var latency: Double?                 // 最近一次 ping 的往返毫秒

    init(url: URL, name: String) {
        self.url = url
        self.name = name
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.ping() }
    }

    func connect() {
        guard !stopped else { return }
        reconnectScheduled = false
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: url, protocols: ["binary"])
        t.maximumMessageSize = 64 << 20
        task = t
        t.resume()
        receive(t)
    }

    /// 换了连接设置，旧的这条不再用
    func stop() {
        stopped = true
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }

    func ping(_ done: ((Double?) -> Void)? = nil) {
        guard let t = task, connected else { done?(nil); return }
        let t0 = Date()
        t.sendPing { [weak self] e in
            DispatchQueue.main.async {
                let ms = e == nil ? Date().timeIntervalSince(t0) * 1000 : nil
                if let ms { self?.latency = ms }
                done?(ms)
            }
        }
    }

    private func scheduleReconnect() {
        connected = false
        guard !reconnectScheduled, !stopped else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] r in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch r {
                case .success(let m):
                    var data: Data?
                    switch m {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = j["task_id"] as? String {
                        self.onResult?(id, j["is_final"] as? Bool ?? false, j["text"] as? String ?? "")
                    }
                    self.receive(t)
                case .failure(let e):
                    Log.w("[\(self.name)] 接收失败 \(e.localizedDescription)")
                    self.scheduleReconnect()
                }
            }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { [name] e in if let e { Log.w("[\(name)] 发送失败 \(e.localizedDescription)") } }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        Log.w("[\(name)] 已连上 \(url)")
        connected = true
        ping()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        scheduleReconnect()
    }
}
