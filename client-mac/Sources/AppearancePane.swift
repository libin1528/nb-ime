import Cocoa

final class AppearancePane: Pane {
    private let surface = CapsuleSurface()
    private let descriptionLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private var previewTimer: Timer?
    private var phase: Float = 0

    override func build() {
        add(UI.sectionTitle("输入时的皮肤"), after: 8)
        let skins = CapsuleSkin.allCases
        let selected = skins.firstIndex(of: Settings.current.capsuleSkin) ?? 0
        add(UI.segmented(skins.map(\.title), selected: selected) { [weak self] index in
            Settings.current.capsuleSkin = skins[index]
            self?.refresh()
        }, full: false, after: 10)
        add(descriptionLabel, after: 24)

        let stage = NSView()
        stage.heightAnchor.constraint(equalToConstant: 190).isActive = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            surface.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
        ])
        add(GroupView([stage]), after: 12)
        add(UI.footnote("预览的是输入时的实际样式。皮肤会自动保存，也适用于识别中和输入结果提示。"))
        surface.content.setPreview("让想法自然流淌，\n把声音变成文字。")
        surface.content.freeze()
        refresh()
    }

    private var sizeConstraints: [NSLayoutConstraint] = []

    private func refresh() {
        let skin = Settings.current.capsuleSkin
        surface.skin = skin
        descriptionLabel.stringValue = skin.detail
        NSLayoutConstraint.deactivate(sizeConstraints)
        let size = surface.content.desiredSize()
        sizeConstraints = [surface.widthAnchor.constraint(equalToConstant: size.width),
                           surface.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(sizeConstraints)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        previewTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.13
            self.surface.content.target = 0.15 + (sin(self.phase) + 1) * 0.18
            self.surface.content.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        previewTimer?.invalidate()
        previewTimer = nil
    }

    deinit { previewTimer?.invalidate() }
}
