import Foundation

/// Port de OtcParser.kt: listas en formato OTC (JSON de OTT Navigator).
/// Devuelve el mismo resultado que las M3U, así el resto de la app no distingue el origen.
/// Las entradas type=movie/series se saltan (van a la biblioteca de medios).
public enum OtcParser {

    public static func looksLikeOtc(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        return t.hasPrefix("{") && t.contains("\"channels\"")
    }

    public static func parse(_ raw: String, language: String = Locale.current.languageCode ?? "es") -> M3uParseResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FEFF}", with: "")
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return M3uParseResult(channels: [], epgUrl: nil, vodLibraries: [])
        }
        let provider = root["provider"] as? [String: Any] ?? [:]
        let b64 = Set(String(describing: provider["base64"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })

        /// Decodifica un campo si el proveedor lo declara en base64.
        func dec(_ field: String, _ v: String) -> String {
            guard b64.contains("*") || b64.contains(field.lowercased()),
                  let d = Data(base64Encoded: v, options: .ignoreUnknownCharacters),
                  let s = String(data: d, encoding: .utf8) else { return v }
            return s
        }
        func str(_ o: [String: Any], _ f: String) -> String? {
            guard let v = o[f], !(v is NSNull) else { return nil }
            let s = dec(f, "\(v)")
            return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
        }
        func num(_ o: [String: Any], _ f: String) -> Int64? {
            guard let v = o[f], !(v is NSNull), let d = Double("\(v)".trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int64(d)
        }
        func list(_ o: [String: Any], _ f: String) -> [String] {
            guard let v = o[f] else { return [] }
            let items: [String] = (v as? [Any]).map { $0.map { "\($0)" } }
                ?? "\(v)".components(separatedBy: CharacterSet(charactersIn: ";,"))
            return items.map { dec(f, $0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
        }
        func urls(_ o: [String: Any], _ f: String) -> [String] { list(o, f).filter { $0.lowercased().hasPrefix("http") } }

        var cats: [String: String] = [:]
        for (id, c) in (root["categories"] as? [String: Any] ?? [:]) {
            guard let o = c as? [String: Any] else { continue }
            if let n = str(o, "name:\(language)") ?? str(o, "name") { cats[id] = n }
        }

        let epg = urls(provider, "epg").first
        var seen = Set<String>()
        let vod = urls(provider, "vod_library").filter { seen.insert($0).inserted }
        let provType = str(provider, "archive_type")
        let provDays = num(provider, "archive_days").map { String($0) }

        var channels: [IptvChannel] = []
        var skippedVod = 0
        for case let c as [String: Any] in (root["channels"] as? [Any] ?? []) {
            let type = str(c, "type")?.lowercased()
            if type == "movie" || type == "series" { skippedVod += 1; continue }
            guard let url = str(c, "url"), let name = str(c, "name:\(language)") ?? str(c, "name") else { continue }

            var headers: [String: String] = [:]
            if let h = c["headers"] as? [String: Any] {
                for (k, v) in h { headers[k] = dec("headers", "\(v)") }
            } else if let h = c["headers"] as? String {
                for p in dec("headers", h).components(separatedBy: "&") {
                    let k = (p.components(separatedBy: "=").first ?? "").trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty {
                        headers[k] = p.components(separatedBy: "=").dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            if let ua = str(c, "user_agent") { headers["User-Agent"] = ua }
            if let rf = str(c, "referrer") { headers["Referer"] = rf }

            let drmType = str(c, "drm_type")?.lowercased()
            var rawKey: String?
            if let k = c["drm_key"] {
                if let o = k as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: o) { rawKey = String(data: d, encoding: .utf8) }
                else { rawKey = dec("drm_key", "\(k)") }
            }
            let keys = parseKeys(rawKey)
            let licenseUrl = str(c, "drm_url")
            var fmt = str(c, "source_format")?.lowercased()
            if fmt == "dash" { fmt = "mpd" }

            var drm: DrmMode = .none
            if drmType?.contains("widevine") == true { drm = .widevine }
            else if drmType?.contains("playready") == true { drm = .playready }
            else if drmType?.contains("clearkey") == true || !keys.isEmpty { drm = .clearkey }
            else if licenseUrl != nil { drm = .widevine }

            var keyJson: String?
            if !keys.isEmpty, let d = try? JSONSerialization.data(withJSONObject: keys), let s = String(data: d, encoding: .utf8) {
                keyJson = KodiPropParser.normalizeClearKeyToJson(s)
            }
            let epgId = str(c, "epg_id")
            let group = str(c, "category").map { cats[$0] ?? $0 }

            // epg_shift: horas enteras de -12 a 12; si no, segundos
            let shift = num(c, "epg_shift").map { (-12...12).contains($0) ? $0 * 3600 : $0 }
            var opts = OtcChannelOpts()
            opts.number = num(c, "number").map { Int($0) }; opts.isRadio = type == "radio"; opts.epgShiftSec = shift
            opts.codec = list(c, "codec"); opts.audioTrack = num(c, "audio_track").map { Int($0) }
            opts.videoTrack = str(c, "video_track"); opts.blAudio = list(c, "bl_audio_track"); opts.blVideo = list(c, "bl_video_track")
            opts.runtimeAttrUrl = str(c, "runtime_attr_url"); opts.seekPreview = str(c, "seek_preview"); opts.drmData = str(c, "drm_data")

            let archiveDays = num(c, "archive_days").map { String($0) } ?? provDays
            let hasArchive = str(c, "archive_source") != nil || provType != nil
            channels.append(IptvChannel(
                id: M3uParser.stableId(epgId, name, url), name: name, url: url, group: group,
                tvgId: epgId, tvgName: str(c, "epg_name"), m3uLogo: str(c, "icon"),
                catchup: hasArchive ? (provType ?? "default") : nil,
                catchupSource: str(c, "archive_source"), catchupDays: archiveDays,
                userAgent: headers["User-Agent"], referrer: headers["Referer"], httpHeaders: headers,
                clearKeys: keys, clearKeyJson: keyJson, manifestType: fmt, licenseType: drmType, licenseUrl: licenseUrl,
                drmMode: drm, fromIsmlList: M3uParser.isIsmlUrl(url), otc: opts))
        }
        // Con números de canal se respeta ese orden (los que no tienen, al final y en su orden)
        var ordered = channels
        if channels.contains(where: { $0.otc?.number != nil }) {
            ordered = channels.enumerated().sorted {
                let a = $0.element.otc?.number ?? Int.max, b = $1.element.otc?.number ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map { $0.element }
        }

        var meta: [String: String] = ["canales": String(ordered.count)]
        if skippedVod > 0 { meta["vod_omitidos"] = String(skippedVod) }
        if let v = num(provider, "max_connections") { meta["max_connections"] = String(v) }
        if let v = num(provider, "billed_till") { meta["billed_till"] = String(v) }
        if let v = str(provider, "user_message") { meta["user_message"] = v }
        if let v = num(provider, "refresh_minutes") { meta["refresh_minutes"] = String(v) }
        if let v = str(provider, "refresh_at") { meta["refresh_at"] = v }
        if let v = provType { meta["archive_type"] = v }
        if let v = provDays { meta["archive_days"] = v }

        var uniq = Set<String>()
        let unique = ordered.filter { uniq.insert($0.id + $0.url).inserted }
        return M3uParseResult(channels: unique, epgUrl: epg, vodLibraries: vod, meta: meta)
    }

    /// drm_key: «kid:key», «kid1:key1,kid2:key2», {"kid":"key"} o conjunto JWK ({"keys":[{kid,k}]}).
    static func parseKeys(_ raw: String?) -> [String: String] {
        let r = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if r.isEmpty { return [:] }
        if r.hasPrefix("{") && r.contains("\"keys\""),
           let d = r.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let arr = o["keys"] as? [[String: Any]] {
            func hex(_ b64: String) -> String? {
                var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while s.count % 4 != 0 { s += "=" }
                return Data(base64Encoded: s).map { $0.map { String(format: "%02x", $0) }.joined() }
            }
            var out: [String: String] = [:]
            for k in arr {
                if let kid = (k["kid"] as? String).flatMap(hex), let key = (k["k"] as? String).flatMap(hex) { out[kid] = key }
            }
            if !out.isEmpty { return out }
        }
        return parseClearKeysHexMap(r)
    }
}
