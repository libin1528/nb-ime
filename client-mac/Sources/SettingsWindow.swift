// 设置窗口：通用 / 快捷键 / 热词 / 历史 / 识别服务 / 关于（design/mockup.html 第 4 节）。

import Cocoa
import ServiceManagement

extension Notification.Name {
    static let connectionChanged = Notification.Name("NBConnectionChanged")
}

/// 设置窗口要向主控要的东西
protocol SettingsHost: AnyObject {
    var isConnected: Bool { get }
    var needsLocalNetwork: Bool { get }
    var latency: Double? { get }
    func testConnection(_ done: @escaping (Double?) -> Void)
    /// 开始录新快捷键；没有辅助功能权限时返回 false
    func captureHotkey(_ done: @escaping (UInt16?) -> Void) -> Bool
    func cancelHotkeyCapture()
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let width: CGFloat = 680
    static let height: CGFloat = 480
    static let inner: CGFloat = width - 56

    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private weak var host: SettingsHost?

    init(host: SettingsHost) { self.host = host }

    enum Tab: Int { case general, hotkey, words, history, conn, about }

    func show(_ tab: Tab? = nil) {
        if window == nil { build() }
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        Settings.reloadHotwords()
        NotificationCenter.default.post(name: .hotwordsChanged, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var nsWindow: NSWindow? { window }

    private func build() {
        guard let host else { return }
        let tc = NSTabViewController()
        tc.tabStyle = .toolbar
        tc.transitionOptions = []
        let items: [(String, String, NSViewController)] = [
            ("通用", "gearshape", GeneralPane()),
            ("快捷键", "keyboard", HotkeyPane(host: host)),
            ("热词", "text.badge.star", WordsPane()),
            ("历史", "clock", HistoryPane()),
            ("识别服务", "desktopcomputer", ConnPane(host: host)),
            ("关于", "info.circle", AboutPane()),
        ]
        for (title, symbol, vc) in items {
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            vc.title = title
            tc.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tc)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: Self.width, height: Self.height))
        w.center()
        window = w
        tabs = tc
    }

    func windowWillClose(_ n: Notification) { host?.cancelHotkeyCapture() }
}

// MARK: - 每个标签页的底子

class Pane: NSViewController {
    let stack = NSStackView()

    override func loadView() {
        let v = BackgroundView()
        v.frame = NSRect(x: 0, y: 0, width: SettingsWindow.width, height: SettingsWindow.height)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 22),
            v.widthAnchor.constraint(equalToConstant: SettingsWindow.width),
            v.heightAnchor.constraint(equalToConstant: SettingsWindow.height),
        ])
        view = v
        preferredContentSize = v.frame.size
        build()
    }

    func build() {}

    override func viewDidAppear() {
        super.viewDidAppear()
        // 切到这一页时不要自动把光标放进第一个输入框
        view.window?.makeFirstResponder(nil)
    }

    /// 加一块，after 是和下一块之间的距离
    func add(_ v: NSView, full: Bool = true, after: CGFloat = 16) {
        stack.addArrangedSubview(v)
        if full { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.setCustomSpacing(after, after: v)
    }
}

final class BackgroundView: NSView {
    override func draw(_ dirty: NSRect) {
        UI.windowBG.setFill()
        dirty.fill()
    }
}

// MARK: - 通用

final class GeneralPane: Pane {
    private var loginSwitch: NSSwitch!

    override func build() {
        let s = Settings.current
        loginSwitch = UI.toggle(SMAppService.mainApp.status == .enabled) { on in
            AppController.setLoginItem(on)
        }
        add(GroupView([
            UI.row("登录时自动启动", nil, loginSwitch),
            UI.row("提示框位置", "「跟着光标」在拿不到光标位置的应用里会退回到屏幕底部",
                   UI.segmented(["屏幕底部", "跟着光标"], selected: s.hudPosition == "caret" ? 1 : 0) {
                       Settings.current.hudPosition = $0 == 1 ? "caret" : "bottom"
                   }),
            UI.row("说话时实时显示文字", "每 2 秒更新一次；松开后用完整识别的结果输入",
                   UI.toggle(s.streamPreview) { Settings.current.streamPreview = $0 }),
            UI.row("开始和结束时的提示音", nil, UI.toggle(s.sounds) { Settings.current.sounds = $0 }),
        ]))
        add(UI.sectionTitle("文字"), after: 6)
        let lang = NSPopUpButton()
        lang.controlSize = .small
        let langs = [("自动（中英混说）", "auto"), ("中文", "chinese"), ("英文", "english")]
        lang.addItems(withTitles: langs.map(\.0))
        lang.selectItem(at: langs.firstIndex { $0.1 == s.language } ?? 0)
        lang.onAction { _ in Settings.current.language = langs[lang.indexOfSelectedItem].1 }
        add(GroupView([
            UI.row("识别语言", nil, lang),
            UI.row("短句去掉末尾的句号", "12 个字以内，比如「好的」「收到」",
                   UI.toggle(s.stripShortTrailingPeriod) { Settings.current.stripShortTrailingPeriod = $0 }),
            UI.row("输入后恢复剪贴板", "文字是借剪贴板粘进去的，粘完把你原来复制的东西放回去",
                   UI.toggle(s.restoreClipboard) { Settings.current.restoreClipboard = $0 }),
        ]))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

// MARK: - 快捷键

final class HotkeyPane: Pane {
    private weak var host: SettingsHost?
    private let line = NSStackView()
    private let hint = UI.label("修饰键（Option、Command、Control、Shift、Fn）或者 F1–F19 这类单键都可以", size: 12, color: .secondaryLabelColor)
    // 两个快捷键各一行：键帽、更换；第二个还能清掉
    private let caps = [KeyCap("", size: 13, pad: 10), KeyCap("", size: 13, pad: 10)]
    private var changeButtons: [NSButton] = []
    private var clearButton: NSButton!
    private var recordingSlot: Int?

    init(host: SettingsHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        line.orientation = .horizontal
        line.spacing = 10
        let hero = UI.vstack([line, hint], spacing: 12, align: .centerX)
        hero.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 22, right: 0)
        add(hero)
        changeButtons = (0..<2).map { i in UI.button("更换") { [weak self] in self?.startCapture(i) } }
        clearButton = UI.button("清掉") { [weak self] in
            Settings.current.hotkeyCode2 = nil
            self?.hint.stringValue = "第二个快捷键清掉了"
            self?.hint.textColor = .secondaryLabelColor
            self?.refresh()
        }
        add(GroupView([
            UI.row("快捷键", nil, UI.hstack([caps[0], changeButtons[0]], spacing: 8)),
            UI.row("第二个快捷键", "可以不设；两个都能按住说话，效果一样",
                   UI.hstack([caps[1], changeButtons[1], clearButton], spacing: 8)),
        ]))
        let s = Settings.current
        add(GroupView([
            UI.row("按住多久才开始录音", "太短容易误触，太长开头会慢",
                   slider(s.holdThreshold, 0.1, 0.8) { Settings.current.holdThreshold = $0 }),
            UI.row("松开后多录一会儿", "免得吞掉最后一个字",
                   slider(s.tailSeconds, 0, 0.6) { Settings.current.tailSeconds = $0 }),
        ]), after: 10)
        add(UI.footnote("按住快捷键时又按了别的键，算你在用组合快捷键，这次不录音。"))
        refresh()
    }

    /// 按当前设置重画：上面一句「按住 A 或 B 说话」，下面两行键帽
    private func refresh() {
        let codes = Settings.current.hotkeyCodes
        line.arrangedSubviews.forEach { $0.removeFromSuperview() }
        line.addArrangedSubview(UI.label("按住", size: 15))
        for (i, c) in codes.enumerated() {
            if i > 0 { line.addArrangedSubview(UI.label("或", size: 15)) }
            line.addArrangedSubview(KeyCap(Hotkey.keyLabel(c), size: 15, pad: 14))
        }
        line.addArrangedSubview(UI.label("说话，松开就输入", size: 15))
        let second = Settings.current.hotkeyCode2
        for i in 0..<2 where recordingSlot != i {
            caps[i].recording = false
            caps[i].text = i == 0 ? Hotkey.keyLabel(Settings.current.hotkeyCode) : second.map(Hotkey.keyLabel) ?? "没设"
        }
        caps[1].alphaValue = second == nil && recordingSlot != 1 ? 0.5 : 1
        changeButtons[1].title = second == nil ? "设置" : "更换"
        changeButtons.forEach { $0.isEnabled = recordingSlot == nil }
        clearButton.isHidden = second == nil
        clearButton.isEnabled = recordingSlot == nil
    }

    private func slider(_ v: Double, _ lo: Double, _ hi: Double, _ f: @escaping (Double) -> Void) -> NSView {
        let s = NSSlider(value: v, minValue: lo, maxValue: hi, target: nil, action: nil)
        s.controlSize = .small
        s.numberOfTickMarks = Int(((hi - lo) / 0.05).rounded()) + 1
        s.allowsTickMarkValuesOnly = true
        s.tickMarkPosition = .below
        s.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let val = UI.label(String(format: "%.2f 秒", v), color: .secondaryLabelColor)
        val.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        val.alignment = .right
        val.widthAnchor.constraint(equalToConstant: 56).isActive = true
        s.onAction { c in
            let x = ((c as! NSSlider).doubleValue * 20).rounded() / 20
            val.stringValue = String(format: "%.2f 秒", x)
            f(x)
        }
        return UI.hstack([s, val], spacing: 8)
    }

    private func startCapture(_ slot: Int) {
        guard let host else { return }
        guard host.captureHotkey({ [weak self] code in self?.captured(code) }) else {
            hint.stringValue = "要先在「系统设置 › 隐私与安全性 › 辅助功能」里打开 NB 输入法"
            return
        }
        recordingSlot = slot
        caps[slot].recording = true
        caps[slot].text = "按下新的键…"
        caps[slot].alphaValue = 1
        hint.stringValue = "按 Esc 取消"
        hint.textColor = .secondaryLabelColor
        refresh()
    }

    private func captured(_ code: UInt16?) {
        guard let slot = recordingSlot else { return }
        recordingSlot = nil
        if let code {
            // 两个不能是同一个键
            let other = slot == 0 ? Settings.current.hotkeyCode2 : Settings.current.hotkeyCode
            if code == other {
                hint.stringValue = "\(Hotkey.keyName(code))已经是\(slot == 0 ? "第二个" : "第一个")快捷键了，换一个"
                hint.textColor = .systemRed
                NSSound.beep()
                refresh()
                return
            }
            if slot == 0 { Settings.current.hotkeyCode = code } else { Settings.current.hotkeyCode2 = code }
            hint.stringValue = "已改成\(Hotkey.keyName(code))"
        } else {
            hint.stringValue = "没改"
        }
        hint.textColor = .secondaryLabelColor
        refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if recordingSlot != nil {
            host?.cancelHotkeyCapture()
            captured(nil)
        }
    }
}

// MARK: - 热词

/// 一行一个词，像改文档一样直接改；停手半秒自动存
final class WordsPane: Pane, NSTextViewDelegate {
    private let text = NSTextView()
    private let count = UI.label("", size: 12, color: .secondaryLabelColor)
    private var saveWork: DispatchWorkItem?

    override func build() {
        add(UI.wrapping("人名、产品名、专业词，一行一个。识别时会优先往这些词上靠，读音一样的也会换成这里的写法，比如加了「Wan3」，说「万三」就输入 Wan3。",
                        size: 13, width: SettingsWindow.inner), after: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 290).isActive = true
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        text.defaultParagraphStyle = para
        text.typingAttributes[.paragraphStyle] = para
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        scroll.documentView = text
        add(scroll, after: 8)
        add(count)
        reload()
        NotificationCenter.default.addObserver(forName: .hotwordsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.saveWork == nil else { return }   // 自己存的不用回填，免得光标跳
            self.reload()
        }
    }

    private func reload() {
        let words = Settings.hotwordList()
        text.string = words.joined(separator: "\n")
        count.stringValue = "\(words.count) 个词 · 只存在这台 Mac 上，团队里每个人各管各的"
    }

    private func parsed() -> [String] {
        var seen = Set<String>()
        return text.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    func textDidChange(_ n: Notification) {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func save() {
        let words = parsed()
        if words != Settings.hotwordList() { Settings.saveHotwords(words) }
        saveWork = nil
        count.stringValue = "\(words.count) 个词 · 只存在这台 Mac 上，团队里每个人各管各的"
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if saveWork != nil { saveWork?.cancel(); save() }
    }
}

// MARK: - 历史

final class HistoryPane: Pane, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let search = NSSearchField()
    private let empty = UI.label("还没有记录", color: .tertiaryLabelColor)
    private var rows: [HistoryEntry] = []

    override func build() {
        search.placeholderString = "搜索"
        search.widthAnchor.constraint(equalToConstant: 280).isActive = true
        search.onAction { [weak self] _ in self?.reload() }
        let clear = UI.button("清空历史") { [weak self] in self?.confirmClear() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        add(UI.hstack([search, spacer, clear], spacing: 8), after: 10)

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let group = GroupView([scroll])
        empty.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(empty)
        empty.centerXAnchor.constraint(equalTo: group.centerXAnchor).isActive = true
        empty.centerYAnchor.constraint(equalTo: group.centerYAnchor).isActive = true
        add(group, after: 10)
        add(UI.footnote("保留最近 \(History.limit) 条，只存在这台 Mac 上。"))
        reload()
        NotificationCenter.default.addObserver(forName: .historyChanged, object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    private func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        rows = q.isEmpty ? History.items : History.items.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
        empty.stringValue = q.isEmpty ? "还没有记录" : "没找到"
        empty.isHidden = !rows.isEmpty
        table.reloadData()
    }

    private func confirmClear() {
        guard !History.items.isEmpty, let w = view.window else { return }
        let a = NSAlert()
        a.messageText = "清空全部 \(History.items.count) 条识别历史？"
        a.informativeText = "清空后找不回来。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        a.buttons[0].hasDestructiveAction = true
        a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { History.clear() } }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        HistoryCell(rows[row], width: SettingsWindow.inner)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let r = HistoryRowView()
        r.last = row == rows.count - 1
        return r
    }
}

private final class HistoryCell: NSTableCellView {
    let copyButton: NSButton

    init(_ e: HistoryEntry, width: CGFloat) {
        copyButton = UI.button("复制") { Paster.copy(e.text) }
        super.init(frame: .zero)
        let text = UI.wrapping(e.text, size: 13, color: .labelColor, width: width - 120)
        text.isSelectable = true
        var meta = History.when(e.date) + " · " + String(format: "%.1f 秒", e.seconds)
        if !e.app.isEmpty { meta += " · " + e.app }
        let left = UI.vstack([text, UI.label(meta, size: 11, color: .tertiaryLabelColor)], spacing: 2)
        copyButton.controlSize = .small
        copyButton.alphaValue = 0
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let h = NSStackView(views: [left, spacer, copyButton])
        h.alignment = .top
        h.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 鼠标移上去才露出「复制」；行与行之间一条细线
private final class HistoryRowView: NSTableRowView {
    var last = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private var cell: HistoryCell? { subviews.compactMap { $0 as? HistoryCell }.first }
    override func mouseEntered(with event: NSEvent) { cell?.copyButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { cell?.copyButton.animator().alphaValue = 0 }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !last else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 14, y: bounds.maxY - 1, width: bounds.width - 28, height: 1 / (window?.backingScaleFactor ?? 2)).fill()
    }
}

// MARK: - 识别服务

final class ConnPane: Pane {
    private weak var host: SettingsHost?
    private let badge = NSImageView()
    private let badgeBG = NSView()
    private let titleLabel = UI.label("", weight: .semibold)
    private let sub = UI.label("", size: 12, color: .secondaryLabelColor)
    private var sshRows: [NSView] = []

    init(host: SettingsHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        badgeBG.wantsLayer = true
        badgeBG.layer?.cornerRadius = 10
        badgeBG.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBG.addSubview(badge)
        NSLayoutConstraint.activate([
            badgeBG.widthAnchor.constraint(equalToConstant: 40), badgeBG.heightAnchor.constraint(equalToConstant: 40),
            badge.centerXAnchor.constraint(equalTo: badgeBG.centerXAnchor), badge.centerYAnchor.constraint(equalTo: badgeBG.centerYAnchor),
        ])
        let test = UI.button("测试一下") { [weak self] in
            self?.sub.stringValue = "正在测…"
            self?.host?.testConnection { _ in self?.refresh() }
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let card = UI.hstack([badgeBG, UI.vstack([titleLabel, sub], spacing: 2), spacer, test], spacing: 14)
        card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        add(GroupView([card]))

        let s = Settings.current
        add(UI.sectionTitle("连接方式"), after: 6)
        let viaSSH = !s.tunnelHost.isEmpty
        let sshHost = field(viaSSH ? s.tunnelHost : "winrig") { Settings.current.tunnelHost = $0 }
        let host = field(s.serverHost) { Settings.current.serverHost = $0 }
        let port = field(String(s.serverPort)) { if let p = Int($0) { Settings.current.serverPort = p } }
        let sshRow = UI.row("SSH 主机", "~/.ssh/config 里的名字，要能免密登录", sshHost)
        let hostRow = UI.row("服务器", nil, host)
        sshRows = [sshRow]
        let mode = UI.segmented(["SSH 隧道", "局域网直连"], selected: viaSSH ? 0 : 1) { [weak self] i in
            Settings.current.tunnelHost = i == 0 ? (sshHost.stringValue.isEmpty ? "winrig" : sshHost.stringValue) : ""
            self?.sshRows.forEach { $0.isHidden = i != 0 }
        }
        sshRow.isHidden = !viaSSH
        add(GroupView([
            UI.row("方式", "SSH 隧道不用在 ITX 上开防火墙；局域网直连要服务端对局域网开放", mode),
            sshRow, hostRow, UI.row("端口", nil, port),
        ]), after: 10)
        add(UI.footnote("识别在你自己的 ITX 上完成，录音不出局域网。"))
        refresh()
        NotificationCenter.default.addObserver(forName: .connectionChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        host?.testConnection { [weak self] _ in self?.refresh() }
    }

    private func field(_ v: String, _ f: @escaping (String) -> Void) -> NSTextField {
        let t = NSTextField(string: v)
        t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        t.alignment = .right
        t.bezelStyle = .roundedBezel
        t.controlSize = .small
        t.widthAnchor.constraint(equalToConstant: 180).isActive = true
        t.cell?.sendsActionOnEndEditing = true
        t.onAction { c in
            let v = (c as! NSTextField).stringValue.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { f(v) }
        }
        return t
    }

    private func refresh() {
        guard let host else { return }
        let ok = host.isConnected
        let sym = ok ? "checkmark" : "exclamationmark"
        badge.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .bold))
        badge.contentTintColor = ok ? NSColor(hex: 0x16a34a) : UI.orange
        badgeBG.layer?.backgroundColor = (ok ? UI.green : UI.orange).withAlphaComponent(0.15).cgColor
        titleLabel.stringValue = ok ? "已连接 ITX" : "连不上 ITX"
        if ok {
            let ms = host.latency.map { "延迟 \(Int($0.rounded())) 毫秒 · " } ?? ""
            sub.stringValue = ms + "模型 Qwen3-ASR-1.7B · 显卡加速"
        } else {
            sub.stringValue = host.needsLocalNetwork
                ? "要在「系统设置 › 隐私与安全性 › 本地网络」里打开 NB 输入法"
                : "正在重试；看看 ITX 开着没有、网络通不通"
        }
    }
}

// MARK: - 关于

final class AboutPane: Pane {
    override func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2"
        let buttons = UI.hstack([
            UI.button("查看日志") { NSWorkspace.shared.open(Log.url) },
            UI.button("打开数据文件夹") { NSWorkspace.shared.open(Settings.dir) },
        ], spacing: 8)
        let hero = UI.vstack([
            icon,
            UI.label("NB 输入法", size: 17, weight: .semibold),
            UI.label("版本 \(v) · 识别服务 CapsWriter 2.6", color: .secondaryLabelColor),
            UI.label("Newbase Lab", size: 12, color: .tertiaryLabelColor),
            buttons,
        ], spacing: 10, align: .centerX)
        hero.setCustomSpacing(6, after: hero.arrangedSubviews[1])
        hero.setCustomSpacing(16, after: hero.arrangedSubviews[3])
        hero.edgeInsets = NSEdgeInsets(top: 60, left: 0, bottom: 0, right: 0)
        add(hero)
    }
}
