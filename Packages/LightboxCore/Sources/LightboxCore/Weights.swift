// Prompt weighting: `(text:1.3)`, `(text)` = ×1.1, `[text]` = ×1/1.1.
//
// An unclosed bracket weights everything after it, so every prompt fragment
// is rewritten into a canonical, flat form before fragments are joined:
// brackets balanced, weights clamped, no nesting. A stray `[[[[` can then no longer weaken the
// parts that follow it (such as the forced safety negatives).
//
// The canonical form only uses `(text:weight)`, which ComfyUI understands;
// square brackets are resolved into weights.

import Foundation

public enum Weights {
    /// Weights are clamped to this range.
    public static let minWeight = 0.3
    public static let maxWeight = 2.0
    /// Range of per-item emphasis sliders.
    public static let minEmphasis = 0.5
    public static let maxEmphasis = 1.5

    static let round = 1.1
    static let square = 1.0 / 1.1

    public enum Segment: Equatable, Sendable {
        case text(String, Double)
        /// `BREAK`: starts a new 75-token chunk.
        case brk
    }

    /// Parse with the A1111/sd.cpp rules (and their quirks).
    public static func parse(_ text: String) -> [Segment] {
        var res: [Segment] = []
        var roundOpen: [Int] = []
        var squareOpen: [Int] = []

        func multiply(from: Int, by m: Double) {
            for k in from..<res.count {
                if case .text(let t, let w) = res[k] { res[k] = .text(t, w * m) }
            }
        }
        // Appends to the last segment unless a bracket opened after it (its
        // text must stay separate so the bracket's weight applies to it alone).
        func pushText(_ t: String) {
            let open = max(roundOpen.last ?? 0, squareOpen.last ?? 0)
            let afterOpen = res.count > open
            if afterOpen, case .text(let s, let w)? = res.last, w == 1.0 {
                res[res.count - 1] = .text(s + t, w)
            } else {
                res.append(.text(t, 1.0))
            }
        }

        let b = Array(text)
        func isWord(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == "\\" {
                // `\(` is a literal bracket; other escapes carry no meaning.
                if i + 1 < b.count, "()[]\\".contains(b[i + 1]) {
                    pushText(String(b[i + 1]))
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            switch c {
            case "(":
                roundOpen.append(res.count)
                i += 1
            case "[":
                squareOpen.append(res.count)
                i += 1
            case ")":
                if let from = roundOpen.popLast() { multiply(from: from, by: round) } else { pushText(")") }
                i += 1
            case "]":
                if let from = squareOpen.popLast() { multiply(from: from, by: square) } else { pushText("]") }
                i += 1
            case ":":
                // `:<number>)` closes the innermost round bracket with that weight.
                var numLen = 0
                while i + 1 + numLen < b.count {
                    let d = b[i + 1 + numLen]
                    let ok = (d.isASCII && d.isNumber) || d == "." || (numLen == 0 && (d == "+" || d == "-"))
                    if !ok { break }
                    numLen += 1
                }
                let after = 1 + numLen
                if numLen > 0, i + after < b.count, b[i + after] == ")" {
                    if let from = roundOpen.popLast() {
                        let w = Double(String(b[(i + 1)..<(i + after)])) ?? 1.0
                        multiply(from: from, by: w)
                    }
                    i += after + 1
                } else {
                    pushText(":")
                    i += 1
                }
            case "B"
            where i + 5 <= b.count && String(b[i..<(i + 5)]) == "BREAK"
                && (i == 0 || !isWord(b[i - 1]))
                && (i + 5 == b.count || !isWord(b[i + 5])):
                res.append(.brk)
                i += 5
            default:
                pushText(String(c))
                i += 1
            }
        }
        for from in roundOpen { multiply(from: from, by: round) }
        for from in squareOpen { multiply(from: from, by: square) }

        // Merge neighbours with the same weight.
        var merged: [Segment] = []
        for s in res {
            if case .text(let b, let wb) = s, case .text(let a, let wa)? = merged.last, abs(wa - wb) < 1e-4 {
                merged[merged.count - 1] = .text(a + b, wa)
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    static func clamp(_ w: Double) -> Double {
        w.isFinite ? min(max(w, minWeight), maxWeight) : 1.0
    }

    /// "1.2", "0.85", "2": at most two decimals, no trailing zeros.
    static func format(_ w: Double) -> String {
        var s = String(format: "%.2f", w)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func serialize(_ segments: [Segment]) -> String {
        var out = ""
        for s in segments {
            switch s {
            case .brk:
                while out.last?.isWhitespace == true { out.removeLast() }
                out += " BREAK "
            case .text(let raw, let weight):
                // Brackets and backslashes left as text would be read as syntax again.
                let t = raw.filter { !"()[]\\".contains($0) }
                let w = clamp(weight)
                if abs(w - 1.0) < 0.005 {
                    out += t
                    continue
                }
                // Keep separators outside the group: ", (sun:1.1), ".
                let isSep: (Character) -> Bool = { $0.isWhitespace || $0 == "," }
                let lead = t.prefix(while: isSep)
                let rest = t.dropFirst(lead.count)
                let trail = String(rest.reversed().prefix(while: isSep).reversed())
                let core = rest.dropLast(trail.count)
                if core.isEmpty {
                    out += t
                    continue
                }
                out += "\(lead)(\(core):\(format(w)))\(trail)"
            }
        }
        return collapseSpaces(out)
    }

    /// Balanced, flat, clamped form of a prompt fragment. Idempotent.
    public static func canonical(_ text: String) -> String {
        serialize(parse(text))
    }

    /// The fragment with every part's weight multiplied by `emphasis`
    /// (clamped to the slider range).
    public static func emphasize(_ text: String, _ emphasis: Double) -> String {
        let e = emphasis.isFinite ? min(max(emphasis, minEmphasis), maxEmphasis) : 1.0
        let segments = parse(text).map { s -> Segment in
            if case .text(let t, let w) = s { return .text(t, w * e) }
            return s
        }
        return serialize(segments)
    }

    /// Whether `word` occurs somewhere at full weight (≥ 1).
    public static func hasFullWeightWord(_ text: String, _ word: String) -> Bool {
        parse(text).contains { s in
            guard case .text(let t, let w) = s else { return false }
            return w >= 1.0 - 1e-4 && normalize(t).split(separator: " ").contains { $0 == word }
        }
    }

    /// Split at commas outside weight groups.
    public static func splitTerms(_ text: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for c in text {
            switch c {
            case "(", "[": depth += 1
            case ")", "]": depth = max(depth - 1, 0)
            case "," where depth == 0:
                out.append(current)
                current = ""
                continue
            default: break
            }
            current.append(c)
        }
        out.append(current)
        return out
    }
}
