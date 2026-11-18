import Foundation

// Port de KodiPropParser.kt: lee líneas #KODIPROP y convierte claves ClearKey.
public enum KodiPropParser {

    /// "#KODIPROP:clave=valor" → (clave, valor). nil si no hay "=".
    public static func parseLine(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = body[..<eq].trimmingCharacters(in: .whitespaces)
        let value = unquote(String(body[body.index(after: eq)...]))
        return (key, decodeEscaped(value))
    }

    /// "Host=x&Origin=y" (o separado por "|") → cabeceras HTTP.
    public static func parseStreamHeaders(_ value: String) -> [String: String] {
        let decoded = decodeEscaped(value.trimmingCharacters(in: .whitespaces))
        let parts: [String]
        if decoded.contains("&") { parts = decoded.components(separatedBy: "&") }
        else if decoded.contains("|") { parts = decoded.components(separatedBy: "|") }
        else { parts = [decoded] }
        var result: [String: String] = [:]
        for part0 in parts {
            let part = part0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = decodeUrlSafe(part[..<eq].trimmingCharacters(in: .whitespaces))
            let headerValue = decodeUrlSafe(unquote(String(part[part.index(after: eq)...])))
            if !headerValue.trimmingCharacters(in: .whitespaces).isEmpty { result[name] = headerValue }
        }
        return result
    }

    /// Escapes \xNN, \n, \t, \r, \\ y \" de las listas.
    public static func decodeEscaped(_ input: String) -> String {
        if input.trimmingCharacters(in: .whitespaces).isEmpty { return input }
        let chars = Array(input)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "x" && i + 3 < chars.count,
                   let code = UInt32(String(chars[i + 2...i + 3]), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.unicodeScalars.append(scalar); i += 4
                } else if n == "n" { out.append("\n"); i += 2 }
                else if n == "t" { out.append("\t"); i += 2 }
                else if n == "r" { out.append("\r"); i += 2 }
                else if n == "\\" { out.append("\\"); i += 2 }
                else if n == "\"" { out.append("\""); i += 2 }
                else { out.append(c); i += 1 }
            } else { out.append(c); i += 1 }
        }
        return out
    }

    /// Hexadecimal → Base64 "URL safe" sin relleno (formato JWK de ClearKey).
    public static func hexToBase64Url(_ hex: String) -> String? {
        let clean = hex.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
        guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
        var bytes = [UInt8]()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(b); idx = next
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Convierte la clave de la lista a JSON ClearKey {"keys":[{kty,kid,k}],"type":"temporary"}.
    public static func normalizeClearKeyToJson(_ raw: String?) -> String? {
        let value = decodeEscaped((raw ?? "").trimmingCharacters(in: .whitespaces))
            .trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }

        var keys: [[String: String]] = []

        if value.hasPrefix("{") && !value.contains("\"keys\"") {
            // {"kidHex":"keyHex"}
            // org.json de Android acepta llaves sin comillas ({kid:key}); JSONSerialization no.
            // Si el JSON estricto falla, se lee con el parser tolerante de claves.
            var obj: [String: Any]
            if let data = value.data(using: .utf8),
               let strict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj = strict
            } else {
                obj = parseClearKeysHexMap(value).mapValues { $0 as Any }
            }
            if obj.isEmpty { return nil }
            for (kidHex, v) in obj.sorted(by: { $0.key < $1.key }) {
                guard let keyHex = v as? String,
                      let kid = hexToBase64Url(kidHex.trimmingCharacters(in: .whitespaces)),
                      let k = hexToBase64Url(keyHex.trimmingCharacters(in: .whitespaces)) else { return nil }
                keys.append(["kty": "oct", "kid": kid, "k": k])
            }
            if keys.isEmpty { return nil }
        } else if value.hasPrefix("{") {
            // Ya viene como {"keys":[...]}
            guard let data = value.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["keys"] as? [[String: Any]] else { return nil }
            for item in arr {
                guard let kid = normalizeKidOrKey(item["kid"] as? String ?? ""),
                      let k = normalizeKidOrKey(item["k"] as? String ?? "") else { return nil }
                keys.append(["kty": "oct", "kid": kid, "k": k])
            }
        } else {
            var cleaned = value
            for prefix in ["clearkey:", "org.w3.clearkey:"] where cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            var pair: [String] = []
            for sep in [":", "=", ","] where cleaned.contains(sep) {
                pair = cleaned.components(separatedBy: sep)
                if pair.count > 2 { pair = [pair[0], pair.dropFirst().joined(separator: sep)] }
                break
            }
            guard pair.count == 2,
                  let kid = normalizeKidOrKey(pair[0]), let k = normalizeKidOrKey(pair[1]) else { return nil }
            keys.append(["kty": "oct", "kid": kid, "k": k])
        }

        let out: [String: Any] = ["keys": keys, "type": "temporary"]
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Ayudas privadas

    private static func normalizeKidOrKey(_ raw: String) -> String? {
        let v = unquote(decodeEscaped(raw.trimmingCharacters(in: .whitespaces)))
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        if v.isEmpty { return nil }
        if v.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil { return hexToBase64Url(v) }
        if v.range(of: "^[A-Za-z0-9_\\-+/=]{20,64}$", options: .regularExpression) != nil {
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return nil
    }

    private static func unquote(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        for q in ["\"", "'"] where s.count >= 2 && s.hasPrefix(q) && s.hasSuffix(q) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func decodeUrlSafe(_ v: String) -> String { v.removingPercentEncoding ?? v }
}
