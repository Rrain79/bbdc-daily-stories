import AppKit
import ApplicationServices
import Foundation

struct CollectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

enum Tab: String {
    case learned = "学习"
    case reviewed = "复习"

    var other: Tab { self == .learned ? .reviewed : .learned }
}

let navigationHelp = "请打开不背单词「我的内容 → 近日已学 → 今天」后重试。"
let countPattern = #"^[0-9]+\s*词$"#
let wordPattern = #"^[A-Za-z][A-Za-z0-9 .'’()/–-]*$"#
let emptyMessages: Set<String> = ["暂无单词", "还没有单词", "还没有学习新词", "还没有复习单词", "还没有学习的单词", "还没有复习的单词", "还没有学习过的单词", "还没有复习过的单词"]

func readCount(_ labels: [String]) throws -> Int {
    let counts = Set(labels.compactMap { label -> Int? in
        guard label.range(of: countPattern, options: .regularExpression) != nil else { return nil }
        return Int(label.prefix(while: { $0.isASCII && $0.isNumber }))
    })
    if counts.count == 1, let count = counts.first { return count }
    if counts.isEmpty, labels.contains(where: emptyMessages.contains) { return 0 }
    throw CollectionError("无法确认页面显示的词数。\(navigationHelp)")
}

struct WordList {
    private(set) var words: [String] = []
    private var seen: Set<String> = []

    mutating func append(_ labels: [String]) {
        for label in labels where label.range(of: wordPattern, options: .regularExpression) != nil {
            let key = label.precomposedStringWithCompatibilityMapping.lowercased()
            if seen.insert(key).inserted { words.append(label) }
        }
    }

    func checked(tab: Tab, expected: Int, observed: Int) throws -> [String] {
        guard expected == observed, words.count == expected else {
            throw CollectionError("「\(tab.rawValue)」最初显示 \(expected) 词，实际读到 \(words.count) 词，最后显示 \(observed) 词。请保持页面不动后重试。")
        }
        return words
    }
}

struct DailyWords: Encodable {
    struct Lists: Encodable {
        let learned: [String]
        let reviewed: [String]
    }

    let date: String
    let counts: [String: Int]
    let lists: Lists

    init(date: String, learned: [String], reviewed: [String]) {
        self.date = date
        counts = ["learned": learned.count, "reviewed": reviewed.count]
        lists = Lists(learned: learned, reviewed: reviewed)
    }
}

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

struct Element {
    let target: AXUIElement
    let parents: [AXUIElement]
    let role: String
    let labels: [String]

    init(_ target: AXUIElement, parents: [AXUIElement] = []) {
        self.target = target
        self.parents = parents
        role = attribute(target, kAXRoleAttribute) as? String ?? ""
        labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute].compactMap {
            (attribute(target, $0) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    func matches(_ text: String) -> Bool {
        labels.contains { label in
            if label == text { return true }
            if text == "近日已学", label.hasPrefix("近日已学, ") || label.hasPrefix("近日已学，") { return true }
            guard label.hasPrefix(text) else { return false }
            let state = label.dropFirst(text.count).trimmingCharacters(in: CharacterSet(charactersIn: " ,，"))
            return ["选中", "已选中", "已选择", "selected"].contains(state.lowercased())
        }
    }

    var selected: Bool? {
        if labels.contains(where: { $0.hasSuffix("选中") || $0.hasSuffix("已选择") || $0.lowercased().hasSuffix(", selected") }) { return true }
        if let selection = attribute(target, kAXSelectedAttribute) as? Bool { return selection }
        if [kAXRadioButtonRole, "AXTab"].contains(role), let selection = attribute(target, kAXValueAttribute) as? Bool { return selection }
        for parent in parents.reversed() {
            let selectedChildren = attribute(parent, kAXSelectedChildrenAttribute) as? [AXUIElement] ?? []
            if selectedChildren.contains(where: { CFEqual($0, target) }) { return true }
        }
        return nil
    }

    var actions: [String] {
        var actions: CFArray?
        AXUIElementCopyActionNames(target, &actions)
        return actions as? [String] ?? []
    }

    var frame: CGRect? {
        guard let position = attribute(target, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let extent = attribute(target, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(extent as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func belongs(to container: Element) -> Bool {
        parents.contains { CFEqual($0, container.target) }
    }
}

let scrollUp = "AXScrollUpByPage"
let scrollDown = "AXScrollDownByPage"

struct Page {
    let window: Element
    let elements: [Element]

    func control(_ title: String) -> Element? {
        let candidates = elements.filter { $0.matches(title) }
        let controls = candidates.filter { [kAXButtonRole, kAXRadioButtonRole, "AXTab"].contains($0.role) || $0.actions.contains(kAXPressAction) }
        if controls.count == 1 { return controls.first }
        if controls.isEmpty, candidates.count == 1 { return candidates.first }
        return nil
    }

    var isHistory: Bool { control("学习") != nil && control("复习") != nil && control("已标熟") != nil }
    var isToday: Bool { isHistory && control("今天")?.role == kAXButtonRole && todayOption == nil }

    var todayOption: Element? {
        let matches = elements.filter { element in
            element.role == kAXStaticTextRole && element.labels.contains { label in
                label.range(of: #"^今天[,，]\s*[0-9]+\s*词$"#, options: .regularExpression) != nil
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    var count: Int { get throws { try readCount(elements.flatMap(\.labels)) } }

    func scrollArea(_ action: String) -> Element? {
        let candidates = elements.filter { $0.actions.contains(action) }
        let list = candidates.first { candidate in
            elements.contains { $0.belongs(to: candidate) && Self.word($0) != nil }
        }
        return list ?? (candidates.count == 1 ? candidates.first : nil)
    }

    var visibleWords: [String] {
        let list = scrollArea(scrollDown) ?? scrollArea(scrollUp)
        let header = elements.first { item in item.labels.contains { $0.range(of: countPattern, options: .regularExpression) != nil } }
        let footer = ["沉浸刷词", "随身听", "听写", "随手拼", "导出"].compactMap { control($0)?.frame?.minY }.min()
        let lowerBound = max(header?.frame?.maxY ?? -.infinity, list?.frame?.minY ?? -.infinity)
        let upperBound = min(footer ?? .infinity, list?.frame?.maxY ?? .infinity)
        return elements.compactMap { item in
            guard let word = Self.word(item) else { return nil }
            if let list, !item.belongs(to: list) { return nil }
            if let frame = item.frame, frame.midY <= lowerBound || frame.midY >= upperBound { return nil }
            return word
        }
    }

    private static func word(_ item: Element) -> String? {
        guard item.role == kAXStaticTextRole else { return nil }
        return item.labels.first { $0.range(of: wordPattern, options: .regularExpression) != nil }
    }
}

struct Collector {
    static let bundleID = "cn.com.langeasy.LangEasyLexis"
    let app: NSRunningApplication
    let root: AXUIElement

    init() throws {
        guard AXIsProcessTrusted() else {
            throw CollectionError("当前进程没有辅助功能权限。请在「系统设置 → 隐私与安全性 → 辅助功能」授权运行脚本的 Codex 或终端应用后重试。")
        }
        let running = { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first }
        if running() == nil {
            let workspace = NSWorkspace.shared
            let defaultURL = URL(fileURLWithPath: "/Applications/不背单词.app")
            let appURL = workspace.urlForApplication(withBundleIdentifier: Self.bundleID)
                ?? (FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil)
            guard let appURL else { throw CollectionError("这台 Mac 上找不到不背单词。") }
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            let deadline = Date(timeIntervalSinceNow: 12)
            while running() == nil, Date() < deadline { Settle.wait(0.2) }
        }
        guard let app = running() else { throw CollectionError("启动不背单词超时。请先手动打开 App。") }
        self.app = app
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        _ = app.unhide()
        _ = app.activate(options: [.activateAllWindows])
        Settle.wait()
    }

    func snapshot() throws -> Page {
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { attribute($0, kAXRoleAttribute) as? String == kAXWindowRole }) else {
            throw CollectionError("未找到不背单词窗口。\(navigationHelp)")
        }
        var elements: [Element] = []
        func visit(_ target: AXUIElement, parents: [AXUIElement]) {
            guard parents.count < 32, elements.count < 3500, !parents.contains(where: { CFEqual($0, target) }) else { return }
            elements.append(Element(target, parents: parents))
            for child in attribute(target, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, parents: parents + [target])
            }
        }
        visit(window, parents: [])
        return Page(window: Element(window), elements: elements)
    }

    func awaitPage(_ stage: String, _ accepts: (Page) -> Bool) throws -> Page {
        let deadline = Date(timeIntervalSinceNow: 5)
        var foundWindow = false
        repeat {
            if let page = try? snapshot() {
                foundWindow = true
                if accepts(page) { return page }
            }
            Settle.wait(0.25)
        } while Date() < deadline
        let detail = foundWindow ? "无法确认\(stage)" : "无法读取不背单词窗口"
        throw CollectionError("\(detail)。\(navigationHelp)")
    }

    private func press(_ element: Element, on page: Page) throws {
        if element.actions.contains(kAXPressAction), AXUIElementPerformAction(element.target, kAXPressAction as CFString) == .success {
            Settle.wait()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let frame = element.frame, let window = page.window.frame, window.contains(frame) else {
            throw CollectionError("页面按钮位置不可用。\(navigationHelp)")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit, isHit(hit, intended: element.target),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw CollectionError("页面按钮被遮挡或位置已改变。\(navigationHelp)")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Settle.wait()
    }

    private func isHit(_ hit: AXUIElement, intended: AXUIElement) -> Bool {
        var node = hit
        for _ in 0..<12 {
            if CFEqual(node, intended) { return true }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
        }
        return false
    }

    func openToday() throws -> Page {
        var page = try awaitPage("不背单词已打开") { !$0.elements.isEmpty }
        if page.isToday { return page }
        if let today = page.todayOption {
            try press(today, on: page)
            return try awaitPage("已进入今天的词表", \.isToday)
        }
        if !page.isHistory, page.control("近日已学") == nil {
            guard let contents = page.control("我的内容") ?? homeContents(in: page) else { throw CollectionError(navigationHelp) }
            try press(contents, on: page)
            page = try awaitPage("已进入我的内容") { $0.control("近日已学") != nil }
        }
        if !page.isHistory, let recentlyLearned = page.control("近日已学") {
            try press(recentlyLearned, on: page)
            page = try awaitPage("已进入近日已学", \.isHistory)
        }
        if page.isToday { return page }
        let datePattern = #"^(昨天|前天|[0-9]{1,2}月[0-9]{1,2}日|[0-9]{1,2}[-/][0-9]{1,2})$"#
        guard page.isHistory, let window = page.window.frame else { throw CollectionError(navigationHelp) }
        let dateButtons = page.elements.filter { element in
            element.role == kAXButtonRole && (element.frame?.midY ?? .infinity) < window.minY + 160
                && element.labels.contains { $0.range(of: datePattern, options: .regularExpression) != nil }
        }
        guard dateButtons.count == 1, let dateButton = dateButtons.first else { throw CollectionError(navigationHelp) }
        try press(dateButton, on: page)
        page = try awaitPage("日期菜单中有今天") { $0.todayOption != nil }
        guard let today = page.todayOption else { throw CollectionError(navigationHelp) }
        try press(today, on: page)
        return try awaitPage("已进入今天的词表", \.isToday)
    }

    private func homeContents(in page: Page) -> Element? {
        guard page.control("Learn") != nil, page.control("Review") != nil, let window = page.window.frame else { return nil }
        let bottomButtons = page.elements.filter {
            $0.role == kAXButtonRole && $0.frame.map { $0.midY > window.maxY - 100 && window.contains($0) } == true
        }.sorted { ($0.frame?.midX ?? 0) < ($1.frame?.midX ?? 0) }
        guard bottomButtons.count == 3 else { return nil }
        return bottomButtons[1]
    }

    private func selection(_ tab: Tab, on page: Page) -> Bool? {
        if page.control(tab.rawValue)?.selected == true { return true }
        if page.control(tab.other.rawValue)?.selected == true || page.control("已标熟")?.selected == true { return false }
        return nil
    }

    private func select(_ tab: Tab, on original: Page) throws -> Page {
        guard original.isToday, let initial = original.control(tab.rawValue) else { throw CollectionError(navigationHelp) }
        if selection(tab, on: original) == true { return original }
        try press(initial, on: original)
        var result = try awaitPage("今日\(tab.rawValue)的词数") { $0.isToday && (try? $0.count) != nil }
        if selection(tab, on: result) == true { return result }
        let originalCount = try? original.count
        if selection(tab, on: result) != false, let originalCount,
           (try result.count) != originalCount || result.visibleWords != original.visibleWords { return result }
        guard let other = result.control(tab.other.rawValue) else { throw CollectionError(navigationHelp) }
        try press(other, on: result)
        let alternate = try awaitPage("今日\(tab.other.rawValue)的词数") { $0.isToday && (try? $0.count) != nil }
        guard let desired = alternate.control(tab.rawValue) else { throw CollectionError(navigationHelp) }
        try press(desired, on: alternate)
        result = try awaitPage("今日\(tab.rawValue)的词数") { $0.isToday && (try? $0.count) != nil }
        let afterCount = try result.count
        let alternateCount = try alternate.count
        if selection(tab, on: result) == true || (selection(tab, on: result) != false
            && (afterCount != alternateCount || result.visibleWords != alternate.visibleWords)) { return result }
        throw CollectionError("无法核实「\(tab.rawValue)」标签已切换。\(navigationHelp)")
    }

    private func scroll(_ action: String, from page: Page, tab: Tab, expected: Int) throws -> Page? {
        guard let area = page.scrollArea(action) else { return nil }
        guard AXUIElementPerformAction(area.target, action as CFString) == .success else { return nil }
        Settle.wait()
        let next = try awaitPage("滚动后今日\(tab.rawValue)的词数") { $0.isToday && (try? $0.count) != nil }
        guard selection(tab, on: next) != false, try next.count == expected else {
            throw CollectionError("读取期间「\(tab.rawValue)」列表发生变化。\(navigationHelp)")
        }
        return next
    }

    func collect(_ tab: Tab, on start: Page) throws -> (words: [String], page: Page) {
        var page = try select(tab, on: start)
        let expected = try page.count
        var collected = WordList()
        if expected == 0 { return ([], page) }
        collected.append(page.visibleWords)
        if collected.words.count == expected { return (collected.words, page) }

        let deadline = Date(timeIntervalSinceNow: 90)
        for _ in 0..<120 {
            guard Date() < deadline else { throw CollectionError("滚动列表超时。\(navigationHelp)") }
            guard let previous = try scroll(scrollUp, from: page, tab: tab, expected: expected), previous.visibleWords != page.visibleWords else { break }
            page = previous
        }
        collected = WordList()
        collected.append(page.visibleWords)
        for _ in 0..<120 where collected.words.count < expected {
            guard Date() < deadline else { throw CollectionError("滚动列表超时。\(navigationHelp)") }
            guard let next = try scroll(scrollDown, from: page, tab: tab, expected: expected), next.visibleWords != page.visibleWords else { break }
            page = next
            collected.append(page.visibleWords)
        }
        return (try collected.checked(tab: tab, expected: expected, observed: page.count), page)
    }
}

enum Settle {
    static func wait(_ seconds: TimeInterval = 0.55) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}

func dateString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

func selfTest() throws {
    func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw CollectionError("自检失败：\(name)") }
    }
    try check(readCount(["今天", "0词"]) == 0, "明确的零词")
    try check(readCount(["今天", "还没有学习新词"]) == 0, "学习页空状态")
    try check(readCount(["今天", "还没有复习的单词"]) == 0, "明确的空状态")
    try check((try? readCount(["复习"])) == nil, "缺少计数")
    try check((try? readCount(["8词", "9词"])) == nil, "计数冲突")
    var list = WordList()
    list.append(["fragile", "give up", "logogram", "跳过"])
    list.append(["LOGOGRAM", "sprinkle", "co-operate"])
    let learned = try list.checked(tab: .learned, expected: 5, observed: 5)
    try check(learned == ["fragile", "give up", "logogram", "sprinkle", "co-operate"], "长列表合并与短语")
    try check((try? list.checked(tab: .learned, expected: 6, observed: 6)) == nil, "漏词")
    try check((try? list.checked(tab: .learned, expected: 5, observed: 6)) == nil, "采集期间词数变化")
    let longList = (1...35).map { "word-\($0)" }
    var paginated = WordList()
    for start in [0, 6, 12, 18, 24, 30] {
        paginated.append(Array(longList[start..<min(start + 8, longList.count)]))
    }
    try check(paginated.checked(tab: .reviewed, expected: 35, observed: 35) == longList, "长列表顺序与重叠页面")
    let daily = DailyWords(date: "2026-01-01", learned: learned, reviewed: ["sprinkle"])
    let decoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(daily)) as? [String: Any]
    try check(decoded?["date"] as? String == "2026-01-01", "JSON 日期")
    try check(decoded?["counts"] as? [String: Int] == ["learned": 5, "reviewed": 1], "两组各自计数")
    try check(decoded?["lists"] as? [String: [String]] == ["learned": learned, "reviewed": ["sprinkle"]], "两组各自保留重叠词")
    print("采集脚本自检通过。")
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["--help"]:
        print("用法：sh collect-today.sh [--help | --self-test]\n成功采集后输出今日学习与复习词表 JSON。")
    case ["--self-test"]:
        try selfTest()
    case []:
        let day = dateString()
        let collector = try Collector()
        let learned = try collector.collect(.learned, on: collector.openToday())
        let reviewed = try collector.collect(.reviewed, on: learned.page)
        guard day == dateString() else { throw CollectionError("采集跨过午夜。请重新读取今天的词表。") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result = DailyWords(date: day, learned: learned.words, reviewed: reviewed.words)
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    default:
        throw CollectionError("未知参数。请使用 --help 查看用法。")
    }
} catch {
    FileHandle.standardError.write(Data("不背单词采集失败：\(error.localizedDescription)\n".utf8))
    exit(1)
}
