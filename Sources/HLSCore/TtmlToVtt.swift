import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// AVPlayer solo muestra subtítulos WebVTT dentro de HLS. Los de Prime, Disney y otros vienen en TTML:
/// este conversor los pasa a WebVTT (tiempos, saltos de línea y cursiva/negrita básicos).
public enum TtmlToVtt {

    struct Cue { var start: Double; var end: Double; var text: String }

    /// Convierte un documento TTML. Si ya es WebVTT lo devuelve igual.
    public static func convert(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("WEBVTT") { return text }
        let h = Handler()
        let p = XMLParser(data: Data(t.utf8)); p.delegate = h; p.parse()
        var out = "WEBVTT\n\n"
        for c in h.cues where c.end > c.start && !c.text.isEmpty {
            out += "\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n\n"
        }
        return out
    }

    static func stamp(_ s: Double) -> String {
        let ms = Int((max(s, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Tiempo TTML → segundos: «00:01:02.500», «00:01:02:12» (fotogramas), «12.5s», «1500ms», «123t» (ticks).
    static func seconds(_ v: String, frameRate: Double, tickRate: Double) -> Double? {
        let s = v.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("ms"), let d = Double(s.dropLast(2)) { return d / 1000 }
        if s.hasSuffix("s"), let d = Double(s.dropLast()) { return d }
        if s.hasSuffix("m"), let d = Double(s.dropLast()) { return d * 60 }
        if s.hasSuffix("h"), let d = Double(s.dropLast()) { return d * 3600 }
        if s.hasSuffix("t"), let d = Double(s.dropLast()) { return d / tickRate }
        if s.hasSuffix("f"), let d = Double(s.dropLast()) { return d / frameRate }
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count >= 3, let h = Double(parts[0]), let m = Double(parts[1]) else { return Double(s) }
        if parts.count == 4, let sec = Double(parts[2]), let f = Double(parts[3]) { return h * 3600 + m * 60 + sec + f / frameRate }
        guard let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var cues: [Cue] = []
        var frameRate = 25.0, tickRate = 10_000_000.0
        private var cur: Cue?
        private var depth = 0

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            let n = name.split(separator: ":").last.map(String.init) ?? name
            func attr(_ k: String) -> String? { a.first { $0.key.split(separator: ":").last.map(String.init) == k }?.value }
            switch n {
            case "tt":
                if let f = attr("frameRate").flatMap(Double.init) { frameRate = f }
                if let t = attr("tickRate").flatMap(Double.init) { tickRate = t }
            case "p":
                if let b = attr("begin").flatMap({ TtmlToVtt.seconds($0, frameRate: frameRate, tickRate: tickRate) }) {
                    var e = attr("end").flatMap { TtmlToVtt.seconds($0, frameRate: frameRate, tickRate: tickRate) }
                    if e == nil, let d = attr("dur").flatMap({ TtmlToVtt.seconds($0, frameRate: frameRate, tickRate: tickRate) }) { e = b + d }
                    cur = Cue(start: b, end: e ?? b + 3, text: ""); depth = 0
                }
            case "br": if cur != nil { cur?.text += "\n" }
            case "span":
                if cur != nil {
                    let style = (attr("fontStyle") ?? "") + (attr("fontWeight") ?? "")
                    if style.contains("italic") { cur?.text += "<i>" }
                    if style.contains("bold") { cur?.text += "<b>" }
                    spanClose.append((style.contains("italic"), style.contains("bold")))
                }
            default: break
            }
        }
        private var spanClose: [(Bool, Bool)] = []

        func parser(_ p: XMLParser, foundCharacters s: String) {
            if cur != nil { cur?.text += s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let n = name.split(separator: ":").last.map(String.init) ?? name
            if n == "span", cur != nil, let c = spanClose.popLast() {
                if c.1 { cur?.text += "</b>" }
                if c.0 { cur?.text += "</i>" }
            }
            if n == "p", var c = cur {
                // Espacios en blanco repetidos y saltos de línea sobrantes
                c.text = c.text.components(separatedBy: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                cues.append(c); cur = nil
            }
        }
    }
}
