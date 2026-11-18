import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Port de M3uParser.kt. Lee listas IPTV con #EXTINF, #KODIPROP y #EXTVLCOPT.
// Pendiente de portar: listas OTC (OtcParser) y catchup.
public enum M3uParser {

    public static func parse(_ raw: String) -> M3uParseResult {
        if OtcParser.looksLikeOtc(raw) { return OtcParser.parse(raw) }   // lista OTC (JSON de OTT Navigator)
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var channels: [IptvChannel] = []
        var epgUrl: String?
        var vodLibraries: [String] = []

        var currentInfo: String?
        var currentName: String?          // nombre del PRIMER #EXTINF (no se sobreescribe)
        var pendingHeaders: [String: String] = [:]
        var pendingKodiProps: [(key: String, value: String)] = []
        var pendingUserAgent: String?
        var pendingReferrer: String?

        func reset() {
            currentInfo = nil; currentName = nil
            pendingHeaders = [:]; pendingKodiProps = []
            pendingUserAgent = nil; pendingReferrer = nil
        }
        func kodiValue(endingWith suffix: String) -> String? {
            pendingKodiProps.first { $0.key.lowercased().hasSuffix(suffix) }?.value
        }

        for line0 in text.components(separatedBy: "\n") {
            let line = line0.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()

            if lower.hasPrefix("#extm3u") {
                epgUrl = extractAttr(line, "url-tvg") ?? extractAttr(line, "x-tvg-url")
                if let v = extractAttr(line, "vod_library") { vodLibraries = splitVodLibraries(v) }

            } else if lower.hasPrefix("#extinf") {
                if let info = currentInfo {
                    // Segundo EXTINF seguido: fusionar atributos, conservar el nombre del primero
                    let extra = afterFirst(":", in: afterFirst("#EXTINF", in: line))
                    currentInfo = info + " " + extra.trimmingCharacters(in: .whitespaces)
                } else {
                    currentInfo = line
                    let name = afterLast(",", in: line).trimmingCharacters(in: .whitespaces)
                    currentName = (name.isEmpty || name.hasPrefix("type=") || name.hasPrefix("content-type=")) ? nil : name
                }

            } else if lower.hasPrefix("#extvlcopt") {
                let body = afterFirst(":", in: line).trimmingCharacters(in: .whitespaces)
                let key = beforeFirst("=", in: body).trimmingCharacters(in: .whitespaces).lowercased()
                var valueRaw = afterFirst("=", in: body).trimmingCharacters(in: .whitespaces)
                if valueRaw.count >= 2, valueRaw.hasPrefix("\""), valueRaw.hasSuffix("\"") {
                    valueRaw = String(valueRaw.dropFirst().dropLast())
                }
                let value = KodiPropParser.decodeEscaped(valueRaw)
                if key == "http-user-agent" || key == "http-useragent" {
                    pendingUserAgent = value; pendingHeaders["User-Agent"] = value
                } else if key == "http-referrer" || key == "http-referer" {
                    pendingReferrer = value; pendingHeaders["Referer"] = value
                } else if key.hasPrefix("http-") {
                    // Otra cabecera: http-origin → Origin, http-cookie → Cookie…
                    let name = key.dropFirst(5).split(separator: "-")
                        .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
                    if !value.isEmpty { pendingHeaders[name] = value }
                }

            } else if lower.hasPrefix("#kodiprop") {
                guard let (rawKey, value) = KodiPropParser.parseLine(line) else { continue }
                let key = rawKey.lowercased()
                pendingKodiProps.append((rawKey, value))
                if key.hasSuffix("stream_headers") {
                    pendingHeaders.merge(KodiPropParser.parseStreamHeaders(value)) { _, new in new }
                } else if key.hasSuffix("user-agent") || key.hasSuffix("user_agent") {
                    pendingUserAgent = value; pendingHeaders["User-Agent"] = value
                } else if key.hasSuffix("http-origin") || key.hasSuffix("http_origin") {
                    pendingHeaders["Origin"] = value
                }

            } else if !line.hasPrefix("#"), let info = currentInfo {
                let attrs = parseAttributes(info)
                let infoName = afterLast(",", in: info).trimmingCharacters(in: .whitespaces)
                let validInfoName = (infoName.isEmpty || infoName.hasPrefix("type=") || infoName.hasPrefix("content-type=")) ? nil : infoName
                let name = nonBlank(currentName) ?? nonBlank(validInfoName)
                    ?? nonBlank(attrs["tvg-name"]) ?? nonBlank(attrs["tvg-id"]) ?? "Canal"
                let url = line

                let licenseType = kodiValue(endingWith: "license_type")
                let licenseKey = kodiValue(endingWith: "license_key")
                let manifestType = kodiValue(endingWith: "manifest_type")

                var licenseUrl: String?
                var clearKeys: [String: String] = [:]
                var clearKeyJson: String?
                if let k = licenseKey, k.lowercased().hasPrefix("http") {
                    licenseUrl = k
                } else {
                    clearKeys = parseClearKeysHexMap(licenseKey)
                    clearKeyJson = KodiPropParser.normalizeClearKeyToJson(licenseKey)
                }

                // Sublista: solo el atributo exacto type / content-type = "playlist"
                let typeAttr = (attrs["type"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                let ctypeAttr = (attrs["content-type"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if typeAttr == "playlist" || ctypeAttr == "playlist" {
                    let groupTitle = nonBlank(attrs["group-title"])
                    let groupName = groupTitle ?? nonBlank(currentName) ?? "Grupo"
                    let directUrl = url.replacingOccurrences(of: "dl=0", with: "dl=1")
                    channels.append(IptvChannel(
                        id: stableId(nonBlank(attrs["tvg-id"]), groupName, directUrl),
                        name: groupName, url: directUrl, group: groupTitle,
                        m3uLogo: nonBlank(attrs["tvg-logo"]),
                        isPlaylistGroup: true, nestedUrl: directUrl))
                    reset()
                    continue
                }

                // Modo DRM
                let lic = licenseType?.lowercased().trimmingCharacters(in: .whitespaces)
                var drm: DrmMode = .none
                if lic == "fairplay" { drm = .fairplay }
                else if lic?.contains("widevine") == true { drm = .widevine }
                else if lic?.contains("playready") == true { drm = .playready }
                else if lic?.contains("clearkey") == true || lic == "clear" { drm = .clearkey }
                else if !clearKeys.isEmpty || clearKeyJson != nil { drm = .clearkey }
                if licenseUrl != nil && drm != .fairplay && drm != .playready { drm = .widevine }

                // Cabeceras sueltas dentro de cualquier KODIPROP "…header…"
                for (k, v) in pendingKodiProps where k.lowercased().contains("header") {
                    pendingHeaders.merge(KodiPropParser.parseStreamHeaders(v)) { _, new in new }
                }

                let catchupSource = attrs["catchup-source"]
                    ?? pendingKodiProps.first { $0.key.lowercased().contains("catchup") }?.value

                var props: [String: String] = [:]
                for (k, v) in pendingKodiProps { props[k] = v }

                channels.append(IptvChannel(
                    id: stableId(attrs["tvg-id"], name, url),
                    name: name, url: url, group: attrs["group-title"],
                    tvgId: nonBlank(attrs["tvg-id"]), tvgName: nonBlank(attrs["tvg-name"]),
                    m3uLogo: attrs["tvg-logo"], catchup: attrs["catchup"],
                    catchupSource: catchupSource,
                    catchupDays: attrs["catchup-days"] ?? attrs["timeshift"],
                    userAgent: pendingUserAgent ?? pendingHeaders["User-Agent"],
                    referrer: pendingReferrer ?? pendingHeaders["Referer"],
                    httpHeaders: pendingHeaders, kodiProps: props,
                    clearKeys: clearKeys, clearKeyJson: clearKeyJson,
                    manifestType: manifestType, licenseType: licenseType, licenseUrl: licenseUrl,
                    drmMode: drm, fromIsmlList: isIsmlUrl(url)))
                reset()
            }
        }

        // Quitar duplicados exactos (mismo id y url)
        var seen = Set<String>()
        let unique = channels.filter { seen.insert($0.id + $0.url).inserted }
        return M3uParseResult(channels: unique, epgUrl: epgUrl, vodLibraries: vodLibraries)
    }

    // MARK: - Ayudas

    /// URL live de lista isml: …/index.isml/Manifest, …/canal.ism/…
    public static func isIsmlUrl(_ url: String) -> Bool {
        let path = beforeFirst("?", in: url).lowercased()
        return path.contains(".isml") || path.contains(".ism/")
    }

    /// vod_library: varias URLs separadas por coma.
    public static func splitVodLibraries(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http") }
            .filter { seen.insert($0).inserted }
    }

    /// Atributo key="valor" o key=valor de una línea.
    private static func extractAttr(_ line: String, _ key: String) -> String? {
        let k = NSRegularExpression.escapedPattern(for: key)
        if let v = firstGroup("\(k)=\"([^\"]+)\"", in: line) { return nonBlank(v.trimmingCharacters(in: .whitespaces)) }
        if let v = firstGroup("\(k)=([^\\s>]+)", in: line) { return nonBlank(v.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Todos los atributos de un #EXTINF, con la clave en minúsculas.
    private static func parseAttributes(_ extinf: String) -> [String: String] {
        var result: [String: String] = [:]
        for m in allMatches("([A-Za-z0-9_-]+)=\"([^\"]*)\"", in: extinf) {
            result[m[0].lowercased()] = KodiPropParser.decodeEscaped(m[1])
        }
        for m in allMatches("([A-Za-z0-9_-]+)=([^\"\\s,]+)", in: extinf) {
            let k = m[0].lowercased()
            if result[k] == nil { result[k] = KodiPropParser.decodeEscaped(m[1]) }
        }
        return result
    }

    /// Identificador estable: SHA-256 (12 primeros bytes en hex), igual que en Android.
    static func stableId(_ tvgId: String?, _ name: String, _ url: String) -> String {
        let base = nonBlank(tvgId) ?? "\(name)|\(url)"
        let data = Data(base.utf8)
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        #else
        // Sin CryptoKit (Windows/Linux, solo pruebas): FNV-1a de 64 bits repetido.
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx%08llx", h, h >> 32)
        #endif
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s = s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
    private static func afterFirst(_ sep: String, in s: String) -> String {
        guard let r = s.range(of: sep) else { return "" }
        return String(s[r.upperBound...])
    }
    private static func afterLast(_ sep: String, in s: String) -> String {
        guard let r = s.range(of: sep, options: .backwards) else { return "" }
        return String(s[r.upperBound...])
    }
    private static func beforeFirst(_ sep: String, in s: String) -> String {
        guard let r = s.range(of: sep) else { return s }
        return String(s[..<r.lowerBound])
    }
    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        allMatches(pattern, in: s, options: [.caseInsensitive]).first?.first
    }
    private static func allMatches(_ pattern: String, in s: String,
                                   options: NSRegularExpression.Options = []) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }
}

/// {kid:key}, {"kid":"key"} o kid:key → mapa hexadecimal en minúsculas (solo claves de 32 hex).
public func parseClearKeysHexMap(_ licenseKey: String?) -> [String: String] {
    guard let raw = licenseKey?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return [:] }
    var map: [String: String] = [:]

    // JSON estándar
    if let data = raw.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for (k, v) in obj { if let s = v as? String { map[k.lowercased()] = s.lowercased() } }
        if !map.isEmpty { return map }
    }

    var cleaned = raw
    if cleaned.hasPrefix("{") && cleaned.hasSuffix("}") { cleaned = String(cleaned.dropFirst().dropLast()) }
    let pairs: [String]
    if cleaned.contains("&") { pairs = cleaned.components(separatedBy: "&") }
    else if cleaned.contains(",") { pairs = cleaned.components(separatedBy: ",") }
    else { pairs = [cleaned] }

    for pair in pairs {
        let p = pair.trimmingCharacters(in: .whitespaces)
        let sep: String
        if p.contains(":") { sep = ":" } else if p.contains("=") { sep = "=" } else { continue }
        let parts = p.components(separatedBy: sep)
        guard parts.count >= 2 else { continue }
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).lowercased()
                .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        }
        let kid = clean(parts[0]), key = clean(parts.dropFirst().joined(separator: sep))
        let hex = "^[0-9a-f]{32}$"
        if kid.range(of: hex, options: .regularExpression) != nil,
           key.range(of: hex, options: .regularExpression) != nil { map[kid] = key }
    }
    return map
}
