"""Integração do ytm com o macOS.

- "Tocando Agora" (Central de Controle e item da barra de menus do sistema): título, artista,
  álbum, capa, duração e posição, além das teclas de mídia e dos controles do fone.
- Ícone próprio na barra de menus com a música atual e um menu de controles.
- Notificação com os detalhes de cada música que começa a tocar.

Tudo roda na thread principal: o tocador chama `pump()` a cada quadro para o macOS
entregar cliques no menu e comandos de mídia.
"""

import subprocess
import threading
import urllib.request

import AppKit
import objc
from Foundation import NSDate, NSDefaultRunLoopMode, NSObject
from MediaPlayer import (
    MPMediaItemArtwork,
    MPMediaItemPropertyAlbumTitle,
    MPMediaItemPropertyArtist,
    MPMediaItemPropertyArtwork,
    MPMediaItemPropertyPlaybackDuration,
    MPMediaItemPropertyTitle,
    MPNowPlayingInfoCenter,
    MPNowPlayingInfoPropertyElapsedPlaybackTime,
    MPNowPlayingInfoPropertyPlaybackRate,
    MPNowPlayingPlaybackStatePaused,
    MPNowPlayingPlaybackStatePlaying,
    MPNowPlayingPlaybackStateStopped,
    MPRemoteCommandCenter,
    MPRemoteCommandHandlerStatusCommandFailed,
    MPRemoteCommandHandlerStatusSuccess,
)


def _short(text, n):
    return text if len(text) <= n else text[:n - 1] + '…'


def _escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"')


class _MenuTarget(NSObject):
    """Recebe os cliques do menu da barra e repassa para o tocador."""

    def initWithHandler_(self, handler):
        self = objc.super(_MenuTarget, self).init()
        if self is not None:
            self.handler = handler
        return self

    def togglePause_(self, sender):
        self.handler('pause')

    def nextTrack_(self, sender):
        self.handler('next')

    def prevTrack_(self, sender):
        self.handler('prev')

    def quit_(self, sender):
        self.handler('quit')


class MacIntegration:
    def __init__(self, player, notifications=True):
        self.player = player
        self.notifications = notifications
        self.quit_requested = False
        self.center = MPNowPlayingInfoCenter.defaultCenter()
        self._shown = None  # (faixa, pausado, seek_gen) já enviado ao sistema
        self._notified = None
        self._artwork = {}  # id(faixa) -> capa (None enquanto baixa)

        # aplicativo "acessório": sem ícone no Dock, mas com item na barra de menus
        self.app = AppKit.NSApplication.sharedApplication()
        self.app.setActivationPolicy_(AppKit.NSApplicationActivationPolicyAccessory)
        self.app.finishLaunching()
        self._setup_status_item()
        self._setup_remote_commands()

    # -- barra de menus -------------------------------------------------------

    def _setup_status_item(self):
        self.target = _MenuTarget.alloc().initWithHandler_(self._command)
        self.item = AppKit.NSStatusBar.systemStatusBar().statusItemWithLength_(AppKit.NSVariableStatusItemLength)
        self.item.button().setTitle_('♪ YTM')

        menu = AppKit.NSMenu.alloc().init()
        menu.setAutoenablesItems_(False)
        self.menu_title = menu.addItemWithTitle_action_keyEquivalent_('Carregando…', None, '')
        self.menu_artist = menu.addItemWithTitle_action_keyEquivalent_('', None, '')
        for info in (self.menu_title, self.menu_artist):
            info.setEnabled_(False)
        menu.addItem_(AppKit.NSMenuItem.separatorItem())
        self.menu_pause = self._add(menu, 'Pausar', 'togglePause:')
        self._add(menu, 'Próxima', 'nextTrack:')
        self._add(menu, 'Anterior', 'prevTrack:')
        menu.addItem_(AppKit.NSMenuItem.separatorItem())
        self._add(menu, 'Sair do ytm', 'quit:')
        self.item.setMenu_(menu)

    def _add(self, menu, title, action):
        entry = menu.addItemWithTitle_action_keyEquivalent_(title, action, '')
        entry.setTarget_(self.target)
        return entry

    # -- teclas de mídia, fones e Central de Controle -------------------------

    def _setup_remote_commands(self):
        cc = MPRemoteCommandCenter.sharedCommandCenter()

        def handler(name):
            def run(event):
                self._command(name)
                return MPRemoteCommandHandlerStatusSuccess
            return run

        def seek(event):
            if self.player.state != 'playing':
                return MPRemoteCommandHandlerStatusCommandFailed
            self.player.seek(event.positionTime() - self.player.position())
            return MPRemoteCommandHandlerStatusSuccess

        cc.togglePlayPauseCommand().addTargetWithHandler_(handler('pause'))
        cc.playCommand().addTargetWithHandler_(handler('play'))
        cc.pauseCommand().addTargetWithHandler_(handler('stop'))
        cc.nextTrackCommand().addTargetWithHandler_(handler('next'))
        cc.previousTrackCommand().addTargetWithHandler_(handler('prev'))
        cc.changePlaybackPositionCommand().addTargetWithHandler_(seek)

    def _command(self, name):
        p = self.player
        if name == 'pause' or (name == 'play' and p.paused) or (name == 'stop' and not p.paused):
            p.toggle_pause()
        elif name == 'next':
            p.next()
        elif name == 'prev':
            p.prev()
        elif name == 'quit':
            self.quit_requested = True

    # -- atualização ----------------------------------------------------------

    def pump(self):
        """Entrega ao aplicativo os eventos pendentes (cliques, teclas de mídia) e atualiza o sistema."""
        while True:
            event = self.app.nextEventMatchingMask_untilDate_inMode_dequeue_(
                AppKit.NSEventMaskAny, NSDate.distantPast(), NSDefaultRunLoopMode, True)
            if event is None:
                break
            self.app.sendEvent_(event)
        self._refresh()

    def _refresh(self):
        p = self.player
        t = p.track
        if p.state != 'playing' or p.played == 0:
            return
        key = (id(t), p.paused, p.seek_gen, self._artwork.get(id(t)) is not None)
        if key == self._shown:
            return
        self._shown = key

        info = {
            MPMediaItemPropertyTitle: t.title or '',
            MPMediaItemPropertyArtist: t.artist or '',
            MPMediaItemPropertyAlbumTitle: t.album or '',
            MPMediaItemPropertyPlaybackDuration: float(t.duration or 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: float(p.position()),
            MPNowPlayingInfoPropertyPlaybackRate: 0.0 if p.paused else 1.0,
        }
        if self._artwork.get(id(t)):
            info[MPMediaItemPropertyArtwork] = self._artwork[id(t)]
        self.center.setNowPlayingInfo_(info)
        self.center.setPlaybackState_(MPNowPlayingPlaybackStatePaused if p.paused else MPNowPlayingPlaybackStatePlaying)

        icon = '⏸' if p.paused else '♪'
        self.item.button().setTitle_(f'{icon} YTM')  # a música fica no menu
        self.menu_title.setTitle_(_short(t.title or '', 60))
        self.menu_artist.setTitle_(_short(' · '.join(x for x in (t.artist, t.album) if x), 60))
        self.menu_pause.setTitle_('Continuar' if p.paused else 'Pausar')

        if self._notified is not t:
            self._notified = t
            self._notify(t)
            if id(t) not in self._artwork:
                self._artwork[id(t)] = None
                threading.Thread(target=self._load_artwork, args=(t,), daemon=True).start()

    def _notify(self, t):
        if not self.notifications:
            return
        minutes, seconds = divmod(int(t.duration or 0), 60)
        details = ' · '.join(x for x in (t.album, f'{minutes}:{seconds:02d}' if t.duration else '') if x)
        script = (f'display notification "{_escape(details or "YouTube Music")}" '
                  f'with title "♪ {_escape(t.title or "ytm")}" subtitle "{_escape(t.artist or "")}"')
        subprocess.Popen(['osascript', '-e', script], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _load_artwork(self, t):
        url = getattr(t, 'thumbnail', None)
        if not url:
            return
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                data = r.read()
        except Exception:
            return
        image = AppKit.NSImage.alloc().initWithData_(AppKit.NSData.dataWithBytes_length_(data, len(data)))
        if image is None:
            return
        self._artwork[id(t)] = MPMediaItemArtwork.alloc().initWithBoundsSize_requestHandler_(
            image.size(), lambda size: image)
        # a próxima chamada de pump() envia a capa (a chave de _refresh muda)

    def close(self):
        self.center.setNowPlayingInfo_(None)
        self.center.setPlaybackState_(MPNowPlayingPlaybackStateStopped)
        AppKit.NSStatusBar.systemStatusBar().removeStatusItem_(self.item)
