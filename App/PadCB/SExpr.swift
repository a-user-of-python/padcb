import Foundation

/// S-expression tree for KiCad file formats (.kicad_sym, .kicad_sch, ...).
///
/// The parser scans the UTF-8 bytes of the input once and builds strings
/// from byte slices, so multi-megabyte symbol libraries parse without
/// quadratic string concatenation.
enum SExpr {
    case atom(String)
    case string(String)
    case list([SExpr])

    // MARK: - Accessors

    /// Children when this node is a list; empty otherwise.
    var items: [SExpr] {
        if case .list(let children) = self { return children }
        return []
    }

    /// Payload for atom and string nodes; nil for lists.
    var atomValue: String? {
        switch self {
        case .atom(let value), .string(let value): return value
        case .list: return nil
        }
    }

    /// First direct child that is a list whose head atom equals `head`.
    func child(_ head: String) -> SExpr? {
        for item in items {
            if case .list(let children) = item, children.first?.atomValue == head {
                return item
            }
        }
        return nil
    }

    /// All direct children that are lists whose head atom equals `head`.
    func children(_ head: String) -> [SExpr] {
        items.filter { item in
            guard case .list(let children) = item else { return false }
            return children.first?.atomValue == head
        }
    }

    /// atomValue of items[index], or nil when out of range / a list.
    func value(_ index: Int) -> String? {
        let children = items
        guard index >= 0, index < children.count else { return nil }
        return children[index].atomValue
    }

    func double(_ index: Int) -> Double? {
        guard let text = value(index) else { return nil }
        return Double(text)
    }

    func int(_ index: Int) -> Int? {
        guard let text = value(index) else { return nil }
        if let value = Int(text) { return value }
        if let value = Double(text) { return Int(value) }
        return nil
    }

    // MARK: - Parsing

    /// Parse a whole document and return its root expression (for KiCad
    /// files, the single top-level list). Trailing content after the root
    /// list closes is ignored (files end with a newline).
    static func parse(_ text: String) throws -> SExpr {
        var parser = SExprParser(bytes: [UInt8](text.utf8))
        return try parser.parseDocument()
    }
}

enum SExprError: Error {
    case unexpectedEOF
    case unexpectedClose
    case unterminatedString
}

// MARK: - Byte scanner

private struct SExprParser {
    let bytes: [UInt8]
    var pos: Int = 0

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D // space \t \n \r
    }

    mutating func parseDocument() throws -> SExpr {
        var stack: [[SExpr]] = []
        let count = bytes.count
        while pos < count {
            let byte = bytes[pos]
            if isWhitespace(byte) {
                pos += 1
                continue
            }
            switch byte {
            case 0x28: // (
                stack.append([])
                pos += 1
            case 0x29: // )
                guard let frame = stack.popLast() else {
                    throw SExprError.unexpectedClose
                }
                let expr = SExpr.list(frame)
                pos += 1
                if stack.isEmpty {
                    return expr // root complete
                }
                stack[stack.count - 1].append(expr)
            case 0x22: // "
                let value = try parseString()
                if stack.isEmpty {
                    return .string(value)
                }
                stack[stack.count - 1].append(.string(value))
            default:
                let value = parseAtom()
                if stack.isEmpty {
                    return .atom(value)
                }
                stack[stack.count - 1].append(.atom(value))
            }
        }
        throw SExprError.unexpectedEOF
    }

    /// Parse a quoted string; bytes[pos] is the opening quote on entry.
    /// Only \" and \\ are unescaped (matching KiCad's own reader); any
    /// other backslash sequence is preserved verbatim.
    private mutating func parseString() throws -> String {
        pos += 1 // opening quote
        let count = bytes.count
        var out: [UInt8] = []
        out.reserveCapacity(32)
        while pos < count {
            let byte = bytes[pos]
            if byte == 0x22 { // closing quote
                pos += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte == 0x5C { // backslash
                pos += 1
                guard pos < count else { throw SExprError.unterminatedString }
                let escaped = bytes[pos]
                if escaped == 0x22 || escaped == 0x5C {
                    out.append(escaped)
                } else {
                    out.append(0x5C)
                    out.append(escaped)
                }
                pos += 1
                continue
            }
            out.append(byte)
            pos += 1
        }
        throw SExprError.unterminatedString
    }

    /// Parse a bare atom: everything up to whitespace, a parenthesis,
    /// or a quote.
    private mutating func parseAtom() -> String {
        let start = pos
        let count = bytes.count
        while pos < count {
            let byte = bytes[pos]
            if isWhitespace(byte) || byte == 0x28 || byte == 0x29 || byte == 0x22 {
                break
            }
            pos += 1
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }
}
