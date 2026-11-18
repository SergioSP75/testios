import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HLSCore

// Prueba de extremo a extremo de MkvToHls con una URL real de un MKV.
// Uso: MkvProbe <url> <carpeta_salida> [segmentos]
// Escribe la lista maestra, las de cada pista, los inicios y los primeros segmentos para revisarlos con un lector de cajas MP4.

struct NetFetcher: Fetcher {
    func fetch(_ url: URL, headers: [String: String]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("Mozilla/5.0 (iPad) mediakiller-sp75 MediaKillerSP75", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 400 { cont.resume(throwing: NSError(domain: "HTTP", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])); return }
                cont.resume(returning: data ?? Data())
            }.resume()
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 3, let url = URL(string: args[1]) else { print("uso: MkvProbe <url> <carpeta> [segmentos]"); exit(2) }
let out = URL(fileURLWithPath: args[2])
let count = args.count > 3 ? Int(args[3]) ?? 2 : 2
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func save(_ name: String, _ d: Data) { try? d.write(to: out.appendingPathComponent(name)) }

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let src = HttpRangeSource(fetcher: NetFetcher(), url: url, headers: [:])
        let t0 = Date()
        let m = try await MkvToHls.open(source: src, log: { print("[mkv]", $0) })
        print(String(format: "abierto en %.1f s", Date().timeIntervalSince(t0)))
        if args.count > 4, args[4] == "mp4" {
            var tr = [m.videoTrackNumber]; tr += m.audioTracks.prefix(2).map { $0.number }
            let t0 = Date()
            try await m.exportMp4(tracks: tr, to: out.appendingPathComponent("salida.mp4"), maxSegments: count) { _ in }
            print(String(format: "MP4 escrito en %.1f s", Date().timeIntervalSince(t0)))
            sem.signal(); return
        }
        let master = await m.handle(path: "/master.m3u8"); save("master.m3u8", master.body); print(String(decoding: master.body, as: UTF8.self))
        var tracks = [m.videoTrackNumber]; tracks += m.audioTracks.map { $0.number }
        for t in tracks {
            let pl = await m.handle(path: "/t\(t).m3u8"); save("t\(t).m3u8", pl.body)
            let ini = await m.handle(path: "/init-\(t).mp4"); save("init-\(t).mp4", ini.body)
            print("pista \(t): lista \(pl.body.count) B · init \(ini.status) \(ini.body.count) B")
            for i in 0..<count {
                let t1 = Date()
                let s = await m.handle(path: "/seg-\(t)-\(i).m4s"); save("seg-\(t)-\(i).m4s", s.body)
                print(String(format: "  seg %d: %d %d B en %.2f s", i, s.status, s.body.count, Date().timeIntervalSince(t1)))
            }
        }
    } catch { print("ERROR:", error.localizedDescription) }
    sem.signal()
}
sem.wait()
