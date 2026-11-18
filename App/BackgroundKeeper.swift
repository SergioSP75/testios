import AVFoundation
import UIKit

/// Mantiene viva la app mientras hay descargas, aunque se apague o bloquee la pantalla del iPad.
/// iOS suspende las apps en segundo plano a los pocos segundos; la app declara el modo «audio», así que mientras haya un audio
/// (aquí un silencio en bucle) sonando, el sistema la deja seguir trabajando. Además se pide tiempo extra con `beginBackgroundTask`
/// y se impide que la pantalla se apague sola mientras está en primer plano. Las descargas de MKV (reempaquetado) y de listas HLS
/// necesitan esto porque trabajan dentro de la app; un fichero suelto podría usar una sesión del sistema, pero así quedan todas igual.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var taskId: UIBackgroundTaskIdentifier = .invalid
    private var holders = 0

    /// Una descarga más en marcha.
    func acquire() {
        holders += 1
        guard holders == 1 else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        startSilence()
        renewTask()
        Trace.shared.log("descarga", "segundo plano activado (audio silencioso + tarea de fondo)")
    }

    /// Una descarga menos; con la última se suelta todo.
    func release() {
        holders = max(holders - 1, 0)
        guard holders == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        player?.stop(); engine?.stop(); player = nil; engine = nil
        if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId); taskId = .invalid }
        Trace.shared.log("descarga", "segundo plano desactivado")
    }

    private func renewTask() {
        let old = taskId
        taskId = UIApplication.shared.beginBackgroundTask(withName: "descargas") { [weak self] in
            // Se acaba el tiempo extra: se pide otro (el audio sigue manteniendo la app viva)
            Task { @MainActor in self?.renewTask() }
        }
        if old != .invalid { UIApplication.shared.endBackgroundTask(old) }
    }

    private func startSilence() {
        // Si ya suena algo (el reproductor) no hace falta ni conviene tocar la sesión
        let s = AVAudioSession.sharedInstance()
        do { try s.setCategory(.playback, mode: .default, options: [.mixWithOthers]); try s.setActive(true) } catch { Trace.shared.log("descarga", "audio de fondo: \(error.localizedDescription)"); return }
        let e = AVAudioEngine(), p = AVAudioPlayerNode()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return }
        buf.frameLength = 44100                                  // un segundo de silencio (ceros)
        e.attach(p); e.connect(p, to: e.mainMixerNode, format: fmt)
        p.volume = 0
        do { try e.start() } catch { Trace.shared.log("descarga", "motor de audio: \(error.localizedDescription)"); return }
        p.scheduleBuffer(buf, at: nil, options: .loops)
        p.play()
        engine = e; player = p
    }
}
