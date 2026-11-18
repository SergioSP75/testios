import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(Compression)
import Compression
#endif

/// Canal de la guía.
public struct EpgChannel: Equatable {
    public var id: String
    public var displayName: String?
    public var icon: String?
    public var fanart: String?
}

/// Port de XmltvParser.kt: lee guías XMLTV por flujo (SAX), filtrando por ventana de tiempo y por canal
/// antes de guardar, para que guías enormes no llenen la memoria del iPhone.
public enum XmltvParser {

    public struct Stats { public var channels = 0, seen = 0, accepted = 0, skippedByDate = 0, skippedByChannel = 0 }

    public static func parse(_ data: Data, windowStartMs: Int64 = 0, windowEndMs: Int64 = .max,
                             channelAllowed: @escaping (String) -> Bool = { _ in true },
                             onChannel: @escaping (EpgChannel) -> Void,
                             onProgramme: @escaping (EpgProgram, Int64, Int64) -> Void) -> Stats {
        let h = Handler(start: windowStartMs, end: windowEndMs, allowed: channelAllowed, onChannel: onChannel, onProgramme: onProgramme)
        let p = XMLParser(data: data); p.delegate = h; p.parse()
        return h.stats
    }

    private static let maxTitle = 180, maxDesc = 700, maxUrl = 800

    private final class Handler: NSObject, XMLParserDelegate {
        let start: Int64, end: Int64
        let allowed: (String) -> Bool
        let onChannel: (EpgChannel) -> Void
        let onProgramme: (EpgProgram, Int64, Int64) -> Void
        var stats = Stats()

        private var channel: EpgChannel?
        private var prog: EpgProgram?
        private var text = ""
        private var inTitle = false

        init(start: Int64, end: Int64, allowed: @escaping (String) -> Bool,
             onChannel: @escaping (EpgChannel) -> Void, onProgramme: @escaping (EpgProgram, Int64, Int64) -> Void) {
            self.start = start; self.end = end; self.allowed = allowed; self.onChannel = onChannel; self.onProgramme = onProgramme
        }

        private func url(_ attrs: [String: String]) -> String? { attrs["src"] ?? attrs["url"] }

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes a: [String: String]) {
            text = ""
            switch name {
            case "channel": if let id = a["id"] { channel = EpgChannel(id: id) }
            case "programme":
                if let ch = a["channel"] {
                    prog = EpgProgram(channelId: ch, title: "Sin título", start: a["start"] ?? "", stop: a["stop"])
                }
            case "icon", "logo":
                if let s = url(a) { if prog != nil { prog?.icon = String(s.prefix(XmltvParser.maxUrl)) } else { channel?.icon = s } }
            case "image", "poster", "jpg", "thumbnail", "thumb":
                if let s = url(a) { prog?.image = String(s.prefix(XmltvParser.maxUrl)) }
            case "fanart", "banner", "backdrop":
                if let s = url(a) { if prog != nil { prog?.fanart = String(s.prefix(XmltvParser.maxUrl)) } else { channel?.fanart = s } }
            default: break
            }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "display-name": if channel != nil && channel?.displayName == nil { channel?.displayName = t }
            case "title": if prog != nil && !t.isEmpty { prog?.title = String(t.prefix(XmltvParser.maxTitle)) }
            case "desc": if prog != nil { prog?.description = String(t.prefix(XmltvParser.maxDesc)) }
            case "icon", "logo", "image", "poster", "fanart", "banner", "thumb", "thumbnail", "jpg", "backdrop":
                // Variante con la dirección dentro del texto, no en un atributo
                if t.lowercased().hasPrefix("http") {
                    if prog != nil {
                        if ["fanart", "banner", "backdrop"].contains(name) { if prog?.fanart == nil { prog?.fanart = t } }
                        else if name == "icon" { if prog?.icon == nil { prog?.icon = t } }
                        else if prog?.image == nil { prog?.image = t }
                    } else if channel != nil {
                        if channel?.icon == nil && (name == "icon" || name == "logo") { channel?.icon = t }
                    }
                }
            case "channel":
                if let c = channel { stats.channels += 1; onChannel(c) }
                channel = nil
            case "programme":
                if let pr = prog {
                    stats.seen += 1
                    let s = EpgTime.parseMillis(pr.start)
                    let e = EpgTime.parseMillis(pr.stop) ?? ((s ?? 0) + 3_600_000)
                    if let s = s, e >= start, s <= end {
                        if allowed(pr.channelId) { stats.accepted += 1; onProgramme(pr, s, e) } else { stats.skippedByChannel += 1 }
                    } else { stats.skippedByDate += 1 }
                }
                prog = nil
            default: break
            }
            text = ""
        }
    }
}

/// Descompresión de guías .xml.gz (iOS/macOS: framework Compression; en otros sistemas no se usa).
public enum Gzip {
    public static func isGzip(_ d: Data) -> Bool { d.count > 2 && d[d.startIndex] == 0x1f && d[d.startIndex + 1] == 0x8b }

    /// CRC-32 (el que exige el pie de un fichero gzip).
    public static func crc32(_ d: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[i] = c }
        var crc: UInt32 = 0xFFFFFFFF
        for b in d { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    /// Comprime en gzip (cabecera de 10 bytes + deflate + CRC-32 + tamaño). Lo pide la transferencia de listas, que va en gzip como en Android.
    public static func compress(_ d: Data) throws -> Data {
        #if canImport(Compression)
        let raw = try (d as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(raw)
        for v in [crc32(d), UInt32(truncatingIfNeeded: d.count)] { out.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) }) }
        return out
        #else
        throw NSError(domain: "Gzip", code: 2, userInfo: [NSLocalizedDescriptionKey: "gzip no disponible en este sistema"])
        #endif
    }

    /// Devuelve los datos descomprimidos, o los mismos datos si no eran gzip.
    public static func decompress(_ d: Data) throws -> Data {
        guard isGzip(d) else { return d }
        #if canImport(Compression)
        let b = [UInt8](d)
        var p = 10
        let flags = b[3]
        if flags & 4 != 0 { p += 2 + Int(b[p]) + Int(b[p + 1]) << 8 }          // FEXTRA
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 } // FNAME
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 } // FCOMMENT
        if flags & 2 != 0 { p += 2 }                                            // FHCRC
        guard p < b.count - 8 else { throw NSError(domain: "Gzip", code: 1) }
        let raw = Data(b[p..<(b.count - 8)])                                    // deflate sin cabecera ni CRC
        return try (raw as NSData).decompressed(using: .zlib) as Data
        #else
        throw NSError(domain: "Gzip", code: 2, userInfo: [NSLocalizedDescriptionKey: "gzip no disponible en este sistema"])
        #endif
    }
}
