import Foundation

/// Programa de la guía (EPG).
public struct EpgProgram: Codable, Equatable {
    public var channelId: String
    public var title: String
    public var description: String?
    public var start: String
    public var stop: String?
    public var icon: String?
    public var image: String?
    public var fanart: String?
    public init(channelId: String, title: String, description: String? = nil, start: String, stop: String? = nil,
                icon: String? = nil, image: String? = nil, fanart: String? = nil) {
        self.channelId = channelId; self.title = title; self.description = description
        self.start = start; self.stop = stop; self.icon = icon; self.image = image; self.fanart = fanart
    }
    public var bestImage: String? {
        for s in [fanart, image, icon] { if let s = s, !s.isEmpty { return s } }
        return nil
    }
}

/// Port de CatchupUrlBuilder.kt: construye la URL de catchup sustituyendo las etiquetas estándar
/// (${start}, {utc}, ${start-year}… de OTT Navigator, [start]…).
public enum CatchupUrlBuilder {

    public struct Result {
        public let allowed: Bool
        public let url: String?
        public let reason: String
        public let channel: IptvChannel?
    }

    /// `now` se puede fijar en las pruebas.
    public static func build(channel: IptvChannel, program: EpgProgram, now: Date = Date(),
                             timeZone: TimeZone = .current) -> Result {
        guard let startMs = EpgTime.parseMillis(program.start) else {
            return Result(allowed: false, url: nil, reason: "No se pudo interpretar la fecha de inicio EPG", channel: nil)
        }
        guard let stopMs = EpgTime.parseMillis(program.stop) else {
            return Result(allowed: false, url: nil, reason: "No se pudo interpretar la fecha de fin EPG", channel: nil)
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if startMs >= nowMs { return Result(allowed: false, url: nil, reason: "Programa aún no emitido", channel: nil) }
        if (channel.catchup ?? "").isEmpty && (channel.catchupSource ?? "").isEmpty {
            return Result(allowed: false, url: nil, reason: "El canal no tiene catchup-source en la lista M3U", channel: nil)
        }

        let startUnix = startMs / 1000, endUnix = stopMs / 1000
        let duration = max(endUnix - startUnix, 1)
        let offset = max((nowMs - startMs) / 1000, 0)

        func fmt(_ ms: Int64, _ pattern: String, utc: Bool) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            f.timeZone = utc ? TimeZone(identifier: "UTC") : timeZone
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        func enc(_ v: String) -> String {
            // Igual que URLEncoder de Java: solo letras, cifras y .-*_ sin codificar
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: ".-*_")
            return v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
        }

        let utcCmp = fmt(startMs, "yyyyMMddHHmmss", utc: true)
        let utcIso = fmt(startMs, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true)
        let endUtcIso = fmt(stopMs, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true)
        let lutc = fmt(startMs, "yyyyMMddHHmmss", utc: false)
        let channelId = enc(channel.tvgId ?? channel.tvgName ?? channel.name)

        let template = (channel.catchupSource?.isEmpty == false) ? channel.catchupSource! : inferTemplate(channel)
        var out = template

        func replace(_ tags: [String], _ value: String) { for t in tags { out = out.replacingOccurrences(of: t, with: value) } }
        replace(["${start}", "${begin}", "${timestamp}", "{start}", "{begin}", "{timestamp}", "[start]", "[begin]", "[timestamp]"], String(startUnix))
        replace(["${end}", "${stop}", "{end}", "{stop}", "[end]", "[stop]"], String(endUnix))
        replace(["${duration}", "{duration}", "[duration]"], String(duration))
        replace(["${offset}", "{offset}", "[offset]"], String(offset))
        replace(["${start_iso}", "{start_iso}", "[start_iso]"], utcIso)
        replace(["${end_iso}", "{end_iso}", "[end_iso]"], endUtcIso)
        replace(["${utciso}", "{utciso}", "${iso}", "{iso}"], enc(utcIso))
        replace(["${utc}", "{utc}", "[utc]", "{utc:YmdHMS}"], utcCmp)
        replace(["${lutc}", "{lutc}", "[lutc]", "${local}", "{local}"], lutc)

        // Etiquetas por partes de OTT Navigator (listas OTC), siempre en UTC
        for (prefix, ms) in [("start", startMs), ("end", stopMs)] {
            let parts = fmt(ms, "yyyy-MM-dd-HH-mm-ss", utc: true).components(separatedBy: "-")
            for (i, name) in ["year", "mon", "day", "hour", "min", "sec"].enumerated() {
                out = out.replacingOccurrences(of: "${\(prefix)-\(name)}", with: parts[i])
                    .replacingOccurrences(of: "{\(prefix)-\(name)}", with: parts[i])
            }
        }
        replace(["${channel}", "{channel}", "[channel]"], channelId)

        let finalUrl: String
        if out.lowercased().hasPrefix("http") {
            finalUrl = out
        } else if out.hasPrefix("?") || out.hasPrefix("&") {
            let base = channel.url.components(separatedBy: "?").first ?? channel.url
            let existing = channel.url.contains("?") ? channel.url.components(separatedBy: "?").dropFirst().joined(separator: "?") : ""
            let tail = String(out.drop(while: { $0 == "?" || $0 == "&" }))
            finalUrl = existing.isEmpty ? base + out : "\(base)?\(existing)&\(tail)"
        } else {
            finalUrl = channel.url + (channel.url.contains("?") ? "&" : "?") + out
        }

        // Mismas cabeceras, claves y licencia que el directo
        var ch = channel
        ch.url = finalUrl; ch.catchup = nil; ch.catchupSource = nil
        return Result(allowed: true, url: finalUrl, reason: "Catchup: \(program.title)", channel: ch)
    }

    private static func inferTemplate(_ channel: IptvChannel) -> String {
        let type = (channel.catchup ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if type.contains("flussonic") || type.contains("fs") {
            let base = (channel.url.components(separatedBy: "?").first ?? channel.url)
            return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/timeshift_abs-${start}.m3u8"
        }
        if type.contains("shift") { return "?utc=${utc}&lutc=${lutc}" }
        if type.contains("xc") || type.contains("xtream") { return "?start=${start}&duration=${duration}" }
        if type.contains("append") { return "?utc=${utc}&lutc=${lutc}" }
        return "?begin=${start}&end=${end}"
    }
}
