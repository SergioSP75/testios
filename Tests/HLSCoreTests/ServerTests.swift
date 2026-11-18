import XCTest
@testable import HLSCore

/// Servidor simulado: devuelve el JSON que corresponda a cada ruta y apunta las peticiones recibidas.
final class FakeHTTP: ServerHTTP {
    var routes: [(match: String, status: Int, body: String)] = []
    var log: [(url: String, headers: [String: String], body: String)] = []

    func send(url: String, method: String, body: Data?, headers: [String: String], timeout: TimeInterval) async throws -> (status: Int, data: Data) {
        log.append((url, headers, body.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
        // La ruta más específica (la más larga) gana
        guard let r = routes.filter({ url.contains($0.match) }).max(by: { $0.match.count < $1.match.count }) else { return (404, Data()) }
        return (r.status, Data(r.body.utf8))
    }
}

final class ServerTests: XCTestCase {

    private func emby(_ http: FakeHTTP, slot: String = "emby") -> EmbyClient { EmbyClient(http: http, store: MemoryStore(), slot: slot) }

    func testJellyfinLoginYCabeceras() async throws {
        let http = FakeHTTP()
        http.routes = [("/Users/AuthenticateByName", 200, #"{"AccessToken":"tok","User":{"Id":"u1"}}"#),
                       ("/System/Info/Public", 200, #"{"ServerName":"Casa"}"#),
                       ("/Views", 200, #"{"Items":[{"Id":"lib1","Name":"Películas","Type":"CollectionFolder","CollectionType":"movies"}],"TotalRecordCount":1}"#)]
        let c = emby(http, slot: "jellyfin")
        let acc = try await c.loginDirect(serverUrl: "192.168.0.5:8096", user: "ana", password: "x", type: "jellyfin")
        XCTAssertEqual(acc.serverUrl, "http://192.168.0.5:8096")
        XCTAssertEqual(c.serverLabel(), "Casa (Jellyfin)")
        let login = http.log.first!
        XCTAssertTrue(login.headers["Authorization"]?.hasPrefix("MediaBrowser Client=\"MediaKillerSP75\"") == true)
        XCTAssertTrue(login.headers["User-Agent"]?.hasPrefix("Mozilla") == true, "el UA debe empezar por Mozilla")

        let libs = try await c.libraries()
        XCTAssertEqual(libs.map { $0.name }, ["Películas"])
        XCTAssertTrue(libs[0].isFolder)
        // Jellyfin usa Authorization: MediaBrowser Token=…
        XCTAssertEqual(http.log.last!.headers["Authorization"], "MediaBrowser Token=\"tok\"")
    }

    func testEmbyItemsYPoster() async throws {
        let http = FakeHTTP()
        http.routes = [("/Users/AuthenticateByName", 200, #"{"AccessToken":"tok","User":{"Id":"u1"}}"#),
                       ("/Items?", 200, #"{"Items":[{"Id":"m1","Name":"Avatar","Type":"Movie","ProductionYear":2022,"CommunityRating":7.64,"RunTimeTicks":120000000000,"ImageTags":{"Primary":"x"}}],"TotalRecordCount":42}"#)]
        let c = emby(http)
        try await c.loginDirect(serverUrl: "http://srv:8096", user: "a", password: "b")
        let page = try await c.items(parentId: "lib1", search: "ava tar", start: 0, limit: 20, filter: ServerFilter(sort: .year, genre: "Acción"))
        XCTAssertEqual(page.total, 42)
        XCTAssertEqual(page.items[0].rating, "7.6")
        XCTAssertEqual(page.items[0].runtimeSec, 12000)
        let q = http.log.last!.url
        XCTAssertTrue(q.contains("ParentId=lib1") && q.contains("SearchTerm=ava%20tar") && q.contains("Genres=Acci%C3%B3n") && q.contains("SortOrder=Descending"))
        XCTAssertEqual(http.log.last!.headers["X-Emby-Token"], "tok")
        XCTAssertEqual(c.posterUrl(page.items[0]), "http://srv:8096/Items/m1/Images/Primary?maxWidth=360&quality=88&api_key=tok")
    }

    func testEmbyStreamDirectoHlsYStrm() async throws {
        let http = FakeHTTP()
        http.routes = [("/Users/AuthenticateByName", 200, #"{"AccessToken":"tok","User":{"Id":"u1"}}"#),
                       ("/Items/m1?Fields=MediaSources", 200, #"{"MediaSources":[{"Id":"src1","MediaStreams":[{"Type":"Audio","Language":"spa","Index":1},{"Type":"Subtitle","Language":"spa","Index":3}]}]}"#),
                       ("/Items/strm1?Fields=MediaSources", 200, #"{"MediaSources":[{"Id":"s","IsRemote":true,"Path":"https://cdn.example/x.mpd"}]}"#)]
        let c = emby(http)
        try await c.loginDirect(serverUrl: "http://srv:8096", user: "a", password: "b")
        let item = EmbyItem(id: "m1", name: "P", type: "Movie")
        // Por defecto: fichero original
        var url = try await c.streamUrl(item)
        XCTAssertEqual(url, "http://srv:8096/Videos/m1/stream?static=true&api_key=tok")
        // Con tope de bitrate y audio/subtítulos en español: HLS del servidor
        var s = EmbyStreamSettings(); s.maxMbps = 8; s.audioLang = "spa"; s.subLang = "spa"; c.saveStreamSettings(s)
        url = try await c.streamUrl(item)
        XCTAssertTrue(url!.contains("/Videos/m1/master.m3u8?MediaSourceId=src1") && url!.contains("MaxStreamingBitrate=8000000")
                      && url!.contains("AudioStreamIndex=1") && url!.contains("SubtitleStreamIndex=3&SubtitleMethod=Encode"))
        // .strm remoto: se reproduce directamente su dirección
        let strm = try await c.streamUrl(EmbyItem(id: "strm1", name: "S", type: "Movie"))
        XCTAssertEqual(strm, "https://cdn.example/x.mpd")
    }

    func testPlexServidoresYStream() async throws {
        let http = FakeHTTP()
        http.routes = [
            ("/api/v2/users/signin", 200, #"{"authToken":"acct"}"#),
            ("/api/v2/resources", 200, #"[{"name":"Mi Plex","provides":"server","clientIdentifier":"mid1","accessToken":"stok","owned":true,"connections":[{"uri":"https://relay.plex/x","relay":true},{"uri":"http://192.168.0.9:32400","local":true},{"uri":"https://pub.example:32400","local":false}]},{"name":"Cliente","provides":"player","clientIdentifier":"p"}]"#),
            ("/identity", 200, "{}"),
            ("/library/sections", 200, #"{"MediaContainer":{"Directory":[{"key":"1","title":"Cine","type":"movie"},{"key":"2","title":"Música","type":"artist"}]}}"#),
            ("/library/metadata/77", 200, #"{"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"key":"/library/parts/9/file.mkv","Stream":[{"id":11,"streamType":2,"languageCode":"spa"}]}]}]}]}}"#)]
        let c = PlexClient(http: http, store: MemoryStore())
        let tok = try await c.signIn(email: "a@b", password: "p")
        let names = try await c.finishLogin(accountToken: tok)
        XCTAssertEqual(names, ["Mi Plex"])
        XCTAssertEqual(c.servers()[0].urls, ["http://192.168.0.9:32400", "https://pub.example:32400", "https://relay.plex/x"], "local, pública y relay al final")
        XCTAssertTrue(c.hasSession())

        let libs = try await c.libraries()
        XCTAssertEqual(libs.map { $0.name }, ["Cine"], "solo películas y series")
        XCTAssertEqual(libs[0].id, "mid1~1")

        let item = EmbyItem(id: "mid1~77", name: "P", type: "Movie")
        var url = try await c.streamUrl(item)
        XCTAssertEqual(url, "http://192.168.0.9:32400/library/parts/9/file.mkv?X-Plex-Token=stok")
        var cfg = PlexServerSettings(); cfg.mode = 2; cfg.audioLang = "spa"; c.saveConfig("mid1", cfg)
        url = try await c.streamUrl(item)
        XCTAssertTrue(url!.contains("/video/:/transcode/universal/start.m3u8?") && url!.contains("audioStreamID=11") && url!.contains("X-Plex-Token=stok"))
    }

    func testErroresClaros() async {
        let http = FakeHTTP()
        http.routes = [("/Users/AuthenticateByName", 401, "")]
        do { _ = try await emby(http).loginDirect(serverUrl: "srv", user: "a", password: "mala"); XCTFail("debía fallar") }
        catch { XCTAssertEqual((error as? ServerError)?.message, "Usuario o contraseña no válidos") }
    }
}
