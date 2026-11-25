// Text normalization shared by the guard and the prompt composer.

import Foundation

/// Lowercase, undo common leetspeak and collapse everything that is not a
/// letter or digit into single spaces, so "L0-li" becomes "lo li".
public func normalize(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for c in text.lowercased().precomposedStringWithCanonicalMapping {
        switch c {
        case "0": out.append("o")
        case "1", "!", "|": out.append("i")
        case "3": out.append("e")
        case "4", "@": out.append("a")
        case "5", "$": out.append("s")
        case "7": out.append("t")
        case let c where c.isLetter || c.isNumber: out.append(c)
        default: out.append(" ")
        }
    }
    return collapseSpaces(out)
}

/// Like ``normalize(_:)`` but keeps digits (and `/` for "y/o"), for age checks.
func normalizeKeepDigits(_ text: String) -> String {
    let mapped = text.lowercased().map { c -> Character in
        c.isLetter || c.isNumber || c == "/" ? c : " "
    }
    return collapseSpaces(String(mapped))
}

func collapseSpaces(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
