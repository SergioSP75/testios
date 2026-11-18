import Foundation

/// Reescribe listas HLS para que AVPlayer lo pida todo al relay local.
///  - Direcciones de listas, segmentos, inicios (EXT-X-MAP) y claves → rutas del relay.
///  - Se quitan las claves SAMPLE-AES-CTR/CBCS (DRM): el relay entrega el vídeo ya descifrado.
///  - Cada segmento lleva la dirección de su inicio (`i`) para encontrar la clave correcta
///    (1080p y ≤720p suelen tener KID distinto: criterio por contenido, nunca por proveedor).
public enum HlsRewriter {

    /// Codifica una URL para ir dentro de la ruta del relay (base64 "URL safe", sin relleno).
    public static func encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> String? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// `true` si la lista es maestra (variantes) y no de segmentos.
    public static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    /// Reescribe `text` (descargada de `base`) para el relay que escucha en `relay` (p. ej. http://127.0.0.1:8123/s1).
    public static func rewrite(_ text: String, base: URL, relay: String) -> String {
        let master = isMaster(text)
        var currentInit: String?
        var out: [String] = []
        // SAMPLE-AES clásico en segmentos TS (sin EXT-X-MAP): el relay descifra cada segmento con esta clave
        var tsKey: (uri: String?, kid: String?, iv: String?)?
        var seq = 0

        func abs(_ u: String) -> String { URL(string: u, relativeTo: base)?.absoluteURL.absoluteString ?? u }
        func route(_ kind: String, _ u: String, extra: String = "") -> String {
            "\(relay)/\(kind)?u=\(encode(abs(u)))\(extra)"
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var nextIsVariant = false
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { seq = Int(t.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0 }
            if t.hasPrefix("#EXT-X-KEY") || t.hasPrefix("#EXT-X-SESSION-KEY") {
                let method = attr(t, "METHOD") ?? ""
                // FairPlay «skd://<base64 JSON>»: lleva KeyId e IV; la clave sale de la lista (ClearKey) por ese KeyId
                if method.uppercased() == "SAMPLE-AES", let u = attr(t, "URI"), u.hasPrefix("skd://"), let info = skdInfo(u) {
                    tsKey = (nil, info.kid, info.iv); continue
                }
                if method.uppercased() == "SAMPLE-AES", let u = attr(t, "URI"), !u.hasPrefix("skd:"),
                   (attr(t, "KEYFORMAT") ?? "identity") == "identity" {
                    tsKey = (abs(u), nil, attr(t, "IV")); continue                   // TS cifrado: se decide al ver si hay EXT-X-MAP
                }
                if method.uppercased().hasPrefix("SAMPLE-AES") { continue }      // DRM: lo descifra el relay
                if method.uppercased() == "AES-128" {
                    out.append(replaceUri(t) { route("key", $0) }); continue     // AES-128 normal: clave por el relay
                }
                out.append(t); continue
            }
            if t.hasPrefix("#EXT-X-MAP") {
                if let u = attr(t, "URI") { currentInit = abs(u) }
                out.append(replaceUri(t) { route("init", $0) }); continue
            }
            if t.hasPrefix("#EXT-X-MEDIA") || t.hasPrefix("#EXT-X-I-FRAME-STREAM-INF") {
                out.append(replaceUri(t) { route("m3u8", $0) }); continue
            }
            if t.hasPrefix("#EXT-X-STREAM-INF") { nextIsVariant = true; out.append(t); continue }
            if t.isEmpty || t.hasPrefix("#") { out.append(line); continue }

            // Línea de dirección
            if master || nextIsVariant {
                out.append(route("m3u8", t)); nextIsVariant = false
            } else if let i = currentInit {
                out.append(route("seg", t, extra: "&i=\(encode(i))"))
            } else if let k = tsKey {
                // IV: el indicado (0x…) o, si falta, el número de secuencia del segmento en 16 bytes
                var iv = (k.iv ?? "").lowercased().replacingOccurrences(of: "0x", with: "")
                if iv.isEmpty { iv = String(repeating: "0", count: 24) + String(format: "%08x", seq) }
                if let ku = k.uri { out.append(route("seg", t, extra: "&k=\(encode(ku))&v=\(iv)")) }
                else { out.append(route("seg", t, extra: "&kid=\(k.kid ?? "")&v=\(iv)")) }
                seq += 1
            } else {
                out.append(route("seg", t))
                seq += 1
            }
        }
        return out.joined(separator: "\n")
    }

    /// Datos de una dirección FairPlay `skd://<base64 de {"ContentId","KeyId","IV"}>`: KeyId (hex sin guiones) e IV (hex).
    static func skdInfo(_ uri: String) -> (kid: String, iv: String?)? {
        var b = String(uri.dropFirst("skd://".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let kid = j["KeyId"] as? String else { return nil }
        var ivHex: String?
        if let iv = j["IV"] as? String, let raw = Data(base64Encoded: iv), raw.count == 16 { ivHex = raw.map { String(format: "%02x", $0) }.joined() }
        return (kid.replacingOccurrences(of: "-", with: "").lowercased(), ivHex)
    }

    // MARK: - Atributos

    /// Valor de un atributo `CLAVE="valor"` o `CLAVE=valor` de una etiqueta HLS.
    static func attr(_ line: String, _ key: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(?:^|[:,])\(key)=(\"[^\"]*\"|[^,]*)") else { return nil }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var v = ns.substring(with: m.range(at: 1))
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v
    }

    private static func replaceUri(_ line: String, _ f: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"") else { return line }
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
        let u = ns.substring(with: m.range(at: 1))
        return ns.replacingCharacters(in: m.range, with: "URI=\"\(f(u))\"")
    }
}

/// Subtítulo suelto (TTML o WebVTT) que acompaña al vídeo, p. ej. los `subs=[…]` de un enlace .strm de Prime.
public struct ExternalSubtitle: Equatable {
    public var url: String
    public var lang: String
    public var name: String
    public var forced: Bool
    public init(url: String, lang: String, name: String, forced: Bool = false) {
        self.url = url; self.lang = lang; self.name = name; self.forced = forced
    }
}

extension HlsRewriter {
    /// Añade a una lista maestra HLS las pistas de subtítulos externos (grupo «subs») y las enlaza en cada variante.
    /// Cada pista es una lista de un solo trozo de `durationSec` segundos que sirve el relay ya convertido a WebVTT.
    public static func addSubtitles(_ master: String, _ subs: [ExternalSubtitle], relay: String, durationSec: Int) -> String {
        if subs.isEmpty || !master.contains("#EXT-X-STREAM-INF") { return master }
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "'") }
        let media = subs.enumerated().map { (i, s) in
            "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(q(s.name))\",LANGUAGE=\"\(q(s.lang))\","
                + "FORCED=\(s.forced ? "YES" : "NO"),DEFAULT=NO,AUTOSELECT=\(s.forced ? "YES" : "NO"),"
                + "URI=\"\(relay)/subpl?u=\(encode(s.url))&d=\(durationSec)&n=\(i)\""
        }
        var out: [String] = []
        var inserted = false
        for line in master.components(separatedBy: "\n") {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                if !inserted { out += media; inserted = true }
                // Sustituye el grupo de subtítulos anterior, si lo había
                var l = line
                if let r = l.range(of: ",SUBTITLES=\"[^\"]*\"", options: .regularExpression) { l.removeSubrange(r) }
                out.append(l + ",SUBTITLES=\"subs\"")
            } else { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}
