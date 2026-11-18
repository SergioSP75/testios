import Foundation

/// Pone en el nombre de cada pista de audio de la lista maestra su idioma, su códec y sus canales
/// («Español · E-AC-3 5.1»), para que el selector de audio del reproductor lo enseñe.
/// AVPlayer escribe el nombre a partir de LANGUAGE (en inglés y sin códec), así que ese atributo se quita
/// y el idioma preferido se marca con DEFAULT=YES para que siga arrancando en el idioma del dispositivo.
public enum AudioLabels {
    public static func annotate(_ master: String, preferLang: String) -> String {
        let nl = "\n"
        let lines = master.components(separatedBy: nl)
        // Códec de cada grupo de audio, según el CODECS de las variantes que lo usan
        var codecOf: [String: String] = [:]
        for l in lines where l.hasPrefix("#EXT-X-STREAM-INF") {
            guard let g = attr(l, "AUDIO"), codecOf[g] == nil, let codecs = attr(l, "CODECS")?.lowercased() else { continue }
            if codecs.contains("ec-3") { codecOf[g] = "E-AC-3" }
            else if codecs.contains("ac-3") { codecOf[g] = "AC-3" }
            else if codecs.contains("ac-4") { codecOf[g] = "AC-4" }
            else if codecs.contains("mp4a") { codecOf[g] = "AAC" }
            else if codecs.contains("opus") { codecOf[g] = "Opus" }
        }
        // La primera pista del idioma preferido de cada grupo es la que arranca (si el grupo no tiene ninguna, se deja como está)
        var defaultDone = Set<String>()
        var out: [String] = []
        for l in lines {
            let audio = l.hasPrefix("#EXT-X-MEDIA") && l.contains("TYPE=AUDIO")
            let subs = l.hasPrefix("#EXT-X-MEDIA") && l.contains("TYPE=SUBTITLES")
            guard audio || subs, let name = attr(l, "NAME"), !name.contains(" · ") else { out.append(l); continue }
            let lang = attr(l, "LANGUAGE") ?? ""
            var line = l
            // Nombre para personas: el código de idioma traducido («es-ES a7» → «Español (España)»); si el nombre ya es legible se respeta
            var shown = LanguageNames.readable(name: name, lang: lang, ui: preferLang)
            if audio {
                var parts: [String] = []
                if l.contains("describes-video"), !shown.lowercased().contains("audio") { parts.append("audiodescripción") }
                if let c = codecOf[attr(l, "GROUP-ID") ?? ""] { parts.append(c) }
                if let ch = attr(l, "CHANNELS") { let t = channelsText(ch); if !t.isEmpty { parts.append(t) } }
                if !parts.isEmpty { shown += " · " + parts.joined(separator: " ") }
            }
            if shown != name { line = replace(line, "NAME", with: shown) }
            if audio, !lang.isEmpty, !preferLang.isEmpty {
                let group = attr(l, "GROUP-ID") ?? ""
                let isPref = lang.lowercased().hasPrefix(preferLang.lowercased()) && !l.contains("describes-video") && !name.lowercased().contains("audio description")
                if isPref, !defaultDone.contains(group) { defaultDone.insert(group); line = setFlag(line, "DEFAULT", "YES") }
                else if line.contains("DEFAULT=YES") { line = setFlag(line, "DEFAULT", "NO") }
            }
            out.append(line)
        }
        return out.joined(separator: nl)
    }

    /// Nombre con códec y canales de cada pista de audio, por «GRUPO|NOMBRE original» (para las ventanas de descarga).
    public static func displayNames(_ master: String, ui: String = "") -> [String: String] {
        let before = master.components(separatedBy: "\n"), after = annotate(master, preferLang: ui).components(separatedBy: "\n")
        var out: [String: String] = [:]
        for (a, b) in zip(before, after) where a.hasPrefix("#EXT-X-MEDIA") && a.contains("TYPE=AUDIO") {
            if let g = attr(a, "GROUP-ID"), let n = attr(a, "NAME"), let m = attr(b, "NAME") { out[g + "|" + n] = m }
        }
        return out
    }

    static func channelsText(_ ch: String) -> String {
        if ch.contains("JOC") { return "Atmos" }
        switch Int(ch.split(separator: "/").first ?? "") ?? 0 {
        case 1: return "mono"
        case 2: return "estéreo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let n where n > 0: return "\(n) canales"
        default: return ""
        }
    }

    static func attr(_ line: String, _ name: String) -> String? {
        guard let r = line.range(of: "(^|[:,])\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        let s = String(line[r])
        guard let q = s.firstIndex(of: "\"") else { return nil }
        return String(s[s.index(after: q)...].dropLast())
    }
    static func replace(_ line: String, _ name: String, with value: String) -> String {
        guard let r = line.range(of: "\(name)=\"[^\"]*\"", options: .regularExpression) else { return line }
        return line.replacingCharacters(in: r, with: "\(name)=\"\(value)\"")
    }
    static func removeAttr(_ line: String, _ name: String) -> String {
        guard let r = line.range(of: ",\(name)=\"[^\"]*\"", options: .regularExpression) else { return line }
        return line.replacingCharacters(in: r, with: "")
    }
    static func setFlag(_ line: String, _ name: String, _ value: String) -> String {
        if let r = line.range(of: "\(name)=(YES|NO)", options: .regularExpression) { return line.replacingCharacters(in: r, with: "\(name)=\(value)") }
        // Sin el atributo: se añade antes de URI, o al final
        if let r = line.range(of: ",URI=") { return line.replacingCharacters(in: r, with: ",\(name)=\(value),URI=") }
        return line + ",\(name)=\(value)"
    }
}
