import XCTest
@testable import HLSCore

/// Lo que se ofrece al descargar/ver, para cada formato visto: HLS (TS, fMP4, HEVC, Dolby Vision), DASH, Smooth, MKV,
/// Emby/Jellyfin y Plex. Los manifiestos de `Fixtures/` son reales (Apple, Akamai, Shaka, Unified Streaming, Microsoft).
final class StreamOffersTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }
    private func fixtureData(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    // HLS ---------------------------------------------------------------------------------------------------------

    func testHlsApleHevcOfreceVideosAudiosYSubtitulos() throws {
        let o = StreamOffers.fromHls(try fixture("hls_bipbop_hevc.m3u8"))
        XCTAssertEqual(o.source, "hls")
        XCTAssertFalse(o.videos.isEmpty)
        XCTAssertEqual(o.videos.first?.height, o.heights.first, "ordenadas de mayor a menor")
        XCTAssertTrue(o.videos.contains { $0.codec == "HEVC" }, "trae variantes HEVC")
        XCTAssertTrue(o.videos.contains { $0.codec == "H.264" }, "y H.264")
        XCTAssertTrue(o.audios.contains { $0.codec == "AAC" && $0.channels == 2 })
        XCTAssertTrue(o.audios.contains { $0.codec == "AC-3" && $0.channels == 6 })
        XCTAssertTrue(o.audios.contains { $0.codec == "E-AC-3" && $0.channels == 6 })
        XCTAssertTrue(o.subs.contains { $0.format == "WebVTT" })
        // Etiquetas como Android
        let v = o.videos.first { $0.height == 1080 && $0.codec == "H.264" }
        XCTAssertNotNil(v)
        XCTAssertTrue(v!.label.hasPrefix("1080p · H.264"), v!.label)
        XCTAssertTrue(v!.label.contains("60 fps"), v!.label)
        XCTAssertTrue(o.audios.first { $0.codec == "E-AC-3" }!.label.contains("E-AC-3 5.1"))
    }

    func testHlsConTsClasicoYSinHevcSinHardwareVaAVlc() throws {
        let master = try fixture("hls_bipbop_hevc.m3u8")
        let sinHw = StreamOffers.fromHls(master, facts: MediaFacts(hardwareHevc: false))
        XCTAssertTrue(sinHw.videos.filter { $0.codec == "HEVC" }.allSatisfy { $0.engine == .vlc })
        XCTAssertTrue(sinHw.videos.filter { $0.codec == "H.264" }.allSatisfy { $0.engine == .avplayer })
        let ts = StreamOffers.fromHls(try fixture("hls_bipbop_ts.m3u8"))
        XCTAssertFalse(ts.videos.isEmpty)
        XCTAssertTrue(ts.videos.allSatisfy { $0.engine == .avplayer })
    }

    func testHlsUnifiedStreamingMasterSimple() throws {
        let o = StreamOffers.fromHls(try fixture("hls_tears.m3u8"))
        XCTAssertGreaterThanOrEqual(o.videos.count, 4)
        XCTAssertEqual(o.heights, o.heights.sorted(by: >))
        XCTAssertEqual(Set(o.videos.map { $0.codec }), ["H.264"])
        XCTAssertTrue(o.videos.allSatisfy { $0.mbps > 0 })
    }

    func testHlsDolbyVisionHdrYAudiodescripcion() {
        let m = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="eac",NAME="Español",LANGUAGE="es",CHANNELS="6",URI="a.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="eac",NAME="Español audiodescripción",LANGUAGE="es",CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="6",URI="ad.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="Español",LANGUAGE="es",FORCED=YES,URI="s.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=15000000,AVERAGE-BANDWIDTH=14000000,CODECS="dvh1.05.06,ec-3",RESOLUTION=3840x2160,FRAME-RATE=24,VIDEO-RANGE=PQ,AUDIO="eac",SUBTITLES="s"
        v1.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,CODECS="hvc1.2.4.L153.B0,ec-3",RESOLUTION=3840x2160,VIDEO-RANGE=HLG,AUDIO="eac",SUBTITLES="s"
        v2.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.640028,ec-3",RESOLUTION=1920x1080,AUDIO="eac",SUBTITLES="s"
        v3.m3u8
        """
        let o = StreamOffers.fromHls(m)
        XCTAssertEqual(o.videos.map { $0.codec }, ["Dolby Vision", "HEVC", "H.264"])
        XCTAssertEqual(o.videos[0].range, "Dolby Vision")
        XCTAssertEqual(o.videos[1].range, "HLG")
        XCTAssertEqual(o.audios.count, 2)
        XCTAssertTrue(o.audios.contains { $0.isDescription })
        XCTAssertTrue(o.subs.first!.forced)
        XCTAssertEqual(o.audios.first!.codec, "E-AC-3")
    }

    // DASH ---------------------------------------------------------------------------------------------------------

    func testDashBigBuckBunnyYMultirate() throws {
        let bbb = StreamOffers.fromMpd(try fixture("dash_bbb.mpd"))
        XCTAssertEqual(bbb.source, "dash")
        XCTAssertGreaterThanOrEqual(bbb.videos.count, 3)
        XCTAssertTrue(bbb.videos.allSatisfy { $0.height > 0 && $0.mbps > 0 })
        XCTAssertFalse(bbb.audios.isEmpty)
        let mr = StreamOffers.fromMpd(try fixture("dash_multirate.mpd"))
        XCTAssertGreaterThanOrEqual(mr.videos.count, 2)
        XCTAssertEqual(mr.heights, mr.heights.sorted(by: >))
    }

    func testDashAngelOneTrayVariosSubtitulosVttYAudios() throws {
        let o = StreamOffers.fromMpd(try fixture("dash_angel.mpd"))
        XCTAssertEqual(Set(o.subs.map { $0.lang }), ["en", "el", "fr", "pt-BR"])
        XCTAssertTrue(o.subs.allSatisfy { $0.format == "WebVTT" && !$0.isImage })
        XCTAssertFalse(o.videos.isEmpty)
        XCTAssertEqual(Set(o.videos.map { $0.codec }), ["H.264", "VP9"], "el MPD trae las dos familias")
        XCTAssertEqual(o.videos.count, 10)
        XCTAssertTrue(o.videos.filter { $0.codec == "VP9" }.allSatisfy { $0.engine == .vlc }, "VP9 sin hardware: VLC")
        XCTAssertFalse(o.audios.isEmpty)
    }

    func testDashMultiperiodoDescartaTrickModeYUsaFpsFraccionario() {
        let mpd = """
        <?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S"><Period>
          <AdaptationSet contentType="video" mimeType="video/mp4" frameRate="24000/1001">
            <Representation id="v1" bandwidth="5000000" width="1920" height="1080" codecs="hvc1.2.4.L150.90"/>
            <Representation id="v2" bandwidth="2000000" width="1280" height="720" codecs="avc1.4d401f"/>
          </AdaptationSet>
          <AdaptationSet contentType="video" mimeType="video/mp4"><EssentialProperty schemeIdUri="http://dashif.org/guidelines/trickmode" value="1"/>
            <Representation id="tm" bandwidth="100000" width="320" height="180" codecs="avc1.4d401f"/></AdaptationSet>
          <AdaptationSet contentType="audio" lang="es" mimeType="audio/mp4"><Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
            <Representation id="a1" bandwidth="640000" codecs="ec-3"><AudioChannelConfiguration schemeIdUri="tag:dolby.com,2014:dash:audio_channel_configuration:2011" value="F801"/></Representation></AdaptationSet>
          <AdaptationSet contentType="audio" lang="es" mimeType="audio/mp4"><Role schemeIdUri="urn:mpeg:dash:role:2011" value="description"/>
            <Representation id="a2" bandwidth="96000" codecs="mp4a.40.2"><AudioChannelConfiguration value="2"/></Representation></AdaptationSet>
          <AdaptationSet contentType="text" lang="es" mimeType="application/ttml+xml"><Representation id="t1" bandwidth="1000" codecs="stpp"/></AdaptationSet>
        </Period></MPD>
        """
        let o = StreamOffers.fromMpd(mpd)
        XCTAssertEqual(o.videos.count, 2, "el trick mode no es una calidad")
        XCTAssertEqual(o.videos[0].codec, "HEVC")
        XCTAssertEqual(o.videos[0].fps, 24000.0 / 1001, accuracy: 0.001)
        XCTAssertEqual(o.audios.count, 2)
        XCTAssertEqual(o.audios[0].codec, "E-AC-3"); XCTAssertEqual(o.audios[0].channels, 6, "F801 = 5.1")
        XCTAssertTrue(o.audios[1].isDescription)
        XCTAssertEqual(o.subs.first?.format, "TTML")
    }

    // Smooth -------------------------------------------------------------------------------------------------------

    func testSmoothSuperSpeedway() throws {
        let o = StreamOffers.fromSmooth(try fixture("smooth_superspeedway.xml"))
        XCTAssertEqual(o.source, "smooth")
        XCTAssertGreaterThanOrEqual(o.videos.count, 3)
        XCTAssertTrue(o.videos.allSatisfy { $0.codec == "H.264" && $0.height > 0 })
        XCTAssertEqual(o.heights.first, o.videos.first?.height)
        XCTAssertFalse(o.audios.isEmpty)
        XCTAssertTrue(o.audios.contains { $0.codec == "AAC" })
    }

    // MKV ----------------------------------------------------------------------------------------------------------

    private struct DataSource: MkvSource {
        let bytes: [UInt8]
        func read(offset: Int64, length: Int) async throws -> [UInt8] {
            let a = Int(offset); guard a < bytes.count else { return [] }
            return Array(bytes[a..<min(a + length, bytes.count)])
        }
    }

    func testMkvRealesDeLaSuiteMatroska() async throws {
        for f in ["mkv_test1.head", "mkv_test5.head"] {
            let d = [UInt8](try fixtureData(f))
            XCTAssertTrue(StreamSniffer.isMatroska(Data(d.prefix(8))), f)
            let report = await MkvToHls.survey(source: DataSource(bytes: d))
            XCTAssertNotNil(report, "\(f) se lee")
            let o = StreamOffers.fromMkv(report ?? [])
            XCTAssertEqual(o.source, "mkv")
            XCTAssertFalse(o.videos.isEmpty, f)
            XCTAssertFalse(o.audios.isEmpty, f)
            XCTAssertTrue(o.videos.allSatisfy { $0.height > 0 && $0.width > 0 }, f)
        }
    }

    func testMkvPistaNoDirectaVaAVlc() {
        let r = [MkvToHls.TrackReport(kind: "Vídeo", label: "1920x1080", codec: "AVC", lang: "", direct: true),
                 MkvToHls.TrackReport(kind: "Audio", label: "Español 6ch", codec: "AAC", lang: "es", direct: true),
                 MkvToHls.TrackReport(kind: "Audio", label: "English 6ch", codec: "DTS", lang: "en", direct: false),
                 MkvToHls.TrackReport(kind: "Audio", label: "Commentary 2ch", codec: "OPUS", lang: "en", direct: false)]
        let o = StreamOffers.fromMkv(r)
        XCTAssertEqual(o.videos.first?.height, 1080)
        XCTAssertEqual(o.audios.map { $0.engine }, [.avplayer, .vlc, .vlc])
        XCTAssertEqual(o.audios.map { $0.codec }, ["AAC", "DTS", "Opus"])
        XCTAssertEqual(o.audios[0].channels, 6)
        XCTAssertEqual(o.audios[0].name, "Español")
    }

    // Servidores ---------------------------------------------------------------------------------------------------

    func testEmbyJellyfinMediaStreams() {
        let streams: [[String: Any]] = [
            ["Type": "Video", "Index": 0, "Codec": "hevc", "Width": 3840, "Height": 2160, "BitRate": 25_000_000, "VideoRangeType": "DOVIWithHDR10", "RealFrameRate": 23.976],
            ["Type": "Audio", "Index": 1, "Codec": "truehd", "Language": "eng", "DisplayTitle": "English - TrueHD - 7.1", "Channels": 8],
            ["Type": "Audio", "Index": 2, "Codec": "eac3", "Language": "spa", "DisplayTitle": "Spanish - EAC3 - 5.1", "Channels": 6, "BitRate": 640_000],
            ["Type": "Subtitle", "Index": 3, "Codec": "subrip", "Language": "spa", "DisplayTitle": "Spanish - SRT"],
            ["Type": "Subtitle", "Index": 4, "Codec": "hdmv_pgs_subtitle", "Language": "eng", "DisplayTitle": "English - PGS", "IsForced": true],
        ]
        let o = StreamOffers.fromEmbyStreams(streams)
        XCTAssertEqual(o.videos.first?.label, "2160p · HEVC · Dolby Vision · 25.0 Mbps")
        XCTAssertEqual(o.audios.map { $0.codec }, ["TrueHD", "E-AC-3"])
        XCTAssertEqual(o.audios.map { $0.engine }, [.vlc, .avplayer])
        XCTAssertEqual(o.subs.map { $0.format }, ["SRT", "PGS"])
        XCTAssertEqual(o.subs.map { $0.isImage }, [false, true])
        XCTAssertTrue(o.subs[1].forced)
        XCTAssertEqual(o.audioLanguages.map { $0.code }, ["eng", "spa"])
    }

    func testPlexStreams() {
        let streams: [[String: Any]] = [
            ["id": 100, "streamType": 1, "codec": "h264", "width": 1920, "height": 1080, "bitrate": 8000, "frameRate": "23.976", "colorTrc": "bt709"],
            ["id": 101, "streamType": 2, "codec": "dca", "languageTag": "en", "displayTitle": "English (DTS 5.1)", "channels": 6, "bitrate": 1509],
            ["id": 102, "streamType": 2, "codec": "aac", "languageTag": "es", "displayTitle": "Español (AAC Stereo)", "channels": 2],
            ["id": 103, "streamType": 3, "codec": "ass", "languageTag": "es", "displayTitle": "Español (ASS)"],
            ["id": 104, "streamType": 3, "codec": "pgs", "languageTag": "en", "displayTitle": "English (PGS)"],
        ]
        let o = StreamOffers.fromPlexStreams(streams)
        XCTAssertEqual(o.videos.first?.label, "1080p · H.264 · 8.0 Mbps")
        XCTAssertEqual(o.audios.map { $0.engine }, [.vlc, .avplayer], "dca = DTS")
        XCTAssertEqual(o.audios[0].kbps, 1509)
        XCTAssertEqual(o.subs.map { $0.format }, ["ASS", "PGS"])
    }

    // Nombres de códec -------------------------------------------------------------------------------------------

    func testNombresDeCodec() {
        XCTAssertEqual(["avc1.64002A", "hvc1.2.4.L150.90", "hev1.1.6.L93.B0", "dvh1.05.06", "vp09.00.40.08", "av01.0.08M.08", "V_MPEGH/ISO/HEVC", "V_MPEG4/ISO/AVC", "V_MPEG2", "H264", "WVC1", "mp4v.20.9"].map(CodecNames.video),
                       ["H.264", "HEVC", "HEVC", "Dolby Vision", "VP9", "AV1", "HEVC", "H.264", "MPEG-2", "H.264", "VC-1", "MPEG-4"])
        XCTAssertEqual(["mp4a.40.2", "mp4a.40.5", "ec-3", "ac-3", "A_EAC3", "A_DTS", "A_TRUEHD", "opus", "A_VORBIS", "A_FLAC", "mp4a.6B", "dca"].map(CodecNames.audio),
                       ["AAC", "HE-AAC", "E-AC-3", "AC-3", "E-AC-3", "DTS", "TrueHD", "Opus", "Vorbis", "FLAC", "MP3", "DTS"])
        XCTAssertTrue(CodecNames.subtitle("hdmv_pgs_subtitle").image)
        XCTAssertTrue(CodecNames.subtitle("S_VOBSUB").image)
        XCTAssertFalse(CodecNames.subtitle("wvtt").image)
        XCTAssertEqual(CodecNames.subtitle("stpp.ttml.im1t").name, "TTML")
    }
}
