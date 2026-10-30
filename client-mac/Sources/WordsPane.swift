// 热词页（design/hotwords/mockup.html）：「列表」四列排常用词、两列排「错的=对的」并像代码一样上色；
// 「文本」还是一行一个，加了行号和颜色。两边改的都是同一份 hotwords.txt，改完就存。

import Cocoa

// MARK: - 上色

/// 一行热词拆成几段、每段什么颜色，列表和文本共用
enum HotwordStyle {
    enum Role { case plain, comment, wrong, short, sep, op, right }

    static let wrong = UI.dynamic(light: NSColor(hex: 0xc2410c), dark: NSColor(hex: 0xff9a62))
    static let right = UI.dynamic(light: NSColor(hex: 0x15803d), dark: NSColor(hex: 0x5ad17f))
    static let warn = UI.dynamic(light: NSColor(hex: 0xb45309), dark: NSColor(hex: 0xf5b54a))
    static let wavy = NSColor(hex: 0xe0a33a)

    /// 每一段在这一行里的位置和角色，连起来正好是整行。左边不到两个字（或和右边一样）的错法是 short，这条规则不生效
    static func tokens(_ line: String) -> [(Range<String.Index>, Role)] {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return [(line.startIndex..<line.endIndex, .comment)] }
        guard let r = ReplaceRule.seps.compactMap({ line.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return [(line.startIndex..<line.endIndex, .plain)]
        }
        let to = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        var out: [(Range<String.Index>, Role)] = []
        var start = line.startIndex
        func part(_ end: String.Index) {
            guard start < end else { return }
            let s = line[start..<end].trimmingCharacters(in: .whitespaces)
            out.append((start..<end, s.isEmpty ? .plain : s.count >= 2 && s != to ? .wrong : .short))
        }
        var i = line.startIndex
        while i < r.lowerBound {
            let n = line.index(after: i)
            if "、/／,，".contains(line[i]) { part(i); out.append((i..<n, .sep)); start = n }
            i = n
        }
        part(r.lowerBound)
        out.append((r, .op))
        if r.upperBound < line.endIndex { out.append((r.upperBound..<line.endIndex, .right)) }
        return out
    }

    static func attrs(_ role: Role, size: CGFloat) -> [NSAttributedString.Key: Any] {
        switch role {
        case .plain: return [.foregroundColor: NSColor.labelColor]
        case .comment, .sep, .op: return [.foregroundColor: NSColor.tertiaryLabelColor]
        case .wrong: return [.foregroundColor: wrong]
        case .short: return [.foregroundColor: wrong, .underlineColor: wavy,
                             .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue]
        case .right: return [.foregroundColor: right, .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)]
        }
    }

    /// 列表里显示的样子：去掉多余空格，等号显示成 →
    static func ruleLabel(_ line: String, size: CGFloat) -> NSMutableAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let out = NSMutableAttributedString()
        for (r, role) in tokens(line) {
            let s = role == .op ? " → " : line[r].trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            out.append(NSAttributedString(string: s, attributes: [.font: font].merging(attrs(role, size: size)) { $1 }))
        }
        return out
    }

    /// 没生效的规则为什么没生效；生效的返回 nil
    static func problem(_ line: String) -> String? {
        guard ReplaceRule.isRule(line), ReplaceRule.parse(line) == nil else { return nil }
        let to = tokens(line).first { $0.1 == .right }.map { line[$0.0].trimmingCharacters(in: .whitespaces) } ?? ""
        return to.isEmpty ? "右边空着，这条没生效" : "左边要至少两个字，这条没生效"
    }

    /// 常用词、规则右边额外算进来的词（和 Settings.hotwordList 一样去重）、规则
    static func split(_ lines: [String]) -> (words: [String], derived: [String], rules: [String]) {
        let words = lines.filter { !ReplaceRule.isRule($0) }, rules = lines.filter(ReplaceRule.isRule)
        var seen = Set(words), derived: [String] = []
        for r in rules { if let to = ReplaceRule.parse(r)?.to, seen.insert(to).inserted { derived.append(to) } }
        return (words, derived, rules)
    }
}

// MARK: - 列表里的一格

/// 常用词、来自替换的词、一条规则或「＋ 添加」。自己画底色和字，悬停出 ×，点一下由列表换成输入框
private final class WordCell: NSView {
    enum Kind { case word, derived, rule, add, addRule }
    let kind: Kind
    let line: String
    var onClick: ((WordCell) -> Void)?
    var onDelete: ((WordCell) -> Void)?
    var editing = false { didSet { needsDisplay = true } }
    var flash = false { didSet { needsDisplay = true } }
    private var hover = false { didSet { needsDisplay = true } }
    private let title: NSAttributedString
    private let why: String?

    static let wordH: CGFloat = 32
    private static let hoverBG = UI.dynamic(light: NSColor(hex: 0xececef), dark: NSColor(white: 1, alpha: 0.09))
    private static let derivedBG = UI.dynamic(light: NSColor(hex: 0xf0f8f2), dark: NSColor(hex: 0x30d158, alpha: 0.10))
    private static let ruleBG = UI.dynamic(light: NSColor(hex: 0xf7f7f9), dark: NSColor(white: 1, alpha: 0.04))
    private static let ruleEdge = UI.dynamic(light: NSColor(hex: 0xe8e8ed), dark: NSColor(white: 1, alpha: 0.08))
    private static let badBG = UI.dynamic(light: NSColor(hex: 0xfff7e8), dark: NSColor(hex: 0xff9f0a, alpha: 0.12))
    private static let badEdge = UI.dynamic(light: NSColor(hex: 0xf5d9a8), dark: NSColor(hex: 0xff9f0a, alpha: 0.35))

    init(_ kind: Kind, _ line: String) {
        self.kind = kind
        self.line = line
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let sys = NSFont.systemFont(ofSize: 13.5)
        switch kind {
        case .word:
            title = NSAttributedString(string: line, attributes: [.font: sys, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            why = nil
        case .derived:
            let t = NSMutableAttributedString(string: line, attributes: [.font: sys, .foregroundColor: HotwordStyle.right, .paragraphStyle: para])
            t.append(NSAttributedString(string: "  来自替换", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: HotwordStyle.right.withAlphaComponent(0.65)]))
            title = t
            why = nil
        case .rule:
            let t = HotwordStyle.ruleLabel(line, size: 12.5)
            let wrap = NSMutableParagraphStyle()
            wrap.lineBreakMode = .byWordWrapping
            t.addAttribute(.paragraphStyle, value: wrap, range: NSRange(location: 0, length: t.length))
            title = t
            why = HotwordStyle.problem(line)
        case .add, .addRule:
            title = NSAttributedString(string: kind == .add ? "＋ 添加" : "＋ 添加替换", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor])
            why = nil
        }
        super.init(frame: .zero)
        toolTip = kind == .derived ? "替换规则右边的词，要删去改那条规则" : kind == .word ? line : nil
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var deletable: Bool { kind == .word || kind == .rule }
    private var textW: CGFloat { bounds.width - 11 - (deletable ? 28 : 11) }

    /// 规则可能折行，没生效的下面还有一句，高度跟着变
    func height(width: CGFloat) -> CGFloat {
        guard kind == .rule else { return Self.wordH }
        let h = title.boundingRect(with: NSSize(width: width - 39, height: 1000), options: .usesLineFragmentOrigin).height
        return max(Self.wordH + 2, ceil(h) + 17) + (why == nil ? 0 : 17)
    }

    override func draw(_ dirty: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if editing {
            NSColor.textBackgroundColor.setFill()
            p.fill()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6.5, yRadius: 6.5)
            ring.lineWidth = 2
            ring.stroke()
            return
        }
        switch kind {
        case .add, .addRule:
            (hover ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor.withAlphaComponent(0.5)).setStroke()
            p.setLineDash([3, 3], count: 2, phase: 0)
            p.stroke()
            let t = NSMutableAttributedString(attributedString: title)
            if hover { t.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: NSRange(location: 0, length: t.length)) }
            t.draw(at: NSPoint(x: 11, y: (bounds.height - t.size().height) / 2))
            return
        case .word: (flash ? NSColor.controlAccentColor.withAlphaComponent(0.16) : hover ? Self.hoverBG : UI.groupBG).setFill()
        case .derived: Self.derivedBG.setFill()
        case .rule: (flash ? NSColor.controlAccentColor.withAlphaComponent(0.12) : why != nil ? Self.badBG : Self.ruleBG).setFill()
        }
        p.fill()
        if kind == .rule {
            (why != nil ? Self.badEdge : hover ? NSColor.separatorColor : Self.ruleEdge).setStroke()
            p.lineWidth = 1
            p.stroke()
            title.draw(with: NSRect(x: 11, y: 8, width: textW, height: bounds.height), options: .usesLineFragmentOrigin)
            if let why {
                NSAttributedString(string: why, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: HotwordStyle.warn])
                    .draw(at: NSPoint(x: 11, y: bounds.height - 23))
            }
        } else {
            let h = title.size().height
            title.draw(with: NSRect(x: 11, y: (bounds.height - h) / 2, width: textW, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if hover && deletable {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(ovalIn: xRect).fill()
            let x = NSAttributedString(string: "×", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.windowBackgroundColor])
            let s = x.size()
            x.draw(at: NSPoint(x: xRect.midX - s.width / 2, y: xRect.midY - s.height / 2 - 0.5))
        }
    }

    private var xRect: NSRect {
        NSRect(x: bounds.width - 22, y: kind == .rule ? 9 : (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if deletable, xRect.insetBy(dx: -3, dy: -3).contains(p) { onDelete?(self) }
        else if kind != .derived { onClick?(self) }
    }
}

/// 输规则时浮在输入框下面，先给你看上色后的样子
private final class TipView: NSView {
    var text = NSAttributedString() {
        didSet {
            let s = text.size()
            setFrameSize(NSSize(width: ceil(s.width) + 20, height: ceil(s.height) + 12))
            needsDisplay = true
        }
    }
    private static let bg = UI.dynamic(light: .white, dark: NSColor(hex: 0x2c2c2e))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = NSShadow()
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        Self.bg.setFill()
        p.fill()
        UI.groupEdge.setStroke()
        p.stroke()
        text.draw(at: NSPoint(x: 10, y: 6))
    }
}

// MARK: - 列表

/// 常用词四列、规则两列，手排位置。点一格就在上面放一个输入框，回车存，Esc 不改，删空就是删掉
private final class WordsList: NSView, NSTextFieldDelegate {
    var lines: [String] = []
    var onChange: (([String]) -> Void)?
    var onDeleted: ((String, Int) -> Void)?
    /// 浮出的预览放在这上面，免得被滚动区域裁掉
    weak var overlay: NSView?
    var isEditing: Bool { field != nil }

    private var cells: [WordCell] = []
    private var field: NSTextField?
    private var editCell: WordCell?
    private let tip = TipView()

    override var isFlipped: Bool { true }

    func render(flash: String? = nil) {
        guard field == nil else { return }
        subviews.forEach { $0.removeFromSuperview() }
        cells = []
        let (words, derived, rules) = HotwordStyle.split(lines)
        var y = header("常用词", words.count + derived.count, "点一下就能改 · 读音相近的也会写成这样", at: 0)
        y = grid(words.map { WordCell(.word, $0) } + derived.map { WordCell(.derived, $0) } + [WordCell(.add, "")], cols: 4, at: y)
        y = header("一定替换", rules.count, "左边几种错法用顿号隔开，至少两个字", at: y + 18)
        y = grid(rules.map { WordCell(.rule, $0) } + [WordCell(.addRule, "")], cols: 2, at: y)
        setFrameSize(NSSize(width: frame.width, height: max(y + 4, enclosingScrollView?.contentSize.height ?? 0)))
        if let flash, let c = cells.last(where: { $0.line == flash }) {
            c.flash = true
            c.scrollToVisible(c.bounds)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { c.flash = false }
        }
    }

    private func header(_ title: String, _ n: Int, _ hint: String, at y: CGFloat) -> CGFloat {
        let t = UI.label(title, size: 12, weight: .semibold, color: .secondaryLabelColor)
        let c = UI.label("\(n)", size: 11.5, color: .tertiaryLabelColor)
        let h = UI.label(hint, size: 11.5, color: .tertiaryLabelColor)
        for l in [t, c, h] { l.sizeToFit(); addSubview(l) }
        t.setFrameOrigin(NSPoint(x: 2, y: y))
        c.setFrameOrigin(NSPoint(x: t.frame.maxX + 6, y: y + (t.frame.height - c.frame.height) / 2))
        h.setFrameOrigin(NSPoint(x: frame.width - h.frame.width - 2, y: y + (t.frame.height - h.frame.height) / 2))
        return y + t.frame.height + 8
    }

    /// 一行里的格子一样高（规则折行时按最高的那格）
    private func grid(_ items: [WordCell], cols: Int, at top: CGFloat) -> CGFloat {
        let gap: CGFloat = 6
        let w = (frame.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        var y = top
        for row in stride(from: 0, to: items.count, by: cols) {
            let rowCells = items[row..<min(row + cols, items.count)]
            let h = rowCells.map { $0.height(width: w) }.max() ?? WordCell.wordH
            for (i, c) in rowCells.enumerated() {
                c.frame = NSRect(x: CGFloat(i) * (w + gap), y: y, width: w, height: h)
                c.onClick = { [weak self] in self?.edit($0) }
                c.onDelete = { [weak self] in self?.delete($0.line) }
                addSubview(c)
                cells.append(c)
            }
            y += h + gap
        }
        return y - gap
    }

    // MARK: 改

    private func edit(_ cell: WordCell) {
        guard cell !== editCell else { return }
        if field != nil {
            // 正在改别的：先存那一格，重排后再找到这一格
            let (kind, line) = (cell.kind, cell.line)
            finish(keep: true, reopen: false)
            if let again = cells.first(where: { $0.kind == kind && $0.line == line }) { edit(again) }
            return
        }
        let inRules = cell.kind == .rule || cell.kind == .addRule
        let f = NSTextField(string: cell.line)
        f.placeholderString = inRules ? "错的、另一种错法=对的" : "一个词，或者 错的=对的"
        f.font = inRules ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 13.5)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.delegate = self
        f.sizeToFit()
        let h = f.frame.height
        f.frame = NSRect(x: cell.frame.minX + 9, y: inRules ? cell.frame.minY + 8 : cell.frame.midY - h / 2, width: cell.frame.width - 18, height: h)
        cell.editing = true
        addSubview(f)
        field = f
        editCell = cell
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        cell.scrollToVisible(cell.bounds)
        updateTip()
    }

    /// 回车、点别处、Tab 都算存；Esc 不改
    func finish(keep: Bool, reopen: Bool) {
        guard let f = field, let cell = editCell else { return }
        field = nil
        editCell = nil
        tip.removeFromSuperview()
        let v = f.stringValue.trimmingCharacters(in: .whitespaces)
        f.delegate = nil
        if window?.firstResponder === f.currentEditor() { window?.makeFirstResponder(nil) }
        f.removeFromSuperview()
        let old = cell.line
        guard keep, v != old else { return render() }
        if v.isEmpty { return old.isEmpty ? render() : delete(old) }
        if lines.contains(v) { return render(flash: v) }
        if !old.isEmpty, let i = lines.firstIndex(of: old) { lines[i] = v } else { lines.append(v) }
        onChange?(lines)
        render(flash: v)
        // 从「添加」进来、按回车存的，接着在原来那个「添加」里输下一个
        if reopen, old.isEmpty, let add = cells.first(where: { $0.kind == cell.kind }) { edit(add) }
    }

    private func delete(_ line: String) {
        if field != nil { finish(keep: true, reopen: false) }
        guard let i = lines.firstIndex(of: line) else { return }
        lines.remove(at: i)
        onChange?(lines)
        render()
        onDeleted?(line, i)
    }

    private func updateTip() {
        guard let f = field, let cell = editCell, let overlay else { return }
        let v = f.stringValue.trimmingCharacters(in: .whitespaces)
        let inRules = cell.kind == .rule || cell.kind == .addRule
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]
        let s = NSMutableAttributedString()
        if ReplaceRule.isRule(v) {
            if !inRules { s.append(NSAttributedString(string: "回车后放进「一定替换」：", attributes: small)) }
            s.append(HotwordStyle.ruleLabel(v, size: 12.5))
            if let why = HotwordStyle.problem(v) {
                s.append(NSAttributedString(string: "   " + why.replacingOccurrences(of: "，这条没生效", with: ""),
                                            attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: HotwordStyle.warn]))
            }
        } else if inRules, !v.isEmpty {
            s.append(NSAttributedString(string: "中间写 = 或 →", attributes: small))
        } else {
            tip.removeFromSuperview()
            return
        }
        tip.text = s
        let r = overlay.convert(cell.frame, from: self)
        tip.setFrameOrigin(NSPoint(x: r.minX, y: overlay.isFlipped ? r.maxY + 6 : r.minY - 6 - tip.frame.height))
        if tip.superview == nil { overlay.addSubview(tip) }
    }

    func controlTextDidChange(_ n: Notification) { updateTip() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { finish(keep: true, reopen: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finish(keep: false, reopen: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ n: Notification) { finish(keep: true, reopen: false) }
}

// MARK: - 文本视图的行号

/// 左边一列行号；没生效的规则那行显示成黄色的 !
private final class LineRuler: NSRulerView {
    var bad: Set<Int> = [] { didSet { needsDisplay = true } }
    private weak var text: NSTextView?
    private static let bg = UI.dynamic(light: NSColor(hex: 0xf4f4f6), dark: NSColor(white: 1, alpha: 0.03))

    init(_ text: NSTextView, in scroll: NSScrollView) {
        self.text = text
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = text
        ruleThickness = 36
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = text, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let area = rect.intersection(visibleRect)
        Self.bg.setFill()
        area.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: area.minY, width: 1 / (window?.backingScaleFactor ?? 2), height: area.height).fill()
        let s = tv.string as NSString
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let alert: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: HotwordStyle.warn]
        func mark(_ frag: NSRect, _ n: Int) {
            let isBad = bad.contains(n)
            let label = NSAttributedString(string: isBad ? "!" : "\(n + 1)", attributes: isBad ? alert : normal)
            let y = convert(NSPoint(x: 0, y: frag.minY + tv.textContainerOrigin.y), from: tv).y
            let sz = label.size()
            label.draw(at: NSPoint(x: ruleThickness - sz.width - 9, y: y + (frag.height - WordsPane.lineSpacing - sz.height) / 2))
        }
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let first = lm.characterIndexForGlyph(at: glyphs.location)
        let end = NSMaxRange(lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        var n = s.substring(to: min(first, s.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        var i = s.lineRange(for: NSRange(location: min(first, s.length), length: 0)).location
        while i < s.length, i <= end {
            mark(lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil), n)
            n += 1
            i = NSMaxRange(s.lineRange(for: NSRange(location: i, length: 0)))
        }
        // 最后一行是空的（以换行结尾，或者整页还没字）
        if i >= s.length, s.length == 0 || s.hasSuffix("\n") { mark(lm.extraLineFragmentRect, n) }
    }
}

// MARK: - 页面

final class WordsPane: Pane, NSTextViewDelegate {
    static let lineSpacing: CGFloat = 4
    private static let areaH: CGFloat = 372

    private let list = WordsList()
    private let listScroll = NSScrollView()
    private let text = NSTextView()
    private let textScroll = NSScrollView()
    private var ruler: LineRuler!
    private let count = UI.label("", size: 12, color: .secondaryLabelColor)
    private let saved = UI.label("改完自动保存", size: 12, color: .tertiaryLabelColor)
    private let toast = NSView()
    private let toastText = UI.label("", size: 12, color: .white)
    private var toastWork: DispatchWorkItem?
    private var savedWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var selfSaving = false
    private var lastDeleted: (line: String, at: Int)?

    override func build() {
        // 顶上一句话，右边切「列表 / 文本」
        let intro = NSMutableAttributedString(string: "识别时优先往这些词上靠。写 ", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        intro.append(NSAttributedString(string: "错的=对的", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
        intro.append(NSAttributedString(string: " 的，左边一律换成右边。", attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor]))
        let seg = UI.segmented(["列表", "文本"], selected: 0) { [weak self] in self?.showText($0 == 1) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        add(UI.hstack([NSTextField(labelWithAttributedString: intro), spacer, seg], spacing: 12), after: 14)

        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.heightAnchor.constraint(equalToConstant: Self.areaH).isActive = true
        list.frame = NSRect(x: 0, y: 0, width: SettingsWindow.inner, height: Self.areaH)
        list.overlay = view
        list.onChange = { [weak self] in self?.store($0) }
        list.onDeleted = { [weak self] in self?.deleted($0, at: $1) }
        listScroll.documentView = list
        add(listScroll, after: 10)

        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder
        textScroll.heightAnchor.constraint(equalToConstant: Self.areaH).isActive = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.defaultParagraphStyle = Self.para
        text.typingAttributes[.paragraphStyle] = Self.para
        text.minSize = NSSize(width: 0, height: Self.areaH)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        textScroll.documentView = text
        ruler = LineRuler(text, in: textScroll)
        textScroll.verticalRulerView = ruler
        textScroll.hasVerticalRuler = true
        textScroll.rulersVisible = true
        textScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: textScroll.contentView, queue: .main) { [weak self] _ in
            self?.ruler.needsDisplay = true
        }
        textScroll.isHidden = true
        add(textScroll, after: 10)

        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = UI.hstack([count, gap, saved], spacing: 8)
        add(foot)
        buildToast(above: foot)
        reload()
        NotificationCenter.default.addObserver(forName: .hotwordsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.selfSaving, self.saveWork == nil, !self.list.isEditing else { return }   // 自己存的不用回填，免得光标跳
            self.reload()
        }
    }

    private static let para: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        return p
    }()

    private func reload() {
        let lines = Settings.hotwordLines()
        list.lines = lines
        list.render()
        if !textScroll.isHidden {
            text.string = lines.joined(separator: "\n")
            paint()
        }
        count.attributedStringValue = Self.summary(lines)
    }

    private func showText(_ on: Bool) {
        if on {
            list.finish(keep: true, reopen: false)
            text.string = Settings.hotwordLines().joined(separator: "\n")
            paint()
            listScroll.isHidden = true
            textScroll.isHidden = false
            view.window?.makeFirstResponder(text)
        } else {
            flushText()
            list.lines = Settings.hotwordLines()
            list.render()
            textScroll.isHidden = true
            listScroll.isHidden = false
            view.window?.makeFirstResponder(nil)
        }
    }

    // MARK: 存

    private func store(_ lines: [String]) {
        selfSaving = true
        if lines != Settings.hotwordLines() { Settings.saveHotwords(lines) }
        selfSaving = false
        count.attributedStringValue = Self.summary(lines)
        saved.stringValue = "已保存"
        saved.textColor = HotwordStyle.right
        savedWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.saved.stringValue = "改完自动保存"
            self?.saved.textColor = .tertiaryLabelColor
        }
        savedWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    /// 「14 个词 · 3 条替换 · 1 条没生效 · 只存在这台 Mac 上」，没生效的标黄
    private static func summary(_ lines: [String]) -> NSAttributedString {
        let (words, derived, rules) = HotwordStyle.split(lines)
        let bad = rules.filter { ReplaceRule.parse($0) == nil }.count
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let s = NSMutableAttributedString(string: "\(words.count + derived.count) 个词", attributes: base)
        if !rules.isEmpty { s.append(NSAttributedString(string: " · \(rules.count - bad) 条替换", attributes: base)) }
        if bad > 0 {
            s.append(NSAttributedString(string: " · ", attributes: base))
            s.append(NSAttributedString(string: "\(bad) 条没生效", attributes: base.merging([.foregroundColor: HotwordStyle.warn]) { $1 }))
        }
        s.append(NSAttributedString(string: " · 只存在这台 Mac 上", attributes: base))
        return s
    }

    // MARK: 删掉后能撤销

    private func buildToast(above foot: NSView) {
        toast.wantsLayer = true
        toast.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        toast.layer?.cornerRadius = 8
        let undo = NSButton(title: "撤销", target: nil, action: nil)
        undo.isBordered = false
        undo.attributedTitle = NSAttributedString(string: "撤销", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(hex: 0x6cb4ff)])
        undo.onAction { [weak self] _ in self?.undoDelete() }
        let h = UI.hstack([toastText, undo], spacing: 12)
        h.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 10)
        h.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(h)
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.isHidden = true
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: toast.leadingAnchor), h.trailingAnchor.constraint(equalTo: toast.trailingAnchor),
            h.topAnchor.constraint(equalTo: toast.topAnchor), h.bottomAnchor.constraint(equalTo: toast.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -16),
        ])
    }

    private func deleted(_ line: String, at i: Int) {
        lastDeleted = (line, i)
        let shown = ReplaceRule.parse(line).map { $0.from.joined(separator: "、") + " → " + $0.to } ?? line
        toastText.stringValue = "删掉了「\(shown)」"
        toast.isHidden = false
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast.isHidden = true }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private func undoDelete() {
        toast.isHidden = true
        guard let d = lastDeleted else { return }
        lastDeleted = nil
        var lines = Settings.hotwordLines()
        guard !lines.contains(d.line) else { return }
        lines.insert(d.line, at: min(d.at, lines.count))
        store(lines)
        list.lines = lines
        list.render(flash: d.line)
    }

    // MARK: 文本

    /// 按行上色；输入法还在拼字时不动，免得打断
    private func paint() {
        guard !text.hasMarkedText(), let ts = text.textStorage else { return }
        let s = text.string as NSString
        var bad = Set<Int>(), n = 0
        ts.beginEditing()
        ts.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: Self.para],
                         range: NSRange(location: 0, length: ts.length))
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: .byLines) { sub, range, _, _ in
            guard let sub else { return }
            for (r, role) in HotwordStyle.tokens(sub) where role != .plain {
                let nr = NSRange(r, in: sub)
                ts.addAttributes(HotwordStyle.attrs(role, size: 13), range: NSRange(location: range.location + nr.location, length: nr.length))
            }
            if HotwordStyle.problem(sub.trimmingCharacters(in: .whitespaces)) != nil, !sub.hasPrefix("#") { bad.insert(n) }
            n += 1
        }
        ts.endEditing()
        ruler.bad = bad
    }

    private func parsed() -> [String] {
        var seen = Set<String>()
        return text.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0).inserted }
    }

    func textDidChange(_ n: Notification) {
        paint()
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flushText() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func flushText() {
        guard let w = saveWork else { return }
        w.cancel()
        saveWork = nil
        store(parsed())
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        list.finish(keep: true, reopen: false)
        flushText()
    }
}
