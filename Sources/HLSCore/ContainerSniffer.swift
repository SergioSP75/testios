import Foundation

/// Reconoce el contenedor de un fichero por sus primeros bytes. La extensión de la dirección no es de fiar
/// (hay servidores que llaman «.mkv» a un MP4); el contenido manda.
public enum ContainerSniffer {

    /// Extensión canónica del contenedor («mp4», «mkv», «webm», «avi», «wav», «flac», «ogg», «mp3», «ts», «flv», «asf», «mpg», «aac», «m3u8»…) o nil.
    public static func `extension`(of head: Data) -> String? {
        let b = [UInt8](head.prefix(4096))
        guard b.count >= 4 else { return nil }
        func at(_ i: Int, _ s: String) -> Bool { let u = Array(s.utf8); return b.count >= i + u.count && Array(b[i..<i + u.count]) == u }
        if StreamSniffer.isMatroska(head) {
            // WebM = Matroska con DocType «webm»
            let text = String(decoding: b.prefix(64), as: UTF8.self)
            return text.contains("webm") ? "webm" : "mkv"
        }
        if at(4, "ftyp") {
            let brand = String(decoding: b[8..<min(12, b.count)], as: UTF8.self)
            if brand == "qt  " { return "mov" }
            if brand.hasPrefix("M4A") || brand == "M4B " { return "m4a" }
            return "mp4"
        }
        if at(0, "RIFF"), b.count >= 12 { return at(8, "AVI ") ? "avi" : (at(8, "WAVE") ? "wav" : nil) }
        if at(0, "fLaC") { return "flac" }
        if at(0, "OggS") { return "ogg" }
        if at(0, "FLV") { return "flv" }
        if at(0, "#EXTM3U") { return "m3u8" }
        if b.count >= 16, Array(b[0..<4]) == [0x30, 0x26, 0xB2, 0x75] { return "asf" }          // cabecera ASF/WMV/WMA
        if Array(b[0..<4]) == [0x00, 0x00, 0x01, 0xBA] { return "mpg" }                         // MPEG-PS
        if at(0, "ID3") { return "mp3" }
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 {
            return (b[1] & 0x06) == 0 ? "aac" : "mp3"                                           // sincronía MPEG audio / ADTS (capa 00 = AAC)
        }
        // Transport stream: 0x47 cada 188 bytes
        if b[0] == 0x47, b.count > 188, b[188] == 0x47 { return "ts" }
        return nil
    }
}
