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

    private static func isNameStart(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    private static func isNameCharacter(_ unit: UInt16) -> Bool {
        isNameStart(unit) || (unit >= 48 && unit <= 57) || unit == 45 || unit == 58
    }
}
