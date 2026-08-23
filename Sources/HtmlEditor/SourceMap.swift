import Foundation

/// Stamps every opening tag in the source with its character offset, so the
/// preview can map a DOM node back to a spot in the markup and vice versa.
/// The attribute only ever exists in the rendered copy — never in the saved file.
enum SourceMap {
    static let attribute = "data-he-pos"

    private static let lessThan = UInt16(UnicodeScalar("<").value)
    private static let greaterThan = UInt16(UnicodeScalar(">").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let bang = UInt16(UnicodeScalar("!").value)
    private static let question = UInt16(UnicodeScalar("?").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let singleQuote = UInt16(UnicodeScalar("'").value)

    /// Elements whose contents are text, not markup — instrumenting inside them
    /// would corrupt scripts that contain "<".
    private static let rawTextElements: Set<String> = ["script", "style", "textarea"]

    static func instrument(_ source: String) -> String {
        let units = Array(source.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count + units.count / 8)

        var i = 0
        while i < units.count {
            guard units[i] == lessThan, i + 1 < units.count else {
                out.append(units[i])
                i += 1
                continue
            }

            let next = units[i + 1]

            if matches("!--", in: units, at: i + 1) {
                i = copy(units, from: i, until: "-->", into: &out)
                continue
            }
            if next == bang || next == question || next == slash {
                i = copyTag(units, from: i, into: &out)
                continue
            }
            guard isNameStart(next) else {
                out.append(units[i])
                i += 1
                continue
            }

            // <tagname → keep the name, then splice the offset in as an attribute.
            var nameEnd = i + 1
            while nameEnd < units.count, isNameCharacter(units[nameEnd]) { nameEnd += 1 }
            let name = String(utf16CodeUnits: Array(units[(i + 1)..<nameEnd]), count: nameEnd - i - 1).lowercased()

            out.append(contentsOf: units[i..<nameEnd])
            out.append(contentsOf: Array(" \(attribute)=\"\(i)\"".utf16))
            i = copyTag(units, from: nameEnd, into: &out)

            if rawTextElements.contains(name) {
                let closing = "</\(name)"
                while i < units.count, !matches(closing, in: units, at: i) {
                    out.append(units[i])
                    i += 1
                }
            }
        }

        return String(utf16CodeUnits: out, count: out.count)
    }

    /// Copies through the end of a tag, ignoring ">" that sits inside an attribute value.
    private static func copyTag(_ units: [UInt16], from start: Int, into out: inout [UInt16]) -> Int {
        var i = start
        var quote: UInt16?
        while i < units.count {
            let c = units[i]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == doubleQuote || c == singleQuote {
                quote = c
            } else if c == greaterThan {
                out.append(c)
                return i + 1
            }
            out.append(c)
            i += 1
        }
        return i
    }

    private static func copy(_ units: [UInt16], from start: Int, until terminator: String, into out: inout [UInt16]) -> Int {
        var i = start
        let length = terminator.utf16.count
        while i < units.count {
            if matches(terminator, in: units, at: i) {
                out.append(contentsOf: units[i..<min(i + length, units.count)])
                return i + length
            }
            out.append(units[i])
            i += 1
        }
        return i
    }

    private static func matches(_ needle: String, in units: [UInt16], at index: Int) -> Bool {
        let pattern = Array(needle.lowercased().utf16)
        guard index >= 0, index + pattern.count <= units.count else { return false }
        for (offset, expected) in pattern.enumerated() where lowercased(units[index + offset]) != expected {
            return false
        }
        return true
    }

    private static func lowercased(_ unit: UInt16) -> UInt16 {
        (unit >= 65 && unit <= 90) ? unit + 32 : unit
    }


    /// Void elements have no closing tag, so their source range is the tag itself.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img",
        "input", "link", "meta", "param", "source", "track", "wbr"
    ]

    /// The source range of the whole element whose opening tag starts at `position`,
    /// closing tag included. Returns nil if the markup is unbalanced from there.
    static func elementRange(in source: String, startingAt position: Int) -> NSRange? {
        let units = Array(source.utf16)
        guard position >= 0, position + 1 < units.count,
              units[position] == lessThan, isNameStart(units[position + 1]) else { return nil }

        var nameEnd = position + 1
        while nameEnd < units.count, isNameCharacter(units[nameEnd]) { nameEnd += 1 }
        let name = elementName(units, from: position + 1, to: nameEnd)

        var isSelfClosing = false
        guard let openingTagEnd = endOfTag(units, from: nameEnd, isSelfClosing: &isSelfClosing) else { return nil }
        if isSelfClosing || voidElements.contains(name) {
            return NSRange(location: position, length: openingTagEnd - position)
        }

        var depth = 1
        var i = openingTagEnd
        while i < units.count {
            if matches("<!--", in: units, at: i) {
                i = skip(units, from: i, past: "-->")
                continue
            }

            // A closing tag for our own element.
            if matches("</", in: units, at: i), matches(name, in: units, at: i + 2),
               !isNameCharacter(unit(units, at: i + 2 + name.utf16.count)) {
                var ignored = false
                guard let closeEnd = endOfTag(units, from: i + 2, isSelfClosing: &ignored) else { return nil }
                depth -= 1
                if depth == 0 { return NSRange(location: position, length: closeEnd - position) }
                i = closeEnd
                continue
            }

            guard units[i] == lessThan, i + 1 < units.count, isNameStart(units[i + 1]) else {
                i += 1
                continue
            }

            var otherEnd = i + 1
            while otherEnd < units.count, isNameCharacter(units[otherEnd]) { otherEnd += 1 }
            let other = elementName(units, from: i + 1, to: otherEnd)
            var otherIsSelfClosing = false
            guard let end = endOfTag(units, from: otherEnd, isSelfClosing: &otherIsSelfClosing) else { return nil }
            i = end

            if rawTextElements.contains(other) {
                // "<" inside a script body is text, not a nested tag.
                let closing = "</\(other)"
                while i < units.count, !matches(closing, in: units, at: i) { i += 1 }
            } else if other == name, !otherIsSelfClosing, !voidElements.contains(other) {
                depth += 1
            }
        }
        return nil
    }

    private static func elementName(_ units: [UInt16], from start: Int, to end: Int) -> String {
        String(utf16CodeUnits: Array(units[start..<end]), count: end - start).lowercased()
    }

    private static func unit(_ units: [UInt16], at index: Int) -> UInt16 {
        (index >= 0 && index < units.count) ? units[index] : 0
    }

    /// Index just past the tag's ">", ignoring ">" inside attribute values.
    private static func endOfTag(_ units: [UInt16], from start: Int, isSelfClosing: inout Bool) -> Int? {
        var i = start
        var quote: UInt16?
        var lastNonSpace: UInt16 = 0
        while i < units.count {
            let c = units[i]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == doubleQuote || c == singleQuote {
                quote = c
            } else if c == greaterThan {
                isSelfClosing = (lastNonSpace == slash)
                return i + 1
            }
            if c != 32 && c != 9 && c != 10 && c != 13 { lastNonSpace = c }
            i += 1
        }
        return nil
    }

    private static func skip(_ units: [UInt16], from start: Int, past terminator: String) -> Int {
        var i = start
        let length = terminator.utf16.count
        while i < units.count {
            if matches(terminator, in: units, at: i) { return i + length }
            i += 1
        }
        return units.count
    }

    private static func isNameStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    private static func isNameCharacter(_ unit: UInt16) -> Bool {
        isNameStart(unit) || (unit >= 48 && unit <= 57) || unit == 45 || unit == 58
    }
}
