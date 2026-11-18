import Foundation

// MP4 normal (no fragmentado) escrito a mano para las descargas de MKV: un solo fichero con vídeo y audios, cada pista con su
// lista de ediciones (elst), de modo que la sincronía no depende de cómo un montador del sistema alinee pistas sueltas.

/// Tablas de muestras de una pista, que se van llenando segmento a segmento.
final class Mp4Table {
    let number: Int
    let isVideo: Bool
    let timescale: UInt32
    let language: String
    let sampleEntry: [UInt8]
    let width: Int, height: Int

    private(set) var sizes: [UInt32] = []
    private(set) var durations: [UInt32] = []
    private(set) var ctts: [Int32] = []                 // solo vídeo
    private(set) var syncs: [UInt32] = []               // solo vídeo: número (desde 1) de cada fotograma clave
    private(set) var chunks: [(offset: UInt64, count: UInt32)] = []
    /// Instante (en la escala de la pista) que sigue al último fotograma/trama: sirve para unir un segmento con el siguiente sin saltos.
    private var expectedEnd: Int64 = 0
    /// Valor de DTS (vídeo) o instante en muestras (audio) del primer elemento del fichero.
    private(set) var firstStamp: Int64 = 0
    private var hasFirst = false

    init(number: Int, isVideo: Bool, timescale: UInt32, language: String, sampleEntry: [UInt8], width: Int = 0, height: Int = 0) {
        self.number = number; self.isVideo = isVideo; self.timescale = timescale; self.language = language
        self.sampleEntry = sampleEntry; self.width = width; self.height = height
    }

    var sampleCount: Int { sizes.count }
    var totalDuration: Int64 { durations.reduce(0) { $0 + Int64($1) } }

    /// Añade las muestras de un segmento. `stamp` es el DTS (vídeo) o el instante (audio) de la primera, en la escala de la pista.
    /// Si el segmento anterior terminaba un poco antes o después, se ajusta la duración de su última muestra (sin saltos ni deriva).
    func add(offset: UInt64, samples: [Mp4Sample], stamp: Int64) {
        guard !samples.isEmpty else { return }
        if !hasFirst { firstStamp = stamp; expectedEnd = stamp; hasFirst = true }
        else if !durations.isEmpty {
            let drift = stamp - expectedEnd
            // Audio: las tramas son de duración fija, solo se corrige si la deriva pasa de media trama. Vídeo: se une siempre.
            let limit = isVideo ? 0 : Int64(durations.last ?? 1) / 2
            if abs(drift) > limit {
                let fixed = max(Int64(durations[durations.count - 1]) + drift, 1)
                expectedEnd += fixed - Int64(durations[durations.count - 1])
                durations[durations.count - 1] = UInt32(min(fixed, Int64(UInt32.max)))
            }
        }
        chunks.append((offset, UInt32(samples.count)))
        for s in samples {
            sizes.append(UInt32(s.data.count)); durations.append(s.duration)
            if isVideo {
                ctts.append(s.compositionOffset)
                if s.sync { syncs.append(UInt32(sizes.count)) }
            }
            expectedEnd += Int64(s.duration)
        }
    }

    /// Duración del último elemento si no hay otro detrás (se deja la que tiene).
    func finish() {}
}

enum Mp4Moov {
    /// Pasa una lista de (valor, repeticiones) a pares consecutivos.
    private static func runs<T: Equatable>(_ a: [T]) -> [(T, UInt32)] {
        var out: [(T, UInt32)] = []
        for v in a { if let l = out.last, l.0 == v { out[out.count - 1].1 += 1 } else { out.append((v, 1)) } }
        return out
    }

    /// moov completo. Por pista: `lead[n]` = segundos que tarda en empezar respecto al instante 0 de la película (hueco explícito en la
    /// lista de ediciones) y `start[n]` = posición, en la escala de la pista, de su primera muestra que se ve u oye.
    static func build(tables: [Mp4Table], lead: [Int: Double], start: [Int: Int64]) -> [UInt8] {
        let movieScale: UInt32 = 1000
        var traks: [UInt8] = []
        var movieDuration: Int64 = 0
        for t in tables {
            let media = t.totalDuration
            // Duración de lo que se ve en la película (ms): desde su primera muestra visible hasta el final
            let startMedia = max(start[t.number] ?? 0, 0)
            let gapMs = Int64(((lead[t.number] ?? 0) * 1000).rounded())
            let playMs = Int64(Double(max(media - startMedia, 0)) / Double(t.timescale) * 1000)
            movieDuration = max(movieDuration, gapMs + playMs)
            var elst: [UInt8] = []
            var entries: UInt32 = 0
            if gapMs > 0 { elst += Mp4.u32(UInt32(gapMs)) + Mp4.i32(-1) + Mp4.u16(1) + Mp4.u16(0); entries += 1 }
            elst += Mp4.u32(UInt32(playMs)) + Mp4.i32(Int32(clamping: startMedia)) + Mp4.u16(1) + Mp4.u16(0); entries += 1
            let edts = Mp4.box("edts", Mp4.full("elst", Mp4.u32(entries) + elst))

            var stbl = Mp4.full("stsd", Mp4.u32(1) + t.sampleEntry)
            var stts = Mp4.u32(0), n: UInt32 = 0
            for (d, c) in runs(t.durations) { stts += Mp4.u32(c) + Mp4.u32(d); n += 1 }
            stbl += Mp4.full("stts", Mp4.u32(n) + stts.dropFirst(4))
            if t.isVideo {
                var c = [UInt8](); var m: UInt32 = 0
                for (v, r) in runs(t.ctts) { c += Mp4.u32(r) + Mp4.u32(UInt32(max(v, 0))); m += 1 }
                stbl += Mp4.full("ctts", Mp4.u32(m) + c)
                stbl += Mp4.full("stss", Mp4.u32(UInt32(t.syncs.count)) + t.syncs.flatMap { Mp4.u32($0) })
            }
            // Muestras por trozo: se agrupan los trozos consecutivos con el mismo número
            var stsc = [UInt8](); var k: UInt32 = 0; var last: UInt32 = 0
            for (i, ch) in t.chunks.enumerated() where ch.count != last { stsc += Mp4.u32(UInt32(i + 1)) + Mp4.u32(ch.count) + Mp4.u32(1); last = ch.count; k += 1 }
            stbl += Mp4.full("stsc", Mp4.u32(k) + stsc)
            stbl += Mp4.full("stsz", Mp4.u32(0) + Mp4.u32(UInt32(t.sizes.count)) + t.sizes.flatMap { Mp4.u32($0) })
            stbl += Mp4.full("co64", Mp4.u32(UInt32(t.chunks.count)) + t.chunks.flatMap { Mp4.u64($0.offset) })

            let mdhd = Mp4.full("mdhd", version: 1, Mp4.u64(0) + Mp4.u64(0) + Mp4.u32(t.timescale) + Mp4.u64(UInt64(media)) + Mp4.u16(Mp4.packedLanguage(t.language)) + Mp4.u16(0))
            let hdlr = Mp4.full("hdlr", Mp4.u32(0) + Mp4.fourCC(t.isVideo ? "vide" : "soun") + [UInt8](repeating: 0, count: 12) + Array((t.isVideo ? "VideoHandler" : "SoundHandler").utf8) + [0])
            let mediaHeader = t.isVideo ? Mp4.full("vmhd", flags: 1, Mp4.u16(0) + [UInt8](repeating: 0, count: 6)) : Mp4.full("smhd", Mp4.u16(0) + Mp4.u16(0))
            let dinf = Mp4.box("dinf", Mp4.full("dref", Mp4.u32(1) + Mp4.full("url ", flags: 1, [])))
            let minf = Mp4.box("minf", mediaHeader + dinf + Mp4.box("stbl", stbl))
            // Los audios son alternativas entre sí (grupo 1); solo el primero va activado
            let altGroup = t.isVideo ? 0 : 1
            let enabled: UInt32 = (t.isVideo || t.number == tables.first(where: { !$0.isVideo })?.number) ? 3 : 2
            let tkhd = Mp4.full("tkhd", version: 1, flags: enabled,
                                Mp4.u64(0) + Mp4.u64(0) + Mp4.u32(UInt32(t.number)) + Mp4.u32(0) + Mp4.u64(UInt64(gapMs + playMs))
                                + [UInt8](repeating: 0, count: 8) + Mp4.u16(0) + Mp4.u16(altGroup) + Mp4.u16(t.isVideo ? 0 : 0x0100) + Mp4.u16(0)
                                + Mp4.identityMatrix + Mp4.u32(UInt32(t.width) << 16) + Mp4.u32(UInt32(t.height) << 16))
            traks += Mp4.box("trak", tkhd + edts + Mp4.box("mdia", mdhd + hdlr + minf))
        }
        let mvhd = Mp4.full("mvhd", Mp4.u32(0) + Mp4.u32(0) + Mp4.u32(movieScale) + Mp4.u32(UInt32(min(movieDuration, Int64(UInt32.max)))) + Mp4.u32(0x00010000)
                            + Mp4.u16(0x0100) + [UInt8](repeating: 0, count: 10) + Mp4.identityMatrix + [UInt8](repeating: 0, count: 24)
                            + Mp4.u32(UInt32((tables.map { $0.number }.max() ?? 0) + 1)))
        return Mp4.box("moov", mvhd + traks)
    }
}
