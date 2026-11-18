import Foundation

/// Filtra las variantes de una lista maestra HLS por resolución.
///  - `minHeight`: descarta las variantes más pequeñas (se queda con las de ese alto o más; si no hay, con las más altas).
///  - `fixedHeight`: deja solo la mayor variante que no pase de ese alto (calidad fija).
/// Así AVPlayer no arranca en baja resolución: solo puede elegir lo que se le deja.
public enum VariantFilter {
    public static func apply(_ master: String, minHeight: Int, fixedHeight: Int) -> String {
        guard minHeight > 0 || fixedHeight > 0 else { return master }
        let lines = master.components(separatedBy: "\n")
        struct V { var inf: Int; var uri: Int; var height: Int }
        var variants: [V] = []
        var sdrHeights: [Int] = []
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") {
            var h = 0
            if let r = l.range(of: "RESOLUTION=[0-9]+x[0-9]+", options: .regularExpression) {
                h = Int(l[r].split(separator: "x").last ?? "") ?? 0
            }
            if i + 1 < lines.count { variants.append(V(inf: i, uri: i + 1, height: h)) }
            if h > 0, !l.contains("VIDEO-RANGE=PQ"), !l.contains("VIDEO-RANGE=HLG") { sdrHeights.append(h) }
        }
        let heights = variants.map { $0.height }.filter { $0 > 0 }
        guard !heights.isEmpty else { return master }                     // sin resolución declarada no se toca
        var keep = Set<Int>()                                              // posición de la línea INF que se conserva
        if fixedHeight > 0 {
            let fit = heights.filter { $0 <= fixedHeight }.max() ?? heights.min()!
            for v in variants where v.height == fit { keep.insert(v.inf) }
        } else {
            // El mínimo nunca pasa de lo mejor que haya en SDR: si solo quedaran variantes HDR/4K (a veces AVPlayer no las abre)
            // la película no arrancaba (p. ej. error -17223 con 1440p y 2160p HDR)
            let floor = min(minHeight, (sdrHeights.max() ?? heights.max()!))
            for v in variants where v.height >= floor { keep.insert(v.inf) }
        }
        var out: [String] = []
        var skip = Set<Int>()
        for v in variants where !keep.contains(v.inf) { skip.insert(v.inf); skip.insert(v.uri) }
        for (i, l) in lines.enumerated() where !skip.contains(i) { out.append(l) }
        return out.joined(separator: "\n")
    }

    /// Deja solo las variantes que usan el grupo de audio `group` (para cambiar de idioma entre grupos de códec distintos:
    /// AVPlayer solo ofrece las pistas del grupo de la variante que reproduce). Si ninguna lo usa, no toca nada.
    public static func audioGroup(_ master: String, group: String?) -> String {
        guard let group = group, !group.isEmpty else { return master }
        let lines = master.components(separatedBy: "\n")
        var skip = Set<Int>(), kept = 0
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
            if l.contains("AUDIO=\"\(group)\"") { kept += 1 } else { skip.insert(i); skip.insert(i + 1) }
        }
        guard kept > 0 else { return master }
        // Las pistas de los grupos descartados se quitan también: si no, el reproductor las lista duplicadas («Unknown»…)
        for (i, l) in lines.enumerated() where l.hasPrefix("#EXT-X-MEDIA") && l.contains("TYPE=AUDIO") && !l.contains("GROUP-ID=\"\(group)\"") { skip.insert(i) }
        return lines.enumerated().filter { !skip.contains($0.offset) }.map { $0.element }.joined(separator: "\n")
    }

    /// Grupo de audio que se deja por defecto: el que tiene más pistas (idiomas), luego el que usan más variantes y, a igualdad,
    /// el de mejor códec (E-AC-3 antes que AAC; sin Atmos «JOC», que es solo de algunos idiomas). Así la lista de audio es única y
    /// estable: AVPlayer, al cambiar de calidad, saltaba entre grupos y cambiaba el audio o escondía pistas (audiodescripción…).
    /// Devuelve nil si hay un solo grupo.
    public static func autoAudioGroup(_ master: String) -> String? {
        let lines = master.components(separatedBy: "\n")
        var renditions: [String: Int] = [:], joc = Set<String>()
        for l in lines where l.hasPrefix("#EXT-X-MEDIA") && l.contains("TYPE=AUDIO") {
            guard let r = l.range(of: "GROUP-ID=\"[^\"]*\"", options: .regularExpression) else { continue }
            let g = String(l[r].dropFirst(10).dropLast())
            renditions[g, default: 0] += 1
            if l.contains("JOC") { joc.insert(g) }
        }
        guard renditions.count > 1 else { return nil }
        var variants: [String: Int] = [:], rank: [String: Int] = [:]
        for l in lines where l.hasPrefix("#EXT-X-STREAM-INF") {
            guard let r = l.range(of: "AUDIO=\"[^\"]*\"", options: .regularExpression) else { continue }
            let g = String(l[r].dropFirst(7).dropLast())
            variants[g, default: 0] += 1
            let low = l.lowercased()
            rank[g] = max(rank[g] ?? 0, low.contains("ec-3") ? 3 : low.contains("ac-3") ? 2 : 1)
        }
        let best = renditions.keys.max { a, b in
            let ka = (renditions[a] ?? 0, variants[a] ?? 0, (rank[a] ?? 0) - (joc.contains(a) ? 2 : 0))
            let kb = (renditions[b] ?? 0, variants[b] ?? 0, (rank[b] ?? 0) - (joc.contains(b) ? 2 : 0))
            return ka < kb
        }
        return (best.flatMap { variants[$0] } ?? 0) > 0 ? best : nil
    }
}
