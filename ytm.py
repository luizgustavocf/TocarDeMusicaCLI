#!/usr/bin/env python3
"""ytm — tocador de YouTube Music no terminal com visualizador de áudio.

Fluxo do áudio: yt-dlp (download do stream) -> ffmpeg (decodifica para PCM float32)
-> sounddevice (alto-falante). As mesmas amostras alimentam o visualizador (FFT),
então a animação acompanha exatamente o que está tocando.
"""

import argparse
import collections
import colorsys
import json
import os
import random
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
import unicodedata
import urllib.request
from bisect import bisect_right
from dataclasses import dataclass, field
from urllib.parse import parse_qs, quote_plus, urlencode, urlparse

import numpy as np
import psutil
import sounddevice as sd
import yt_dlp

SR = 44100
CH = 2
BLOCK = 1024
RING = 1 << 17  # ~3 s de áudio mono para o visualizador
FFT = 4096
FPS = 30


# --------------------------------------------------------------------------- busca

class _Quiet:
    def debug(self, msg): pass
    info = warning = error = debug


YDL_BASE = {'quiet': True, 'no_warnings': True, 'noprogress': True, 'logger': _Quiet()}


@dataclass
class Track:
    url: str
    title: str = ''
    artist: str = ''
    album: str = ''
    duration: float = 0
    info_path: str | None = None
    lyrics: list | None = None  # [(segundos, linha)]; None = ainda buscando
    lyrics_synced: bool = False
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False)


def _clean_artist(name):
    return (name or '').removesuffix(' - Topic')


def _entry_to_track(e):
    url = e.get('url') or ''
    if not url.startswith('http'):
        url = f"https://music.youtube.com/watch?v={e.get('id')}"
    artist = e.get('artist') or ', '.join(e.get('artists') or []) or e.get('channel') or e.get('uploader')
    return Track(url=url, title=e.get('title') or '', artist=_clean_artist(artist),
                 duration=e.get('duration') or 0)


def _flat(url, limit=None):
    opts = dict(YDL_BASE, extract_flat='in_playlist', skip_download=True)
    if limit:
        opts['playlistend'] = limit
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(url, download=False)


def _entries(info):
    return [e for e in (info.get('entries') or []) if e]


def _video_id(url):
    u = urlparse(url)
    if u.hostname and u.hostname.endswith('youtu.be'):
        return u.path.strip('/')
    return (parse_qs(u.query).get('v') or [None])[0]


def _radio_url(video_id):
    return f'https://music.youtube.com/watch?v={video_id}&list=RDAMVM{video_id}'


def resolve(args):
    """Transforma a entrada do usuário numa lista de faixas + um rótulo."""
    q = ' '.join(args.query).strip()

    if q.startswith(('http://', 'https://')):
        if '/browse/VL' in q:
            q = 'https://music.youtube.com/playlist?list=' + q.split('/browse/VL', 1)[1]
        vid = _video_id(q)
        if args.radio and vid:
            info = _flat(_radio_url(vid), limit=args.n or 50)
            return [_entry_to_track(e) for e in _entries(info)], 'Rádio'
        if 'list=' in q and not args.single:
            info = _flat(q)
            return [_entry_to_track(e) for e in _entries(info)], info.get('title') or 'Playlist'
        return [Track(url=q)], 'YouTube Music'

    if args.playlist:
        found = _entries(_flat(f'https://music.youtube.com/search?q={quote_plus(q)}#community+playlists', limit=1))
        if not found:
            return [], ''
        pid = found[0].get('id') or ''
        info = _flat('https://music.youtube.com/playlist?list=' + pid.removeprefix('VL'))
        return [_entry_to_track(e) for e in _entries(info)], info.get('title') or 'Playlist'

    found = _entries(_flat(f'https://music.youtube.com/search?q={quote_plus(q)}#songs',
                           limit=1 if args.radio else args.n))
    if args.radio and found:
        info = _flat(_radio_url(found[0]['id']), limit=50)
        return [_entry_to_track(e) for e in _entries(info)], 'Rádio: ' + (found[0].get('title') or q)
    return [_entry_to_track(e) for e in found], 'YouTube Music'


# --------------------------------------------------------------------------- letras

LRC_TAG = re.compile(r'\[(\d+):(\d+(?:\.\d+)?)\]')
TITLE_NOISE = re.compile(r'\s*[(\[][^)\]]*(official|video|clipe|lyric|letra|audio|áudio|remaster|4k|hd\b|visualizer)[^)\]]*[)\]]', re.I)


def _lrclib(params):
    req = urllib.request.Request('https://lrclib.net/api/search?' + urlencode(params),
                                 headers={'User-Agent': 'ytm-cli (https://github.com/luizgustavocf/TocarDeMusicaCLI)'})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def parse_lrc(text):
    lines = []
    for raw in text.splitlines():
        words = LRC_TAG.sub('', raw).strip()
        for m, s in LRC_TAG.findall(raw):
            lines.append((int(m) * 60 + float(s), words))
    return sorted(lines)


def fetch_lyrics(title, artist, duration):
    """Busca a letra no LRCLIB. Retorna ([(segundos, linha)], sincronizada).

    Prefere letras sincronizadas com duração parecida com a da faixa (mesma versão
    da gravação). Sem sincronia, distribui as linhas ao longo da música como estimativa.
    """
    title = TITLE_NOISE.sub('', title).strip()
    artist = re.sub(r'\s*(official|vevo)$', '', artist or '', flags=re.I).strip()
    queries = [{'track_name': title, 'artist_name': artist}]
    parts = re.split(r'\s+[-–—]\s+', title, maxsplit=1)
    if len(parts) == 2:  # vídeos no formato "Artista - Música"
        queries.insert(0, {'track_name': parts[1], 'artist_name': parts[0]})
    queries.append({'q': f'{artist} {title}'})

    def score(r):
        d = abs((r.get('duration') or 0) - duration) if duration else 0
        synced = bool(r.get('syncedLyrics'))
        return (0 if synced and d <= 4 else 1 if d <= 15 else 2, not synced, d)

    for q in queries:
        try:
            results = [r for r in _lrclib(q) if r.get('syncedLyrics') or r.get('plainLyrics')]
        except Exception:
            continue
        if not results:
            continue
        best = min(results, key=score)
        if best.get('syncedLyrics'):
            return parse_lrc(best['syncedLyrics']), True
        plain = [l.strip() for l in best['plainLyrics'].splitlines()]
        dur = duration or best.get('duration') or 180
        return [(dur * (0.08 + 0.87 * i / max(len(plain), 1)), l) for i, l in enumerate(plain)], False
    return [], False


# --------------------------------------------------------------------------- player

class Player:
    def __init__(self, tracks, label, args):
        self.tracks = tracks
        self.label = label
        self.repeat = args.repeat
        self.volume = max(0, min(100, args.volume)) / 100
        self.sync_ms = args.sync
        self.idx = 0
        self.lock = threading.RLock()
        self.src = None
        self.paused = False
        self.state = 'loading'  # loading | playing | ended | error
        self.message = ''
        self.error_at = 0.0
        self.gen = 0
        self.seek_gen = 0  # muda a cada (re)início do áudio; o vídeo reinicia junto
        self.base_frames = 0
        self.played = 0
        self.ring = np.zeros(RING, np.float32)
        self.widx = 0
        self.tmpdir = tempfile.mkdtemp(prefix='ytm-')
        self.stream = self._open_stream()
        self.running = True
        threading.Thread(target=self._audio_loop, daemon=True).start()

    @staticmethod
    def _open_stream():
        return sd.OutputStream(samplerate=SR, channels=CH, dtype='float32', blocksize=BLOCK, latency='low')

    @property
    def track(self):
        return self.tracks[self.idx]

    def position(self):
        return (self.base_frames + self.played) / SR

    # -- carregamento ---------------------------------------------------------

    def _fetch(self, t):
        with t.lock:
            if t.info_path:
                return
            with yt_dlp.YoutubeDL(dict(YDL_BASE, format='bestaudio/best', noplaylist=True)) as ydl:
                info = ydl.sanitize_info(ydl.extract_info(t.url, download=False))
            path = os.path.join(self.tmpdir, f"{info['id']}.json")
            with open(path, 'w') as f:
                json.dump(info, f)
            t.title = info.get('track') or info.get('title') or t.title
            t.artist = _clean_artist(info.get('artist') or info.get('channel') or info.get('uploader')) or t.artist
            t.album = info.get('album') or ''
            t.duration = info.get('duration') or t.duration
            t.info_path = path
            t.lyrics_artist = (info.get('artists') or [t.artist])[0]
            sized = [f for f in info.get('formats') or [] if f.get('width') and f.get('height')]
            t.aspect = sized[-1]['width'] / sized[-1]['height'] if sized else 16 / 9
            t.thumbnail = info.get('thumbnail')

    def play_index(self, i):
        with self.lock:
            self.idx = i % len(self.tracks)
            self.gen += 1
            self._kill_src()
            self.state, self.message, self.paused = 'loading', '', False
            self.base_frames = self.played = 0
            gen = self.gen
        threading.Thread(target=self._load, args=(gen,), daemon=True).start()

    def _load(self, gen):
        t = self.track
        try:
            self._fetch(t)
        except Exception as e:  # vídeo indisponível, bloqueado por região etc.
            with self.lock:
                if gen == self.gen:
                    self.state, self.message, self.error_at = 'error', str(e).split('\n')[0][:200], time.time()
            return
        if t.lyrics is None:
            threading.Thread(target=self._fetch_lyrics, args=(t,), daemon=True).start()
        with self.lock:
            if gen != self.gen:
                return
            self._start_src(0)
            self.state = 'playing'
            nxt = self.idx + 1
        if nxt < len(self.tracks):
            threading.Thread(target=self._prefetch, args=(self.tracks[nxt],), daemon=True).start()

    @staticmethod
    def _fetch_lyrics(t):
        try:
            t.lyrics, t.lyrics_synced = fetch_lyrics(t.title, getattr(t, 'lyrics_artist', t.artist), t.duration)
        except Exception:
            t.lyrics = []

    def _prefetch(self, t):
        try:
            self._fetch(t)
        except Exception:
            pass

    def _start_src(self, sec):
        yt = subprocess.Popen(
            [sys.executable, '-m', 'yt_dlp', '-q', '--no-warnings', '--no-progress',
             '--load-info-json', self.track.info_path, '-f', 'bestaudio/best', '-o', '-'],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        ff = subprocess.Popen(
            ['ffmpeg', '-v', 'quiet', '-i', 'pipe:0', '-ss', f'{sec:.2f}',
             '-f', 'f32le', '-ac', str(CH), '-ar', str(SR), 'pipe:1'],
            stdin=yt.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        yt.stdout.close()
        self.src = {'yt': yt, 'ff': ff, 'killed': False}
        self.seek_gen += 1
        self.base_frames, self.played = int(sec * SR), 0

    def _kill_src(self):
        s, self.src = self.src, None
        if not s:
            return
        s['killed'] = True
        for p in (s['ff'], s['yt']):
            try:
                p.kill()
                p.wait(timeout=1)
            except Exception:
                pass

    # -- loop de áudio --------------------------------------------------------

    def _audio_loop(self):
        nbytes = BLOCK * CH * 4
        while self.running:
            with self.lock:
                s, paused = self.src, self.paused
            if s is None or paused:
                if self.stream.active:
                    self.stream.abort()  # descarta o buffer: pausa instantânea
                time.sleep(0.01)
                continue
            data = s['ff'].stdout.read(nbytes)
            if s['killed']:
                continue
            if not data:
                with self.lock:
                    if self.src is s:
                        self._kill_src()
                        if self.played == 0 and self.base_frames == 0:
                            self.state, self.message, self.error_at = 'error', 'falha ao baixar o áudio', time.time()
                        else:
                            self.state = 'ended'
                continue
            buf = np.frombuffer(data[:len(data) // 8 * 8], np.float32).reshape(-1, CH)
            try:
                if not self.stream.active:
                    self.stream.start()
                self.stream.write(np.ascontiguousarray(buf * self.volume, dtype=np.float32))
            except Exception:  # saída de áudio mudou (ex.: fone desconectado)
                try:
                    self.stream.close()
                except Exception:
                    pass
                time.sleep(0.3)
                self.stream = self._open_stream()
                continue
            mono = buf.mean(axis=1)
            with self.lock:
                if self.src is not s:
                    continue
                self.played += len(mono)
                i = self.widx % RING
                n = len(mono)
                first = min(n, RING - i)
                self.ring[i:i + first] = mono[:first]
                self.ring[:n - first] = mono[first:]
                self.widx += n

    def heard_position(self):
        """Posição da música que está saindo no alto-falante agora."""
        try:
            lat = self.stream.latency
        except Exception:
            lat = 0
        return max(0.0, self.position() - lat - self.sync_ms / 1000)

    def recent(self, n):
        """Últimas n amostras que estão saindo no alto-falante agora."""
        try:
            lat = self.stream.latency
        except Exception:
            lat = 0
        with self.lock:
            end = self.widx - int((lat + self.sync_ms / 1000) * SR)
            return self.ring[np.arange(end - n, end) % RING]

    # -- controles ------------------------------------------------------------

    def toggle_pause(self):
        with self.lock:
            if self.state == 'playing':
                self.paused = not self.paused

    def seek(self, delta):
        with self.lock:
            if self.state != 'playing':
                return
            pos = max(0.0, self.position() + delta)
            if self.track.duration and pos >= self.track.duration - 1:
                self._kill_src()
                self.state = 'ended'
                return
            self._kill_src()
            self._start_src(pos)

    def next(self, manual=True):
        if self.idx + 1 < len(self.tracks):
            self.play_index(self.idx + 1)
        elif self.repeat:
            self.play_index(0)
        elif not manual:
            return False
        return True

    def prev(self):
        if self.state == 'playing' and self.position() > 3:
            self.seek(-self.position())
        elif self.idx > 0 or self.repeat:
            self.play_index(self.idx - 1)

    def close(self):
        self.running = False
        with self.lock:
            self._kill_src()
        try:
            self.stream.abort()
            self.stream.close()
        except Exception:
            pass
        shutil.rmtree(self.tmpdir, ignore_errors=True)


# --------------------------------------------------------------------------- vídeo

# alta: vídeo em 720p e 4 pixels por caractere (2 colunas x 2 linhas), com leve nitidez.
# media: mais quadros e cores sem arredondar. baixa: como na v1.3.0.
# A tecla g percorre nesta ordem.
VIDEO_QUALITY = {
    'alta': {'height': 720, 'fps': 30, 'quad': True, 'step': 1, 'filter': 'lanczos,unsharp=3:3:0.6'},
    'media': {'height': 480, 'fps': 24, 'quad': False, 'step': 1, 'filter': 'lanczos'},
    'baixa': {'height': 360, 'fps': 15, 'quad': False, 'step': 8, 'filter': 'area'},
}


class VideoFeed:
    """Decodifica o vídeo da faixa no tamanho da área, no mesmo ritmo do áudio.

    Só roda enquanto o visual 'video' está ativo. Cada (re)início do áudio, troca de
    faixa, de qualidade ou do tamanho do terminal recomeça o vídeo na posição que está tocando.
    """

    def __init__(self, player, quality='alta', engine='timg'):
        self.player = player
        self.quality = quality
        self.engine = engine if engine != 'timg' or shutil.which('timg') else 'interno'
        self.key = None
        self.procs = ()
        self.lock = threading.Lock()
        self.chunks = collections.deque()  # timg: (posição na música, quadro já em códigos de terminal)
        self.timg_shown = False
        self.lead = 1.5  # timg: começa à frente do áudio para compensar a partida (ajustado sozinho)
        self.session = (None, 0.0)  # timg: (faixa e tamanho, início) da sessão atual
        self.frame = None
        self.frame_t = 0.0  # posição da música do quadro atual
        self.frame_quad = False  # o quadro atual foi decodificado para quadrantes
        self.status = ''

    @property
    def settings(self):
        return VIDEO_QUALITY[self.quality]

    def cycle_quality(self):
        names = list(VIDEO_QUALITY)
        self.quality = names[(names.index(self.quality) + 1) % len(names)]

    def cycle_engine(self):
        if shutil.which('timg'):
            self.engine = 'interno' if self.engine == 'timg' else 'timg'

    @staticmethod
    def cells_for(track, cols, rows):
        """Tamanho em caracteres que cabe na área, mantendo a proporção do vídeo
        (um caractere tem o dobro de altura que de largura)."""
        aspect = getattr(track, 'aspect', 16 / 9)
        w = cols
        h = w / aspect / 2
        if h > rows:
            h = rows
            w = h * 2 * aspect
        return max(int(round(w)), 1), max(int(h), 1)

    def size_for(self, track, cols, rows):
        """Tamanho em pixels: meio-bloco mostra 1x2 pixels por caractere; quadrantes, 2x2."""
        w, h = self.cells_for(track, cols, rows)
        return w * (2 if self.settings['quad'] else 1), h * 2

    def _ytdlp(self, track):
        h = self.settings['height']
        return subprocess.Popen(
            [sys.executable, '-m', 'yt_dlp', '-q', '--no-warnings', '--no-progress',
             '--load-info-json', track.info_path, '-o', '-',
             '-f', f'bestvideo[height<={h}][vcodec^=avc1]/bestvideo[height<={h}]/worstvideo'],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    def _scale_filter(self, pw, ph):
        q = self.settings
        scale = q['filter'].split(',', 1)
        return f'fps={q["fps"]},scale={pw}:{ph}:flags={scale[0]}' + (',' + scale[1] if len(scale) > 1 else '')

    def ensure(self, track, cols, rows):
        if self.engine == 'timg':
            return self._ensure_timg(track, cols, rows)
        pw, ph = self.size_for(track, cols, rows)
        key = (track.info_path, pw, ph, self.player.seek_gen, self.quality, 'interno')
        if key == self.key:
            return
        self.stop()
        self.key, self.frame, self.status = key, None, 'carregando vídeo…'
        q = self.settings
        start = self.player.heard_position()
        yt = subprocess.Popen(
            [sys.executable, '-m', 'yt_dlp', '-q', '--no-warnings', '--no-progress',
             '--load-info-json', track.info_path, '-o', '-',
             '-f', f'bestvideo[height<={q["height"]}][vcodec^=avc1]/bestvideo[height<={q["height"]}]/worstvideo'],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        scale = q['filter'].split(',', 1)
        vf = f'fps={q["fps"]},scale={pw}:{ph}:flags={scale[0]}' + (',' + scale[1] if len(scale) > 1 else '')
        ff = subprocess.Popen(
            ['ffmpeg', '-v', 'quiet', '-i', 'pipe:0', '-ss', f'{start:.2f}', '-an',
             '-vf', vf, '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1'],
            stdin=yt.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        yt.stdout.close()
        self.procs = (ff, yt)
        threading.Thread(target=self._read, args=(key, ff, start, pw, ph, q['fps'], q['quad']), daemon=True).start()

    def _read(self, key, ff, start, pw, ph, fps, quad):
        size = pw * ph * 3
        i = 0
        while self.key == key:
            data = ff.stdout.read(size)
            if len(data) < size:
                if self.key == key:
                    self.status = 'vídeo indisponível' if i == 0 else ''
                return
            t = start + i / fps
            i += 1
            while self.key == key and t > self.player.heard_position() + 0.03:  # espera o áudio alcançar
                time.sleep(0.01)
            if self.key == key:
                self.frame = np.frombuffer(data, np.uint8).reshape(ph, pw, 3)
                self.frame_t = t
                self.frame_quad = quad

    # -- motor timg ----------------------------------------------------------
    # O ffmpeg reduz o vídeo para o tamanho exato da área e o timg o transforma em
    # caracteres, mandando a cada quadro só as células que mudaram. O ytm recebe esses
    # quadros por um pipe e os escreve no terminal junto com o resto da tela, na hora
    # em que o áudio chega neles.

    def _ensure_timg(self, track, cols, rows):
        w, h = self.cells_for(track, cols, rows)
        # o timg corrige sozinho a proporção dos caracteres: ele recebe pixels quadrados
        pw = w * (2 if self.settings['quad'] else 1)
        ph = max(round(pw / getattr(track, 'aspect', 16 / 9)) // 2 * 2, 2)
        key = (track.info_path, pw, ph, self.player.seek_gen, self.quality, 'timg')
        self.area = (cols, rows, w, h)
        if key == self.key:
            return
        self.stop()
        same_picture = self.session[0] == (track.info_path, pw, ph, self.quality)
        self.session = ((track.info_path, pw, ph, self.quality), time.time())
        self.key, self.status = key, 'carregando vídeo…'
        if not same_picture:  # mesmo vídeo e tamanho (ex.: reajuste de sincronia): a imagem atual fica até o novo quadro
            self.timg_shown = False
        with self.lock:
            self.chunks.clear()
        q = self.settings
        start = self.player.heard_position() + self.lead
        yt = self._ytdlp(track)
        ff = subprocess.Popen(
            ['ffmpeg', '-v', 'quiet', '-i', 'pipe:0', '-ss', f'{start:.2f}', '-an', '-vf', self._scale_filter(pw, ph),
             '-c:v', 'rawvideo', '-pix_fmt', 'rgb24', '-f', 'nut', 'pipe:1'],
            stdin=yt.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        yt.stdout.close()
        tg = subprocess.Popen(
            ['timg', '-V', '-p', 'q' if q['quad'] else 'h', '-g', f'{w}x{h}', '-o', '/dev/stdout', '-'],
            stdin=ff.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        ff.stdout.close()
        self.procs = (tg, ff, yt)
        threading.Thread(target=self._read_timg, args=(key, tg, start, q['fps']), daemon=True).start()

    def _read_timg(self, key, tg, start, fps):
        sep = None  # o timg volta N linhas ("ESC [ N A") para desenhar cada quadro novo
        buf, i = b'', 0

        def push(frame):
            nonlocal i
            text = frame.decode('utf-8', 'replace').replace('\x1b[?25l', '').replace('\x1b[?25h', '')
            with self.lock:
                self.chunks.append((start + i / fps, text))
            i += 1
            while self.key == key and len(self.chunks) > fps * 2:  # não deixa acumular mais que ~2 s
                time.sleep(0.02)

        while self.key == key:
            data = tg.stdout.read1(1 << 16)
            if not data:
                break
            buf += data
            if sep is None:
                found = re.search(rb'\x1b\[(\d+)A', buf)
                if not found:
                    continue
                sep = found.group(0)
                cols, rows, w, _ = self.area
                self.area = (cols, rows, w, int(found.group(1)))  # altura real usada pelo timg
            *frames, buf = buf.split(sep)
            for frame in frames:
                push(frame)
        if self.key == key:
            if buf.strip():
                push(buf)
            if i == 0:
                self.status = 'vídeo indisponível'

    def take_timg(self, top):
        """Códigos de terminal dos quadros que já chegaram na hora do áudio, posicionados na área."""
        heard = self.player.heard_position()
        out = []
        with self.lock:
            while self.chunks and self.chunks[0][0] <= heard + 0.03:
                t, text = self.chunks.popleft()
                out.append(text)
            late = heard - t if out else 0
        if late > 0.25 and time.time() - self.session[1] < 8:
            # a partida demorou mais que o previsto e o timg segue no ritmo dele, então o atraso
            # não se recupera: recomeça mais à frente (o quadro atual fica na tela)
            self.lead = min(self.lead + late + 0.2, 4.0)
            self.stop()
        if not out:
            return ''
        cols, rows, w, h = self.area
        row, col = top + (rows - h) // 2, (cols - w) // 2 + 1
        pos, nl = f'\x1b[{row};{col}H', f'\n\x1b[{col}G'
        return ''.join(pos + text.replace('\n', nl) for text in out) + RESET

    def timg_body(self, rows, drawing):
        """Linhas da área do vídeo: None mantém o que o timg desenhou."""
        if self.timg_shown:
            return [None] * rows
        if drawing:  # primeiro quadro: limpa a área antes de desenhar
            self.timg_shown = True
            return [''] * rows
        out = [''] * rows
        msg = self.status or 'carregando vídeo…'
        out[rows // 2] = ' ' * max((self.area[0] - dwidth(msg)) // 2, 0) + DIM + msg if hasattr(self, 'area') else msg
        return out

    def stop(self):
        self.key = None
        for p in self.procs:
            try:
                p.kill()
                p.wait(timeout=1)
            except Exception:
                pass
        self.procs = ()


# Quadrantes: cada caractere cobre 2x2 pixels, pintados com 2 cores (texto e fundo).
# Bits: 1 = alto-esquerda, 2 = alto-direita, 4 = baixo-esquerda, 8 = baixo-direita (pixels na cor do texto).
QUAD_CHARS = np.array(list(' ▘▝▀▖▌▞▛▗▚▐▜▄▙▟█'))
QUAD_MASKS = np.arange(1, 8)  # cada divisão em 2 grupos aparece uma vez (a máscara m e 15 - m são a mesma divisão)
QUAD_W = ((QUAD_MASKS[:, None] >> np.arange(4)) & 1).astype(np.float32)  # (7 máscaras, 4 pixels)


def _quadrants(px):
    """Para cada bloco 2x2, escolhe o desenho de quadrante e as 2 cores que mais se aproximam da imagem."""
    rows, cols = px.shape[0] // 2, px.shape[1] // 2
    cells = px[:rows * 2, :cols * 2].reshape(rows, 2, cols, 2, 3).transpose(0, 2, 1, 3, 4).reshape(rows, cols, 4, 3)
    n_fg = QUAD_W.sum(1)[:, None]
    sum_fg = np.einsum('mk,rckx->rcmx', QUAD_W, cells)
    fg = sum_fg / n_fg
    bg = (cells.sum(2)[:, :, None] - sum_fg) / (4 - n_fg)
    pred = QUAD_W[:, :, None] * fg[:, :, :, None] + (1 - QUAD_W[:, :, None]) * bg[:, :, :, None]
    err = ((cells[:, :, None] - pred) ** 2).sum((3, 4))
    best = err.argmin(2)
    pick = best[:, :, None, None]
    fg = np.take_along_axis(fg, pick, 2)[:, :, 0]
    bg = np.take_along_axis(bg, pick, 2)[:, :, 0]
    chars = QUAD_CHARS[QUAD_MASKS[best]]
    # bloco quase liso (variação média < ~10 por canal): uma cor só. Evita pontinhos com o ruído
    # do vídeo nas áreas lisas e gera menos códigos de cor.
    mean = cells.mean(2)
    flat = ((cells - mean[:, :, None]) ** 2).sum((2, 3)) < 4 * 3 * 10 ** 2
    chars = np.where(flat, ' ', chars)
    fg = np.where(flat[:, :, None], mean, fg)
    bg = np.where(flat[:, :, None], mean, bg)
    return chars, fg, bg


# --------------------------------------------------------------------------- visualizador

def _hsv(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
    return int(r * 255), int(g * 255), int(b * 255)


def _ramp(stops, t):
    t = min(max(t, 0.0), 1.0) * (len(stops) - 1)
    i = min(int(t), len(stops) - 2)
    f = t - i
    a, b = stops[i], stops[i + 1]
    return tuple(int(a[k] + (b[k] - a[k]) * f) for k in range(3))


# Cada paleta recebe t (altura 0..1), x (posição horizontal 0..1) e fase (tempo)
PALETTES = {
    'neon': lambda t, x, ph: _hsv(0.52 + 0.42 * t + ph, 0.85, 1.0),
    'arco-iris': lambda t, x, ph: _hsv(x * 0.85 + ph * 3, 0.8 - 0.3 * t, 0.75 + 0.25 * t),
    'fogo': lambda t, x, ph: _ramp([(90, 0, 0), (220, 40, 0), (255, 140, 0), (255, 220, 60), (255, 255, 220)], t),
    'oceano': lambda t, x, ph: _ramp([(10, 30, 120), (0, 110, 220), (0, 210, 230), (180, 255, 250)], t),
    'vu': lambda t, x, ph: (60, 220, 90) if t < 0.6 else (240, 210, 40) if t < 0.85 else (250, 60, 50),
    # tons de cinza: a base some num fundo preto; 'cinza' começa mais claro para a barra inteira aparecer
    'preto-branco': lambda t, x, ph: _ramp([(0, 0, 0), (255, 255, 255)], t),
    'cinza': lambda t, x, ph: _ramp([(38, 38, 38), (255, 255, 255)], t),
}
GRAYS = ('preto-branco', 'cinza')
MODES = ['barras', 'espelho', 'onda', 'letra', 'video', 'vazio']
BLOCKS = ' ▁▂▃▄▅▆▇█'
# bits do caractere braille para (linha 0..3, coluna 0..1)
BRAILLE = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]


def _fg(rgb):
    return f'\x1b[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m'


class Visualizer:
    def __init__(self, mode, palette):
        self.mode = MODES.index(mode)
        self.palette = list(PALETTES).index(palette)
        self.window = np.hanning(FFT).astype(np.float32)
        self.freqs = np.fft.rfftfreq(FFT, 1 / SR)
        self.n = 0
        self.ref_db = -30.0
        self.bass_avg = 1e-6
        self.beat = 0.0
        self.last_beat = 0.0
        self.wave_gain = 1.0
        self.phase = 0.0

    def cycle_mode(self):
        self.mode = (self.mode + 1) % len(MODES)

    def cycle_palette(self):
        self.palette = (self.palette + 1) % len(PALETTES)

    @property
    def mode_name(self):
        return MODES[self.mode]

    @property
    def palette_name(self):
        return list(PALETTES)[self.palette]

    def _color(self, t, x):
        rgb = list(PALETTES.values())[self.palette](t, x, self.phase)
        if self.palette_name in GRAYS:  # clareia na batida para o topo continuar branco
            return tuple(int(c + (255 - c) * 0.3 * self.beat) for c in rgb)
        k = 0.72 + 0.28 * self.beat  # pulsa no grave
        return tuple(min(255, int(c * k)) for c in rgb)

    def _setup(self, n):
        self.n = n
        edges = np.geomspace(35, 16000, n + 1)
        self.centers = np.sqrt(edges[:-1] * edges[1:])
        self.idx = np.searchsorted(self.freqs, edges)
        self.wide = (self.idx[1:] - self.idx[:-1]) >= 2
        self.tilt = 4.5 * np.log2(self.centers / 1000)  # compensa a queda natural dos agudos
        self.bars = np.zeros(n)
        self.peaks = np.zeros(n)
        self.hold = np.zeros(n)

    def update(self, samples, n, dt, active):
        """Calcula o espectro das amostras atuais e anima barras/picos."""
        if n != self.n:
            self._setup(n)
        self.phase = (self.phase + dt * 0.02) % 1.0
        if active:
            spec = np.abs(np.fft.rfft(samples[-FFT:] * self.window)) / (FFT / 4)
            interp = np.interp(self.centers, self.freqs, spec)
            bands = np.maximum.reduceat(spec, np.minimum(self.idx[:-1], len(spec) - 1))
            mag = np.where(self.wide, bands, interp)
            db = 20 * np.log10(mag + 1e-9) + self.tilt
            self.ref_db = max(db.max(), self.ref_db - 6 * dt, -40)
            target = np.clip((db - (self.ref_db - 48)) / 48, 0, 1) ** 1.5

            bass = float(spec[(self.freqs > 30) & (self.freqs < 150)].mean())
            now = time.time()
            if bass > 1.45 * self.bass_avg and bass > 1e-3 and now - self.last_beat > 0.18:
                self.beat, self.last_beat = 1.0, now
            self.bass_avg = 0.92 * self.bass_avg + 0.08 * bass
        else:
            target = np.zeros(n)

        self.beat = max(0.0, self.beat - dt * 3.5)
        rise = target > self.bars
        self.bars = np.where(rise, self.bars + (target - self.bars) * 0.75, np.maximum(target, self.bars - dt * 1.6))
        up = self.bars >= self.peaks
        self.peaks = np.where(up, self.bars, self.peaks)
        self.hold = np.where(up, 0.35, self.hold - dt)
        self.peaks = np.where(self.hold < 0, np.maximum(self.bars, self.peaks - dt * 0.7), self.peaks)

    # -- desenho --------------------------------------------------------------

    @staticmethod
    def layout(width):
        bw, gap = 2, 1
        n = max(4, (width + gap) // (bw + gap))
        margin = (width - (n * (bw + gap) - gap)) // 2
        return n, bw, gap, margin

    def render(self, width, height, samples, track=None, pos=0.0):
        if self.mode_name == 'vazio':
            return [''] * height
        if self.mode_name == 'letra':
            return self._render_lyrics(width, height, track, pos)
        if self.mode_name == 'onda':
            return self._render_wave(width, height, samples)
        if self.mode_name == 'espelho':
            top = (height + 1) // 2
            return self._render_bars(width, top) + self._render_reflection(width, height - top)
        return self._render_bars(width, height)

    def _render_bars(self, width, height):
        n, bw, gap, margin = self.layout(width)
        lines = []
        for r in range(height):
            b = height - 1 - r  # linha contando de baixo
            row_color = self._color((b + 0.5) / height, 0)
            parts, cur = [' ' * margin], None
            for i in range(n):
                lvl = int(self.bars[i] * height * 8) - b * 8
                peak_row = min(int(self.peaks[i] * height), height - 1)
                if lvl > 0:
                    ch, col = BLOCKS[min(lvl, 8)], self._color((b + 0.5) / height, i / n) if self.palette_name == 'arco-iris' else row_color
                elif peak_row == b and self.peaks[i] > 0.03:
                    ch, col = '▁', (235, 235, 245)
                else:
                    ch, col = ' ', cur
                if col != cur:
                    parts.append(_fg(col))
                    cur = col
                parts.append(ch * bw)
                if i < n - 1:
                    parts.append(' ' * gap)
            lines.append(''.join(parts))
        return lines

    def _render_reflection(self, width, height):
        n, bw, gap, margin = self.layout(width)
        lines = []
        for k in range(height):
            parts, cur = [' ' * margin], None
            for i in range(n):
                lvl = int(self.bars[i] * (height + 1) * 2) - k * 2
                ch = '█' if lvl >= 2 else '▀' if lvl == 1 else ' '
                if ch != ' ':
                    t = 1 - (k + 0.5) / max(height, 1)
                    rgb = self._color(self.bars[i], i / n)
                    col = tuple(int(c * (0.15 + 0.35 * t)) for c in rgb)
                    if col != cur:
                        parts.append(_fg(col))
                        cur = col
                parts.append(ch * bw)
                if i < n - 1:
                    parts.append(' ' * gap)
            lines.append(''.join(parts))
        return lines

    def render_video(self, width, height, frame, status, quad=False, step=1):
        out = [''] * height
        if frame is None:
            msg = trunc(status or 'carregando vídeo…', width - 4)
            out[height // 2] = ' ' * max((width - dwidth(msg)) // 2, 0) + DIM + msg
            return out
        px = frame.astype(np.float32)
        if self.palette_name in GRAYS:
            px = np.repeat((px @ np.array([0.299, 0.587, 0.114], np.float32))[:, :, None], 3, axis=2)
        if quad:
            chars, fg, bg = _quadrants(px)
        else:  # ▀: pixel de cima na cor do texto, o de baixo no fundo
            fg, bg = px[0::2], px[1::2]
            chars = np.full(fg.shape[:2], '▀')
        # step > 1 arredonda as cores: menos códigos de cor por linha, menos dados para o terminal
        fg = (np.clip(fg + 0.5, 0, 255).astype(np.uint8) // step * step).tolist()
        bg = (np.clip(bg + 0.5, 0, 255).astype(np.uint8) // step * step).tolist()
        rows, cols = chars.shape
        top = max((height - rows) // 2, 0)
        left = ' ' * max((width - cols) // 2, 0)
        for r in range(min(rows, height)):
            parts, prev = [left], None
            for ch, up, dn in zip(chars[r].tolist(), fg[r], bg[r]):
                if (up, dn) != prev:
                    parts.append(f'\x1b[38;2;{up[0]};{up[1]};{up[2]};48;2;{dn[0]};{dn[1]};{dn[2]}m')
                    prev = (up, dn)
                parts.append(ch)
            parts.append(RESET)
            out[top + r] = ''.join(parts)
        return out

    def _render_lyrics(self, width, height, track, pos):
        lines = track.lyrics if track else None
        out = [''] * height
        mid = height // 2

        def center(text, prefix):
            text = trunc(text, width - 4)
            return ' ' * max((width - dwidth(text)) // 2, 0) + prefix + text

        if not lines:
            msg = 'procurando letra…' if lines is None else 'letra não encontrada'
            out[mid] = center(msg, DIM)
            return out

        times = [t for t, _ in lines]
        cur = bisect_right(times, pos) - 1
        for r in range(height):
            diff = r - mid
            if diff % 2:  # uma linha em branco entre os versos
                continue
            j = cur + diff // 2
            if j == cur == -1:
                out[r] = center('♪', _fg(self._color(0.6, 0.5)))
            if not 0 <= j < len(lines):
                continue
            text = lines[j][1] or '♪'
            if j != cur:
                fade = max(0.18, 0.75 - 0.14 * abs(j - cur))
                out[r] = center(text, _fg(tuple(int(c * fade) for c in self._color(0.7, 0.5))))
                continue
            # verso atual: preenche da esquerda para a direita acompanhando a voz
            text = trunc(text, width - 4)
            nxt = times[j + 1] if j + 1 < len(times) else lines[j][0] + 5
            frac = min(max((pos - lines[j][0]) / max(nxt - lines[j][0], 0.1), 0), 1) if track.lyrics_synced else 1
            k = int(len(text) * min(frac * 1.4, 1))  # a voz costuma terminar antes do próximo verso
            sung, rest = text[:k], text[k:]
            pad = ' ' * max((width - dwidth(text)) // 2, 0)
            out[r] = f'{pad}{BOLD}{_fg(self._color(1.0, 0.5))}{sung}{_fg(self._color(0.55, 0.5))}{rest}'
        if not track.lyrics_synced:
            out[-1] = center('letra sem sincronia: tempo estimado', DIM)
        return out

    def _render_wave(self, width, height, samples):
        dw, dh = width * 2, height * 4
        span = 2048
        # alinha num cruzamento por zero para a onda ficar estável na tela
        head = samples[:-span]
        cross = np.nonzero((head[:-1] <= 0) & (head[1:] > 0))[0]
        start = int(cross[-1]) if len(cross) else len(samples) - span
        seg = np.convolve(samples[start:start + span], np.ones(6) / 6, mode='same')  # suaviza
        x = seg[np.linspace(0, len(seg) - 1, dw).astype(int)]
        peak = float(np.abs(x).max())
        if peak > 1e-4:
            self.wave_gain += (min(0.85 / peak, 40) - self.wave_gain) * 0.15
        y = np.clip(((1 - x * self.wave_gain) / 2 * (dh - 1)).round().astype(int), 0, dh - 1)

        grid = np.zeros((height, width), dtype=np.int32)
        prev = y[0]
        for i, yy in enumerate(y):
            lo, hi = (prev, yy) if prev <= yy else (yy, prev)
            for v in range(lo, hi + 1):
                grid[v // 4, i // 2] |= BRAILLE[v % 4][i % 2]
            prev = yy

        lines = []
        mid = height / 2
        for r in range(height):
            t = abs(r + 0.5 - mid) / mid
            parts, cur = [], None
            for c in range(width):
                bits = grid[r, c]
                if bits:
                    col = self._color(0.25 + 0.75 * t, c / width)
                    if col != cur:
                        parts.append(_fg(col))
                        cur = col
                    parts.append(chr(0x2800 + int(bits)))
                else:
                    parts.append(' ')
            lines.append(''.join(parts))
        return lines


# --------------------------------------------------------------------------- performance

class PerfMonitor:
    """Mede CPU e memória do tocador (Python + yt-dlp + ffmpeg) uma vez por segundo."""

    def __init__(self):
        self.cpu = 0.0  # % de um núcleo, como no Monitor de Atividade
        self.mem = 0  # bytes (memória residente)
        self._procs = {}
        self.visible = True  # tecla h mostra/esconde
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        me = psutil.Process()
        while True:
            cpu = mem = 0
            alive = {}
            for p in [me] + me.children(recursive=True):
                try:
                    p = self._procs.get(p.pid, p)  # reaproveita o objeto para medir a CPU desde a última leitura
                    with p.oneshot():
                        cpu += p.cpu_percent(None)
                        mem += p.memory_info().rss
                    alive[p.pid] = p
                except psutil.Error:
                    pass
            self._procs = alive
            self.cpu, self.mem = cpu, mem
            time.sleep(1)
            while not self.visible:  # escondido: não gasta CPU medindo
                time.sleep(0.2)


# --------------------------------------------------------------------------- interface

RESET, BOLD, DIM = '\x1b[0m', '\x1b[1m', '\x1b[2m'


def _cw(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in 'WF' else 1


def dwidth(s):
    return sum(_cw(c) for c in s)


def trunc(s, w):
    if dwidth(s) <= w:
        return s
    out, cur = [], 0
    for ch in s:
        if cur + _cw(ch) > w - 1:
            break
        out.append(ch)
        cur += _cw(ch)
    return ''.join(out) + '…'


def fmt_time(sec):
    sec = int(max(sec, 0))
    return f'{sec // 3600}:{sec // 60 % 60:02d}:{sec % 60:02d}' if sec >= 3600 else f'{sec // 60:02d}:{sec % 60:02d}'


SPINNER = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'


def build_frame(player, viz, perf, video, cols, rows, now):
    t = player.track
    accent = _fg(viz._color(0.8, 0.5))
    buffering = player.state == 'playing' and player.played == 0
    if player.state == 'loading' or buffering:
        icon = SPINNER[int(now * 12) % len(SPINNER)]
    elif player.state == 'error':
        icon = '✕'
    else:
        icon = '⏸' if player.paused else '▶'

    stats = f'CPU {perf.cpu:4.1f}% · MEM {perf.mem / 2**20:.0f} MB ' if perf.visible else ''
    title = trunc(t.title or 'Carregando…', cols - dwidth(stats) - 5)
    gap = cols - 3 - dwidth(title) - dwidth(stats)
    head1 = f' {accent}{icon}{RESET} {BOLD}{title}{RESET}{" " * max(gap, 1)}{DIM}{stats}{RESET}'

    queue = trunc(f'{player.idx + 1}/{len(player.tracks)} · {player.label} ', max(cols // 3, 10))
    sub = ' · '.join(x for x in (t.artist, t.album) if x)
    if player.state == 'error':
        sub, color = f'Erro: {player.message} — pulando…', '\x1b[31m'
    elif player.state == 'loading' or buffering:
        sub, color = (sub + ' · ' if sub else '') + ('preparando áudio…' if buffering else 'buscando faixa…'), DIM
    else:
        color = DIM
    sub = trunc(sub, cols - dwidth(queue) - 5)
    gap = cols - 3 - dwidth(sub) - dwidth(queue)
    head2 = f'   {color}{sub}{RESET}{" " * max(gap, 1)}{DIM}{queue}{RESET}'

    viz_h = max(rows - 7, 3)
    active = player.state == 'playing' and not player.paused
    samples = player.recent(FFT) if active else np.zeros(FFT, np.float32)
    n, *_ = viz.layout(cols)
    viz.update(samples, n, 1 / FPS, active)
    heard = player.heard_position() if player.state == 'playing' else 0.0
    timg_out = ''
    if viz.mode_name == 'video' and player.state == 'playing' and t.info_path:
        video.ensure(t, cols, viz_h)
        if video.engine == 'timg':
            timg_out = video.take_timg(top=4)
            body = video.timg_body(viz_h, bool(timg_out))
        else:
            body = viz.render_video(cols, viz_h, video.frame, video.status, video.frame_quad, video.settings['step'])
    else:
        video.stop()
        body = viz.render(cols, viz_h, samples, t, heard)

    pos = player.position() if player.state == 'playing' else 0
    dur = t.duration or 0
    left, rt = fmt_time(pos), fmt_time(dur) if dur else '--:--'
    bar_w = max(cols - len(left) - len(rt) - 6, 5)
    frac = min(pos / dur, 1) if dur else 0
    k = int(frac * (bar_w - 1))
    prog = f' {left} {accent}{"━" * k}●{RESET}{DIM}{"─" * (bar_w - 1 - k)}{RESET} {rt}'

    vol = f'vol {int(player.volume * 100)}%'
    shown = f'video ({video.quality} · {video.engine})' if viz.mode_name == 'video' else viz.mode_name
    status = f' {DIM}{vol} · visual: {shown} · cores: {viz.palette_name} · sync: {player.sync_ms:+d}ms' \
             f'{" · repetir" if player.repeat else ""}{RESET}'
    keys = trunc('espaço pausa · ←/→ ±10s · n/p próx/ant · ↑/↓ volume · v visual · g qualidade do vídeo · m motor do vídeo · c cores · [/] sync · r repetir · h hud · q sair', cols - 2)
    lines = [head1, head2, ''] + body + [prog, status, f' {DIM}{keys}{RESET}']
    lines = lines[:rows]
    # cada linha vai para sua posição; None deixa a linha como está (área desenhada pelo timg)
    screen = ''.join(f'\x1b[{i + 1};1H{l}{RESET}\x1b[K' for i, l in enumerate(lines) if l is not None)
    if len(lines) < rows:
        screen += f'\x1b[{len(lines) + 1};1H\x1b[J'
    return screen + timg_out


def handle_keys(data, player, viz, perf, video):
    i = 0
    while i < len(data):
        seq = data[i:i + 3]
        if seq in ('\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D'):
            i += 3
            if seq == '\x1b[A':
                player.volume = min(1.0, round(player.volume + 0.05, 2))
            elif seq == '\x1b[B':
                player.volume = max(0.0, round(player.volume - 0.05, 2))
            elif seq == '\x1b[C':
                player.seek(10)
            else:
                player.seek(-10)
            continue
        ch = data[i]
        i += 1
        if ch in 'qQ':
            return False
        if ch == ' ':
            player.toggle_pause()
        elif ch in 'nN':
            player.next()
        elif ch in 'pP':
            player.prev()
        elif ch in '+=':
            player.volume = min(1.0, round(player.volume + 0.05, 2))
        elif ch in '-_':
            player.volume = max(0.0, round(player.volume - 0.05, 2))
        elif ch in 'vV':
            viz.cycle_mode()
        elif ch in 'cC':
            viz.cycle_palette()
        elif ch == '[':
            player.sync_ms -= 20
        elif ch == ']':
            player.sync_ms += 20
        elif ch in 'rR':
            player.repeat = not player.repeat
        elif ch in 'hH':
            perf.visible = not perf.visible
        elif ch in 'gG':
            video.cycle_quality()
        elif ch in 'mM':
            video.cycle_engine()
    return True


def run_ui(player, viz, mac=None, video_quality='alta', video_engine='timg'):
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    out = sys.stdout
    finished = False
    tty.setcbreak(fd)
    # mensagens de bibliotecas (ex.: avisos do áudio) iriam para o meio da tela: vão para um log
    log_path = os.path.join(tempfile.gettempdir(), 'ytm.log')
    saved_stderr = os.dup(2)
    log = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(log, 2)
    os.close(log)
    out.write('\x1b[?1049h\x1b[?25l\x1b[2J')
    out.flush()
    try:
        perf = PerfMonitor()
        video = VideoFeed(player, video_quality, video_engine)
        player.play_index(0)
        size = None
        next_frame = time.time()
        while True:
            now = time.time()
            if mac:
                mac.pump()
                if mac.quit_requested:
                    break
            if player.state == 'ended' and not player.next(manual=False):
                finished = True
                break
            if player.state == 'error' and now - player.error_at > 2:
                if not player.next(manual=False):
                    finished = True
                    break

            cols, rows = shutil.get_terminal_size()
            if (cols, rows) != size:
                size = (cols, rows)
                out.write('\x1b[2J')
            out.write(build_frame(player, viz, perf, video, cols, rows, now))
            out.flush()

            next_frame += 1 / FPS
            timeout = next_frame - time.time()
            if timeout < 0:
                next_frame, timeout = time.time(), 0
            r, _, _ = select.select([fd], [], [], timeout)
            if r and not handle_keys(os.read(fd, 64).decode(errors='ignore'), player, viz, perf, video):
                break
    except KeyboardInterrupt:
        pass
    finally:
        if 'video' in locals():
            video.stop()
        if mac:
            mac.close()
        out.write('\x1b[0m\x1b[?25h\x1b[?1049l')
        out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        os.dup2(saved_stderr, 2)
        os.close(saved_stderr)
    return finished


def start_mac(player, args):
    """Liga a integração com o macOS; sem PyObjC ou com --sem-mac, o tocador segue sem ela."""
    if args.sem_mac:
        return None
    try:
        from macos import MacIntegration
        return MacIntegration(player, notifications=not args.sem_notificacao)
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(
        prog='ytm',
        description='Toca músicas e playlists do YouTube Music no terminal, com visualizador de áudio.',
        epilog='exemplos:\n'
               '  ytm bohemian rhapsody            toca a primeira música encontrada\n'
               '  ytm -n 10 daft punk              enfileira os 10 primeiros resultados\n'
               '  ytm -p rock classico             busca uma playlist e toca\n'
               '  ytm --radio tiny dancer          toca a música e continua com o rádio dela\n'
               '  ytm "https://music.youtube.com/playlist?list=..."',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('query', nargs='+', help='termo de busca ou link do YouTube / YouTube Music')
    ap.add_argument('-p', '--playlist', action='store_true', help='buscar uma playlist em vez de uma música')
    ap.add_argument('-n', type=int, default=1, metavar='N', help='enfileirar os N primeiros resultados da busca')
    ap.add_argument('--radio', action='store_true', help='depois da música, continuar com o rádio (mix) dela')
    ap.add_argument('--single', action='store_true', help='num link com &list=, tocar só a música')
    ap.add_argument('-s', '--shuffle', action='store_true', help='ordem aleatória')
    ap.add_argument('-r', '--repeat', action='store_true', help='repetir a fila ao terminar')
    ap.add_argument('--volume', type=int, default=100, help='volume inicial 0-100 (padrão 100)')
    ap.add_argument('--visual', choices=MODES, default='barras', help='estilo da animação')
    ap.add_argument('--cores', choices=list(PALETTES), default='neon', help='paleta de cores')
    ap.add_argument('--motor-video', choices=['timg', 'interno'], default='timg',
                    help='quem desenha o visual video: timg (padrão, se instalado; redesenha só o que muda) '
                         'ou interno (o desenho próprio do ytm)')
    ap.add_argument('--qualidade-video', choices=list(VIDEO_QUALITY), default='alta',
                    help='qualidade do visual video: alta (720p, 30 qps, 4 pixels por caractere), '
                         'media (480p, 24 qps) ou baixa (360p, 15 qps); padrão alta')
    ap.add_argument('--sem-mac', action='store_true',
                    help='não integrar com o macOS (Tocando Agora, barra de menus e notificações)')
    ap.add_argument('--sem-notificacao', action='store_true', help='não mostrar notificação a cada música')
    ap.add_argument('--sync', type=int, default=0, metavar='MS',
                    help='atraso extra da animação em ms (ex.: 200 para fones Bluetooth)')
    args = ap.parse_args()

    if not shutil.which('ffmpeg'):
        sys.exit('ytm: ffmpeg não encontrado. Instale com: brew install ffmpeg')
    if not sys.stdin.isatty():
        sys.exit('ytm: precisa ser executado num terminal interativo.')

    print('\x1b[2m🔎 Buscando no YouTube Music…\x1b[0m', file=sys.stderr)
    try:
        tracks, label = resolve(args)
    except Exception as e:
        sys.exit(f'ytm: falha na busca: {e}')
    if not tracks:
        sys.exit('ytm: nada encontrado.')
    if args.shuffle:
        random.shuffle(tracks)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
    player = Player(tracks, label, args)
    try:
        finished = run_ui(player, Visualizer(args.visual, args.cores), start_mac(player, args), args.qualidade_video,
                          args.motor_video)
    finally:
        player.close()
    if finished:
        print('♪ Fim da fila.')


if __name__ == '__main__':
    main()
