"""Genera la serie de prueba de PROVEEDORES (Disney, Max…) a partir de tus catálogos privados. Los ficheros de salida llevan
claves y enlaces con token: se guardan como *.local.json y están en .gitignore (NO se suben a git ni al repo de la CI).
Uso: python genera_privada.py <carpeta_con_los_catalogos>   (o la variable de entorno CATALOGOS_OTT)"""
import json, os, sys
AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CATALOGOS_OTT", ".")
FUENTES = [  # (fichero, plataforma, cuántos)
    ("disney/peliculas_disney.json", "Disney", 3),
    ("hbomax/condropbox/catalogo_db_max.json", "Max", 3),
]
SERIES = ("hbomax/candi/mediateca_series.json", "Max series", 2)

tests, pelis = [], []
for fichero, plataforma, n in FUENTES:
    try:
        datos = json.load(open(os.path.join(RAIZ, fichero), encoding="utf-8"))
    except Exception as e:
        print("sin", fichero, e); continue
    for d in datos[:n]:
        v = d.get("video") or ""
        if not v: continue
        kind = "dash" if ".mpd" in v else "smooth" if ".ism" in v else "hlsPlain"
        tests.append({"name": f"{plataforma}: {d.get('name')}", "url": v, "keys": d.get("drmkey") or "", "headers": {}, "expect": {"kind": kind, "engine": "avplayer"}})
        pelis.append({"name": f"{plataforma}: {d.get('name')}", "video": v, "drm": d.get("drm") or "", "drmkey": d.get("drmkey") or "", "category": plataforma, "info": {}})
try:
    datos = json.load(open(os.path.join(RAIZ, SERIES[0]), encoding="utf-8"))
    for s in datos[:SERIES[2]]:
        ep = s["seasons"][0]["episodes"][0]
        v = ep.get("video") or ""
        if not v: continue
        tests.append({"name": f"{SERIES[1]}: {s.get('name')} T1E1", "url": v, "keys": ep.get("drmkey") or "", "headers": {}, "expect": {"kind": "dash" if ".mpd" in v else "hlsPlain", "engine": "avplayer"}})
except Exception as e:
    print("sin series", e)
json.dump(tests, open(os.path.join(AQUI, "tests_proveedores.local.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
json.dump(pelis, open(os.path.join(AQUI, "serie_proveedores.local.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(tests), "casos privados")
