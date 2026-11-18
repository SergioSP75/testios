import SwiftUI
import Network
import CryptoKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import HLSCore

// Transferencia de listas entre dispositivos con código QR. Port de PlaylistTransfer.kt / ListTransferActivity.kt de Android,
// con el MISMO protocolo (así iPad y Android se envían listas entre sí):
//  · Red local: el receptor abre un servidor HTTP mínimo. Dirección: http://<ip>:<puerto>/r/<token>  (el token evita inyecciones).
//  · Internet (relay cifrado): canal aleatorio en ntfy.sh. Dirección: https://ntfy.sh/<canal>#k=<clave>. La clave va solo tras el «#»
//    (no llega al servidor): el relay solo ve AES-256-GCM. El receptor confirma por «<canal>-ack», también cifrado.
// Contenido: {"v":1,"rid":…,"from":…,"lists":[{name,url,isLocal,content?}],"media":[{name,url,isLocal,enabled,content?}]}

// MARK: - Cifrado del relay

enum TransferCodec {
    static let relayBase = "https://ntfy.sh"
    static let prefix = "fk1:"

    struct Relay { var topic: String; var key: Data }

    static func newRelay() -> Relay {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let topic = "fk" + String((0..<22).map { _ in alphabet.randomElement()! })
        return Relay(topic: topic, key: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    }

    /// Base64 «URL» sin relleno (como Base64.URL_SAFE|NO_PADDING de Android).
    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func fromB64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func url(_ r: Relay) -> String { "\(relayBase)/\(r.topic)#k=\(b64url(r.key))" }

    /// Interpreta una dirección pública de receptor; nil si no es de relay.
    static func parse(_ raw: String) -> Relay? {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.lowercased().hasPrefix(relayBase + "/"), let hash = u.range(of: "#k=") else { return nil }
        let topic = String(u[u.index(u.startIndex, offsetBy: relayBase.count + 1)..<hash.lowerBound]).components(separatedBy: "?")[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !topic.isEmpty, let key = fromB64url(String(u[hash.upperBound...]).trimmingCharacters(in: .whitespaces)), key.count == 32 else { return nil }
        return Relay(topic: topic, key: key)
    }

    /// gzip → AES-GCM (IV de 12 bytes delante, etiqueta de 16 detrás, el canal como dato autenticado) → «fk1:» + base64.
    static func encrypt(_ r: Relay, _ plain: Data, channel: String) throws -> String {
        let sealed = try AES.GCM.seal(try Gzip.compress(plain), using: SymmetricKey(data: r.key), authenticating: Data(channel.utf8))
        return prefix + (sealed.combined ?? Data()).base64EncodedString()
    }

    static func decrypt(_ r: Relay, _ message: String, channel: String) throws -> Data {
        guard message.hasPrefix(prefix), let raw = Data(base64Encoded: String(message.dropFirst(prefix.count))) else {
            throw NSError(domain: "Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "mensaje no reconocido"])
        }
        let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: raw), using: SymmetricKey(data: r.key), authenticating: Data(channel.utf8))
        return try Gzip.decompress(plain)
    }

    /// Publica un mensaje en el canal del relay.
    static func publish(topic: String, body: String) async throws {
        guard let u = URL(string: "\(relayBase)/\(topic)") else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = "POST"; req.httpBody = Data(body.utf8); req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NSError(domain: "Transfer", code: code, userInfo: [NSLocalizedDescriptionKey: "el relay respondió HTTP \(code)"]) }
    }

    /// Texto de un evento del relay (o del adjunto, si ntfy lo convirtió en adjunto por tamaño).
    static func text(of ev: [String: Any]) async -> String? {
        if let att = (ev["attachment"] as? [String: Any])?["url"] as? String, let u = URL(string: att),
           let (d, _) = try? await URLSession.shared.data(from: u) { return String(decoding: d, as: UTF8.self) }
        return ev["message"] as? String
    }
}

// MARK: - Cuentas de servidores (Emby, Jellyfin, Plex)

/// Equivale a ServerAccounts.kt: exporta las cuentas con sesión y vuelve a entrar con las recibidas (no se copia ningún token de Emby/Jellyfin).
@MainActor
enum ServerAccounts {
    static func label(_ kind: String) -> String { kind == "jellyfin" ? "Jellyfin" : kind == "plex" ? "Plex" : "Emby" }

    static func hasSession(_ kind: String) -> Bool {
        let hub = ServerHub.shared
        return kind == "jellyfin" ? hub.jellyfin.hasSession() : kind == "plex" ? hub.plex.hasSession() : hub.emby.hasSession()
    }

    /// Cuentas con sesión en este aparato, en el formato del campo «servers».
    static func export() -> [[String: Any]] {
        let hub = ServerHub.shared
        var out: [[String: Any]] = []
        if let a = hub.emby.account() { out.append(["kind": "emby", "mode": a.mode, "url": a.mode == "direct" ? a.serverUrl : "", "user": a.email, "password": a.password]) }
        if let a = hub.jellyfin.account() { out.append(["kind": "jellyfin", "mode": "direct", "url": a.serverUrl, "user": a.email, "password": a.password]) }
        if let t = hub.plex.accountTokenForShare(), !t.isEmpty { out.append(["kind": "plex", "token": t]) }
        return out
    }

    /// Entra con una cuenta recibida; true si quedó conectada.
    static func signIn(_ o: [String: Any]) async -> Bool {
        let hub = ServerHub.shared
        let user = (o["user"] as? String) ?? "", pass = (o["password"] as? String) ?? "", url = (o["url"] as? String) ?? ""
        do {
            switch (o["kind"] as? String) ?? "emby" {
            case "plex":
                var token = (o["token"] as? String) ?? ""
                if token.isEmpty { token = try await hub.plex.signIn(email: user, password: pass) }
                _ = try await hub.plex.finishLogin(accountToken: token)
            case "jellyfin":
                _ = try await hub.jellyfin.loginDirect(serverUrl: url, user: user, password: pass, type: "jellyfin")
            default:
                if (o["mode"] as? String) == "direct" { _ = try await hub.emby.loginDirect(serverUrl: url, user: user, password: pass, type: "emby") }
                else { _ = try await hub.emby.loginConnect(email: user, password: pass) }
            }
            hub.touch()
            return true
        } catch { return false }
    }
}

// MARK: - Aplicar lo recibido

@MainActor
enum TransferApply {
    /// Aplica el contenido recibido y devuelve la respuesta para el emisor (mismos campos que Android).
    /// `confirm` pregunta al usuario del receptor antes de sustituir algo que ya existe (mismo nombre y otra dirección).
    static func apply(_ data: Data, store: PlaylistStore, confirm: (String) async -> Bool) async -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ["ok": false, "error": "contenido no válido"] }
        let from = (root["from"] as? String) ?? "?"
        var added: [String] = [], over: [String] = [], skipped: [String] = []
        var mAdded: [String] = [], mOver: [String] = [], mSkipped: [String] = []
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        func safe(_ n: String) -> String { String(n.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }.prefix(40)) }

        for o in (root["lists"] as? [[String: Any]]) ?? [] {
            let name = ((o["name"] as? String) ?? "").isEmpty ? "Lista recibida" : (o["name"] as! String)
            let url = ((o["url"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let existing = store.playlists.first { $0.name == name }
            if (o["isLocal"] as? Bool) == true, let content = o["content"] as? String, !content.isEmpty {
                // Lista local del emisor: se guarda como fichero propio
                if existing != nil, !(await confirm("La lista «\(name)» ya existe. ¿Sustituirla por la de \(from)?")) { skipped.append(name); continue }
                let file = "lista_\(safe(name)).m3u"
                try? content.write(to: docs.appendingPathComponent(file), atomically: true, encoding: .utf8)
                store.upsertLocal(name: name, fileName: file)
                if existing != nil { over.append(name) } else { added.append(name) }
                continue
            }
            if url.isEmpty { skipped.append("\(name) (sin dirección)"); continue }
            if store.playlists.contains(where: { $0.url == url }) { skipped.append(name); continue }     // misma lista
            if existing != nil, !(await confirm("La lista «\(name)» ya existe con otra dirección. ¿Sustituirla por la de \(from)?")) { skipped.append(name); continue }
            switch store.addOrReplace(name: name, url: url) {
            case "added": added.append(name)
            case "replaced": over.append(name)
            default: skipped.append(name)
            }
        }
        for o in (root["media"] as? [[String: Any]]) ?? [] {
            let name = ((o["name"] as? String) ?? "").isEmpty ? "Mediateca recibida" : (o["name"] as! String)
            let url = ((o["url"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let enabled = (o["enabled"] as? Bool) ?? true
            let existing = MediaLists.shared.lists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if (o["isLocal"] as? Bool) == true, let content = o["content"] as? String, !content.isEmpty {
                if existing != nil, !(await confirm("🎬 La mediateca «\(name)» ya existe. ¿Sustituirla por la de \(from)?")) { mSkipped.append(name); continue }
                let file = "mediateca_\(safe(name)).json"
                try? content.write(to: docs.appendingPathComponent(file), atomically: true, encoding: .utf8)
                _ = MediaLists.shared.addOrReplace(name: name, url: "local:" + file, enabled: enabled, force: true)
                if existing != nil { mOver.append(name) } else { mAdded.append(name) }
                continue
            }
            if url.isEmpty { mSkipped.append("\(name) (sin dirección)"); continue }
            if MediaLists.shared.lists.contains(where: { $0.url == url }) { mSkipped.append(name); continue }
            if existing != nil, !(await confirm("🎬 La mediateca «\(name)» ya existe con otra dirección. ¿Sustituirla por la de \(from)?")) { mSkipped.append(name); continue }
            switch MediaLists.shared.addOrReplace(name: name, url: url, enabled: enabled) {
            case "added": mAdded.append(name)
            case "replaced": mOver.append(name)
            default: mSkipped.append(name)
            }
        }
        // Cuentas de servidores externos (Emby, Jellyfin, Plex): si ya hay sesión de ese tipo se pregunta; el receptor vuelve a entrar él solo
        var envDone: [String] = [], envSkipped = false
        if let env = root["env"] as? [String: Any] {
            var okNames: [String] = []
            for o in (env["servers"] as? [[String: Any]]) ?? [] {
                let kind = (o["kind"] as? String) ?? "emby"
                let label = ServerAccounts.label(kind)
                if ServerAccounts.hasSession(kind), !(await confirm("☁ Ya hay sesión en \(label). ¿Sustituirla por la cuenta de \(from)?")) { envSkipped = true; continue }
                if await ServerAccounts.signIn(o) { okNames.append(label) } else { envSkipped = true }
            }
            if !okNames.isEmpty { envDone.append("servidores externos (\(okNames.joined(separator: ", ")))") }
            // Direcciones y guía: lo único del «entorno» de Android que existe también en iOS (apariencia, botones de barra,
            // Kodi y DLNA no tienen equivalente y se ignoran)
            let epg = ((env["epg"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let days = env["epgCacheDays"] as? Int
            if !epg.isEmpty || days != nil {
                if await confirm("⚙ \(from) envía su configuración del entorno (dirección de la guía y días de guía). ¿Aplicarla? Cambiará la tuya.") {
                    if !epg.isEmpty { UserDefaults.standard.set(epg, forKey: "set.epgUrl") }
                    if let d = days { UserDefaults.standard.set(min(7, max(1, d)), forKey: "set.epgDays") }
                    envDone.append("direcciones")
                } else { envSkipped = true }
            }
        }
        Trace.shared.log("transferir", "recibidas: \(added.count) añadidas, \(over.count) sustituidas, \(skipped.count) omitidas · mediateca \(mAdded.count + mOver.count) · entorno \(envDone.count)")
        return ["ok": true, "rid": (root["rid"] as? String) ?? "", "from": UIDevice.current.name,
                "added": added, "overwritten": over, "skipped": skipped,
                "mediaAdded": mAdded, "mediaOverwritten": mOver, "mediaSkipped": mSkipped,
                "envApplied": envDone, "envSkipped": envSkipped]
    }

    /// Frase para mostrar el resultado (como describeResult de Android).
    static func describe(_ r: [String: Any]) -> (ok: Bool, text: String) {
        guard (r["ok"] as? Bool) == true else { return (false, "El receptor respondió con error: \((r["error"] as? String) ?? "?")") }
        func n(_ k: String) -> Int { (r[k] as? [Any])?.count ?? 0 }
        let who = ((r["from"] as? String).flatMap { $0.isEmpty ? nil : " en \($0)" }) ?? ""
        let media = n("mediaAdded") + n("mediaOverwritten") + n("mediaSkipped") > 0 ? " · Mediateca: \(n("mediaAdded") + n("mediaOverwritten")) recibida(s), \(n("mediaSkipped")) omitida(s)" : ""
        let env = ((r["envApplied"] as? [String]) ?? []).joined(separator: ", ")
        let eTxt = !env.isEmpty ? " · Entorno: \(env)" : ((r["envSkipped"] as? Bool) == true ? " · Entorno: no aplicado" : "")
        return (true, "✔ Recibido\(who): \(n("added")) añadida(s), \(n("overwritten")) sustituida(s), \(n("skipped")) omitida(s)\(media)\(eTxt)")
    }
}

// MARK: - Receptor

@MainActor
final class TransferReceiver: ObservableObject {
    @Published var localAddress = ""         // QR de la red local
    @Published var relayAddress = ""         // QR público (relay cifrado)
    @Published var running = false
    @Published var log: [String] = []
    @Published var question: String?           // pregunta pendiente (sustituir algo existente); la pantalla la enseña como aviso
    private var answer: CheckedContinuation<Bool, Never>?

    /// Pregunta al usuario y espera su respuesta (sí/no).
    func ask(_ text: String) async -> Bool {
        while question != nil, running { try? await Task.sleep(nanoseconds: 200_000_000) }      // de una en una
        guard running else { return false }
        return await withCheckedContinuation { c in answer = c; question = text }
    }

    /// Un envío cada vez (red local e internet pueden llegar a la vez): así las preguntas no se mezclan.
    private var applying = false
    private func process(_ data: Data, via: String) async -> [String: Any] {
        while applying { try? await Task.sleep(nanoseconds: 200_000_000) }
        applying = true; defer { applying = false }
        guard let store = store else { return ["ok": false, "error": "sin almacén"] }
        let from = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["from"] as? String ?? "?"
        note("⏳ Recibiendo de \(from) (\(via))…")
        let result = await TransferApply.apply(data, store: store, confirm: { await self.ask($0) })
        note(TransferApply.describe(result).text)
        return result
    }
    func reply(_ yes: Bool) { question = nil; answer?.resume(returning: yes); answer = nil }

    private var listener: NWListener?
    private var relayTask: Task<Void, Never>?
    private weak var store: PlaylistStore?

    /// Como Android: red local e internet a la vez, cada una con su QR.
    func start(store: PlaylistStore) {
        stop(); self.store = store
        running = true; log = []
        UIApplication.shared.isIdleTimerDisabled = true          // pantalla encendida mientras se espera
        startLocal(); startRelay()
    }

    func stop() {
        listener?.cancel(); listener = nil
        relayTask?.cancel(); relayTask = nil
        reply(false)
        UIApplication.shared.isIdleTimerDisabled = false
        running = false; localAddress = ""; relayAddress = ""
    }

    private func note(_ s: String) { log.insert(s, at: 0) }

    // Red local ---------------------------------------------------------

    private func startLocal() {
        let token = String((0..<12).map { _ in Array("abcdefghijkmnopqrstuvwxyz23456789").randomElement()! })
        var made: NWListener?
        for p in 8765...8775 { if let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(p))!) { made = l; break } }
        guard let l = made ?? (try? NWListener(using: .tcp)) else { note("No se pudo abrir el puerto de la red local"); return }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard case .ready = st, let port = l?.port?.rawValue else { return }
            let ip = LocalHttpServer.lanAddress() ?? "?"
            Task { @MainActor in if ip != "?" { self?.localAddress = "http://\(ip):\(port)/r/\(token)" }; self?.note(ip == "?" ? "Sin wifi: no hay dirección local" : "Esperando en la red local…") }
        }
        l.newConnectionHandler = { [weak self] c in self?.serve(c, token: token) }
        l.start(queue: .global())
        listener = l
    }

    /// Una petición HTTP: POST /r/<token> con el contenido → se aplica y se responde el resultado.
    private nonisolated func serve(_ c: NWConnection, token: String) {
        c.start(queue: .global())
        var buf = Data()
        func respond(_ code: Int, _ body: Data, _ type: String = "application/json; charset=utf-8") {
            let head = "HTTP/1.1 \(code) OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
        func err(_ m: String) -> Data { (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": m])) ?? Data() }
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                if let d = data { buf.append(d) }
                guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else {
                    if done || error != nil || buf.count > 65536 { c.cancel() } else { more() }
                    return
                }
                let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = head.first?.components(separatedBy: " ") ?? []
                let method = first.first ?? "", path = (first.count > 1 ? first[1] : "").components(separatedBy: "?")[0]
                let length = head.compactMap { l -> Int? in l.lowercased().hasPrefix("content-length:") ? Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) : nil }.first ?? 0
                guard path == "/r/\(token)" else { respond(404, err("dirección de receptor no válida")); return }
                if method == "GET" { respond(200, Data("MediaKillerSP75: receptor de listas activo".utf8), "text/plain; charset=utf-8"); return }
                guard method == "POST", length > 0, length <= 10_000_000 else { respond(400, err("petición no válida")); return }
                if buf.count - sep.upperBound < length {
                    if done || error != nil { c.cancel() } else { more() }
                    return
                }
                let body = Data(buf[sep.upperBound..<(sep.upperBound + length)])
                Task { @MainActor [weak self] in
                    guard let self = self else { respond(500, err("sin almacén")); return }
                    let result = await self.process(body, via: "red local")
                    respond(200, (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
                }
            }
        }
        more()
    }

    // Internet (ntfy cifrado) -----------------------------------------------

    private func startRelay() {
        let relay = TransferCodec.newRelay()
        relayAddress = TransferCodec.url(relay)
        note("Esperando por internet…")
        relayTask = Task { [weak self] in
            var since = String(Int(Date().timeIntervalSince1970) - 5)
            while !Task.isCancelled {
                guard let u = URL(string: "\(TransferCodec.relayBase)/\(relay.topic)/json?since=\(since)") else { return }
                var req = URLRequest(url: u); req.timeoutInterval = 75       // ntfy manda un latido cada ~45 s
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        guard let ev = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], (ev["event"] as? String) == "message" else { continue }
                        since = (ev["id"] as? String) ?? since
                        guard let msg = await TransferCodec.text(of: ev), let plain = try? TransferCodec.decrypt(relay, msg, channel: relay.topic) else { continue }
                        await self?.handleRelay(plain, relay: relay)
                    }
                } catch { if Task.isCancelled { return }; try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }
        }
    }

    private func handleRelay(_ plain: Data, relay: TransferCodec.Relay) async {
        let result = await process(plain, via: "URL pública")
        // Confirmación cifrada para el emisor
        let ack = "\(relay.topic)-ack"
        if let d = try? JSONSerialization.data(withJSONObject: result), let m = try? TransferCodec.encrypt(relay, d, channel: ack) {
            try? await TransferCodec.publish(topic: ack, body: m)
        }
    }
}

// MARK: - Emisor

enum TransferSender {
    /// Envía el contenido al receptor (red local o relay) y espera su confirmación.
    static func send(to receiver: String, payload: Data, rid: String) async -> (ok: Bool, text: String) {
        let target = receiver.trimmingCharacters(in: .whitespacesAndNewlines)
        if let relay = TransferCodec.parse(target) { return await sendRelay(relay, payload, rid) }
        guard let u = URL(string: target), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
            return (false, "Dirección no válida: debe empezar por http:// o ser la dirección pública del receptor")
        }
        var req = URLRequest(url: u, timeoutInterval: 150)
        req.httpMethod = "POST"; req.httpBody = payload
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return (false, "Respuesta inesperada del receptor (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
            }
            return await MainActor.run { TransferApply.describe(json) }
        } catch { return (false, "No se pudo conectar con el receptor: \(error.localizedDescription)") }
    }

    private static func sendRelay(_ relay: TransferCodec.Relay, _ payload: Data, _ rid: String) async -> (ok: Bool, text: String) {
        let sentAt = Int(Date().timeIntervalSince1970) - 5
        do { try await TransferCodec.publish(topic: relay.topic, body: try TransferCodec.encrypt(relay, payload, channel: relay.topic)) }
        catch { return (false, "No se pudo enviar al relay: \(error.localizedDescription)") }
        // Espera la confirmación cifrada (hasta 2,5 min)
        let ack = "\(relay.topic)-ack"
        for _ in 0..<75 {
            if let u = URL(string: "\(TransferCodec.relayBase)/\(ack)/json?poll=1&since=\(sentAt)"),
               let (d, _) = try? await URLSession.shared.data(from: u) {
                for line in String(decoding: d, as: UTF8.self).components(separatedBy: "\n") {
                    guard let ev = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], (ev["event"] as? String) == "message",
                          let msg = await TransferCodec.text(of: ev), let plain = try? TransferCodec.decrypt(relay, msg, channel: ack),
                          let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any], (json["rid"] as? String) == rid else { continue }
                    return await MainActor.run { TransferApply.describe(json) }
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return (false, "Enviado, pero el receptor no confirmó en 2,5 min. ¿Está abierta la pantalla de recibir?")
    }

    /// Contenido a enviar: las listas elegidas (las locales llevan su texto) y las de mediateca.
    @MainActor
    static func payload(lists: [PlaylistConfig], media: [MediaListConfig], servers: Bool, env: Bool, rid: String) -> Data {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let l: [[String: Any]] = lists.map { p in
            var o: [String: Any] = ["name": p.name, "url": p.url, "isLocal": false, "forceFfmpeg": false]
            if p.url.hasPrefix("local:"), let text = try? String(contentsOf: docs.appendingPathComponent(String(p.url.dropFirst(6))), encoding: .utf8) {
                o["isLocal"] = true; o["content"] = text
            }
            return o
        }
        let m: [[String: Any]] = media.map { x in
            var o: [String: Any] = ["name": x.name, "url": x.url, "isLocal": false, "enabled": x.enabled]
            if x.url.hasPrefix("local:"), let text = try? String(contentsOf: docs.appendingPathComponent(String(x.url.dropFirst(6))), encoding: .utf8) {
                o["isLocal"] = true; o["content"] = text
            }
            return o
        }
        var root: [String: Any] = ["v": 1, "rid": rid, "from": UIDevice.current.name, "sentAt": Int(Date().timeIntervalSince1970 * 1000), "lists": l, "media": m]
        var e: [String: Any] = [:]
        if servers { e["servers"] = ServerAccounts.export() }
        if env {
            e["epg"] = PlaylistStore.defaultEpgUrl ?? ""
            e["epgCacheDays"] = AppSettings.epgDays
        }
        if !e.isEmpty { root["env"] = e }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}

// MARK: - Pantallas

/// Código QR de un texto.
func qrImage(_ text: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8); f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

/// Transferir listas: recibir (muestra el QR) o enviar (lee el QR del receptor).
struct ListTransferView: View {
    @EnvironmentObject var store: PlaylistStore
    @StateObject private var receiver = TransferReceiver()
    @State private var sending = false
    @State private var target = ""
    @State private var scanning = false
    @State private var pickedLists = Set<String>()
    @State private var pickedMedia = Set<String>()
    @State private var withServers = false
    @State private var withEnv = false
    @State private var status = ""
    @State private var busy = false
    @ObservedObject private var media = MediaLists.shared

    var body: some View {
        List {
            Picker("Modo", selection: $sending) { Text("Recibir").tag(false); Text("Enviar").tag(true) }
                .pickerStyle(.segmented).onChange(of: sending) { now in status = ""; if now { receiver.stop() } else { receiver.start(store: store) } }
            if sending { sendSection } else { receiveSection }
        }
        .themedScreen().navigationTitle("Transferir listas")
        .onAppear {
            if !sending, !receiver.running { receiver.start(store: store) }
            // Como Android: todo marcado de entrada
            if pickedLists.isEmpty && pickedMedia.isEmpty { pickedLists = Set(store.playlists.map { $0.id }); pickedMedia = Set(media.lists.map { $0.id }) }
        }
        .onDisappear { receiver.stop() }
        .alert("Confirmar", isPresented: Binding(get: { receiver.question != nil }, set: { if !$0 { receiver.reply(false) } })) {
            Button("Sustituir", role: .destructive) { receiver.reply(true) }
            Button("Omitir", role: .cancel) { receiver.reply(false) }
        } message: { Text(receiver.question ?? "") }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScannerView { code in target = code; scanning = false }
                    .ignoresSafeArea().navigationTitle("Escanea el QR del receptor").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { scanning = false } } }
            }
        }
    }

    @ViewBuilder private var receiveSection: some View {
        Section {
            Text("Mantén esta pantalla abierta. En el otro aparato: Enviar / recibir listas → Enviar, y escanea uno de estos dos QR.").font(.footnote)
        }
        Section {
            qrBlock("🏠 Red local (misma wifi)", receiver.localAddress, empty: "Sin red local: conecta el aparato a una wifi")
        }
        Section {
            qrBlock("🌍 Pública (cualquier red, cifrada)", receiver.relayAddress, empty: "Preparando…")
        }
        Section("Estado") {
            if receiver.log.isEmpty { Text("⏳ Esperando listas…").font(.footnote) }
            ForEach(Array(receiver.log.enumerated()), id: \.offset) { Text($1).font(.footnote) }
        }
        Section {
            Button(receiver.running ? "Cerrar el receptor" : "Volver a activar el receptor") {
                if receiver.running { receiver.stop() } else { receiver.start(store: store) }
            }
        }
    }

    private func qrBlock(_ title: String, _ address: String, empty: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline.bold())
            if address.isEmpty { Text(empty).font(.footnote).foregroundStyle(.secondary) }
            else {
                if let img = qrImage(address) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220).padding(8).background(.white)
                }
                Text(address).font(.caption2.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                Button("Copiar dirección") { UIPasteboard.general.string = address }.font(.footnote)
            }
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var sendSection: some View {
        Section("Receptor") {
            Button { scanning = true } label: { Label("Escanear el QR del receptor", systemImage: "qrcode.viewfinder") }
            TextField("o pega su dirección", text: $target).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Section("Listas de canales") {
            ForEach(store.playlists) { p in
                Toggle("\(p.url.hasPrefix("local:") ? "📁" : "☁")  \(p.name)\(p.enabled ? "" : "  (desactivada)")", isOn: Binding(get: { pickedLists.contains(p.id) }, set: { if $0 { pickedLists.insert(p.id) } else { pickedLists.remove(p.id) } }))
            }
        }
        if !media.lists.isEmpty {
            Section("Mediateca") {
                ForEach(media.lists) { m in
                    Toggle("🎬  \(m.name)\(m.enabled ? "" : "  (desactivada)")  · Mediateca", isOn: Binding(get: { pickedMedia.contains(m.id) }, set: { if $0 { pickedMedia.insert(m.id) } else { pickedMedia.remove(m.id) } }))
                }
            }
        }
        Section("Configuración") {
            Toggle("⚙ Configuración del entorno (dirección y días de guía)", isOn: $withEnv)
            Toggle("☁ Cuentas de servidores externos (Emby, Jellyfin, Plex)", isOn: $withServers)
        }
        Section {
            Button(busy ? "Enviando…" : "Enviar") { Task { await send() } }
                .disabled(busy || target.trimmingCharacters(in: .whitespaces).isEmpty || (pickedLists.isEmpty && pickedMedia.isEmpty && !withServers && !withEnv))
            if !status.isEmpty { Text(status).font(.footnote) }
        }
    }

    private func send() async {
        busy = true; status = ""
        let rid = UUID().uuidString
        let body = TransferSender.payload(lists: store.playlists.filter { pickedLists.contains($0.id) },
                                          media: media.lists.filter { pickedMedia.contains($0.id) }, servers: withServers, env: withEnv, rid: rid)
        let r = await TransferSender.send(to: target, payload: body, rid: rid)
        status = r.text; busy = false
    }
}

/// Lector de códigos QR con la cámara.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let c = ScannerController(); c.onCode = onCode; return c }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { if ok { self?.setup() } }
            }
        }

        private func setup() {
            guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else { return }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let p = AVCaptureVideoPreviewLayer(session: session)
            p.videoGravity = .resizeAspectFill; p.frame = view.bounds
            view.layer.addSublayer(p); preview = p
            DispatchQueue.global().async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); if session.isRunning { session.stopRunning() } }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true; onCode?(code)
        }
    }
}
