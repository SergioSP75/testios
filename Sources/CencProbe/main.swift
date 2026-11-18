import Foundation
import HLSCore

// Herramienta de pruebas: descifra un segmento real y comprueba que el vídeo queda bien formado.
// Uso: CencProbe <init.mp4> <segmento.m4s> <claves.json>
let args = CommandLine.arguments
guard args.count == 4,
      let initData = FileManager.default.contents(atPath: args[1]),
      let segData = FileManager.default.contents(atPath: args[2]),
      let keyData = FileManager.default.contents(atPath: args[3]) else {
    print("Uso: CencProbe <init.mp4> <segmento.m4s> <claves.json>"); exit(2)
}
let initBytes = [UInt8](initData)
var seg = [UInt8](segData)
let keys = parseClearKeysHexMap(String(data: keyData, encoding: .utf8))

print("esquema:", Cenc.scheme(initBytes) ?? "(claro)", "| KID:", Cenc.kid(initBytes) ?? "?")
guard let kid = Cenc.kid(initBytes), let keyHex = keys[kid] else {
    print("SIN CLAVE para ese KID. Claves disponibles:", keys.keys.sorted().map { String($0.prefix(8)) })
    exit(1)
}
let key = stride(from: 0, to: 32, by: 2).map { i -> UInt8 in
    let s = keyHex.index(keyHex.startIndex, offsetBy: i)
    return UInt8(keyHex[s..<keyHex.index(s, offsetBy: 2)], radix: 16)!
}
let tenc = Cenc.tenc(initBytes)
do {
    let n = try Cenc.decryptSegment(&seg, key: key, cbcs: Cenc.scheme(initBytes) == "cbcs" ? tenc : nil)
    print("muestras descifradas:", n)
} catch { print("ERROR:", error); exit(1) }

// Comprobar el vídeo: las muestras AVCC son [longitud de 4 bytes + NAL]; en claro cuadran y el bit prohibido es 0.
func valid(_ b: [UInt8]) -> (ok: Int, bad: Int) {
    var ok = 0, bad = 0
    for box in Cenc.boxes(b, from: 0, to: b.count) where box.type == "mdat" {
        var p = box.bodyStart
        while p + 5 < box.end {
            let len = Cenc.u32(b, p)
            if len <= 0 || p + 4 + len > box.end || b[p + 4] & 0x80 != 0 { bad += 1; break }
            ok += 1; p += 4 + len
        }
    }
    return (ok, bad)
}
let r = valid(seg)
print("NAL válidas:", r.ok, "| mdat con fallo:", r.bad, r.bad == 0 && r.ok > 0 ? "→ OK" : "→ MAL")
exit(r.bad == 0 && r.ok > 0 ? 0 : 1)
