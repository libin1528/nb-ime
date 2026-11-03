// 连识别服务：ssh 隧道 + WebSocket。
// 协议见 CapsWriter-Offline core/protocol.py：JSON 文本帧，音频是 16kHz 单声道 float32 的 base64。

import AppKit
import Foundation
import Network

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
            "-L", "127.0.0.1:\(s.localPort):127.0.0.1:\(s.serverPort)",
            "-L", "127.0.0.1:\(s.polishLocalPort):127.0.0.1:\(s.polishPort)",   // 润色用的小模型
            "-L", "127.0.0.1:\(s.transcribeLocalPort):127.0.0.1:\(s.transcribePort)",   // OpenAI 兼容的转写接口，输入法自己不用
            s.tunnelHost,
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

// MARK: - 网络变化

/// 换了网络（离开办公室、连上别的 Wi-Fi、合盖后在别处打开）时通知一声，好让隧道马上重开。
/// ssh 每次起来都按 ~/.ssh/config 重新选路：在办公室走局域网，在外面走公网端口映射（at-office.sh 判）。
/// 不重开的话，旧隧道要等 ServerAlive 两次没回（约 30 秒）才断，这段时间按住说话没反应。
final class NetWatch {
    private let monitor = NWPathMonitor()
    private var last: String?
    private var debounce: DispatchWorkItem?
    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            // 网卡、状态、地址族都一样就不算换网络；同一网卡换 Wi-Fi 时状态会先掉成 unsatisfied 再回来
            let key = "\(path.status)|\(path.availableInterfaces.map(\.name).joined(separator: ","))|\(path.supportsIPv4)|\(path.supportsIPv6)"
            DispatchQueue.main.async { self?.update(key, satisfied: path.status == .satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.w("睡眠唤醒")
            self?.fire()
        }
    }

    private func update(_ key: String, satisfied: Bool) {
        defer { last = key }
        guard let last, last != key else { return }   // 第一次回调是启动时的现状，不算变化
        Log.w("网络变了：\(key)")
        if satisfied { fire() }
    }

    /// 网络刚变时常常连着来几次，等 2 秒稳定了再动
    private func fire() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
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
