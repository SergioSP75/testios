import XCTest
@testable import HLSCore

/// Un MKV pequeño construido a mano: vídeo H.264 con fotogramas B y audio AAC, para probar el paso a HLS fMP4.
private struct MemorySource: MkvSource {
    let bytes: [UInt8]
    func read(offset: Int64, length: Int) async throws -> [UInt8] {
        let a = Int(offset)
        guard a < bytes.count else { return [] }
        return Array(bytes[a..<min(a + length, bytes.count)])
    }
}

private enum B {
    static func size(_ n: Int) -> [UInt8] { [0x10, UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] }          // vint de 4 bytes
    static func id(_ v: UInt32) -> [UInt8] {
        var out: [UInt8] = []; var x = v
        while x > 0 { out.insert(UInt8(x & 0xFF), at: 0); x >>= 8 }
        return out
    }
    static func el(_ i: UInt32, _ payload: [UInt8]) -> [UInt8] { id(i) + size(payload.count) + payload }
    static func uint(_ i: UInt32, _ v: Int) -> [UInt8] { el(i, [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    static func str(_ i: UInt32, _ s: String) -> [UInt8] { el(i, Array(s.utf8)) }
    /// SimpleBlock de la pista `track` con tiempo relativo `rel` (ms), tipo clave o no, y datos.
    static func block(_ track: Int, _ rel: Int, key: Bool, _ data: [UInt8]) -> [UInt8] {
        el(0xA3, [UInt8(0x80 | track), UInt8((rel >> 8) & 0xFF), UInt8(rel & 0xFF), key ? 0x80 : 0x00] + data)
    }
}

final class MkvToHlsTests: XCTestCase {
    /// avcC mínimo (perfil High 4.0) y trama «NAL» de relleno con prefijo de longitud de 4 bytes.
    private let avcC: [UInt8] = [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0x00, 0x04, 0x67, 0x64, 0x00, 0x28, 0x01, 0x00, 0x02, 0x68, 0xEE]
    private func nal(_ n: Int) -> [UInt8] { [0, 0, 0, UInt8(n)] + [UInt8](repeating: 0x65, count: n) }

    private func makeMkv() -> [UInt8] {
        let ebml = B.el(0x1A45DFA3, B.str(0x4282, "matroska"))
        let info = B.el(0x1549A966, B.el(0x2AD7B1, [0x0F, 0x42, 0x40]) + B.el(0x4489, [0x40, 0xC3, 0x88, 0x00, 0, 0, 0, 0]))     // escala 1 ms, duración 10000 ms
        let video = B.el(0xAE, B.uint(0xD7, 1) + B.uint(0x83, 1) + B.str(0x86, "V_MPEG4/ISO/AVC") + B.el(0x63A2, avcC)
                         + B.el(0xE0, B.uint(0xB0, 1280) + B.uint(0xBA, 720)))
        let audio = B.el(0xAE, B.uint(0xD7, 2) + B.uint(0x83, 2) + B.str(0x86, "A_AAC") + B.str(0x22B59C, "spa") + B.el(0x63A2, [0x12, 0x10])
                         + B.el(0xE1, B.el(0xB5, [0x40, 0xE7, 0x70, 0x00, 0, 0, 0, 0]) + B.uint(0x9F, 2)))
        let tracks = B.el(0x1654AE6B, video + audio)
        // Dos clusters de 6 s. Vídeo en orden de decodificación I P B B (presentación 0, 120, 40, 80 ms)
        func cluster(_ t0: Int) -> [UInt8] {
            var c = B.uint(0xE7, t0)
            c += B.block(1, 0, key: true, nal(10)) + B.block(1, 120, key: false, nal(6)) + B.block(1, 40, key: false, nal(4)) + B.block(1, 80, key: false, nal(4))
            c += B.block(2, 0, key: true, [1, 2, 3, 4, 5]) + B.block(2, 21, key: true, [6, 7, 8])
            return B.el(0x1F43B675, c)
        }
        let c1 = cluster(0), c2 = cluster(6000)
        let headLen = ebml.count
        // Posiciones de los clusters relativas al inicio de los datos del Segment: se calculan con el tamaño de Info+Tracks+Cues
        func cues(_ p1: Int, _ p2: Int) -> [UInt8] {
            func cp(_ t: Int, _ p: Int) -> [UInt8] { B.el(0xBB, B.uint(0xB3, t) + B.el(0xB7, B.uint(0xF7, 1) + B.uint(0xF1, p))) }
            return B.el(0x1C53BB6B, cp(0, p1) + cp(6000, p2))
        }
        let cuesLen = cues(0, 0).count
        let p1 = info.count + tracks.count + cuesLen
        let p2 = p1 + c1.count
        let segBody = info + tracks + cues(p1, p2) + c1 + c2
        _ = headLen
        return ebml + B.el(0x18538067, segBody)
    }

    func testMasterYSegmentos() async throws {
        let mkv = try await MkvToHls.open(source: MemorySource(bytes: makeMkv()))
        let master = String(decoding: (await mkv.handle(path: "/master.m3u8")).body, as: UTF8.self)
        XCTAssertTrue(master.contains("avc1.640028"), master)
        XCTAssertTrue(master.contains("mp4a.40.2"))
        XCTAssertTrue(master.contains("RESOLUTION=1280x720"))
        XCTAssertTrue(master.contains("LANGUAGE=\"es\""))
        let pl = String(decoding: (await mkv.handle(path: "/t1.m3u8")).body, as: UTF8.self)
        XCTAssertTrue(pl.contains("seg-1-0.m4s") && pl.contains("seg-1-1.m4s"), pl)

        let ini = await mkv.handle(path: "/init-1.mp4")
        XCTAssertEqual(ini.status, 200)
        XCTAssertTrue(ini.body.range(of: Data("avcC".utf8)) != nil && ini.body.range(of: Data("moov".utf8)) != nil)

        // Segmento de vídeo: 4 muestras, desfases de composición no negativos, DTS creciente
        let seg = [UInt8]((await mkv.handle(path: "/seg-1-0.m4s")).body)
        let boxes = Cenc.boxes(seg, from: 0, to: seg.count)
        XCTAssertEqual(boxes.map { $0.type }, ["moof", "mdat"])
        let mdat = boxes[1]
        XCTAssertEqual(mdat.end - mdat.bodyStart, 4 + 10 + 4 + 6 + 4 + 4 + 4 + 4)       // las cuatro tramas con su prefijo de longitud
        // trun: número de muestras
        let trunAt = seg.firstIndex(of: 0x74).flatMap { _ in (0..<(seg.count - 4)).first { seg[$0] == 0x74 && seg[$0 + 1] == 0x72 && seg[$0 + 2] == 0x75 && seg[$0 + 3] == 0x6E } }
        let t = try XCTUnwrap(trunAt)
        let count = Int(seg[t + 8]) << 24 | Int(seg[t + 9]) << 16 | Int(seg[t + 10]) << 8 | Int(seg[t + 11])
        XCTAssertEqual(count, 4)

        // Audio: dos tramas AAC
        let a = [UInt8]((await mkv.handle(path: "/seg-2-0.m4s")).body)
        let ab = Cenc.boxes(a, from: 0, to: a.count)
        XCTAssertEqual(ab.map { $0.type }, ["moof", "mdat"])
        XCTAssertEqual(ab[1].end - ab[1].bodyStart, 8)

        // Segmento 1 existe y uno inexistente da 404
        let s1 = await mkv.handle(path: "/seg-1-1.m4s")
        XCTAssertEqual(s1.status, 200)
        let bad = await mkv.handle(path: "/seg-1-9.m4s")
        XCTAssertEqual(bad.status, 404)
    }

    func testRechazaDTSySinVideo() async throws {
        // Códecs de audio que AVPlayer no decodifica
        XCTAssertFalse(MkvToHls.audioSupported("A_DTS"))
        XCTAssertFalse(MkvToHls.videoSupported("V_AV1"))
        XCTAssertTrue(MkvToHls.videoSupported("V_MPEGH/ISO/HEVC"))
        // Cadenas de códec
        XCTAssertEqual(CodecStrings.hevc([1, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 120]), "hvc1.2.4.L120.90")
        XCTAssertEqual(CodecStrings.aac([0x12, 0x10]).codec, "mp4a.40.2")
        XCTAssertEqual(CodecStrings.aac([0x12, 0x10]).rate, 44100)
    }

    func testDetectaMatroska() {
        XCTAssertTrue(StreamSniffer.isMatroska(Data([0x1A, 0x45, 0xDF, 0xA3, 1, 2])))
        XCTAssertFalse(StreamSniffer.isMatroska(Data("#EXTM3U".utf8)))
    }
}
