import XCTest
@testable import HLSCore

/// Catálogo de pistas y cabeceras propias en los servidores externos (red simulada).
final class ServerOffersTests: XCTestCase {
    private func clearHeaders() { UserDefaults.standard.removeObject(forKey: "set.serverHeaders") }
    override func setUp() { clearHeaders() }
    override func tearDown() { clearHeaders() }

    func testEmbyDaElCatalogoDeUnaPeliculaConDtsYPgs() async throws {
        let http = FakeHTTP()
        http.routes = [("/Users/AuthenticateByName", 200, #"{"AccessToken":"tok","User":{"Id":"u1"}}"#),
                       ("/Items/m1?Fields=MediaSources", 200, #"""
                       {"MediaSources":[{"Id":"s1","MediaStreams":[
                         {"Type":"Video","Index":0,"Codec":"hevc","Width":3840,"Height":2160,"BitRate":30000000,"VideoRangeType":"HDR10"},
                         {"Type":"Audio","Index":1,"Codec":"dts","Language":"eng","DisplayTitle":"English DTS-HD MA 7.1","Channels":8},
                         {"Type":"Audio","Index":2,"Codec":"ac3","Language":"spa","DisplayTitle":"Español AC3 5.1","Channels":6,"BitRate":640000},
                         {"Type":"Subtitle","Index":3,"Codec":"hdmv_pgs_subtitle","Language":"eng","DisplayTitle":"English PGS"},
                         {"Type":"Subtitle","Index":4,"Codec":"subrip","Language":"spa","DisplayTitle":"Español SRT"}]}]}
                       """#)]
        let c = EmbyClient(http: http, store: MemoryStore())
        try await c.loginDirect(serverUrl: "http://srv:8096", user: "a", password: "b")
        let o = await c.streamOffer(EmbyItem(id: "m1", name: "P", type: "Movie"))
        XCTAssertNotNil(o)
        XCTAssertEqual(o?.videos.first?.label, "2160p · HEVC · HDR10 (PQ) · 30.0 Mbps")
        XCTAssertEqual(o?.audios.map { $0.engine }, [.vlc, .avplayer], "DTS solo VLC; AC-3 AVPlayer")
        XCTAssertEqual(o?.subs.map { $0.isImage }, [true, false])
        XCTAssertEqual(o?.audioLanguages.map { $0.code }, ["eng", "spa"])
    }

    func testPlexDaElCatalogoDeLaParte() async throws {
        let http = FakeHTTP()
        http.routes = [
            ("/api/v2/users/signin", 200, #"{"authToken":"acct"}"#),
            ("/api/v2/resources", 200, #"[{"name":"Mi Plex","provides":"server","clientIdentifier":"mid1","accessToken":"stok","owned":true,"connections":[{"uri":"http://192.168.0.9:32400","local":true}]}]"#),
            ("/identity", 200, "{}"),
            ("/library/metadata/77", 200, #"{"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"key":"/library/parts/9/file.mkv","Stream":[{"id":10,"streamType":1,"codec":"h264","width":1920,"height":1080,"bitrate":9000},{"id":11,"streamType":2,"codec":"eac3","languageTag":"es","displayTitle":"Español (EAC3 5.1)","channels":6},{"id":12,"streamType":3,"codec":"srt","languageTag":"es","displayTitle":"Español (SRT)"}]}]}]}]}}"#)]
        let c = PlexClient(http: http, store: MemoryStore())
        _ = try await c.finishLogin(accountToken: try await c.signIn(email: "a@b", password: "p"))
        let o = await c.streamOffer(EmbyItem(id: "mid1~77", name: "P", type: "Movie"))
        XCTAssertEqual(o?.videos.count, 1)
        XCTAssertEqual(o?.audios.first?.codec, "E-AC-3")
        XCTAssertEqual(o?.subs.first?.format, "SRT")
    }

    func testCabecerasPropiasDeServidorLlegaAlServidor() async throws {
        ServerHeaders.text = "X-Proxy-Key: clave123\nUser-Agent: Mozilla/5.0 prueba"
        let http = FakeHTTP()
        http.routes = [("/Users/AuthenticateByName", 200, #"{"AccessToken":"tok","User":{"Id":"u1"}}"#),
                       ("/Views", 200, #"{"Items":[],"TotalRecordCount":0}"#)]
        let c = EmbyClient(http: http, store: MemoryStore())
        try await c.loginDirect(serverUrl: "http://srv:8096", user: "a", password: "b")
        _ = try await c.libraries()
        for r in http.log {
            XCTAssertEqual(r.headers["X-Proxy-Key"], "clave123", r.url)
            XCTAssertEqual(r.headers["User-Agent"], "Mozilla/5.0 prueba", "las propias mandan sobre el UA del cliente")
        }
        XCTAssertGreaterThanOrEqual(http.log.count, 2)
    }

    func testCabecerasPropiasTambienEnPlex() async throws {
        ServerHeaders.text = "X-Proxy-Key: p1"
        let http = FakeHTTP()
        http.routes = [("/api/v2/users/signin", 200, #"{"authToken":"acct"}"#)]
        let c = PlexClient(http: http, store: MemoryStore())
        _ = try await c.signIn(email: "a@b", password: "p")
        XCTAssertEqual(http.log.first?.headers["X-Proxy-Key"], "p1")
    }
}
