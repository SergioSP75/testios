import XCTest
@testable import HLSCore

/// Reconocer el contenedor por los bytes (la extensión de la dirección puede mentir).
final class ContainerSnifferTests: XCTestCase {
    private func d(_ bytes: [UInt8], pad: Int = 4096) -> Data { Data(bytes + [UInt8](repeating: 0, count: max(0, pad - bytes.count))) }
    private func s(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testContenedores() {
        XCTAssertEqual(ContainerSniffer.extension(of: d([0, 0, 0, 0x20] + s("ftypisom") + [0, 0, 2, 0])), "mp4")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0, 0, 0, 0x14] + s("ftypqt  "))), "mov")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0, 0, 0, 0x20] + s("ftypM4A "))), "m4a")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x88] + s("matroska"))), "mkv")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84] + s("webm"))), "webm")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("RIFF") + [0x10, 0, 0, 0] + s("AVI LIST"))), "avi")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("RIFF") + [0x10, 0, 0, 0] + s("WAVEfmt "))), "wav")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("fLaC"))), "flac")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("OggS"))), "ogg")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("FLV") + [1, 5])), "flv")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("ID3") + [3, 0])), "mp3")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0xFF, 0xFB, 0x90, 0x64])), "mp3")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0xFF, 0xF1, 0x50, 0x80])), "aac", "ADTS")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0x00, 0x00, 0x01, 0xBA, 0x44])), "mpg")
        XCTAssertEqual(ContainerSniffer.extension(of: d([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])), "asf")
        XCTAssertEqual(ContainerSniffer.extension(of: d(s("#EXTM3U\n#EXT-X-VERSION:3"))), "m3u8")
        XCTAssertNil(ContainerSniffer.extension(of: d(s("<html>no es vídeo</html>"))))
        XCTAssertNil(ContainerSniffer.extension(of: Data([1, 2])))
    }

    func testTransportStreamPorElPatronDe188() {
        var b = [UInt8](repeating: 0xFF, count: 600)
        for i in stride(from: 0, to: 600, by: 188) { b[i] = 0x47 }
        XCTAssertEqual(ContainerSniffer.extension(of: Data(b)), "ts")
    }

    func testElContenidoMandaSobreLaExtensionDeLaUrl() {
        let mp4 = d([0, 0, 0, 0x20] + s("ftypisom"))
        let ext = ContainerSniffer.extension(of: mp4) ?? EngineChooser.fileExtension(of: "https://h/p/Peli.mkv")
        XCTAssertEqual(ext, "mp4")
        XCTAssertEqual(EngineChooser.choose(setting: .auto, facts: MediaFacts(kind: .other, fileExtension: ext, videoCodecs: ["avc1"], audioCodecs: ["mp4a.40.2"])), .avplayer)
    }
}
