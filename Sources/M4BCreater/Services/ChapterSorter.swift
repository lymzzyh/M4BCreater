import Foundation

enum ChapterSorter {
    static func sortedURLs(_ urls: [URL]) -> [URL] {
        urls.sorted { compare($0.lastPathComponent, $1.lastPathComponent) }
    }

    static func sortedItems(_ items: [StorageItem]) -> [StorageItem] {
        items.sorted { compare($0.name.isEmpty ? $0.url.lastPathComponent : $0.name, $1.name.isEmpty ? $1.url.lastPathComponent : $1.name) }
    }

    static func sortedChapters(_ chapters: [Chapter]) -> [Chapter] {
        chapters.sorted { compare($0.title.isEmpty ? $0.sourceURL.lastPathComponent : $0.title, $1.title.isEmpty ? $1.sourceURL.lastPathComponent : $1.title) }
    }

    static func compare(_ lhs: String, _ rhs: String) -> Bool {
        let left = tokenize(lhs)
        let right = tokenize(rhs)
        for index in 0..<min(left.count, right.count) {
            let l = left[index]
            let r = right[index]
            if l == r { continue }
            switch (l, r) {
            case (.number(let a, _), .number(let b, _)):
                return a == b ? l.raw < r.raw : a < b
            default:
                return l.raw.localizedCaseInsensitiveCompare(r.raw) == .orderedAscending
            }
        }
        return left.count == right.count ? lhs.localizedStandardCompare(rhs) == .orderedAscending : left.count < right.count
    }

    private static func tokenize(_ value: String) -> [Token] {
        let normalized = value.deletingKnownExtension
        var tokens: [Token] = []
        var currentText = ""
        var currentDigits = ""

        func flushText() {
            guard !currentText.isEmpty else { return }
            appendChineseAwareText(currentText, to: &tokens)
            currentText = ""
        }

        func flushDigits() {
            guard !currentDigits.isEmpty else { return }
            tokens.append(.number(Int(currentDigits) ?? 0, currentDigits))
            currentDigits = ""
        }

        for character in normalized {
            if character.isNumber, character.isASCII {
                flushText()
                currentDigits.append(character)
            } else {
                flushDigits()
                currentText.append(character)
            }
        }
        flushDigits()
        flushText()
        return tokens.isEmpty ? [.text(normalized)] : tokens
    }

    private static func appendChineseAwareText(_ text: String, to tokens: inout [Token]) {
        var buffer = ""
        var chineseNumber = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            tokens.append(.text(buffer))
            buffer = ""
        }

        func flushChineseNumber() {
            guard !chineseNumber.isEmpty else { return }
            if let number = parseChineseNumber(chineseNumber) {
                tokens.append(.number(number, chineseNumber))
            } else {
                tokens.append(.text(chineseNumber))
            }
            chineseNumber = ""
        }

        for character in text {
            if chineseNumberCharacters.contains(character) {
                flushBuffer()
                chineseNumber.append(character)
            } else {
                flushChineseNumber()
                buffer.append(character)
            }
        }
        flushChineseNumber()
        flushBuffer()
    }

    private static let chineseNumberCharacters = Set("零〇一二两三四五六七八九十百千万")

    private static func parseChineseNumber(_ value: String) -> Int? {
        guard value.contains(where: { chineseNumberCharacters.contains($0) }) else { return nil }
        var total = 0
        var section = 0
        var number = 0
        var sawUnit = false

        for character in value {
            if let digit = chineseDigit(character) {
                number = digit
            } else if let unit = chineseUnit(character) {
                sawUnit = true
                let multiplier = unit
                if multiplier == 10_000 {
                    section = (section + number) * multiplier
                    total += section
                    section = 0
                } else {
                    section += (number == 0 ? 1 : number) * multiplier
                }
                number = 0
            } else {
                return nil
            }
        }
        let result = total + section + number
        if result == 0, !value.contains("零"), !value.contains("〇") { return nil }
        return sawUnit || value.count == 1 ? result : parseChineseDigits(value)
    }

    private static func parseChineseDigits(_ value: String) -> Int? {
        var result = ""
        for character in value {
            guard let digit = chineseDigit(character) else { return nil }
            result.append(String(digit))
        }
        return Int(result)
    }

    private static func chineseDigit(_ character: Character) -> Int? {
        switch character {
        case "零", "〇": 0
        case "一": 1
        case "二", "两": 2
        case "三": 3
        case "四": 4
        case "五": 5
        case "六": 6
        case "七": 7
        case "八": 8
        case "九": 9
        default: nil
        }
    }

    private static func chineseUnit(_ character: Character) -> Int? {
        switch character {
        case "十": 10
        case "百": 100
        case "千": 1_000
        case "万": 10_000
        default: nil
        }
    }

    private enum Token: Equatable {
        case text(String)
        case number(Int, String)

        var raw: String {
            switch self {
            case .text(let value): value
            case .number(_, let value): value
            }
        }
    }
}

private extension String {
    var deletingKnownExtension: String {
        let url = URL(fileURLWithPath: self)
        return url.pathExtension.isEmpty ? self : url.deletingPathExtension().lastPathComponent
    }
}

private extension Character {
    var isASCII: Bool {
        unicodeScalars.allSatisfy { $0.isASCII }
    }
}
