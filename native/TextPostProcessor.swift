import Foundation

/// Custom dictionary substitutions + light cleanup.
/// Stored at dictionaryURL: { "rules": [{"from":"…","to":"…","regex":false}] }
struct ProcessingOptions {var removeFillers=true;var removeRepetitions=false;var autoEdit=true;var autoFormat=true}
final class TextPostProcessor {
    private let dictionaryURL: URL
    private let options: ProcessingOptions

    struct Rule: Codable {
        var from: String
        var to: String
        var regex: Bool
    }
    private struct File: Codable { var rules: [Rule] }

    private(set) var rules: [Rule] = []

    init(dictionaryURL: URL,options: ProcessingOptions=ProcessingOptions()) {self.dictionaryURL=dictionaryURL;self.options=options;reload()}

    func reload() {
        guard let data = try? Data(contentsOf: dictionaryURL),
              let f = try? JSONDecoder().decode(File.self, from: data) else {
            rules = []
            return
        }
        rules = f.rules
    }

    func saveRules(_ rules: [Rule]) {
        self.rules = rules
        let f = File(rules: rules)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: dictionaryURL, options: .atomic)
        }
    }

    func apply(_ raw: String) -> String {
        var s = raw
        // Strip whisper bracketed annotations like [BLANK_AUDIO] (Music) etc.
        s = s.replacingOccurrences(of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\([^\\)]*音乐[^\\)]*\\)", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Convert Traditional Chinese -> Simplified Chinese using the OS
        // built-in transliteration. Whisper's base model often emits a mix of
        // Hant/Hans glyphs; this guarantees Simplified output.
        let m = NSMutableString(string: s)
        if CFStringTransform(m, nil, "Hant-Hans" as CFString, false) {
            s = m as String
        }
        // Text alone cannot establish whether a phrase was hallucinated.
        // Leave silence rejection to callers that have audio evidence.
        // User rules
        for r in rules {
            if r.regex {
                s = s.replacingOccurrences(of: r.from, with: r.to, options: .regularExpression)
            } else {
                s = s.replacingOccurrences(of: r.from, with: r.to)
            }
        }

        // —— 对标 Typeless 的 4 个 AI 优化开关 ——
        let cfg = options
        if cfg.removeFillers     { s = Self.stripFillers(s) }
        if cfg.removeRepetitions { s = Self.collapseRepetitions(s) }
        if cfg.autoEdit          { s = Self.autoEdit(s) }
        if cfg.autoFormat        { s = Self.autoFormat(s) }

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup helpers

    /// 中英文常见填充词。**注意**：保守列表，避免误伤。
    private static let fillerPatterns: [String] = [
        // 中文：作为独立"词"出现时才清掉（避免吃掉"那个人"里的"那个"）
        "(?<![\\u4e00-\\u9fa5])(嗯+|呃+|啊+|哦+|唉+|哎+)(?![\\u4e00-\\u9fa5])",
        "(?<![\\u4e00-\\u9fa5])(那个|这个|就是说|就是|然后呢|然后|其实|反正|对吧|你知道吗|你知道的)(?=[\\s,，。！？!?])",
        // 英文
        "\\b(uh+|um+|er+|ah+|hmm+|like|you know|i mean|sort of|kind of)\\b"
    ]

    static func stripFillers(_ input: String) -> String {
        var s = input
        for p in fillerPatterns {
            s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // 清理填充词留下的多余空格 / 标点
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "([,，。！？!?])\\1+", with: "$1", options: .regularExpression)
        return s
    }

    /// 折叠相邻重复（"我我我想说"→"我想说"，"the the cat"→"the cat"）。
    static func collapseRepetitions(_ input: String) -> String {
        var s = input
        // 中文相邻重复字
        s = s.replacingOccurrences(of: "([\\u4e00-\\u9fa5])\\1{1,}", with: "$1", options: .regularExpression)
        // 英文相邻重复词
        s = s.replacingOccurrences(of: "\\b(\\w+)(\\s+\\1\\b){1,}", with: "$1",
                                   options: [.regularExpression, .caseInsensitive])
        return s
    }

    /// 自动改写：处理"我想说……不，我是想说……"这类自我更正，仅保留最后一段。
    static func autoEdit(_ input: String) -> String {
        var s = input
        // "X，不对，Y" / "X，应该是 Y" / "X，我是说 Y" → 只留 Y
        let patterns = [
            "[^，。！？!?]*?(?:，|,)\\s*(?:不对|不是|应该是|我是说|我的意思是|或者说)[，,]?\\s*",
            "[^.!?]*?(?:,|\\s)+(?:no,|i mean,|actually,|sorry,)\\s*"
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s
    }

    /// 自动格式化：把口语里的"第一/第二/第三"或"首先/其次/最后"折成换行列表；
    /// 中文末尾补句号；英文句首大写。
    static func autoFormat(_ input: String) -> String {
        var s = input
        // 列表项前换行
        let listMarkers = "(第[一二三四五六七八九十]+[，,、:：]|首先[，,]?|其次[，,]?|然后[，,]?|最后[，,]?|另外[，,]?)"
        s = s.replacingOccurrences(of: "\\s*\(listMarkers)", with: "\n$1", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 中文：若末尾没有标点，补一个句号
        if let last = s.last,
           !"。！？.!?，,；;".contains(last),
           s.range(of: "[\\u4e00-\\u9fa5]", options: .regularExpression) != nil {
            s += "。"
        }
        // 英文：句首字母大写（仅在以拉丁字母开头时）
        if let first = s.first, first.isASCII, first.isLetter {
            s = first.uppercased() + s.dropFirst()
        }
        return s
    }
}
