import Foundation

/// Una línea de subtítulo con su tiempo de entrada y de salida (en segundos).
public struct SubtitleCue: Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Lector sencillo de WebVTT (lo que bajan las descargas): saca los tiempos y el texto sin etiquetas.
public enum WebVTT {
    public static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count >= 2, let s = time(parts[0]), let e = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let body = lines[(i + 1)...].joined(separator: "\n")
            let clean = stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: clean)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// El texto que toca enseñar en el segundo `t` (varias líneas a la vez se unen).
    public static func text(at t: Double, in cues: [SubtitleCue]) -> String {
        cues.filter { $0.start <= t && t < $0.end }.map { $0.text }.joined(separator: "\n")
    }

    /// Junta varios trozos de WebVTT (uno por segmento) en un solo fichero: una cabecera y todas las entradas.
    public static func merge(_ pieces: [String]) -> String {
        var out = "WEBVTT\n\n"
        for p in pieces {
            let t = p.replacingOccurrences(of: "\r\n", with: "\n")
            var lines = t.components(separatedBy: "\n")
            // Fuera la cabecera («WEBVTT…», X-TIMESTAMP-MAP…) hasta la primera línea en blanco
            if let f = lines.first, f.hasPrefix("WEBVTT") || f.hasPrefix("\u{FEFF}WEBVTT") {
                if let blank = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { lines = Array(lines[blank...]) } else { lines = [] }
            }
            out += lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n\n"
        }
        return out
    }

    static func time(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard p.count >= 2, p.count <= 3 else { return nil }
        let nums = p.compactMap { Double($0) }
        guard nums.count == p.count else { return nil }
        return nums.count == 3 ? nums[0] * 3600 + nums[1] * 60 + nums[2] : nums[0] * 60 + nums[1]
    }

    static func stripTags(_ s: String) -> String {
        var out = "", inTag = false
        for ch in s { if ch == "<" { inTag = true } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) } }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
