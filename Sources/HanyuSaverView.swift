import AppKit
import ScreenSaver

// MARK: - Данные

struct Word: Decodable {
    let w: String          // иероглифы (упрощённые)
    let p: String          // пиньинь
    let m: [String]        // значения из БКРС
    let e: [[String]]?     // примеры [кит, пиньинь, рус]
}

struct WordBase: Decodable {
    let source: String
    let systems: [String: [String: [Word]]]
}

enum HSKSystem: String, CaseIterable {
    case hsk2, hsk3

    var title: String { self == .hsk2 ? "HSK 2.0 (1–6)" : "HSK 3.0 (1–9)" }
    var levels: [String] { self == .hsk2 ? ["1", "2", "3", "4", "5", "6"] : ["1", "2", "3", "4", "5", "6", "7"] }

    func levelTitle(_ level: String) -> String {
        self == .hsk3 && level == "7" ? "HSK 7–9" : "HSK \(level)"
    }
}

let levelColors: [String: NSColor] = [
    "1": NSColor(srgbRed: 0.36, green: 0.79, blue: 0.65, alpha: 1),
    "2": NSColor(srgbRed: 0.59, green: 0.77, blue: 0.35, alpha: 1),
    "3": NSColor(srgbRed: 0.52, green: 0.72, blue: 0.92, alpha: 1),
    "4": NSColor(srgbRed: 0.94, green: 0.62, blue: 0.15, alpha: 1),
    "5": NSColor(srgbRed: 0.94, green: 0.60, blue: 0.48, alpha: 1),
    "6": NSColor(srgbRed: 0.89, green: 0.29, blue: 0.29, alpha: 1),
    "7": NSColor(srgbRed: 0.69, green: 0.66, blue: 0.93, alpha: 1),
]

/// Детерминированный генератор: одно зерно даёт одну колоду во всех процессах legacyScreenSaver.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        // FNV-1a: Hasher в Swift засеивается случайно в каждом процессе
        state = seed.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

// MARK: - Настройки

final class Settings {
    static let moduleName = "local.hanyu.screensaver"
    let defaults: UserDefaults

    init() {
        defaults = ScreenSaverDefaults(forModuleWithName: Settings.moduleName) ?? .standard
        defaults.register(defaults: [
            "system": HSKSystem.hsk2.rawValue,
            "levels": ["1", "2", "3"],
            "duration": 8.0,
            "meanings": 3,
            "examples": true,
            "perDisplay": false,
        ])
    }

    var system: HSKSystem {
        get { HSKSystem(rawValue: defaults.string(forKey: "system") ?? "") ?? .hsk2 }
        set { defaults.set(newValue.rawValue, forKey: "system") }
    }
    var levels: Set<String> {
        get { Set(defaults.stringArray(forKey: "levels") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "levels") }
    }
    var duration: Double {
        get { defaults.double(forKey: "duration") }
        set { defaults.set(newValue, forKey: "duration") }
    }
    var meanings: Int {
        get { defaults.integer(forKey: "meanings") }
        set { defaults.set(newValue, forKey: "meanings") }
    }
    var examples: Bool {
        get { defaults.bool(forKey: "examples") }
        set { defaults.set(newValue, forKey: "examples") }
    }
    /// false — одно слово на всех дисплеях со сменой по часам, true — своя колода у каждого
    var perDisplay: Bool {
        get { defaults.bool(forKey: "perDisplay") }
        set { defaults.set(newValue, forKey: "perDisplay") }
    }

    func save() { defaults.synchronize() }
}

// MARK: - Вид

@objc(HanyuSaverView)
final class HanyuSaverView: ScreenSaverView {
    private static var cachedBase: WordBase?

    private let settings = Settings()
    private var deck: [(level: String, word: Word)] = []
    private var current: (level: String, word: Word)?
    private var shownAt = Date.distantPast
    private var offset = CGPoint.zero
    private let startedAt = Date()
    // общий режим: все слова выбранных уровней в фиксированном порядке и перестановка текущего круга
    private var pool: [(level: String, word: Word)] = []
    private var poolKey = ""
    private var order: [Int] = []
    private var orderCycle = -1
    private var slot = -1
    // статическое: legacyScreenSaver может пересоздать вид, пока лист открыт
    private static var sheetController: ConfigSheetController?

    private let fade: TimeInterval = 1.2
    private let background = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.071, alpha: 1)

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        reloadDeck()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        reloadDeck()
    }

    private func loadBase() -> WordBase? {
        if let base = Self.cachedBase { return base }
        guard let url = Bundle(for: HanyuSaverView.self).url(forResource: "words", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let base = try? JSONDecoder().decode(WordBase.self, from: data) else { return nil }
        Self.cachedBase = base
        return base
    }

    func reloadDeck() {
        deck = []
        current = nil
        shownAt = .distantPast
        poolKey = ""
        orderCycle = -1
        slot = -1
    }

    /// Слова выбранных уровней. Уровни сортируются: порядок обхода Set разный в разных процессах.
    private func selectedWords() -> (key: String, words: [(level: String, word: Word)]) {
        let system = settings.system
        var levels = settings.levels.intersection(system.levels)
        if levels.isEmpty { levels = ["1"] }
        let sorted = levels.sorted()
        let byLevel = loadBase()?.systems[system.rawValue] ?? [:]
        let words = sorted.flatMap { lvl in (byLevel[lvl] ?? []).map { (lvl, $0) } }
        return ("\(system.rawValue):\(sorted.joined(separator: ","))", words)
    }

    // Свой режим: случайная колода без повторов, смена по своему таймеру
    private func nextWord() {
        if deck.isEmpty { deck = selectedWords().words.shuffled() }
        current = deck.popLast()
        shownAt = Date()
        // небольшой сдвиг карточки, чтобы текст не «выжигался» в одном месте
        offset = CGPoint(x: .random(in: -0.04...0.04), y: .random(in: -0.04...0.04))
    }

    // Общий режим: номер слайда считается от часов, колода тасуется по зерну,
    // поэтому все дисплеи без связи между собой показывают одно слово и меняют его одновременно
    private func show(slot: Int, period: TimeInterval) {
        let selected = selectedWords()
        if selected.key != poolKey {
            pool = selected.words
            poolKey = selected.key
            orderCycle = -1
        }
        self.slot = slot
        guard !pool.isEmpty else { current = nil; return }
        let cycle = slot / pool.count
        if cycle != orderCycle {
            var rng = SplitMix64(seed: "\(poolKey)#\(cycle)")
            order = Array(pool.indices).shuffled(using: &rng)
            orderCycle = cycle
        }
        current = pool[order[slot % pool.count]]
        shownAt = Date(timeIntervalSince1970: Double(slot) * period)
        var rng = SplitMix64(seed: "\(poolKey)@\(slot)")
        offset = CGPoint(x: .random(in: -0.04...0.04, using: &rng), y: .random(in: -0.04...0.04, using: &rng))
    }

    override func animateOneFrame() {
        let total = settings.duration + 2 * fade
        if settings.perDisplay {
            if current == nil || Date().timeIntervalSince(shownAt) >= total { nextWord() }
        } else {
            let now = Int((Date().timeIntervalSince1970 / total).rounded(.down))
            if now != slot || current == nil { show(slot: now, period: total) }
        }
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        background.setFill()
        bounds.fill()
        guard let (level, word) = current, let ctx = NSGraphicsContext.current?.cgContext else {
            if current == nil, loadBase() == nil { drawCentered("words.json не найден", size: bounds.height * 0.03, color: .gray) }
            return
        }

        let elapsed = Date().timeIntervalSince(shownAt)
        let total = settings.duration + 2 * fade
        // в общем режиме запуск может попасть на середину слайда — тогда карточка проявляется с момента старта
        let sinceStart = Date().timeIntervalSince(startedAt)
        let alpha = CGFloat(min(elapsed / fade, (total - elapsed) / fade, sinceStart / fade).clamped(0, 1))
        let color = levelColors[level] ?? .white
        let h = bounds.height

        ctx.saveGState()
        ctx.setAlpha(alpha)

        // Бейдж уровня и источник
        let badgeFont = NSFont.systemFont(ofSize: max(10, h * 0.018), weight: .medium)
        let badge = NSAttributedString(string: settings.system.levelTitle(level), attributes: [.font: badgeFont, .foregroundColor: color])
        let bs = badge.size()
        let pad = CGSize(width: h * 0.014, height: h * 0.006)
        let badgeRect = NSRect(x: h * 0.03, y: h - h * 0.03 - bs.height - 2 * pad.height,
                               width: bs.width + 2 * pad.width, height: bs.height + 2 * pad.height)
        let path = NSBezierPath(roundedRect: badgeRect, xRadius: badgeRect.height / 2, yRadius: badgeRect.height / 2)
        path.lineWidth = max(1, h * 0.0015)
        color.setStroke()
        path.stroke()
        badge.draw(at: NSPoint(x: badgeRect.minX + pad.width, y: badgeRect.minY + pad.height))

        let src = NSAttributedString(string: "大БКРС · \(settings.system == .hsk2 ? "HSK 2.0" : "HSK 3.0")", attributes: [
            .font: NSFont.systemFont(ofSize: max(9, h * 0.014)),
            .foregroundColor: NSColor(white: 0.35, alpha: 1),
        ])
        src.draw(at: NSPoint(x: bounds.width - h * 0.03 - src.size().width, y: badgeRect.midY - src.size().height / 2))

        // Карточка слова: собираем строки сверху вниз, затем центрируем по высоте
        let maxWidth = min(bounds.width * 0.8, h * 1.3)
        var lines: [(NSAttributedString, CGFloat)] = [] // строка и отступ после неё

        lines.append((text(word.p, font: .systemFont(ofSize: h * 0.04, weight: .light), color: color, kern: h * 0.002), h * 0.004))

        let hanziFont = NSFont(name: "Songti SC", size: h * 0.2) ?? .systemFont(ofSize: h * 0.2)
        var hanzi = text(word.w, font: hanziFont, color: NSColor(srgbRed: 0.95, green: 0.94, blue: 0.9, alpha: 1))
        if hanzi.size().width > maxWidth {
            let scaled = hanziFont.withSize(hanziFont.pointSize * maxWidth / hanzi.size().width)
            hanzi = text(word.w, font: scaled, color: NSColor(srgbRed: 0.95, green: 0.94, blue: 0.9, alpha: 1))
        }
        lines.append((hanzi, h * 0.006))

        lines.append((NSAttributedString(), h * 0.025))

        let meaningFont = NSFont.systemFont(ofSize: h * 0.03)
        let numColor = NSColor(white: 0.42, alpha: 1)
        let meanings = Array(word.m.prefix(max(1, settings.meanings)))
        for (i, m) in meanings.enumerated() {
            let s = NSMutableAttributedString()
            if meanings.count > 1 {
                s.append(text("\(i + 1).  ", font: meaningFont, color: numColor))
            }
            s.append(text(m, font: meaningFont, color: NSColor(srgbRed: 0.85, green: 0.84, blue: 0.81, alpha: 1)))
            lines.append((s, h * 0.008))
        }

        if settings.examples, let ex = word.e?.first, ex.count == 3 {
            lines.append((NSAttributedString(), h * 0.025))
            lines.append((text(ex[0], font: NSFont(name: "PingFang SC", size: h * 0.032) ?? .systemFont(ofSize: h * 0.032),
                               color: NSColor(white: 0.78, alpha: 1)), h * 0.002))
            lines.append((text(ex[1], font: .systemFont(ofSize: h * 0.022, weight: .light), color: color.withAlphaComponent(0.75)), h * 0.004))
            lines.append((text(ex[2], font: .systemFont(ofSize: h * 0.024), color: NSColor(white: 0.52, alpha: 1)), 0))
        }

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let measured = lines.map { line -> (NSAttributedString, CGFloat, CGFloat) in
            let s = NSMutableAttributedString(attributedString: line.0)
            s.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: s.length))
            let height = s.length == 0 ? 0 : s.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            return (s, ceil(height), line.1)
        }
        let totalHeight = measured.reduce(0) { $0 + $1.1 + $1.2 }
        var y = (h + totalHeight) / 2 + offset.y * h
        let x = (bounds.width - maxWidth) / 2 + offset.x * bounds.width
        for (s, height, gap) in measured {
            y -= height
            if s.length > 0 {
                s.draw(with: NSRect(x: x, y: y, width: maxWidth, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            y -= gap
        }

        // Полоса прогресса снизу
        let progress = CGFloat((elapsed / total).clamped(0, 1))
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: max(2, h * 0.003)).fill()
        color.withAlphaComponent(0.7).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * progress, height: max(2, h * 0.003)).fill()

        ctx.restoreGState()
    }

    private func text(_ s: String, font: NSFont, color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    }

    private func drawCentered(_ s: String, size: CGFloat, color: NSColor) {
        let a = text(s, font: .systemFont(ofSize: size), color: color)
        let sz = a.size()
        a.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }

    // MARK: Настройки (кнопка «Параметры…»)

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let controller = ConfigSheetController(settings: settings) { [weak self] in self?.reloadDeck() }
        Self.sheetController = controller
        return controller.window
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

// MARK: - Окно настроек

/// В legacyScreenSaver лист без этого не становится key-окном и может оказаться под окном Настроек.
final class SheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ConfigSheetController: NSObject {
    let window: NSWindow
    private let settings: Settings
    private let onSave: () -> Void
    private let systemPopup = NSPopUpButton()
    private var levelBoxes: [NSButton] = []
    private let levelStack = NSStackView()
    private let durationSlider = NSSlider(value: 8, minValue: 3, maxValue: 30, target: nil, action: nil)
    private let durationLabel = NSTextField(labelWithString: "")
    private let meaningsPopup = NSPopUpButton()
    private let examplesBox = NSButton(checkboxWithTitle: "Показывать пример с пиньинем", target: nil, action: nil)
    private let perDisplayBox = NSButton(checkboxWithTitle: "Разные слова на каждом дисплее", target: nil, action: nil)

    init(settings: Settings, onSave: @escaping () -> Void) {
        self.settings = settings
        self.onSave = onSave
        window = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init()
        build()
        window.contentView?.layoutSubtreeIfNeeded()
        if let size = window.contentView?.fittingSize { window.setContentSize(size) }
    }

    private func row(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let r = NSStackView(views: [label, view])
        r.spacing = 10
        r.alignment = .firstBaseline
        return r
    }

    private func build() {
        systemPopup.addItems(withTitles: HSKSystem.allCases.map(\.title))
        systemPopup.selectItem(at: HSKSystem.allCases.firstIndex(of: settings.system) ?? 0)
        systemPopup.target = self
        systemPopup.action = #selector(systemChanged)

        levelStack.orientation = .horizontal
        levelStack.spacing = 8
        rebuildLevelBoxes(selected: settings.levels)

        durationSlider.doubleValue = settings.duration
        durationSlider.target = self
        durationSlider.action = #selector(durationChanged)
        durationSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        durationChanged()

        meaningsPopup.addItems(withTitles: ["1", "2", "3", "4"])
        meaningsPopup.selectItem(at: (settings.meanings - 1).clamped(0, 3))

        examplesBox.state = settings.examples ? .on : .off
        perDisplayBox.state = settings.perDisplay ? .on : .off

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Готово", target: self, action: #selector(save))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, ok])

        let note = NSTextField(wrappingLabelWithString: "Переводы и примеры: 大БКРС (bkrs.info). Списки HSK: clem109/hsk-vocabulary (2.0), ivankra/hsk30 (3.0).")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            row("Система HSK:", systemPopup),
            row("Уровни:", levelStack),
            row("Время на слово:", NSStackView(views: [durationSlider, durationLabel])),
            row("Значений:", meaningsPopup),
            row("", examplesBox),
            row("", perDisplayBox),
            note,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        window.contentView = content
    }

    private var selectedSystem: HSKSystem { HSKSystem.allCases[max(0, systemPopup.indexOfSelectedItem)] }

    private func rebuildLevelBoxes(selected: Set<String>) {
        levelBoxes.forEach { $0.removeFromSuperview() }
        let system = selectedSystem
        levelBoxes = system.levels.map { lvl in
            let b = NSButton(checkboxWithTitle: system == .hsk3 && lvl == "7" ? "7–9" : lvl, target: nil, action: nil)
            b.identifier = NSUserInterfaceItemIdentifier(lvl)
            b.state = selected.contains(lvl) ? .on : .off
            return b
        }
        levelBoxes.forEach { levelStack.addArrangedSubview($0) }
    }

    @objc private func systemChanged() {
        rebuildLevelBoxes(selected: Set(levelBoxes.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }))
    }

    @objc private func durationChanged() {
        durationLabel.stringValue = "\(Int(durationSlider.doubleValue.rounded())) с"
    }

    @objc private func save() {
        settings.system = selectedSystem
        let levels = Set(levelBoxes.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue })
        settings.levels = levels.isEmpty ? ["1"] : levels
        settings.duration = durationSlider.doubleValue.rounded()
        settings.meanings = meaningsPopup.indexOfSelectedItem + 1
        settings.examples = examplesBox.state == .on
        settings.perDisplay = perDisplayBox.state == .on
        settings.save()
        onSave()
        close()
    }

    @objc private func cancel() { close() }

    private func close() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            NSApp.endSheet(window)
        }
        window.orderOut(nil)
    }
}
