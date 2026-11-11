// ytm-helper — ajudante do ytm para o que o R não faz sozinho no macOS.
//
// - Áudio: recebe PCM (float32, 44,1 kHz, estéreo intercalado) pela entrada padrão, toca com o
//   AVAudioEngine e avisa quantos quadros já saíram no alto-falante. É isso que o ytm usa
//   para sincronizar as animações, a letra e o vídeo.
// - Integração com o macOS: "Tocando Agora" (título, artista, álbum, capa, duração e posição),
//   teclas de mídia, controles do fone e o ícone ♪ YTM na barra de menus.
//
// Mensagens recebidas (entrada padrão): 1 byte de tipo + 4 bytes de tamanho (little-endian) + conteúdo.
//   A  áudio: float32 intercalado (esquerda, direita, ...)
//   F  descarta o áudio pendente e começa uma nova contagem; conteúdo: número da contagem (uint32)
//   N  Tocando Agora: JSON {title, artist, album, duration, elapsed, paused, artwork}
//   Q  sair
// Linhas enviadas (saída padrão):
//   pos <contagem> <quadros tocados desde o último F>
//   lost <contagem>     a saída de áudio mudou (ex.: fone desconectado) e o áudio pendente se perdeu
//   cmd pause|play|stop|next|prev|quit
//   seek <segundos>
//   size <colunas> <linhas>   tamanho do terminal (no início e quando a janela muda)
//
// Uso: ytm-helper [--sem-mac]

import AppKit
import AVFoundation
import Foundation
import MediaPlayer

let sampleRate = 44100.0
let withMac = !CommandLine.arguments.contains("--sem-mac")

let outLock = NSLock()
func say(_ line: String) {
    outLock.lock()
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    outLock.unlock()
}

// MARK: - áudio

final class Audio {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let lock = NSLock()
    var gen: UInt32 = 0
    var played: Int64 = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        start()
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.restart() }
    }

    func start() {
        do {
            try engine.start()
            node.play()
        } catch {
            FileHandle.standardError.write("ytm-helper: falha ao abrir o áudio: \(error)\n".data(using: .utf8)!)
        }
    }

    // a saída de áudio mudou: o motor para sozinho e o áudio agendado se perde
    func restart() {
        lock.lock()
        let g = gen
        gen &+= 1  // ignora os avisos dos buffers descartados
        lock.unlock()
        node.stop()
        engine.stop()
        start()
        say("lost \(g)")
    }

    func flush(_ newGen: UInt32) {
        lock.lock()
        gen = newGen
        played = 0
        lock.unlock()
        node.stop()  // os avisos dos buffers descartados chegam com a contagem antiga
        node.play()
        say("pos \(newGen) 0")
    }

    func push(_ data: Data) {
        let frames = data.count / 8
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let left = buf.floatChannelData![0], right = buf.floatChannelData![1]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s = raw.bindMemory(to: Float.self)
            for i in 0..<frames {
                left[i] = s[2 * i]
                right[i] = s[2 * i + 1]
            }
        }
        lock.lock()
        let g = gen
        lock.unlock()
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            if self.gen == g {
                self.played += Int64(frames)
                let p = self.played
                self.lock.unlock()
                say("pos \(g) \(p)")
            } else {
                self.lock.unlock()
            }
        }
    }
}

// MARK: - integração com o macOS

final class Mac: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menuTitle = NSMenuItem(title: "Carregando…", action: nil, keyEquivalent: "")
    let menuArtist = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var menuPause: NSMenuItem!
    var artworkURL: String?
    var artwork: MPMediaItemArtwork?
    var last: [String: Any] = [:]

    override init() {
        super.init()
        item.button?.title = "♪ YTM"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuTitle.isEnabled = false
        menuArtist.isEnabled = false
        menu.addItem(menuTitle)
        menu.addItem(menuArtist)
        menu.addItem(.separator())
        menuPause = add(menu, "Pausar", #selector(pause))
        _ = add(menu, "Próxima", #selector(next))
        _ = add(menu, "Anterior", #selector(prev))
        menu.addItem(.separator())
        _ = add(menu, "Sair do ytm", #selector(quit))
        item.menu = menu

        let cc = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ name: String) {
            cmd.addTarget { _ in say("cmd \(name)"); return .success }
        }
        on(cc.togglePlayPauseCommand, "pause")
        on(cc.playCommand, "play")
        on(cc.pauseCommand, "stop")
        on(cc.nextTrackCommand, "next")
        on(cc.previousTrackCommand, "prev")
        cc.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            say("seek \(e.positionTime)")
            return .success
        }
    }

    func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc func pause() { say("cmd pause") }
    @objc func next() { say("cmd next") }
    @objc func prev() { say("cmd prev") }
    @objc func quit() { say("cmd quit") }

    static func short(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    func update(_ info: [String: Any]) {
        last = info
        let title = info["title"] as? String ?? ""
        let artist = info["artist"] as? String ?? ""
        let album = info["album"] as? String ?? ""
        let paused = info["paused"] as? Bool ?? false
        var np: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPMediaItemPropertyPlaybackDuration: info["duration"] as? Double ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info["elapsed"] as? Double ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
        let url = info["artwork"] as? String
        if url != artworkURL {
            artworkURL = url
            artwork = nil
            if let u = url, let link = URL(string: u) { loadArtwork(link, for: u) }
        }
        if let art = artwork { np[MPMediaItemPropertyArtwork] = art }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = np
        center.playbackState = paused ? .paused : .playing

        item.button?.title = paused ? "⏸ YTM" : "♪ YTM"
        menuTitle.title = Mac.short(title, 60)
        menuArtist.title = Mac.short([artist, album].filter { !$0.isEmpty }.joined(separator: " · "), 60)
        menuPause.title = paused ? "Continuar" : "Pausar"
    }

    func loadArtwork(_ link: URL, for url: String) {
        URLSession.shared.dataTask(with: link) { data, _, _ in
            guard let data = data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self.artworkURL == url else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.update(self.last)  // envia a capa ao Tocando Agora
            }
        }.resume()
    }

    func close() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        NSStatusBar.system.removeStatusItem(item)
    }
}

// MARK: - entrada

let audio = Audio()
var mac: Mac?

func finish() -> Never {
    DispatchQueue.main.sync { mac?.close() }
    exit(0)
}

func readExact(_ n: Int) -> Data? {
    var data = Data()
    while data.count < n {
        let chunk = FileHandle.standardInput.readData(ofLength: n - data.count)
        if chunk.isEmpty { return nil }
        data.append(chunk)
    }
    return data
}

// tamanho do terminal: no início e a cada mudança da janela (o R não tem como perguntar sem abrir um processo)
let tty = open("/dev/tty", O_RDONLY)
func reportSize() {
    var ws = winsize()
    if tty >= 0, ioctl(tty, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
        say("size \(ws.ws_col) \(ws.ws_row)")
    }
}
signal(SIGWINCH, SIG_IGN)
let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
winch.setEventHandler { reportSize() }
winch.resume()
reportSize()

let app = NSApplication.shared
if withMac {
    app.setActivationPolicy(.accessory)  // sem ícone no Dock, mas com item na barra de menus
    mac = Mac()
}

Thread {
    while true { autoreleasepool {  // libera a cada mensagem os objetos temporários do sistema
        guard let head = readExact(5) else { finish() }
        let kind = head[head.startIndex]
        let size = head.subdata(in: (head.startIndex + 1)..<(head.startIndex + 5))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard let body = size > 0 ? readExact(Int(UInt32(littleEndian: size))) : Data() else { finish() }
        switch kind {
        case UInt8(ascii: "A"):
            audio.push(body)
        case UInt8(ascii: "F"):
            let g = body.count >= 4 ? UInt32(littleEndian: body.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) : 0
            audio.flush(g)
        case UInt8(ascii: "N"):
            if let info = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                DispatchQueue.main.async { mac?.update(info) }
            }
        case UInt8(ascii: "Q"):
            finish()
        default:
            break
        }
    } }
}.start()

app.run()
