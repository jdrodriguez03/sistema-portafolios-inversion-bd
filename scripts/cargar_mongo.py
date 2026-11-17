"""
cargar_mongo.py - Carga el componente documental en MongoDB.

Base: portafolios_nosql
  mercado_activos : un documento por accion/fondo con la ficha completa
                    de Yahoo Finance (estructura variable) y el historial
                    diario de precios EMBEBIDO.
  trm_raw         : las publicaciones de la TRM tal como las entrega la API
                    de datos.gov.co (valores como texto, sin transformar).

Fuente: datos/raw/*.json (respuestas crudas guardadas por generar_datos.py).
Si no existen (modo --simular), se construyen desde datos/*.csv.

Uso:
  python scripts/cargar_mongo.py             carga las colecciones
  python scripts/cargar_mongo.py --exportar  exporta las colecciones a backup/mongo/
"""
import csv
import json
import sys
from datetime import datetime
from pathlib import Path

from pymongo import MongoClient
from bson import json_util

RAIZ = Path(__file__).resolve().parent.parent
DATOS = RAIZ / "datos"
RAW = DATOS / "raw"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generar_datos import TICKERS  # noqa: E402

URI = "mongodb://localhost:27017"
BASE = "portafolios_nosql"


def fecha(s):
    return datetime.fromisoformat(s[:10])


def documentos_activos():
    meta = {t[0]: t for t in TICKERS}
    docs = []
    crudos = sorted(RAW.glob("yf_*.json")) if RAW.exists() else []
    if crudos:
        for f in crudos:
            d = json.loads(f.read_text(encoding="utf-8"))
            t = d["ticker"]
            info = d.get("info") or {}
            docs.append({
                "_id": t,
                "ticker": t,
                "nombre": info.get("longName") or info.get("shortName") or meta[t][1],
                "tipo": "FONDO" if info.get("quoteType") == "ETF" or meta[t][2] == 2 else "ACCION",
                "mercado": meta[t][3],
                "fuente": d.get("fuente", "yfinance"),
                "descargado_en": datetime.fromisoformat(d["descargado_en"]),
                "info": info,
                "historia": [{**h, "fecha": fecha(h["fecha"])} for h in d["historia"]],
            })
        return docs, "datos/raw (respuestas crudas de yfinance)"

    hist = {}
    with open(DATOS / "precios.csv", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            hist.setdefault(r["ticker"], []).append(
                {"fecha": fecha(r["fecha"]), "cierre": float(r["cierre"]), "dividendo": float(r["dividendo"])})
    for t, h in hist.items():
        docs.append({"_id": t, "ticker": t, "nombre": meta[t][1],
                     "tipo": "FONDO" if meta[t][2] == 2 else "ACCION", "mercado": meta[t][3],
                     "fuente": "simulado", "descargado_en": datetime.now(), "info": {}, "historia": h})
    return docs, "datos/precios.csv (modo simulado)"


def documentos_trm():
    f = RAW / "trm_datos_gov_co.json"
    if f.exists():
        d = json.loads(f.read_text(encoding="utf-8"))
        return [{**r, "_fuente": d["fuente"]} for r in d["registros"]], "datos/raw/trm_datos_gov_co.json"
    docs = []
    with open(DATOS / "trm.csv", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            docs.append({"valor": r["valor_cop"], "unidad": "COP",
                         "vigenciadesde": r["fecha_desde"] + "T00:00:00.000",
                         "vigenciahasta": r["fecha_hasta"] + "T00:00:00.000", "_fuente": "simulado"})
    return docs, "datos/trm.csv (modo simulado)"


def main():
    cli = MongoClient(URI, serverSelectionTimeoutMS=5000)
    db = cli[BASE]
    if "--exportar" in sys.argv:
        destino = RAIZ / "backup" / "mongo"
        destino.mkdir(parents=True, exist_ok=True)
        for nombre in db.list_collection_names():
            docs = list(db[nombre].find())
            (destino / f"{nombre}.json").write_text(
                json_util.dumps(docs, indent=1, ensure_ascii=False), encoding="utf-8")
            print(f"  {nombre}: {len(docs)} documentos -> backup/mongo/{nombre}.json")
        return

    activos, origen_a = documentos_activos()
    trm, origen_t = documentos_trm()
    db.mercado_activos.drop()
    db.trm_raw.drop()
    db.mercado_activos.insert_many(activos)
    db.trm_raw.insert_many(trm)
    print(f"mercado_activos: {len(activos)} documentos desde {origen_a}")
    for d in activos:
        print(f"  {d['ticker']:6} {d['tipo']:7} campos en info: {len(d['info']):3}  dias en historia: {len(d['historia'])}")
    print(f"trm_raw: {len(trm)} documentos desde {origen_t}")


if __name__ == "__main__":
    main()
