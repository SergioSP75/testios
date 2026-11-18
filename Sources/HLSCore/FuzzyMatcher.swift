import Foundation

/// Port de FuzzyMatcher.kt: empareja nombres de canal con los de la guía (EPG).
/// Score = exacto (1.0) · contención (0.92-1.0) · mezcla de Jaccard de palabras (40 %), Dice de bigramas (35 %)
/// y Levenshtein (25 %). Normaliza acentos y quita sufijos de TV española (HD, 4K, ES, canal…).
public enum FuzzyMatcher {
    public static let threshold = 0.60

    public static func bestMatch(_ candidates: [String], queries: [String?]) -> (String, Double)? {
        if candidates.isEmpty { return nil }
        let normalized = candidates.map { ($0, normalize($0)) }
        var best: String?
        var bestScore = 0.0
        for raw in queries {
            guard let raw = raw else { continue }
            let q = normalize(raw)
            if q.isEmpty { continue }
            for (cand, nc) in normalized {
                let s = score(q, nc)
                if s > bestScore { bestScore = s; best = cand }
                if bestScore == 1.0 { break }
            }
        }
        if let b = best, bestScore >= threshold { return (b, bestScore) }
        return nil
    }

    private static let strips: [NSRegularExpression] = [
        "\\b(hd|fhd|4k|uhd|8k|sd)\\b",
        "\\b(\\+1|plus1|plus 1)\\b",
        "\\b(tv|tve|canal|channel|ch|network|net)\\b",
        "\\b(es|esp|spain|espana|espanol|spa)\\b",
        "\\b(premium|ultra|extra|mega|super)\\b",
        "\\b(east|west|norte|sur|este|oeste)\\b"
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func normalize(_ s: String) -> String {
        // Quitar acentos (á→a, ñ→n, ç→c…)
        var r = s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        r = r.replacingOccurrences(of: "+", with: " plus ")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "@", with: " at ")
        for re in strips {
            r = re.stringByReplacingMatches(in: r, range: NSRange(location: 0, length: (r as NSString).length), withTemplate: " ")
        }
        r = String(r.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " })
        return r.split(separator: " ").joined(separator: " ")
    }

    public static func score(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }
        if a.contains(b) || b.contains(a) {
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            if ratio >= 0.7 { return 0.92 + ratio * 0.08 }
        }
        let lev = 1.0 - Double(levenshtein(Array(a), Array(b))) / Double(max(a.count, b.count))
        return tokenJaccard(a, b) * 0.40 + dice(a, b) * 0.35 + lev * 0.25
    }

    private static func tokenJaccard(_ a: String, _ b: String) -> Double {
        let ta = Set(a.split(separator: " ").filter { $0.count > 1 }.map(String.init))
        let tb = Set(b.split(separator: " ").filter { $0.count > 1 }.map(String.init))
        if ta.isEmpty && tb.isEmpty { return 1.0 }
        if ta.isEmpty || tb.isEmpty { return 0.0 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }

    private static func bigrams(_ s: String) -> [String] {
        let c = Array(s.replacingOccurrences(of: " ", with: ""))
        if c.count < 2 { return [] }
        return (0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) }
    }

    private static func dice(_ a: String, _ b: String) -> Double {
        let ba = bigrams(a); var bb = bigrams(b)
        if ba.isEmpty && bb.isEmpty { return 1.0 }
        if ba.isEmpty || bb.isEmpty { return 0.0 }
        var common = 0
        for g in ba { if let i = bb.firstIndex(of: g) { common += 1; bb.remove(at: i) } }
        return 2.0 * Double(common) / Double(ba.count + bigrams(b).count)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : 1 + min(prev[j], curr[j - 1], prev[j - 1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
