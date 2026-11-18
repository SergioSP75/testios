import Foundation
import Network
import HLSCore

/// Servidor HTTP mínimo en 127.0.0.1 al que AVPlayer pide el vídeo ya descifrado.
/// Solo traslada peticiones a `RelayCore`; soporta GET/HEAD y «Range» (AVPlayer lo usa).
final class LocalHttpServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "relay.http")
    /// Una sesión de reproducción = un RelayCore, identificado por el primer tramo de la ruta (/s1/…).
    private var sessions: [String: RelayHandler] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    /// false si el sistema cerró el puerto (p. ej. al suspender la app): hay que volver a abrirlo
    private(set) var alive = false

    func start() throws {
        listener?.cancel(); listener = nil; alive = false; port = 0
        let params = NWParameters.tcp
        // Escucha también en la wifi: con AirPlay es la Apple TV quien pide los trozos a este dispositivo (en 127.0.0.1 no llegan).
        // Es lo mismo que hace el Cast de Android (CastRelay sirve por la IP de la wifi).
        let l = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = l.port?.rawValue ?? 0; self?.alive = true; ready.signal() }
            if case .failed = st { self?.alive = false; ready.signal() }
            if case .cancelled = st { self?.alive = false }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        listener = l
        if port == 0 { throw NSError(domain: "Relay", code: 1, userInfo: [NSLocalizedDescriptionKey: "no se pudo abrir el relay local"]) }
    }

    /// IPv4 de la wifi (o del cable) de este dispositivo; nil si no hay red local.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }            // wifi/cable; se evitan túneles y datos móviles
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            found = String(cString: host)
            if name == "en0" { break }
        }
        return found
    }

    func stop() { listener?.cancel(); listener = nil }

    func add(id: String, core: RelayHandler) { lock.lock(); sessions[id] = core; lock.unlock() }
    func remove(id: String) { lock.lock(); sessions[id] = nil; lock.unlock() }
    private func core(_ id: String) -> RelayHandler? { lock.lock(); defer { lock.unlock() }; return sessions[id] }

    // MARK: - Conexiones

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    /// Lee hasta la línea en blanco que cierra la cabecera HTTP.
    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                Task { await self.respond(c, head: head) }
            } else if done || err != nil || buf.count > 64 * 1024 {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    private func respond(_ c: NWConnection, head: String) async {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0]), target = String(parts[1])
        var range: String?
        for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
            range = l.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }
        // /<sesion>/<tipo>?u=…  → la sesión es el primer tramo
        let comps = target.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let sid = comps.first.map(String.init), let core = core(sid) else {
            send(c, status: 404, type: "text/plain", body: Data("sesión desconocida".utf8), method: method, range: nil); return
        }
        let rest = comps.count > 1 ? "/" + comps[1] : "/"
        let r = await core.handle(path: rest)
        send(c, status: r.status, type: r.contentType, body: r.body, method: method, range: range)
    }

    private func send(_ c: NWConnection, status: Int, type: String, body: Data, method: String, range: String?) {
        var status = status
        var payload = body
        var extra = ""
        // Range: bytes=a-b → 206 con ese trozo
        if status == 200, let r = range, r.hasPrefix("bytes="), body.count > 0 {
            let spec = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let a = Int(spec.first ?? "") ?? 0
            let b = spec.count > 1 ? (Int(spec[1]) ?? body.count - 1) : body.count - 1
            if a < body.count {
                let end = min(b, body.count - 1)
                payload = body.subdata(in: a..<(end + 1))
                extra = "Content-Range: bytes \(a)-\(end)/\(body.count)\r\n"
                status = 206
            }
        }
        let text = status == 206 ? "Partial Content" : status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
            + "Accept-Ranges: bytes\r\n\(extra)Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        if method != "HEAD" { out.append(payload) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
