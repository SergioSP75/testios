import Foundation

/// Una calidad de vídeo de la lista maestra, con su etiqueta como en Android: «2160p · VP9 · HDR10 (PQ) · 15.0 Mbps».
public struct VideoVariant: Identifiable, Hashable {
    public let height: Int
    public let codec: String        // «H.264», «HEVC», «VP9», «AV1», «Dolby Vision»
    public let range: String        // «SDR», «HDR10 (PQ)», «HLG», «Dolby Vision»
    public let mbps: Double
    public var id: String { "\(height)|\(codec)|\(range)|\(Int(mbps * 10))" }
    public init(height: Int, codec: String, range: String, mbps: Double) { self.height = height; self.codec = codec; self.range = range; self.mbps = mbps }

    /// «2160p · VP9 · HDR10 (PQ) · 15.0 Mbps» (el rango solo si es HDR)
    public var label: String {
        var p = [height > 0 ? "\(height)p" : "Vídeo", codec]
        if range != "SDR" { p.append(range) }
        if mbps > 0 { p.append(String(format: "%.1f Mbps", mbps)) }
        return p.joined(separator: " · ")
    }
}

public enum VideoLabels {
    /// Calidades de vídeo de una lista maestra, de mayor a menor (resolución y, a igualdad, bitrate). Sin repetidas.
    public static func variants(_ master: String) -> [VideoVariant] {
        var out: [VideoVariant] = []
        for l in master.components(separatedBy: "\n") where l.hasPrefix("#EXT-X-STREAM-INF") {
            // Sin RESOLUTION no hay altura que mostrar: pistas de solo audio o de imágenes sueltas
            guard let r = l.range(of: "RESOLUTION=\\d+x\\d+", options: .regularExpression),
                  let h = Int(l[r].split(separator: "x").last ?? "") else { continue }
            let codecs = (AudioLabels.attr(l, "CODECS") ?? "").lowercased()
            let video = codecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.hasPrefix("mp4a") && !$0.hasPrefix("ec-3") && !$0.hasPrefix("ac-3") && !$0.hasPrefix("ac-4") && !$0.hasPrefix("opus") } ?? ""
            let bw = number(l, "AVERAGE-BANDWIDTH") ?? number(l, "BANDWIDTH") ?? 0
            let v = VideoVariant(height: h, codec: codecName(video), range: rangeName(l, video), mbps: bw / 1_000_000)
            if !out.contains(where: { $0.id == v.id }) { out.append(v) }
        }
        return out.sorted { ($0.height, $0.mbps) > ($1.height, $1.mbps) }
    }

    static func codecName(_ c: String) -> String {
        if c.hasPrefix("avc") { return "H.264" }
        if c.hasPrefix("hvc") || c.hasPrefix("hev") { return "HEVC" }
        if c.hasPrefix("dvh") { return "Dolby Vision" }
        if c.hasPrefix("vp09") { return "VP9" }
        if c.hasPrefix("av01") { return "AV1" }
        return c.isEmpty ? "?" : String(c.prefix { $0 != "." }).uppercased()
    }

    /// Rango de color: Dolby Vision por el códec; en VP9 y AV1, por la curva de transferencia del texto del códec (16 = PQ, 18 = HLG);
    /// si no, por VIDEO-RANGE de la lista.
    static func rangeName(_ line: String, _ codec: String) -> String {
        if codec.hasPrefix("dvh") { return "Dolby Vision" }
        let f = codec.split(separator: ".").map(String.init)
        let pos = codec.hasPrefix("vp09") && f.count >= 9 ? 6 : (codec.hasPrefix("av01") && f.count >= 10 ? 7 : -1)
        if pos >= 0 {
            switch Int(f[pos]) { case 16: return "HDR10 (PQ)"; case 18: return "HLG"; default: break }
        }
        switch AudioLabels.attr(line, "VIDEO-RANGE") { case "PQ": return "HDR10 (PQ)"; case "HLG": return "HLG"; default: return "SDR" }
    }

    static func number(_ line: String, _ name: String) -> Double? {
        guard let r = line.range(of: "(^|[:,])\(name)=\\d+", options: .regularExpression) else { return nil }
        return Double(line[r].split(separator: "=").last ?? "")
    }
}
