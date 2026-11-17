"""
generar_datos.py - Genera sql/04_carga_datos.sql

Fuentes
  * Precios y dividendos de acciones y fondos: Yahoo Finance (libreria yfinance)
  * TRM oficial: Superintendencia Financiera, datos.gov.co (dataset 32sa-8pi3)
  * Asesores, clientes, cuentas y operaciones: datos sinteticos generados con
    una semilla fija (reproducibles) que respetan las reglas de negocio que
    validan los triggers (saldo suficiente, tenencia, vencimientos, etc.)

Uso (desde la carpeta del proyecto)
  python scripts/generar_datos.py              descarga (o reutiliza datos/*.csv) y genera el SQL
  python scripts/generar_datos.py --descargar  fuerza una nueva descarga
  python scripts/generar_datos.py --simular    sin internet: precios y TRM simulados

La descarga guarda ademas las respuestas crudas de las API en datos/raw/
(se usan en el componente MongoDB).
"""
import argparse
import bisect
import csv
import json
import random
import sys
import time
import unicodedata
from datetime import date, datetime, timedelta
from decimal import Decimal, ROUND_HALF_UP, ROUND_DOWN
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
DATOS = RAIZ / "datos"
RAW = DATOS / "raw"
SALIDA = RAIZ / "sql" / "04_carga_datos.sql"

SEMILLA = 2026
INICIO_PRECIOS = date(2024, 1, 2)
TASA_COMISION = Decimal("0.005")
CENT = Decimal("0.01")

# (ticker, nombre, tipo, mercado)   tipo: 1 = ACCION, 2 = FONDO
TICKERS = [
    ("EC",    "Ecopetrol S.A. (ADR)",               1, "NYSE"),
    ("CIB",   "Bancolombia S.A. (ADR)",             1, "NYSE"),
    ("AAPL",  "Apple Inc.",                         1, "NASDAQ"),
    ("MSFT",  "Microsoft Corporation",              1, "NASDAQ"),
    ("AMZN",  "Amazon.com Inc.",                    1, "NASDAQ"),
    ("GOOGL", "Alphabet Inc. Clase A",              1, "NASDAQ"),
    ("TSLA",  "Tesla Inc.",                         1, "NASDAQ"),
    ("JNJ",   "Johnson & Johnson",                  1, "NYSE"),
    ("SPY",   "SPDR S&P 500 ETF Trust",             2, "NYSE ARCA"),
    ("QQQ",   "Invesco QQQ Trust (Nasdaq-100)",     2, "NASDAQ"),
]
# (nombre, serie, tasa cupon, emision, vencimiento, mes y dia del cupon) - valores de referencia
TES = [
    ("TES 2027 (corto plazo)",   "TFIT08031127", Decimal("0.0575"), date(2019, 11, 3),  date(2027, 11, 3)),
    ("TES 2032 (mediano plazo)", "TFIT16300632", Decimal("0.0700"), date(2016, 6, 30),  date(2032, 6, 30)),
    ("TES 2036 (largo plazo)",   "TFIT16091036", Decimal("0.0625"), date(2020, 10, 9),  date(2036, 10, 9)),
]
BANCOS = ["Bancolombia", "Davivienda", "Banco de Bogota", "BBVA Colombia",
          "Banco de Occidente", "Banco Popular", "Banco Caja Social", "Itau Colombia"]
VALOR_TITULO_TES_COP = Decimal("1000000")

# Lista alternada: posiciones pares masculinas, impares femeninas
NOMBRES = ["Andres", "Camila", "Santiago", "Valentina", "Juan", "Maria", "Carlos", "Laura", "Felipe",
           "Daniela", "Sebastian", "Paula", "David", "Natalia", "Miguel", "Sofia", "Jorge", "Carolina",
           "Alejandro", "Diana", "Ricardo", "Juliana", "Oscar", "Angela", "Mauricio", "Catalina",
           "Fernando", "Luisa", "Esteban", "Marcela", "Hernan", "Adriana", "Gabriel", "Monica",
           "Rafael", "Patricia", "Ivan", "Claudia", "Nicolas", "Gloria"]
APELLIDOS = ["Gomez", "Rodriguez", "Martinez", "Lopez", "Garcia", "Hernandez", "Ramirez", "Torres",
             "Diaz", "Vargas", "Moreno", "Rojas", "Jimenez", "Castro", "Ortiz", "Suarez", "Restrepo",
             "Gutierrez", "Mejia", "Cardenas", "Salazar", "Acosta", "Rincon", "Ospina", "Giraldo",
             "Zapata", "Velez", "Pardo", "Londono", "Cortes"]


def q2(x):
    return Decimal(x).quantize(CENT, ROUND_HALF_UP)


def q4(x):
    return Decimal(x).quantize(Decimal("0.0001"), ROUND_HALF_UP)


# ---------------------------------------------------------------------------
# 1. Datos de mercado
# ---------------------------------------------------------------------------
def descargar():
    """Descarga precios (yfinance) y TRM (datos.gov.co). Guarda CSV y JSON crudo."""
    import requests
    import yfinance as yf

    DATOS.mkdir(exist_ok=True)
    RAW.mkdir(exist_ok=True)
    ahora = datetime.now().isoformat(timespec="seconds")
    filas = []
    for ticker, *_ in TICKERS:
        tk = yf.Ticker(ticker)
        h = None
        for intento in range(4):                      # reintentos ante limite de peticiones
            try:
                h = tk.history(start=INICIO_PRECIOS.isoformat(), auto_adjust=False)
                if not h.empty:
                    break
            except Exception as e:
                print(f"  {ticker}: intento {intento + 1} fallido ({e})")
            time.sleep(5 * (intento + 1))
        if h is None or h.empty:
            print(f"  AVISO: sin datos para {ticker}; se omite")
            continue
        historia = []
        for idx, r in h.iterrows():
            f = idx.date().isoformat()
            div = float(r.get("Dividends", 0) or 0)
            filas.append((ticker, f, f"{float(r['Close']):.4f}", f"{div:.6f}"))
            historia.append({"fecha": f, "apertura": float(r["Open"]), "maximo": float(r["High"]),
                             "minimo": float(r["Low"]), "cierre": float(r["Close"]),
                             "volumen": int(r["Volume"]), "dividendo": div})
        try:
            # Se conserva la ficha completa (anidada y distinta entre acciones y ETF)
            info = json.loads(json.dumps(tk.info, default=str))
        except Exception:
            info = {}
        (RAW / f"yf_{ticker}.json").write_text(json.dumps(
            {"fuente": "yfinance", "ticker": ticker, "descargado_en": ahora, "info": info,
             "historia": historia}, ensure_ascii=False), encoding="utf-8")
        print(f"  {ticker}: {len(historia)} dias")
    with open(DATOS / "precios.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["ticker", "fecha", "cierre", "dividendo"])
        w.writerows(filas)

    url = "https://www.datos.gov.co/resource/32sa-8pi3.json"
    resp = requests.get(url, params={"$limit": 5000, "$order": "vigenciadesde",
                                     "$where": "vigenciadesde >= '2023-12-01T00:00:00.000'"}, timeout=60)
    resp.raise_for_status()
    crudo = resp.json()
    (RAW / "trm_datos_gov_co.json").write_text(json.dumps(
        {"fuente": url, "descargado_en": ahora, "registros": crudo}, ensure_ascii=False), encoding="utf-8")
    with open(DATOS / "trm.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["fecha_desde", "fecha_hasta", "valor_cop"])
        for r in crudo:
            w.writerow([r["vigenciadesde"][:10], r["vigenciahasta"][:10], r["valor"]])
    print(f"  TRM: {len(crudo)} rangos")


def simular(rnd):
    """Sin internet: caminata aleatoria para precios y TRM (se declara en el SQL)."""
    DATOS.mkdir(exist_ok=True)
    base = {"EC": 11.8, "CIB": 31.0, "AAPL": 185.0, "MSFT": 370.0, "AMZN": 150.0, "GOOGL": 138.0,
            "TSLA": 248.0, "JNJ": 160.0, "SPY": 472.0, "QQQ": 402.0}
    div_trim = {"EC": 0.35, "CIB": 0.85, "AAPL": 0.25, "MSFT": 0.78, "JNJ": 1.24, "SPY": 1.75,
                "QQQ": 0.62, "GOOGL": 0.20}
    dias = []
    d = INICIO_PRECIOS
    while d < date.today():
        if d.weekday() < 5:
            dias.append(d)
        d += timedelta(days=1)
    with open(DATOS / "precios.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["ticker", "fecha", "cierre", "dividendo"])
        for t, p in base.items():
            vol = 0.028 if t == "TSLA" else 0.009 if t in ("SPY", "QQQ", "JNJ") else 0.016
            ultimo_trim = None
            for d in dias:
                p *= 1 + rnd.gauss(0.0005, vol)
                trim = (d.year, (d.month - 1) // 3)
                div = 0
                if t in div_trim and d.month in (2, 5, 8, 11) and d.day >= 10 and trim != ultimo_trim:
                    div, ultimo_trim = div_trim[t], trim
                w.writerow([t, d.isoformat(), f"{p:.4f}", f"{div:.6f}"])
    with open(DATOS / "trm.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["fecha_desde", "fecha_hasta", "valor_cop"])
        v = 3900.0
        d = date(2023, 12, 1)
        fin = date.today() + timedelta(days=1)
        while d <= fin:
            if d.weekday() < 5:
                v *= 1 + rnd.gauss(-0.0002, 0.006)
                hasta = d + timedelta(days=2) if d.weekday() == 4 else d
                w.writerow([d.isoformat(), hasta.isoformat(), f"{v:.2f}"])
            d += timedelta(days=1)


def leer_mercado():
    precios, dividendos = {}, {}
    with open(DATOS / "precios.csv", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            f = date.fromisoformat(r["fecha"])
            precios.setdefault(r["ticker"], {})[f] = q4(r["cierre"])
            if float(r["dividendo"]) > 0:
                dividendos.setdefault(r["ticker"], {})[f] = Decimal(r["dividendo"])
    trm = []
    with open(DATOS / "trm.csv", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            trm.append([date.fromisoformat(r["fecha_desde"]), date.fromisoformat(r["fecha_hasta"]),
                        q2(r["valor_cop"])])
    # Rangos sin duplicados ni solapes (restriccion EXCLUDE de la tabla trm)
    trm.sort(key=lambda x: x[0])
    limpio = []
    for r in trm:
        if limpio and r[0] == limpio[-1][0]:
            limpio[-1] = r
        else:
            limpio.append(r)
    for i in range(len(limpio) - 1):
        tope = limpio[i + 1][0] - timedelta(days=1)
        if limpio[i][1] > tope:
            limpio[i][1] = tope
        if limpio[i][1] < limpio[i][0]:
            limpio[i][1] = limpio[i][0]
    return precios, dividendos, limpio


# ---------------------------------------------------------------------------
# 2. Simulacion de la operacion de la firma
# ---------------------------------------------------------------------------
class Generador:
    def __init__(self, precios, dividendos, trm, rnd):
        self.rnd = rnd
        self.precios, self.dividendos, self.trm = precios, dividendos, trm
        self.trm_desde = [r[0] for r in trm]
        self.tickers = [t for t in TICKERS if t[0] in precios]
        self.dias = sorted(set.intersection(*[set(precios[t[0]]) for t in self.tickers]))
        self.corte = self.dias[-1]
        self.asesores, self.clientes, self.cuentas = [], [], []
        self.activos = []          # (id, tipo, nombre, fecha_registro, detalle)
        self.eventos = []          # (timestamp, secuencia, sql)
        self.seq = 0
        self.id_ticker = {}
        self.id_tes = []
        self.n_cdt = 0

    # -- utilidades ---------------------------------------------------------
    def trm_en(self, f):
        i = bisect.bisect_right(self.trm_desde, f) - 1
        return self.trm[max(i, 0)][2]

    def dia_habil(self, f):
        i = bisect.bisect_left(self.dias, f)
        return self.dias[i] if i < len(self.dias) else None

    def evento(self, ts, sql):
        self.seq += 1
        self.eventos.append((ts, self.seq, sql))

    # -- catalogo de personas y activos --------------------------------------
    def crear_personas(self, n_asesores=6, n_clientes=60):
        rnd = self.rnd
        usados, docs = set(), set()

        def persona():
            while True:
                i = rnd.randrange(len(NOMBRES))
                n = NOMBRES[i]
                if rnd.random() < 0.35:                 # segundo nombre del mismo genero
                    n += " " + rnd.choice(NOMBRES[i % 2::2])
                a = rnd.choice(APELLIDOS) + " " + rnd.choice(APELLIDOS)
                if (n, a) not in usados and len(set(n.split())) == len(n.split()) \
                        and len(set(a.split())) == 2:
                    usados.add((n, a))
                    break
            while True:
                doc = str(rnd.randint(10_000_000, 1_199_999_999))
                if doc not in docs:
                    docs.add(doc)
                    break
            return n, a, doc

        def correo(n, a, dominio, i):
            base = f"{n.split()[0]}.{a.split()[0]}{i}".lower()
            base = unicodedata.normalize("NFKD", base).encode("ascii", "ignore").decode()
            return f"{base}@{dominio}"

        for i in range(1, n_asesores + 1):
            n, a, doc = persona()
            ingreso = date(rnd.randint(2015, 2023), rnd.randint(1, 12), rnd.randint(1, 28))
            self.asesores.append((i, "CC", doc, n, a, correo(n, a, "firmaasesora.com.co", ""),
                                  f"60{rnd.randint(1, 8)}{rnd.randint(2000000, 7999999)}", ingreso))

        activos_asesor = list(range(1, n_asesores))          # el ultimo asesor queda sin clientes
        pesos = [rnd.uniform(0.6, 1.6) for _ in activos_asesor]
        id_cuenta = 0
        for i in range(1, n_clientes + 1):
            n, a, doc = persona()
            perfil = rnd.choices([1, 2, 3], [0.30, 0.42, 0.28])[0]
            apertura = self.dia_habil(INICIO_PRECIOS + timedelta(days=rnd.randint(10, 560)))
            nac = date(rnd.randint(1955, 2000), rnd.randint(1, 12), rnd.randint(1, 28))
            tipo_doc = "CE" if rnd.random() < 0.06 else "CC"
            self.clientes.append((i, perfil, rnd.choices(activos_asesor, pesos)[0], tipo_doc, doc, n, a,
                                  correo(n, a, rnd.choice(["gmail.com", "outlook.com", "hotmail.com"]), i),
                                  f"3{rnd.randint(0, 2)}{rnd.randint(0, 9)}{rnd.randint(1000000, 9999999)}",
                                  nac, apertura - timedelta(days=rnd.randint(0, 12))))
            id_cuenta += 1
            self.cuentas.append({"id": id_cuenta, "cliente": i, "perfil": perfil,
                                 "nombre": "Portafolio principal", "apertura": apertura})
            if rnd.random() < 0.27:
                ap2 = self.dia_habil(apertura + timedelta(days=rnd.randint(60, 420)))
                if ap2 and ap2 < self.corte - timedelta(days=60):
                    id_cuenta += 1
                    self.cuentas.append({"id": id_cuenta, "cliente": i, "perfil": perfil,
                                         "nombre": rnd.choice(["Ahorro para retiro", "Fondo educativo",
                                                               "Inversion de largo plazo", "Portafolio en dolares"]),
                                         "apertura": ap2})

    def crear_activos_base(self):
        aid = 0
        for ticker, nombre, tipo, mercado in self.tickers:
            aid += 1
            self.id_ticker[ticker] = aid
            self.activos.append((aid, tipo, nombre, INICIO_PRECIOS, ("AF", ticker, mercado)))
        for nombre, serie, cupon, emision, venc in TES:
            aid += 1
            self.id_tes.append((aid, cupon, venc))
            self.activos.append((aid, 4, nombre, INICIO_PRECIOS, ("TES", serie, cupon, emision, venc)))
        self.sig_activo = aid

    # -- simulacion de una cuenta --------------------------------------------
    def simular_cuenta(self, c, cdt_forzado=None):
        rnd, corte = self.rnd, self.corte
        perfil = c["perfil"]
        if perfil == 1:
            objetivo = rnd.uniform(0.24, 0.34) if rnd.random() < 0.22 else rnd.uniform(0.06, 0.17)
        elif perfil == 2:
            objetivo = rnd.uniform(0.56, 0.70) if rnd.random() < 0.22 else rnd.uniform(0.25, 0.45)
        else:
            objetivo = rnd.uniform(0.60, 0.90)
        deposito0 = q2(rnd.choice([8, 12, 15, 20, 25, 30, 40, 50, 60, 80, 100, 150, 220]) * 1000
                       * rnd.uniform(0.85, 1.15))
        favoritos = rnd.sample([t[0] for t in self.tickers], rnd.randint(3, 5))
        st = {"caja": Decimal(0), "rv": {}, "cdt": {}, "tes": {}, "min": {}}
        cid = c["id"]
        cupon_pagado = set()
        inactiva_desde = corte - timedelta(days=rnd.randint(95, 330)) if rnd.random() < 0.2 else None

        def ts(d):
            n = st["min"].get(d, 0)
            st["min"][d] = n + 1
            base = 9 * 60 + 35 + (cid * 7) % 240
            return datetime(d.year, d.month, d.day) + timedelta(minutes=base + n * 3)

        def registrar(d, plantilla):
            t = ts(d)
            self.evento(t, plantilla.format(ts=t.strftime("%Y-%m-%d %H:%M:%S")))

        def mov(d, tipo, monto):
            monto = q2(monto)
            if monto <= 0 or (tipo == "RETIRO" and monto > st["caja"]):
                return False
            st["caja"] += monto if tipo == "DEPOSITO" else -monto
            registrar(d, "INSERT INTO movimiento_efectivo (id_cuenta, tipo_movimiento, fecha_hora, monto) "
                         f"VALUES ({cid}, '{tipo}', '{{ts}}', {monto});")
            return True

        def trans(d, aid, tipo, cantidad, precio, tasa=None):
            monto = q2(cantidad * precio)
            com = q2(cantidad * precio * TASA_COMISION)
            if tipo == "COMPRA":
                if monto + com > st["caja"]:
                    return None
                st["caja"] -= monto + com
            else:
                st["caja"] += monto - com
            registrar(d, "INSERT INTO transaccion (id_cuenta, id_activo, tipo_transaccion, fecha_hora, cantidad, "
                         f"precio_unitario, tasa_pactada) VALUES ({cid}, {aid}, '{tipo}', '{{ts}}', {cantidad}, "
                         f"{precio}, {tasa if tasa is not None else 'NULL'});")
            return monto

        def comprar_rv(d, presupuesto):
            t = rnd.choice(favoritos)
            p = self.precios[t][d]
            cant = int(Decimal(presupuesto) / (p * Decimal("1.005")))
            if cant >= 1 and trans(d, self.id_ticker[t], "COMPRA", Decimal(cant), p) is not None:
                st["rv"][t] = st["rv"].get(t, Decimal(0)) + cant

        def comprar_cdt(d, presupuesto, venc=None):
            presupuesto = Decimal(presupuesto) / Decimal("1.005")
            if presupuesto < 1000:
                return
            if venc is None:
                venc = d + timedelta(days=rnd.choice([180, 270, 360, 360, 540, 720]))
            plazo = (venc - d).days
            tasa = q4(rnd.uniform(0.088, 0.128))
            precio = q4(q2(presupuesto))
            banco = rnd.choice(BANCOS)
            self.sig_activo += 1
            self.n_cdt += 1
            aid = self.sig_activo
            if trans(d, aid, "COMPRA", Decimal(1), precio, tasa) is None:
                self.sig_activo -= 1
                self.n_cdt -= 1
                return
            self.activos.append((aid, 3, f"CDT {banco} {plazo} dias No. {self.n_cdt:03d}", d,
                                 ("CDT", banco, d, venc)))
            st["cdt"][aid] = {"cop": precio * self.trm_en(d), "tasa": tasa, "compra": d, "venc": venc}

        def comprar_tes(d, presupuesto):
            aid, cupon, venc = rnd.choice(self.id_tes)
            precio = q4(VALOR_TITULO_TES_COP / self.trm_en(d))
            cant = int(Decimal(presupuesto) / (precio * Decimal("1.005")))
            if cant >= 1 and trans(d, aid, "COMPRA", Decimal(cant), precio, q4(rnd.uniform(0.092, 0.118))) is not None:
                st["tes"][aid] = st["tes"].get(aid, 0) + cant
                if (d.month, d.day) >= (venc.month, venc.day):
                    cupon_pagado.add((aid, d.year))     # el cupon de este anio ya se pago

        def invertir(d, total):
            total = Decimal(total)
            rv = total * Decimal(str(objetivo))
            for _ in range(rnd.randint(1, 3)):
                comprar_rv(d, rv / 2 if rv > 4000 else rv)
            rf = total - rv
            if rf > 1500:
                if rnd.random() < 0.3 and rf > 3000:
                    comprar_tes(d, rf * Decimal("0.4"))
                    rf *= Decimal("0.6")
                comprar_cdt(d, min(rf, st["caja"] * Decimal("0.97")))

        def vender_rv(d):
            if not st["rv"]:
                return
            t = rnd.choice(sorted(st["rv"]))
            tiene = st["rv"][t]
            cant = tiene if rnd.random() < 0.15 else Decimal(max(1, int(tiene * Decimal(str(rnd.uniform(0.2, 0.6))))))
            trans(d, self.id_ticker[t], "VENTA", cant, self.precios[t][d])
            st["rv"][t] = tiene - cant
            if st["rv"][t] == 0:
                del st["rv"][t]

        # Recorrido dia a dia desde la apertura
        i0 = bisect.bisect_left(self.dias, c["apertura"])
        prox = i0 + rnd.randint(0, 6)
        primera = True
        dia_forzado = None
        if cdt_forzado:
            dia_forzado = self.dia_habil(cdt_forzado - timedelta(days=rnd.choice([180, 360])))
            if dia_forzado is None or dia_forzado <= c["apertura"]:
                dia_forzado = None
        mov(c["apertura"], "DEPOSITO", deposito0)

        for i in range(i0, len(self.dias)):
            d = self.dias[i]
            # Dividendos (Regla 8)
            for t in sorted(st["rv"]):
                div = self.dividendos.get(t, {}).get(d)
                if div:
                    monto = q2(st["rv"][t] * div)
                    if monto > 0:
                        st["caja"] += monto
                        self.evento(datetime(d.year, d.month, d.day, 8, 0) + timedelta(seconds=cid),
                                    "INSERT INTO rendimiento (id_cuenta, id_activo, fecha, tipo_rendimiento, monto) "
                                    f"VALUES ({cid}, {self.id_ticker[t]}, '{d}', 'DIVIDENDO', {monto});")
            # Cupon anual de TES (primer dia habil desde la fecha del cupon)
            for aid, cupon, venc in self.id_tes:
                if aid in st["tes"] and (aid, d.year) not in cupon_pagado \
                        and (d.month, d.day) >= (venc.month, venc.day):
                    cupon_pagado.add((aid, d.year))
                    monto = q2(st["tes"][aid] * VALOR_TITULO_TES_COP * cupon / self.trm_en(d))
                    st["caja"] += monto
                    self.evento(datetime(d.year, d.month, d.day, 8, 30) + timedelta(seconds=cid),
                                "INSERT INTO rendimiento (id_cuenta, id_activo, fecha, tipo_rendimiento, monto) "
                                f"VALUES ({cid}, {aid}, '{d}', 'INTERES', {monto});")
            # Redencion de CDT vencidos (Regla 6: solo al vencimiento)
            for aid in sorted(st["cdt"]):
                l = st["cdt"][aid]
                if d >= l["venc"]:
                    dias = (l["venc"] - l["compra"]).days
                    valor = l["cop"] * (1 + l["tasa"]) ** (Decimal(dias) / Decimal(365)) / self.trm_en(d)
                    trans(d, aid, "VENTA", Decimal(1), q4(valor))
                    del st["cdt"][aid]
            # CDT que vencera poco despues de la fecha de corte
            if dia_forzado and d >= dia_forzado:
                monto = max(q2(deposito0 * Decimal(str(rnd.uniform(0.08, 0.25)))), Decimal("2500.00"))
                mov(d, "DEPOSITO", monto)
                comprar_cdt(d, monto, venc=cdt_forzado)
                dia_forzado = None
            # Operaciones periodicas
            if i < prox or (inactiva_desde and d >= inactiva_desde):
                continue
            if primera:
                invertir(d, st["caja"] * Decimal(str(rnd.uniform(0.80, 0.94))))
                primera = False
            else:
                accion = rnd.choices(["aporte", "caja", "venta", "retiro"], [0.38, 0.17, 0.30, 0.15])[0]
                if accion == "aporte":
                    aporte = q2(deposito0 * Decimal(str(rnd.uniform(0.05, 0.30))))
                    mov(d, "DEPOSITO", aporte)
                    invertir(d, aporte * Decimal("0.95"))
                elif accion == "caja" and st["caja"] > deposito0 * Decimal("0.04"):
                    invertir(d, st["caja"] * Decimal(str(rnd.uniform(0.5, 0.9))))
                elif accion == "venta":
                    vender_rv(d)
                elif accion == "retiro":
                    mov(d, "RETIRO", st["caja"] * Decimal(str(rnd.uniform(0.10, 0.40))))
            prox = i + rnd.randint(30, 85)

    def simular(self):
        self.crear_personas()
        self.crear_activos_base()
        antiguas = [c for c in self.cuentas if c["apertura"] < self.corte - timedelta(days=400)]
        forzadas = self.rnd.sample(antiguas, min(12, len(antiguas)))
        desfases = [6, 13, 19, 27, 34, 41, 48, 57, 66, 74, 81, 88]
        venc_forzado = {c["id"]: self.corte + timedelta(days=k) for c, k in zip(forzadas, desfases)}
        for c in self.cuentas:
            self.simular_cuenta(c, venc_forzado.get(c["id"]))
        self.eventos.sort(key=lambda e: (e[0], e[1]))


# ---------------------------------------------------------------------------
# 3. Escritura del script SQL
# ---------------------------------------------------------------------------
def sql_str(s):
    return "'" + str(s).replace("'", "''") + "'"


def lotes(filas, n=400):
    for i in range(0, len(filas), n):
        yield filas[i:i + n]


def escribir_sql(g, origen):
    L = []
    w = L.append
    w("-- =====================================================================")
    w("-- 04_carga_datos.sql  (generado por scripts/generar_datos.py - NO editar a mano)")
    w(f"-- Precios y TRM: {origen}")
    w(f"-- Fecha de corte de precios: {g.corte}   Semilla de datos sinteticos: {SEMILLA}")
    w("-- Requiere: 01_ddl.sql, 02_funciones_triggers.sql y 03_carga_catalogos.sql")
    w("-- Las operaciones se insertan en orden cronologico: los triggers validan")
    w("-- cada una y van actualizando el saldo de efectivo de la cuenta.")
    w("-- =====================================================================")
    w("SET client_encoding = 'UTF8';")
    w("BEGIN;")
    w("")
    w("-- Asesores")
    w("INSERT INTO asesor (id_asesor, tipo_documento, numero_documento, nombres, apellidos, email, telefono, fecha_ingreso) VALUES")
    w(",\n".join(f"  ({a[0]}, '{a[1]}', '{a[2]}', {sql_str(a[3])}, {sql_str(a[4])}, '{a[5]}', '{a[6]}', '{a[7]}')"
                 for a in g.asesores) + ";")
    w("")
    w("-- Clientes")
    w("INSERT INTO cliente (id_cliente, id_perfil, id_asesor, tipo_documento, numero_documento, nombres, apellidos, email, telefono, fecha_nacimiento, fecha_vinculacion) VALUES")
    w(",\n".join(f"  ({c[0]}, {c[1]}, {c[2]}, '{c[3]}', '{c[4]}', {sql_str(c[5])}, {sql_str(c[6])}, '{c[7]}', '{c[8]}', '{c[9]}', '{c[10]}')"
                 for c in g.clientes) + ";")
    w("")
    w("-- Cuentas (el saldo inicia en 0; el efectivo entra con depositos)")
    w("INSERT INTO cuenta (id_cuenta, id_cliente, nombre_cuenta, fecha_apertura) VALUES")
    w(",\n".join(f"  ({c['id']}, {c['cliente']}, {sql_str(c['nombre'])}, '{c['apertura']}')" for c in g.cuentas) + ";")
    w("")
    w("-- Activos: supertipo y subtipo en la misma transaccion (especializacion total)")
    w("INSERT INTO activo (id_activo, id_tipo_activo, nombre, fecha_registro) VALUES")
    w(",\n".join(f"  ({a[0]}, {a[1]}, {sql_str(a[2])}, '{a[3]}')" for a in g.activos) + ";")
    af = [a for a in g.activos if a[4][0] == "AF"]
    w("INSERT INTO accion_fondo (id_activo, id_tipo_activo, ticker, mercado) VALUES")
    w(",\n".join(f"  ({a[0]}, {a[1]}, '{a[4][1]}', '{a[4][2]}')" for a in af) + ";")
    tes = [a for a in g.activos if a[4][0] == "TES"]
    w("INSERT INTO tes (id_activo, id_tipo_activo, serie, tasa_cupon, fecha_emision, fecha_vencimiento) VALUES")
    w(",\n".join(f"  ({a[0]}, 4, '{a[4][1]}', {a[4][2]}, '{a[4][3]}', '{a[4][4]}')" for a in tes) + ";")
    cdt = [a for a in g.activos if a[4][0] == "CDT"]
    w("INSERT INTO cdt (id_activo, id_tipo_activo, entidad_emisora, fecha_emision, fecha_vencimiento) VALUES")
    w(",\n".join(f"  ({a[0]}, 3, {sql_str(a[4][1])}, '{a[4][2]}', '{a[4][3]}')" for a in cdt) + ";")
    w("")
    w("-- TRM por rango de vigencia")
    for lote in lotes(g.trm):
        w("INSERT INTO trm (fecha_desde, fecha_hasta, valor_cop) VALUES")
        w(",\n".join(f"  ('{r[0]}', '{r[1]}', {r[2]})" for r in lote) + ";")
    w("")
    w("-- Precios de cierre diarios")
    filas = [(g.id_ticker[t[0]], f, p) for t in g.tickers for f, p in sorted(g.precios[t[0]].items())]
    for lote in lotes(filas, 500):
        w("INSERT INTO precio_historico (id_activo, fecha, precio_cierre) VALUES")
        w(",\n".join(f"  ({r[0]}, '{r[1]}', {r[2]})" for r in lote) + ";")
    w("")
    w("-- Operaciones en orden cronologico (movimientos, transacciones y rendimientos)")
    for _, _, sql in g.eventos:
        w(sql)
    w("")
    w("-- Sincronizar las secuencias de identidad con los ids cargados")
    for tabla, col in [("asesor", "id_asesor"), ("cliente", "id_cliente"), ("cuenta", "id_cuenta"),
                       ("activo", "id_activo")]:
        w(f"SELECT setval(pg_get_serial_sequence('{tabla}', '{col}'), (SELECT MAX({col}) FROM {tabla}));")
    w("")
    w("COMMIT;")
    w("ANALYZE;")
    SALIDA.parent.mkdir(exist_ok=True)
    SALIDA.write_text("\n".join(L) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--descargar", action="store_true", help="fuerza la descarga de precios y TRM")
    ap.add_argument("--simular", action="store_true", help="precios y TRM simulados (sin internet)")
    args = ap.parse_args()
    rnd = random.Random(SEMILLA)
    marca = DATOS / "ORIGEN.txt"

    if args.simular:
        simular(rnd)
        marca.write_text("SIMULADOS (caminata aleatoria; no son datos de mercado reales)", encoding="utf-8")
    elif args.descargar or not (DATOS / "precios.csv").exists():
        print("Descargando precios (yfinance) y TRM (datos.gov.co)...")
        try:
            descargar()
        except Exception as e:
            print(f"\nERROR en la descarga: {e}\nRevise la conexion o ejecute con --simular.")
            sys.exit(1)
        marca.write_text(f"REALES: Yahoo Finance (yfinance) y datos.gov.co, descargados el {date.today()}",
                         encoding="utf-8")
    origen = marca.read_text(encoding="utf-8") if marca.exists() else "archivos en datos/"

    precios, dividendos, trm = leer_mercado()
    g = Generador(precios, dividendos, trm, random.Random(SEMILLA))
    g.simular()
    escribir_sql(g, origen)

    n = lambda clave: sum(1 for e in g.eventos if clave in e[2])
    print(f"\nGenerado {SALIDA.relative_to(RAIZ)}  ({origen})")
    print(f"  asesores {len(g.asesores)} | clientes {len(g.clientes)} | cuentas {len(g.cuentas)} | "
          f"activos {len(g.activos)} (CDT {g.n_cdt})")
    print(f"  transacciones {n('INTO transaccion')} | movimientos {n('INTO movimiento_efectivo')} | "
          f"rendimientos {n('INTO rendimiento')}")
    print(f"  precios {sum(len(v) for v in precios.values())} | TRM {len(trm)} rangos | corte {g.corte}")


if __name__ == "__main__":
    main()
