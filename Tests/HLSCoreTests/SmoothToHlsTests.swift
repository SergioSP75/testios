import XCTest
@testable import HLSCore

/// Smooth Streaming → HLS fMP4: manifiesto de ejemplo pequeño (un vídeo H.264 y un audio AAC en directo).
final class SmoothToHlsTests: XCTestCase {
    let xml = """
    <SmoothStreamingMedia MajorVersion="2" MinorVersion="0" TimeScale="10000000" Duration="0" IsLive="TRUE" LookAheadFragmentCount="2">
      <StreamIndex Type="audio" Name="audio-20000" Language="spa" TimeScale="10000000" Url="QualityLevels({bitrate})/Fragments(audio-20000={start time})">
        <QualityLevel Index="0" Bitrate="128000" FourCC="AACL" SamplingRate="48000" Channels="2" CodecPrivateData="1190" />
        <c t="1000" d="20000000" /><c d="20000000" /><c d="20000000" /><c d="20000000" /><c d="20000000" />
      </StreamIndex>
      <StreamIndex Type="video" Name="video" TimeScale="10000000" Url="QualityLevels({bitrate})/Fragments(video={start time})" MaxWidth="640" MaxHeight="360">
        <QualityLevel Index="0" Bitrate="700000" FourCC="AVC1" MaxWidth="640" MaxHeight="360" CodecPrivateData="00000001674D401EA9181405FF2E02200000030002000003003C0000000168EE3C80" />
        <c t="1000" d="20000000" /><c d="20000000" /><c d="20000000" /><c d="20000000" /><c d="20000000" />
      </StreamIndex>
    </SmoothStreamingMedia>
    """
    let url = URL(string: "https://cdn.example.com/x/index.isml/Manifest?tok=1")!

    func testMaestra() throws {
        let m = try SmoothToHls.master(xml, manifestUrl: url, relay: "http://r/s1")
        XCTAssertTrue(m.contains("CODECS=\"avc1.4D401E,mp4a.40.2\""), m)
        XCTAssertTrue(m.contains("RESOLUTION=640x360"))
        XCTAssertTrue(m.contains("AUDIO=\"aud\""))
        XCTAssertTrue(m.contains("LANGUAGE=\"spa\""))
    }

    func testListaDeFragmentos() throws {
        let p = try SmoothToHls.mediaPlaylist(xml, manifestUrl: url, stream: "video", bitrate: 700000, relay: "http://r/s1")
        XCTAssertEqual(p.components(separatedBy: "#EXTINF").count - 1, 3, "5 fragmentos menos 2 de «mirar adelante»")
        XCTAssertTrue(p.contains("#EXT-X-MAP:URI=\"http://r/s1/ssi?"))
        XCTAssertFalse(p.contains("ENDLIST"))
    }

    func testDireccionDeFragmento() {
        let u = SmoothToHls.fragmentUrl(manifestUrl: url, relative: "QualityLevels(700000)/Fragments(video=1000)")
        XCTAssertEqual(u?.absoluteString, "https://cdn.example.com/x/index.isml/QualityLevels(700000)/Fragments(video=1000)?tok=1")
    }

    func testInicioTieneMoovConAvcC() throws {
        let i = try SmoothToHls.initSegment(xml, stream: "video", bitrate: 700000)
        XCTAssertTrue(Cenc.isInit(i))
        XCTAssertTrue(String(decoding: i, as: UTF8.self).contains("avcC"))
        let a = try SmoothToHls.initSegment(xml, stream: "audio-20000", bitrate: 128000)
        XCTAssertTrue(String(decoding: a, as: UTF8.self).contains("esds"))
        // Todas las cajas encajan en el tamaño total
        XCTAssertEqual(Cenc.boxes(i, from: 0, to: i.count).map { $0.size }.reduce(0, +), i.count)
    }

    func testFragmentoRecibeTfdtYPistaUno() {
        func box(_ t: String, _ body: [UInt8]) -> [UInt8] { let n = 8 + body.count; return [UInt8(n >> 24), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + Array(t.utf8) + body }
        let tfhd = box("tfhd", [0, 0, 0, 0, 0, 0, 0, 7])                       // pista 7
        let trun = box("trun", [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 100])          // flags data_offset, 0 muestras, offset 100
        let moof = box("moof", box("traf", tfhd + trun))
        let seg = moof + box("mdat", [1, 2, 3])
        let out = SmoothToHls.fixFragment(seg, start: 0x1234)
        XCTAssertEqual(out.count, seg.count + 20)
        let moofB = Cenc.boxes(out, from: 0, to: out.count)[0]
        XCTAssertEqual(moofB.size, moof.count + 20)
        let traf = Cenc.boxes(out, from: moofB.bodyStart, to: moofB.end)[0]
        let kids = Cenc.boxes(out, from: traf.bodyStart, to: traf.end)
        XCTAssertEqual(kids.map { $0.type }, ["tfhd", "tfdt", "trun"])
        XCTAssertEqual(Cenc.u32(out, kids[0].bodyStart + 4), 1)                  // pista 1
        XCTAssertEqual(Cenc.u32(out, kids[2].bodyStart + 8), 120)                // data_offset +20
    }
}

/// Tivify: `$Time$` con timescale 90000 supera los 32 bits; no debe desbordarse al rellenar la plantilla.
final class MpdTimeOverflowTests: XCTestCase {
    func testTimeGrandeNoSeDesborda() async throws {
        let xml = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="dynamic" profiles="urn:mpeg:dash:profile:isoff-live:2011"><Period>
        <AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="90000" initialization="v_init.mp4" media="v_$Time$.m4s"><SegmentTimeline><S t="8313393920" d="720000" r="2"/></SegmentTimeline></SegmentTemplate>
        <Representation id="0" bandwidth="1000" codecs="avc1.640020" width="1280" height="720"/></AdaptationSet></Period></MPD>
        """
        let out = try await MpdToHls.mediaPlaylist(xml, base: URL(string: "https://x.example/a/b.mpd")!, repId: "0", relay: "http://r") { _, _, _ in Data() }
        let urls = out.components(separatedBy: "\n").filter { $0.contains("/seg?") }.compactMap { l in l.components(separatedBy: "u=").last?.components(separatedBy: "&").first }.compactMap(HlsRewriter.decode)
        XCTAssertTrue(urls.first?.hasSuffix("v_8313393920.m4s") ?? false, "\(urls)")
        XCTAssertTrue(urls.last?.hasSuffix("v_8314833920.m4s") ?? false, "\(urls)")
    }
}

/// gzip: el CRC-32 de «123456789» es 0xCBF43926 (valor de referencia del estándar).
final class GzipCrcTests: XCTestCase {
    func testCrc32() { XCTAssertEqual(Gzip.crc32(Data("123456789".utf8)), 0xCBF43926) }
}
