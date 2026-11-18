import SwiftUI

/// Pantalla del modo de pruebas automáticas: se pone la dirección del PC y se lanza.
struct TestView: View {
    @StateObject private var runner = TestRunner()
    @AppStorage("testServer") private var server = "http://192.168.0.95:8800"

    var body: some View {
        VStack(spacing: 12) {
            TextField("Servidor de pruebas (PC)", text: $server)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button(runner.running ? "Probando…" : "Lanzar pruebas") {
                Task { await runner.run(server: server) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.running)
            // Vista previa del caso en curso: así se ve si hay imagen
            if let m = runner.current, let p = m.player {
                PlayerSurface(player: p).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            List(runner.log, id: \.self) { Text($0).font(.caption) }
        }
        .padding()
        .themedScreen()
        .navigationTitle("Pruebas")
    }
}
