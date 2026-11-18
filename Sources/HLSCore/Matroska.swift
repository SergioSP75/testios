import Foundation

// Lector de Matroska (MKV/WebM) para pasar el vídeo a HLS fMP4 SIN recodificar (MkvToHls).
// AVPlayer no abre el contenedor MKV, pero sí el vídeo H.264/HEVC y el audio AAC/AC-3/E-AC-3 que suele llevar dentro.
// Aquí solo se lee la estructura (EBML): pistas, índice de posiciones (Cues) y los bloques de cada grupo de clusters.

/// Una pista del fichero (vídeo, audio o subtítulos).
public struct MkvTrack {
    public var number = 0
    public var type = 0                    // 1 vídeo · 2 audio · 17 subtítulos
    public var codecId = ""
    public var codecPrivate: [UInt8] = []
    public var language = ""
    public var name = ""
    public var isDefault = false
    public var defaultDurationNs: Int64 = 0
    public var width = 0, height = 0
    public var sampleRate = 0.0, channels = 0
    /// Color (HDR): primarias, transferencia, matriz y rango (0 = sin indicar).
    public var colorPrimaries = 0, colorTransfer = 0, colorMatrix = 0, colorRange = 0
    /// Bytes que el muxer quitó del principio de cada trama (compresión «header stripping»); hay que devolverlos.
    public var headerStrip: [UInt8] = []
}

/// Un bloque del fichero con sus tramas (con «lacing» puede haber varias).
public struct MkvBlock {
    public var track: Int
    public var ticks: Int64                // tiempo absoluto en unidades de TimecodeScale
    public var keyframe: Bool
    public var frames: [[UInt8]]
}

/// Un punto del índice: instante y posición del cluster (relativa al inicio de los datos del Segment).
public struct MkvCue { public var ticks: Int64; public var clusterPos: Int64 }

/// Datos del fichero que hacen falta para generar HLS.
public struct MkvInfo {
    public var timecodeScale: Int64 = 1_000_000
    public var durationSec = 0.0
    public var tracks: [MkvTrack] = []
    public var segmentStart: Int64 = 0     // posición absoluta donde empiezan los datos del Segment
    public var segmentEnd: Int64 = Int64.max
    public var cues: [MkvCue] = []
    public var firstCluster: Int64 = -1    // relativa a segmentStart
    public func seconds(_ ticks: Int64) -> Double { Double(ticks) * Double(timecodeScale) / 1e9 }
}

/// De dónde se leen los bytes del fichero (en la app: peticiones HTTP con «Range»; en las pruebas, memoria).
public protocol MkvSource {
    func read(offset: Int64, length: Int) async throws -> [UInt8]
}

/// Lectura por HTTP con «Range» usando el mismo `Fetcher` que el resto del relay.
public struct HttpRangeSource: MkvSource {
    let fetcher: Fetcher, url: URL, headers: [String: String]
    public init(fetcher: Fetcher, url: URL, headers: [String: String]) { self.fetcher = fetcher; self.url = url; self.headers = headers }
    public func read(offset: Int64, length: Int) async throws -> [UInt8] {
        let d = try await fetcher.fetch(url, headers: headers.merging(["Range": "bytes=\(offset)-\(offset + Int64(length) - 1)"]) { a, _ in a })
        return [UInt8](d.prefix(length))        // si el servidor ignorara Range y mandara más, no se usa de más
    }
}

public enum MkvError: Error, LocalizedError {
    case notMatroska, truncated(String), noVideo, unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .notMatroska: return "no es un fichero Matroska"
        case .truncated(let w): return "fichero MKV incompleto (\(w))"
        case .noVideo: return "el MKV no tiene vídeo"
        case .unsupported(let w): return w
        }
    }
}

/// Identificadores EBML que se usan.
enum Ebml {
    static let header: UInt32 = 0x1A45DFA3, segment: UInt32 = 0x18538067, seekHead: UInt32 = 0x114D9B74, seek: UInt32 = 0x4DBB
    static let seekID: UInt32 = 0x53AB, seekPos: UInt32 = 0x53AC, info: UInt32 = 0x1549A966, tcScale: UInt32 = 0x2AD7B1, duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE, trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83
    static let flagDefault: UInt32 = 0x88, defaultDuration: UInt32 = 0x23E383, name: UInt32 = 0x536E, language: UInt32 = 0x22B59C
    static let languageBcp: UInt32 = 0x22B59D, codecId: UInt32 = 0x86, codecPrivate: UInt32 = 0x63A2
    static let video: UInt32 = 0xE0, pixelW: UInt32 = 0xB0, pixelH: UInt32 = 0xBA, colour: UInt32 = 0x55B0
    static let matrix: UInt32 = 0x55B1, range: UInt32 = 0x55B9, transfer: UInt32 = 0x55BA, primaries: UInt32 = 0x55BB
    static let audio: UInt32 = 0xE1, samplingFreq: UInt32 = 0xB5, channels: UInt32 = 0x9F
    static let contentEncodings: UInt32 = 0x6D80, contentEncoding: UInt32 = 0x6240, contentCompression: UInt32 = 0x5034
    static let compAlgo: UInt32 = 0x4254, compSettings: UInt32 = 0x4255
    static let cues: UInt32 = 0x1C53BB6B, cuePoint: UInt32 = 0xBB, cueTime: UInt32 = 0xB3, cueTrackPositions: UInt32 = 0xB7, cueClusterPos: UInt32 = 0xF1
    static let cluster: UInt32 = 0x1F43B675, timecode: UInt32 = 0xE7, simpleBlock: UInt32 = 0xA3, blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1, referenceBlock: UInt32 = 0xFB
}

/// Un elemento EBML ya situado dentro de un búfer.
struct EbmlElement { var id: UInt32; var start: Int; var end: Int }      // start/end = datos del elemento (sin cabecera)

enum EbmlReader {
    /// Identificador (con sus bits de longitud) en `p`.
    static func readID(_ b: [UInt8], _ p: Int) -> (id: UInt32, len: Int)? {
        guard p < b.count else { return nil }
        let first = b[p]
        var len = 1; var mask: UInt8 = 0x80
        while len <= 4 && (first & mask) == 0 { len += 1; mask >>= 1 }
        guard len <= 4, p + len <= b.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<len { v = (v << 8) | UInt32(b[p + i]) }
        return (v, len)
    }

    /// Tamaño (vint sin sus bits de longitud). `unknown` = tamaño desconocido (todo unos).
    static func readSize(_ b: [UInt8], _ p: Int) -> (size: Int64, len: Int, unknown: Bool)? {
        guard p < b.count else { return nil }
        let first = b[p]
        var len = 1; var mask: UInt8 = 0x80
        while len <= 8 && (first & mask) == 0 { len += 1; mask >>= 1 }
        guard len <= 8, p + len <= b.count else { return nil }
        var v = UInt64(first & (mask &- 1))
        for i in 1..<max(len, 1) where i < len { v = (v << 8) | UInt64(b[p + i]) }
        let allOnes = (UInt64(1) << UInt64(7 * len)) - 1
        return (Int64(truncatingIfNeeded: v), len, v == allOnes)
    }

    /// Hijos de un elemento maestro dentro de `b[from..<to]`. Para un hijo de tamaño desconocido, llega hasta `to`.
    static func children(_ b: [UInt8], from: Int, to: Int) -> [EbmlElement] {
        var out: [EbmlElement] = []
        var p = from
        while p < to {
            guard let (id, il) = readID(b, p), let (sz, sl, unknown) = readSize(b, p + il) else { break }
            let s = p + il + sl
            let e = unknown ? to : min(to, s + Int(min(sz, Int64(Int32.max))))
            if s > to { break }
            out.append(EbmlElement(id: id, start: s, end: e))
            p = e
        }
        return out
    }

    static func uint(_ b: [UInt8], _ e: EbmlElement) -> Int64 {
        var v: UInt64 = 0
        for i in e.start..<e.end { v = (v << 8) | UInt64(b[i]) }
        return Int64(truncatingIfNeeded: v)
    }
    static func float(_ b: [UInt8], _ e: EbmlElement) -> Double {
        let n = e.end - e.start
        if n == 4 { var v: UInt32 = 0; for i in e.start..<e.end { v = (v << 8) | UInt32(b[i]) }; return Double(Float(bitPattern: v)) }
        if n == 8 { var v: UInt64 = 0; for i in e.start..<e.end { v = (v << 8) | UInt64(b[i]) }; return Double(bitPattern: v) }
        return 0
    }
    static func string(_ b: [UInt8], _ e: EbmlElement) -> String {
        var bytes = Array(b[e.start..<e.end]); while bytes.last == 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public enum Matroska {

    // MARK: - Cabecera: pistas, duración e índice

    /// Lee lo necesario para empezar: pistas, duración y puntos del índice (Cues). Pocas peticiones pequeñas.
    public static func open(_ src: MkvSource) async throws -> MkvInfo {
        let head = try await src.read(offset: 0, length: 64)
        guard let (id0, il0) = EbmlReader.readID(head, 0), id0 == Ebml.header, let (hs, hl, _) = EbmlReader.readSize(head, il0) else { throw MkvError.notMatroska }
        var pos = Int64(il0 + hl) + hs                                 // fin de la cabecera EBML
        // Elemento Segment
        let segHead = try await src.read(offset: pos, length: 16)
        guard let (sid, sil) = EbmlReader.readID(segHead, 0), sid == Ebml.segment, let (ssz, ssl, sunk) = EbmlReader.readSize(segHead, sil) else { throw MkvError.notMatroska }
        var info = MkvInfo()
        info.segmentStart = pos + Int64(sil + ssl)
        info.segmentEnd = sunk ? Int64.max : info.segmentStart + ssz
        pos = info.segmentStart
        var cuesAt: Int64 = -1
        var seen = 0
        // Elementos de primer nivel hasta el primer cluster
        while pos < info.segmentEnd && seen < 200 {
            seen += 1
            let h = try await src.read(offset: pos, length: 16)
            guard let (id, il) = EbmlReader.readID(h, 0), let (sz, sl, unk) = EbmlReader.readSize(h, il) else { break }
            let body = pos + Int64(il + sl)
            if id == Ebml.cluster { info.firstCluster = pos - info.segmentStart; break }
            let wanted = [Ebml.seekHead, Ebml.info, Ebml.tracks, Ebml.cues].contains(id)
            if wanted && !unk && sz < 32_000_000 {
                let data = try await src.read(offset: body, length: Int(sz))
                switch id {
                case Ebml.seekHead: if let c = parseSeekHead(data, wantID: Ebml.cues) { cuesAt = c }
                case Ebml.info: parseInfo(data, into: &info)
                case Ebml.tracks: info.tracks = parseTracks(data)
                case Ebml.cues: info.cues = parseCues(data)
                default: break
                }
            }
            if unk { break }
            pos = body + sz
        }
        guard info.tracks.contains(where: { $0.type == 1 }) else { throw MkvError.noVideo }
        // Índice al final del fichero (lo habitual): la SeekHead dice dónde
        if info.cues.isEmpty, cuesAt >= 0 {
            let abs = info.segmentStart + cuesAt
            let h = try await src.read(offset: abs, length: 16)
            if let (id, il) = EbmlReader.readID(h, 0), id == Ebml.cues, let (sz, sl, unk) = EbmlReader.readSize(h, il), !unk, sz < 32_000_000 {
                info.cues = parseCues(try await src.read(offset: abs + Int64(il + sl), length: Int(sz)))
            }
        }
        // Sin índice: se recorren las cabeceras de los clusters (más lento)
        if info.cues.isEmpty, info.firstCluster >= 0 { info.cues = try await scanClusters(src, info) }
        info.cues.sort { $0.clusterPos < $1.clusterPos }
        return info
    }

    static func parseSeekHead(_ b: [UInt8], wantID: UInt32) -> Int64? {
        for s in EbmlReader.children(b, from: 0, to: b.count) where s.id == Ebml.seek {
            var id: UInt32 = 0; var pos: Int64 = -1
            for c in EbmlReader.children(b, from: s.start, to: s.end) {
                if c.id == Ebml.seekID { id = UInt32(truncatingIfNeeded: EbmlReader.uint(b, c)) }
                if c.id == Ebml.seekPos { pos = EbmlReader.uint(b, c) }
            }
            if id == wantID, pos >= 0 { return pos }
        }
        return nil
    }

    static func parseInfo(_ b: [UInt8], into info: inout MkvInfo) {
        var dur = 0.0
        for e in EbmlReader.children(b, from: 0, to: b.count) {
            if e.id == Ebml.tcScale { info.timecodeScale = max(EbmlReader.uint(b, e), 1) }
            if e.id == Ebml.duration { dur = EbmlReader.float(b, e) }
        }
        info.durationSec = dur * Double(info.timecodeScale) / 1e9
    }

    static func parseTracks(_ b: [UInt8]) -> [MkvTrack] {
        var out: [MkvTrack] = []
        for te in EbmlReader.children(b, from: 0, to: b.count) where te.id == Ebml.trackEntry {
            var t = MkvTrack(); t.isDefault = true
            for e in EbmlReader.children(b, from: te.start, to: te.end) {
                switch e.id {
                case Ebml.trackNumber: t.number = Int(EbmlReader.uint(b, e))
                case Ebml.trackType: t.type = Int(EbmlReader.uint(b, e))
                case Ebml.flagDefault: t.isDefault = EbmlReader.uint(b, e) != 0
                case Ebml.defaultDuration: t.defaultDurationNs = EbmlReader.uint(b, e)
                case Ebml.name: t.name = EbmlReader.string(b, e)
                case Ebml.language: if t.language.isEmpty { t.language = EbmlReader.string(b, e) }       // «eng» si no hay etiqueta (omisión del formato)
                case Ebml.languageBcp: t.language = EbmlReader.string(b, e)
                case Ebml.codecId: t.codecId = EbmlReader.string(b, e)
                case Ebml.codecPrivate: t.codecPrivate = Array(b[e.start..<e.end])
                case Ebml.video:
                    for v in EbmlReader.children(b, from: e.start, to: e.end) {
                        if v.id == Ebml.pixelW { t.width = Int(EbmlReader.uint(b, v)) }
                        if v.id == Ebml.pixelH { t.height = Int(EbmlReader.uint(b, v)) }
                        if v.id == Ebml.colour {
                            for c in EbmlReader.children(b, from: v.start, to: v.end) {
                                switch c.id {
                                case Ebml.primaries: t.colorPrimaries = Int(EbmlReader.uint(b, c))
                                case Ebml.transfer: t.colorTransfer = Int(EbmlReader.uint(b, c))
                                case Ebml.matrix: t.colorMatrix = Int(EbmlReader.uint(b, c))
                                case Ebml.range: t.colorRange = Int(EbmlReader.uint(b, c))
                                default: break
                                }
                            }
                        }
                    }
                case Ebml.audio:
                    for a in EbmlReader.children(b, from: e.start, to: e.end) {
                        if a.id == Ebml.samplingFreq { t.sampleRate = EbmlReader.float(b, a) }
                        if a.id == Ebml.channels { t.channels = Int(EbmlReader.uint(b, a)) }
                    }
                case Ebml.contentEncodings:
                    for ce in EbmlReader.children(b, from: e.start, to: e.end) where ce.id == Ebml.contentEncoding {
                        for cc in EbmlReader.children(b, from: ce.start, to: ce.end) where cc.id == Ebml.contentCompression {
                            var algo: Int64 = 0; var settings: [UInt8] = []
                            for x in EbmlReader.children(b, from: cc.start, to: cc.end) {
                                if x.id == Ebml.compAlgo { algo = EbmlReader.uint(b, x) }
                                if x.id == Ebml.compSettings { settings = Array(b[x.start..<x.end]) }
                            }
                            if algo == 3 { t.headerStrip = settings }
                        }
                    }
                default: break
                }
            }
            if t.language.isEmpty { t.language = "eng" }
            if t.number > 0 { out.append(t) }
        }
        return out
    }

    static func parseCues(_ b: [UInt8]) -> [MkvCue] {
        var out: [MkvCue] = []
        for cp in EbmlReader.children(b, from: 0, to: b.count) where cp.id == Ebml.cuePoint {
            var time: Int64 = 0; var pos: Int64 = -1
            for e in EbmlReader.children(b, from: cp.start, to: cp.end) {
                if e.id == Ebml.cueTime { time = EbmlReader.uint(b, e) }
                if e.id == Ebml.cueTrackPositions {
                    for x in EbmlReader.children(b, from: e.start, to: e.end) where x.id == Ebml.cueClusterPos { if pos < 0 { pos = EbmlReader.uint(b, x) } }
                }
            }
            if pos >= 0 { out.append(MkvCue(ticks: time, clusterPos: pos)) }
        }
        // Varias pistas apuntan al mismo cluster: se deja uno por posición
        var seen = Set<Int64>()
        return out.filter { seen.insert($0.clusterPos).inserted }
    }

    /// Sin Cues: se salta de cluster en cluster leyendo solo su cabecera y su marca de tiempo.
    static func scanClusters(_ src: MkvSource, _ info: MkvInfo) async throws -> [MkvCue] {
        var out: [MkvCue] = []
        var rel = info.firstCluster
        while info.segmentStart + rel < info.segmentEnd {
            let h = try await src.read(offset: info.segmentStart + rel, length: 40)
            guard let (id, il) = EbmlReader.readID(h, 0), id == Ebml.cluster, let (sz, sl, unk) = EbmlReader.readSize(h, il), !unk else { break }
            var t: Int64 = 0
            if let (cid, cil) = EbmlReader.readID(h, il + sl), cid == Ebml.timecode, let (csz, csl, _) = EbmlReader.readSize(h, il + sl + cil) {
                let s = il + sl + cil + csl
                if s + Int(csz) <= h.count { t = EbmlReader.uint(h, EbmlElement(id: cid, start: s, end: s + Int(csz))) }
            }
            out.append(MkvCue(ticks: t, clusterPos: rel))
            rel += Int64(il + sl) + sz
            if out.count > 20000 { break }
        }
        return out
    }

    // MARK: - Bloques de un grupo de clusters

    /// Todos los bloques de los clusters que contiene `b` (varios clusters seguidos), en el orden del fichero.
    public static func blocks(_ b: [UInt8], tracks: [MkvTrack]) -> [MkvBlock] {
        var strip: [Int: [UInt8]] = [:]
        for t in tracks where !t.headerStrip.isEmpty { strip[t.number] = t.headerStrip }
        var out: [MkvBlock] = []
        for cl in EbmlReader.children(b, from: 0, to: b.count) where cl.id == Ebml.cluster {
            var base: Int64 = 0
            for e in EbmlReader.children(b, from: cl.start, to: cl.end) {
                switch e.id {
                case Ebml.timecode: base = EbmlReader.uint(b, e)
                case Ebml.simpleBlock: if let bl = parseBlock(b, e, base: base, simple: true, hasRef: false, strip: strip) { out.append(bl) }
                case Ebml.blockGroup:
                    var blockEl: EbmlElement?; var hasRef = false
                    for x in EbmlReader.children(b, from: e.start, to: e.end) {
                        if x.id == Ebml.block { blockEl = x }
                        if x.id == Ebml.referenceBlock { hasRef = true }
                    }
                    if let be = blockEl, let bl = parseBlock(b, be, base: base, simple: false, hasRef: hasRef, strip: strip) { out.append(bl) }
                default: break
                }
            }
        }
        return out
    }

    static func parseBlock(_ b: [UInt8], _ e: EbmlElement, base: Int64, simple: Bool, hasRef: Bool, strip: [Int: [UInt8]]) -> MkvBlock? {
        guard let (tn, tl, _) = EbmlReader.readSize(b, e.start) else { return nil }
        var p = e.start + tl
        guard p + 3 <= e.end else { return nil }
        let rel = Int16(bitPattern: UInt16(b[p]) << 8 | UInt16(b[p + 1]))
        let flags = b[p + 2]
        p += 3
        let key = simple ? (flags & 0x80) != 0 : !hasRef
        let track = Int(tn)
        var frames: [[UInt8]] = []
        let lacing = (flags >> 1) & 0x03
        if lacing == 0 {
            frames = [Array(b[p..<e.end])]
        } else {
            guard p < e.end else { return nil }
            let n = Int(b[p]) + 1; p += 1
            var sizes: [Int] = []
            switch lacing {
            case 1:                                              // Xiph
                for _ in 0..<(n - 1) {
                    var s = 0
                    while p < e.end { let v = Int(b[p]); p += 1; s += v; if v != 255 { break } }
                    sizes.append(s)
                }
            case 3:                                              // EBML
                guard let (first, fl, _) = EbmlReader.readSize(b, p) else { return nil }
                p += fl; var cur = Int(first); sizes.append(cur)
                for _ in 1..<max(n - 1, 1) where n > 2 {
                    guard let (raw, rl, _) = EbmlReader.readSize(b, p) else { return nil }
                    p += rl
                    let bias = (Int64(1) << Int64(7 * rl - 1)) - 1
                    cur += Int(raw - bias); sizes.append(cur)
                }
            default:                                             // tamaño fijo
                let each = (e.end - p) / n
                sizes = Array(repeating: each, count: n - 1)
            }
            let used = sizes.reduce(0, +)
            sizes.append(e.end - p - used)
            for s in sizes where s >= 0 && p + s <= e.end { frames.append(Array(b[p..<(p + s)])); p += s }
        }
        if let pre = strip[track], !pre.isEmpty { frames = frames.map { pre + $0 } }
        return MkvBlock(track: track, ticks: base + Int64(rel), keyframe: key, frames: frames)
    }
}
