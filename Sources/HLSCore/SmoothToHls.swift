import Foundation

/// AVPlayer no reproduce Smooth Streaming (SS, tecnología Microsoft: `…/index.isml/Manifest`). Este conversor lo presenta como HLS fMP4:
///  - `master`        → lista maestra (vídeos por calidad + audios).
///  - `mediaPlaylist` → lista de fragmentos de una pista (en directo, la ventana final).
///  - `initSegment`   → inicio fMP4 (ftyp+moov) fabricado con el `CodecPrivateData` del manifiesto (SS no trae inicio propio).
///  - `fixFragment`   → arregla un fragmento: pista nº 1 y caja `tfdt` (tiempo de inicio) que el HLS exige y SS no pone.
/// Como en Android (CastRelay.ssManifest/ssFragment): se decide por la estructura del manifiesto y los fragmentos se descifran al vuelo.
public enum SmoothToHls {

    typealias Node = MpdToHls.Node

    /// Un fragmento de la línea de tiempo: inicio y duración en unidades del `TimeScale`.
    struct Chunk { let start: Int; let dur: Int }

    // MARK: - Lectura del manifiesto

    static func parse(_ xml: String) throws -> Node {
        let root = try MpdToHls.parse(xml)
        guard root.name == "SmoothStreamingMedia" else { throw NSError(domain: "SmoothToHls", code: 1, userInfo: [NSLocalizedDescriptionKey: "no es Smooth Streaming"]) }
        return root
    }

    /// Línea de tiempo de una pista: cada `<c>` con `t` (inicio, opcional), `d` (duración) y `r` (repeticiones, opcional).
    static func timeline(_ stream: Node) -> [Chunk] {
        var out: [Chunk] = []
        var clock = 0
        for c in stream.all("c") {
            if let t = c.attrs["t"].flatMap(Int.init) { clock = t }
            let d = c.attrs["d"].flatMap(Int.init) ?? 0
            let repeats = max(1, c.attrs["r"].flatMap(Int.init) ?? 1)
            for _ in 0..<repeats { out.append(Chunk(start: clock, dur: d)); clock += d }
        }
        return out
    }

    /// Pista (StreamIndex) por nombre y su calidad (QualityLevel) por ancho de banda.
    static func find(_ root: Node, stream: String, bitrate: Int) -> (Node, Node)? {
        guard let s = root.all("StreamIndex").first(where: { ($0.attrs["Name"] ?? $0.attrs["Type"] ?? "") == stream }),
              let q = s.all("QualityLevel").first(where: { Int($0.attrs["Bitrate"] ?? "") == bitrate }) ?? s.all("QualityLevel").first
        else { return nil }
        return (s, q)
    }

    static func hexBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex, let n = s.index(i, offsetBy: 2, limitedBy: s.endIndex), let b = UInt8(s[i..<n], radix: 16) { out.append(b); i = n }
        return out
    }

    /// `CodecPrivateData` de H.264 = «00000001 SPS 00000001 PPS» → (SPS, PPS).
    static func spsPps(_ hex: String) -> (sps: [UInt8], pps: [UInt8])? {
        let b = hexBytes(hex)
        var starts: [Int] = []                                     // posición del primer byte tras cada 00 00 00 01
        var i = 0
        while i + 4 <= b.count { if b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 { starts.append(i + 4); i += 4 } else { i += 1 } }
        guard starts.count >= 2 else { return nil }
        let sps = Array(b[starts[0]..<(starts[1] - 4)]), pps = Array(b[starts[1]...])
        return sps.count >= 4 && !pps.isEmpty ? (sps, pps) : nil
    }

    /// Códec HLS de una calidad: avc1.PPCCLL (de la SPS) o mp4a.40.N (del AudioSpecificConfig).
    static func codec(_ q: Node) -> String {
        let fourcc = (q.attrs["FourCC"] ?? "").uppercased()
        if fourcc.hasPrefix("AVC") || fourcc == "H264", let sp = spsPps(q.attrs["CodecPrivateData"] ?? "") {
            return String(format: "avc1.%02X%02X%02X", sp.sps[1], sp.sps[2], sp.sps[3])
        }
        if fourcc.hasPrefix("AAC"), let asc = hexBytes(q.attrs["CodecPrivateData"] ?? "").first { return "mp4a.40.\(Int(asc) >> 3)" }
        return fourcc.lowercased()
    }

    /// KID (32 hex) del objeto PlayReady del manifiesto. Va en XML UTF-16 y en orden de GUID (mitad little-endian). Como Android `ssKid`.
    public static func protectionKid(_ xml: String) -> String? {
        guard let root = try? parse(xml),
              let header = root.child("Protection")?.child("ProtectionHeader"),
              let data = Data(base64Encoded: header.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = String(data: data, encoding: .utf16LittleEndian) ?? String(data: data.dropFirst(10), encoding: .utf16LittleEndian),
              let r = text.range(of: "<KID>"), let e = text.range(of: "</KID>"), r.upperBound <= e.lowerBound,
              let g = Data(base64Encoded: String(text[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespaces)), g.count == 16 else { return nil }
        let b = [UInt8](g)
        return ([b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8...]).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Listas HLS

    public static func isSmooth(_ text: String) -> Bool { text.contains("<SmoothStreamingMedia") }

    /// Lista maestra. `manifestUrl` = dirección ya resuelta del manifiesto.
    public static func master(_ xml: String, manifestUrl: URL, relay: String) throws -> String {
        let root = try parse(xml)
        func playlist(_ stream: Node, _ q: Node) -> String {
            "\(relay)/ssp?u=\(HlsRewriter.encode(manifestUrl.absoluteString))&r=\(HlsRewriter.encode(stream.attrs["Name"] ?? stream.attrs["Type"] ?? ""))&b=\(q.attrs["Bitrate"] ?? "0")"
        }
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var audioCodec = "mp4a.40.2", audioBitrate = 0
        var firstAudio = true
        for s in root.all("StreamIndex") where (s.attrs["Type"] ?? "").lowercased() == "audio" {
            guard let q = s.all("QualityLevel").max(by: { (Int($0.attrs["Bitrate"] ?? "") ?? 0) < (Int($1.attrs["Bitrate"] ?? "") ?? 0) }) else { continue }
            if firstAudio { audioCodec = codec(q); audioBitrate = Int(q.attrs["Bitrate"] ?? "") ?? 0 }
            let lang = s.attrs["Language"] ?? "und"
            var l = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(lang) \(s.attrs["Name"] ?? "")\",LANGUAGE=\"\(lang)\""
            l += ",DEFAULT=\(firstAudio ? "YES" : "NO"),AUTOSELECT=YES"
            if let c = q.attrs["Channels"], Int(c) != nil { l += ",CHANNELS=\"\(c)\"" }
            lines.append(l + ",URI=\"\(playlist(s, q))\"")
            firstAudio = false
        }
        let hasAudio = !firstAudio
        for s in root.all("StreamIndex") where (s.attrs["Type"] ?? "").lowercased() == "video" {
            for q in s.all("QualityLevel").sorted(by: { (Int($0.attrs["Bitrate"] ?? "") ?? 0) < (Int($1.attrs["Bitrate"] ?? "") ?? 0) }) {
                let bw = (Int(q.attrs["Bitrate"] ?? "") ?? 0) + audioBitrate
                let w = q.attrs["MaxWidth"] ?? s.attrs["MaxWidth"] ?? "", h = q.attrs["MaxHeight"] ?? s.attrs["MaxHeight"] ?? ""
                var l = "#EXT-X-STREAM-INF:BANDWIDTH=\(bw),CODECS=\"\(codec(q))\(hasAudio ? ",\(audioCodec)" : "")\""
                if !w.isEmpty, !h.isEmpty { l += ",RESOLUTION=\(w)x\(h)" }
                if hasAudio { l += ",AUDIO=\"aud\"" }
                lines.append(l); lines.append(playlist(s, q))
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Lista de fragmentos de una pista. En directo, solo la ventana final (`window` fragmentos) sin los de «mirar adelante».
    public static func mediaPlaylist(_ xml: String, manifestUrl: URL, stream: String, bitrate: Int, relay: String, window: Int = 600) throws -> String {
        let root = try parse(xml)
        guard let (s, q) = find(root, stream: stream, bitrate: bitrate) else { throw NSError(domain: "SmoothToHls", code: 2, userInfo: [NSLocalizedDescriptionKey: "pista \(stream) no encontrada"]) }
        let scale = Double(s.attrs["TimeScale"] ?? root.attrs["TimeScale"] ?? "10000000") ?? 10_000_000
        let live = (root.attrs["IsLive"] ?? "").uppercased() == "TRUE"
        var chunks = timeline(s)
        if live {
            chunks = Array(chunks.dropLast(min(chunks.count, Int(root.attrs["LookAheadFragmentCount"] ?? "") ?? 2)))
            chunks = Array(chunks.suffix(window))
        }
        guard let first = chunks.first else { throw NSError(domain: "SmoothToHls", code: 3, userInfo: [NSLocalizedDescriptionKey: "sin fragmentos"]) }
        // Nº de secuencia estable entre recargas: tiempo de inicio entre la duración típica (si no, AVPlayer perdería el hilo al deslizar la ventana)
        let typical = max(1, chunks[chunks.count / 2].dur)
        let seq = Int((Double(first.start) / Double(typical)).rounded())
        let target = Int(ceil(Double(chunks.map { $0.dur }.max() ?? 0) / scale))
        let enc = HlsRewriter.encode(manifestUrl.absoluteString), rEnc = HlsRewriter.encode(stream)
        var out = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, target))", "#EXT-X-MEDIA-SEQUENCE:\(seq)"]
        if !live { out.append("#EXT-X-PLAYLIST-TYPE:VOD") }
        out.append("#EXT-X-MAP:URI=\"\(relay)/ssi?u=\(enc)&r=\(rEnc)&b=\(bitrate)\"")
        let template = s.attrs["Url"] ?? ""
        let kidParam = protectionKid(xml).map { "&kid=\($0)" } ?? ""
        for c in chunks {
            // La dirección real del fragmento: plantilla del manifiesto con {bitrate} y {start time}
            let rel = template.replacingOccurrences(of: "{bitrate}", with: "\(q.attrs["Bitrate"] ?? "\(bitrate)")")
                .replacingOccurrences(of: "{start time}", with: "\(c.start)")
            out.append(String(format: "#EXTINF:%.5f,", Double(c.dur) / scale))
            out.append("\(relay)/ssf?u=\(enc)&f=\(HlsRewriter.encode(rel))&t=\(c.start)\(kidParam)")
        }
        if !live { out.append("#EXT-X-ENDLIST") }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// Dirección absoluta de un fragmento: carpeta del manifiesto + plantilla (conserva la query, que puede llevar el token).
    public static func fragmentUrl(manifestUrl: URL, relative: String) -> URL? {
        // A mano: URLComponents se rompe (error fatal) con algunos caracteres de las plantillas de Smooth
        let full = manifestUrl.absoluteString
        let query = full.firstIndex(of: "?").map { String(full[$0...]) } ?? ""
        let path = full.firstIndex(of: "?").map { String(full[..<$0]) } ?? full
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return URL(string: String(path[...slash]) + relative.replacingOccurrences(of: " ", with: "%20") + query)
    }

    // MARK: - Inicio fMP4 fabricado

    private static func u32(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    private static func u16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    private static func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
    /// Caja MP4: tamaño + tipo + contenido.
    private static func box(_ type: String, _ parts: [UInt8]...) -> [UInt8] {
        let body = parts.flatMap { $0 }
        return u32(8 + body.count) + Array(type.utf8) + body
    }
    /// Descriptor MPEG-4 (esds): etiqueta + longitud de un byte (los contenidos son pequeños).
    private static func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }

    /// Código de idioma ISO-639-2 («spa») empaquetado en 15 bits como pide `mdhd`.
    private static func packedLang(_ l: String) -> Int {
        let c = Array(l.lowercased().utf8)
        guard c.count == 3, c.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return 0x55C4 }     // «und»
        return (Int(c[0]) - 0x60) << 10 | (Int(c[1]) - 0x60) << 5 | (Int(c[2]) - 0x60)
    }

    /// ftyp+moov de una pista (siempre «track_ID 1»: `fixFragment` renumera los fragmentos).
    public static func initSegment(_ xml: String, stream: String, bitrate: Int) throws -> [UInt8] {
        let root = try parse(xml)
        guard let (s, q) = find(root, stream: stream, bitrate: bitrate) else { throw NSError(domain: "SmoothToHls", code: 2, userInfo: [NSLocalizedDescriptionKey: "pista \(stream) no encontrada"]) }
        let isVideo = (s.attrs["Type"] ?? "").lowercased() == "video"
        let scale = Int(s.attrs["TimeScale"] ?? root.attrs["TimeScale"] ?? "10000000") ?? 10_000_000
        let priv = q.attrs["CodecPrivateData"] ?? ""
        let w = Int(q.attrs["MaxWidth"] ?? s.attrs["MaxWidth"] ?? "") ?? 0, h = Int(q.attrs["MaxHeight"] ?? s.attrs["MaxHeight"] ?? "") ?? 0
        let matrix: [UInt8] = u32(0x00010000) + zeros(12) + u32(0x00010000) + zeros(12) + u32(0x40000000)

        // Entrada de descripción de muestra (avc1 o mp4a)
        var entry: [UInt8]
        if isVideo {
            guard let sp = spsPps(priv) else { throw NSError(domain: "SmoothToHls", code: 4, userInfo: [NSLocalizedDescriptionKey: "solo H.264 (AVC1)"]) }
            let avcC = box("avcC", [1, sp.sps[1], sp.sps[2], sp.sps[3], 0xFF, 0xE1], u16(sp.sps.count), sp.sps, [1], u16(sp.pps.count), sp.pps)
            entry = box("avc1", zeros(6), u16(1), zeros(16), u16(w), u16(h), u32(0x00480000), u32(0x00480000), zeros(4), u16(1),
                        zeros(32), u16(0x18), [0xFF, 0xFF], avcC)
        } else {
            let asc = hexBytes(priv)
            let dec = descriptor(4, [0x40, 0x15] + zeros(3) + u32(0) + u32(Int(q.attrs["Bitrate"] ?? "") ?? 0) + descriptor(5, asc))
            let esds = box("esds", zeros(4), descriptor(3, u16(0) + [0] + dec + descriptor(6, [2])))
            let channels = Int(q.attrs["Channels"] ?? "") ?? 2, rate = Int(q.attrs["SamplingRate"] ?? "") ?? 48000
            entry = box("mp4a", zeros(6), u16(1), zeros(8), u16(channels), u16(16), zeros(4), u32(rate << 16), esds)
        }
        let stbl = box("stbl", box("stsd", zeros(4), u32(1), entry), box("stts", zeros(8)), box("stsc", zeros(8)), box("stsz", zeros(12)), box("stco", zeros(8)))
        let dinf = box("dinf", box("dref", zeros(4), u32(1), box("url ", [0, 0, 0, 1])))
        let mediaHeader = isVideo ? box("vmhd", [0, 0, 0, 1], zeros(8)) : box("smhd", zeros(8))
        let minf = box("minf", mediaHeader, dinf, stbl)
        let mdia = box("mdia", box("mdhd", zeros(12), u32(scale), u32(0), u16(packedLang(s.attrs["Language"] ?? "und")), zeros(2)),
                       box("hdlr", zeros(8), Array((isVideo ? "vide" : "soun").utf8), zeros(12), [0]), minf)
        let tkhd = box("tkhd", [0, 0, 0, 7], zeros(8), u32(1), zeros(4), u32(0), zeros(8), zeros(4), u16(isVideo ? 0 : 0x0100), zeros(2),
                       matrix, u32(w << 16), u32(h << 16))
        let trak = box("trak", tkhd, mdia)
        let mvhd = box("mvhd", zeros(12), u32(1000), u32(0), u32(0x00010000), u16(0x0100), zeros(10), matrix, zeros(24), u32(2))
        let mvex = box("mvex", box("trex", zeros(4), u32(1), u32(1), zeros(12)))
        let ftyp = box("ftyp", Array("iso6".utf8), u32(1), Array("iso6".utf8), Array("isom".utf8), Array("avc1".utf8))
        return ftyp + box("moov", mvhd, trak, mvex)
    }

    // MARK: - Arreglo de fragmentos

    /// Pone la pista nº 1 en `tfhd` e inserta `tfdt` (tiempo de inicio) si falta. Los tamaños de `traf` y `moof` y los
    /// `data_offset` de `trun` se corrigen por los 20 bytes añadidos. Se llama DESPUÉS de descifrar (que no mueve nada).
    public static func fixFragment(_ seg: [UInt8], start: Int) -> [UInt8] {
        var b = seg
        guard let moof = Cenc.boxes(b, from: 0, to: b.count).first(where: { $0.type == "moof" }),
              let traf = Cenc.boxes(b, from: moof.bodyStart, to: moof.end).first(where: { $0.type == "traf" }) else { return seg }
        let kids = Cenc.boxes(b, from: traf.bodyStart, to: traf.end)
        guard let tfhd = kids.first(where: { $0.type == "tfhd" }) else { return seg }
        let trackIdPos = tfhd.bodyStart + 4
        let id = u32(1); for i in 0..<4 { b[trackIdPos + i] = id[i] }
        if kids.contains(where: { $0.type == "tfdt" }) { return b }

        // tfdt versión 1: tamaño 20 = 8 (cabecera) + 4 (versión/flags) + 8 (tiempo)
        let t = (0..<8).map { UInt8(truncatingIfNeeded: start >> (8 * (7 - $0))) }
        let tfdt = u32(20) + Array("tfdt".utf8) + [1, 0, 0, 0] + t
        // Los data_offset de los trun cuentan desde el inicio del moof: todos crecen 20
        for trun in kids where trun.type == "trun" {
            let flags = Cenc.u32(b, trun.bodyStart) & 0xFFFFFF
            guard flags & 0x1 != 0 else { continue }
            let p = trun.bodyStart + 8
            let off = Int(Int32(truncatingIfNeeded: Cenc.u32(b, p))) + 20
            let o = u32(off); for i in 0..<4 { b[p + i] = o[i] }
        }
        for bx in [moof, traf] {
            let n = u32(bx.size + 20); for i in 0..<4 { b[bx.start + i] = n[i] }
        }
        b.insert(contentsOf: tfdt, at: tfhd.end)
        return b
    }
}
