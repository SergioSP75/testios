import XCTest
@testable import HLSCore

final class SubtitleTests: XCTestCase {
    func testTtmlAWebVtt() {
        let ttml = """
        <?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" tickRate="10000000" frameRate="25">
         <body><div>
          <p begin="00:00:01.500" end="00:00:03.000">Hola<br/>mundo</p>
          <p begin="15000000t" end="45000000t"><span tts:fontStyle="italic">Cursiva</span> normal</p>
          <p begin="00:00:10:12" end="12s">Con fotogramas</p>
         </div></body></tt>
        """
        let vtt = TtmlToVtt.convert(ttml)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:01.500 --> 00:00:03.000\nHola\nmundo"))
        XCTAssertTrue(vtt.contains("00:00:01.500 --> 00:00:04.500\n<i>Cursiva</i> normal"), "ticks: 15000000t = 1,5 s")
        XCTAssertTrue(vtt.contains("00:00:10.480 --> 00:00:12.000\nCon fotogramas"), "10 s + 12/25 fotogramas")
    }

    func testWebVttSePasaTalCual() {
        XCTAssertEqual(TtmlToVtt.convert("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx\n"), "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx\n")
    }

    func testSubtitulosExternosEnListaMaestra() {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS=\"avc1\"\nhttp://127.0.0.1:1/s1/m3u8?u=AA\n"
        let out = HlsRewriter.addSubtitles(master, [ExternalSubtitle(url: "https://x/es.ttml2", lang: "es-es", name: "Español (forzados)", forced: true)],
                                           relay: "http://127.0.0.1:1/s1", durationSec: 3600)
        XCTAssertTrue(out.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"Español (forzados)\",LANGUAGE=\"es-es\",FORCED=YES"))
        XCTAssertTrue(out.contains("SUBTITLES=\"subs\""))
        XCTAssertTrue(out.contains("/s1/subpl?u="))
    }
}
