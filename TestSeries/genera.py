"""Genera la serie de prueba de formatos (solo URLs públicas, sin claves ni tokens) en dos formatos:
  - serie_formatos.json  → Mediateca (serie → temporadas → capítulos), para verla y reproducirla desde la app
  - tests_formatos.json  → lista del «modo pruebas» (TestRunner): [{name, url, keys, headers, expect}]
Cada capítulo lleva `expect` = lo que debe ocurrir: kind (hlsPlain, dash, smooth, matroska, other), engine (avplayer|vlc), e info del contenido.
La serie de proveedores privados (Disney, Max, Movistar, Orange…) se genera aparte con genera_privada.py y NO se sube a git."""
import json, os
AQUI = os.path.dirname(os.path.abspath(__file__))

# (temporada, nombre, url, kind esperado, motor esperado, qué prueba)
T = [
 (1, "HLS clásico en TS (bipbop)", "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8", "hlsPlain", "avplayer", "HLS TS H.264 + AAC, subtítulos WebVTT, varias calidades"),
 (1, "HLS fMP4 HEVC + AC-3 + E-AC-3 (bipbop)", "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8", "hlsPlain", "avplayer", "HEVC y H.264, audio AAC/AC-3/E-AC-3 5.1, subtítulos"),
 (1, "HLS Unified Streaming (Tears of Steel)", "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8", "hlsPlain", "avplayer", "HLS simple con audio+vídeo en la misma variante"),
 (1, "DASH Big Buck Bunny 30 fps", "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd", "dash", "avplayer", "DASH H.264 + AAC, SegmentTemplate"),
 (1, "DASH MultiRate (Qualcomm)", "https://dash.akamaized.net/dash264/TestCases/1c/qualcomm/2/MultiRate.mpd", "dash", "avplayer", "DASH varias calidades"),
 (1, "DASH Angel One (H.264 y VP9, 4 subtítulos VTT)", "https://storage.googleapis.com/shaka-demo-assets/angel-one-widevine/dash.mpd", "dash", "avplayer", "VP9 sin hardware → VLC; cifrado Widevine: solo se mira el catálogo"),
 (1, "Smooth Streaming (Super Speedway)", "https://playready.directtaps.net/smoothstreaming/SSWSS720H264/SuperSpeedway_720.ism/Manifest", "smooth", "avplayer", "Smooth H.264 + AAC"),
 (2, "MP4 H.264 + AAC", "https://download.samplelib.com/mp4/sample-5s.mp4", "other", "avplayer", "MP4 directo"),
 (2, "MP4 que se llama .mkv (el contenido manda)", "https://test-videos.co.uk/vids/bigbuckbunny/mkv/360/Big_Buck_Bunny_360_10s_1MB.mkv", "other", "avplayer", "extensión .mkv pero es MP4 H.264: se detecta por los bytes"),
 (2, "MKV MPEG-4 ASP + MP3 (suite Matroska test1)", "https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/master/test_files/test1.mkv", "matroska", "vlc", "MKV con vídeo DivX/Xvid y audio MP3: no pasa directo a HLS, va a VLC"),
 (2, "MKV H.264 + MP3 (suite Matroska test3)", "https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/master/test_files/test3.mkv", "matroska", "vlc", "H.264 pasa directo pero el MP3 no, va a VLC"),
 (2, "MKV H.264 + AAC dos pistas (suite Matroska test5)", "https://raw.githubusercontent.com/ietf-wg-cellar/matroska-test-files/master/test_files/test5.mkv", "matroska", "avplayer", "MKV con varias pistas"),
 (2, "WebM VP9", "https://test-videos.co.uk/vids/bigbuckbunny/webm/vp9/360/Big_Buck_Bunny_360_10s_1MB.webm", "matroska", "vlc", "WebM VP9: sin hardware VP9 → VLC"),
 (2, "AVI", "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-avi-file.avi", "other", "vlc", "AVI: solo VLC"),
 (3, "Audio FLAC", "https://samples.ffmpeg.org/flac/Yesterday.flac", "other", "vlc", "FLAC sin vídeo: solo VLC"),
 (3, "Audio MP3", "https://download.samplelib.com/mp3/sample-3s.mp3", "other", "avplayer", "MP3 directo"),
 (3, "Audio WAV", "https://download.samplelib.com/wav/sample-3s.wav", "other", "avplayer", "WAV directo"),
]

episodios = {}
tests = []
for s, nombre, url, kind, engine, nota in T:
    episodios.setdefault(s, []).append({"episode": len(episodios.get(s, [])) + 1, "name": nombre, "video": url, "info": {"plot": nota}, "expect": {"kind": kind, "engine": engine}})
    tests.append({"name": nombre, "url": url, "keys": "", "headers": {}, "expect": {"kind": kind, "engine": engine}})
serie = [{"name": "Prueba de formatos", "category": "Pruebas", "info": {"year": "2026", "plot": "Formatos de vídeo y audio para validar el reproductor (AVPlayer, relay y VLC). Solo enlaces públicos.", "genre": ["Pruebas"]},
          "seasons": [{"season": s, "episodes": e} for s, e in sorted(episodios.items())]}]
json.dump(serie, open(os.path.join(AQUI, "serie_formatos.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
json.dump(tests, open(os.path.join(AQUI, "tests_formatos.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(tests), "capítulos")
