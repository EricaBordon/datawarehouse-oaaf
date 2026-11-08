"""
DATAWAREHOUSE OAAF — Generador del dataset sintético (Hito H3)
Cátedra Datawarehouse (22891) · Uninorte · Alumna: Érica Bordón

Genera las tres fuentes heterogéneas del acta de alcance:
  1. movimientos_migratorios.csv  (exportación del sistema de control fronterizo)
  2. alertas_inspeccion.json      (servicio de alertas, JSON anidado)
  3. catalogo_puestos.xlsx        (planilla de puestos de control) + .csv de contingencia

Periodo: 01/10/2024 a 30/09/2026. Todo es sintético: no hay personas reales.
Los viajeros se identifican con un código seudónimo (VJ-nnnnnn).

Criterio ético: la probabilidad de alerta depende SOLO del estado del documento,
de la conducta de viaje (cruces frecuentes, permanencia excedida previa) y de un
componente aleatorio de listas de vigilancia. NUNCA de la nacionalidad.

Defectos deliberados: se inyectan al final y se documentan en defectos_inyectados.md.

Uso:  python generar_datos_oaaf.py  [carpeta_salida]
Determinista: semilla fija 22891 -> mismos archivos en cada ejecución.
"""
import json
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

SEMILLA = 22891
rng = np.random.default_rng(SEMILLA)
SALIDA = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "fuentes"
SALIDA.mkdir(parents=True, exist_ok=True)

INICIO = datetime(2024, 10, 1)
FIN = datetime(2026, 9, 30, 23, 59)
DIAS = (FIN.date() - INICIO.date()).days + 1

# ---------------------------------------------------------------------------
# 1. Catálogo de puestos de control (nombres reales, datos operativos simulados)
# ---------------------------------------------------------------------------
PUESTOS = [
    # codigo, nombre, tipo, ciudad, departamento, pais_limitrofe, dotacion, lat, lon, peso_flujo
    ("PC-CDE-PA", "Puente de la Amistad", "TERRESTRE", "Ciudad del Este", "Alto Paraná", "Brasil", 9, -25.5094, -54.6006, 0.36),
    ("PC-ENC-SR", "Puente San Roque González de Santa Cruz", "TERRESTRE", "Encarnación", "Itapúa", "Argentina", 6, -27.3586, -55.8664, 0.18),
    ("PC-ASU-AE", "Aeropuerto Internacional Silvio Pettirossi", "AÉREO", "Luque", "Central", "N/A (aéreo)", 7, -25.2400, -57.5191, 0.16),
    ("PC-PJC-FS", "Pedro Juan Caballero - Ponta Porã (frontera seca)", "TERRESTRE", "Pedro Juan Caballero", "Amambay", "Brasil", 4, -22.5531, -55.7336, 0.10),
    ("PC-FAL-SI", "Puente San Ignacio de Loyola (Falcón - Clorinda)", "TERRESTRE", "José Falcón", "Presidente Hayes", "Argentina", 3, -25.2442, -57.6939, 0.07),
    ("PC-SDG-TE", "Salto del Guairá - Mundo Novo", "TERRESTRE", "Salto del Guairá", "Canindeyú", "Brasil", 3, -24.0603, -54.3083, 0.05),
    ("PC-MGZ-AE", "Aeropuerto Internacional Guaraní", "AÉREO", "Minga Guazú", "Alto Paraná", "N/A (aéreo)", 2, -25.4545, -54.8427, 0.04),
    ("PC-ASU-FL", "Puerto Itá Enramada", "FLUVIAL", "Asunción", "Capital", "Argentina", 2, -25.3361, -57.6531, 0.04),
]
COD_PUESTOS = [p[0] for p in PUESTOS]
TIPO_PUESTO = {p[0]: p[2] for p in PUESTOS}
PAIS_PUESTO = {p[0]: p[5] for p in PUESTOS}
TERRESTRES_BRA = ["PC-CDE-PA", "PC-PJC-FS", "PC-SDG-TE"]
TERRESTRES_ARG = ["PC-ENC-SR", "PC-FAL-SI", "PC-ASU-FL"]
AEREOS = ["PC-ASU-AE", "PC-MGZ-AE"]

# ---------------------------------------------------------------------------
# 2. Catálogos de apoyo (deben coincidir con las dimensiones estáticas del DW)
# ---------------------------------------------------------------------------
NACIONALIDADES = {  # ISO3: peso en viajeros ocasionales
    "PRY": 30, "BRA": 20, "ARG": 20, "BOL": 4, "URY": 3, "CHL": 3, "PER": 2, "COL": 2,
    "VEN": 1, "USA": 3, "MEX": 1, "ESP": 3, "DEU": 2, "ITA": 1.5, "FRA": 1, "CHN": 1,
    "TWN": 1.5, "KOR": 1, "JPN": 0.5, "LBN": 0.5, "ZAF": 0.2, "AUS": 0.3,
}
MERCOSUR = {"PRY", "ARG", "BRA", "BOL", "URY", "CHL", "PER", "COL"}
NOMBRE_PAIS = {"BRA": "Brasil", "ARG": "Argentina", "BOL": "Bolivia", "URY": "Uruguay", "CHL": "Chile",
               "ESP": "España", "PRY": "Paraguay", "USA": "Estados Unidos"}
MOTIVOS = {"TUR": "Turismo", "NEG": "Negocios", "TRA": "Tránsito", "TRB": "Trabajo", "EST": "Estudio", "RES": "Residencia"}
TRANSPORTES = {"AER": "Aéreo", "TPA": "Terrestre particular", "OMN": "Ómnibus", "FLU": "Fluvial", "PIE": "A pie"}
DOCS = {"PAS": "Pasaporte", "CIM": "Cédula de identidad MERCOSUR", "CIP": "Cédula de identidad paraguaya",
        "DVE": "Documento de viaje de emergencia"}
RANGOS = ["18-29", "30-44", "45-59", "60+", "Menor"]
P_RANGOS = [0.27, 0.34, 0.22, 0.10, 0.07]

# Estacionalidad mensual (vacaciones de verano, julio y fiestas) y crecimiento interanual
FACTOR_MES = {1: 1.30, 2: 1.15, 3: 0.90, 4: 0.95, 5: 0.90, 6: 0.88, 7: 1.20,
              8: 0.95, 9: 0.90, 10: 0.95, 11: 0.97, 12: 1.25}
fechas = [INICIO.date() + timedelta(days=i) for i in range(DIAS)]
peso_dia = np.array([FACTOR_MES[f.month] * (1.08 if f >= datetime(2025, 10, 1).date() else 1.0)
                     * (1.12 if f.weekday() >= 5 else 1.0) for f in fechas])
peso_dia = peso_dia / peso_dia.sum()


def elegir(dic):
    claves = list(dic)
    p = np.array([dic[k] for k in claves], dtype=float)
    return claves[rng.choice(len(claves), p=p / p.sum())]


def hora_cruce(puesto):
    """Hora del día según el tipo de puesto (los aeropuertos tienen picos de madrugada y noche)."""
    if TIPO_PUESTO[puesto] == "AÉREO":
        pesos = [3, 3, 4, 6, 8, 7, 5, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 5, 6, 7, 7, 6, 5, 4]
    else:
        pesos = [1, 0.6, 0.4, 0.4, 0.8, 2, 4, 7, 8, 8, 8, 8, 7, 7, 7, 8, 8, 8, 7, 6, 4, 3, 2, 1.5]
    p = np.array(pesos, dtype=float)
    h = rng.choice(24, p=p / p.sum())
    return int(h), int(rng.integers(0, 60)), int(rng.integers(0, 60))


def puesto_para(nac, perfil):
    if nac == "BRA":
        return rng.choice(TERRESTRES_BRA, p=[0.65, 0.22, 0.13]) if rng.random() < 0.85 else rng.choice(AEREOS)
    if nac == "ARG":
        return rng.choice(TERRESTRES_ARG, p=[0.60, 0.27, 0.13]) if rng.random() < 0.85 else rng.choice(AEREOS)
    if nac == "BOL":
        return rng.choice(["PC-ASU-AE", "PC-FAL-SI"], p=[0.6, 0.4])
    if nac == "PRY":
        if perfil == "fronterizo":
            return rng.choice(TERRESTRES_BRA + TERRESTRES_ARG, p=[0.40, 0.12, 0.08, 0.22, 0.12, 0.06])
        return rng.choice(COD_PUESTOS, p=[p[9] for p in PUESTOS])
    return rng.choice(AEREOS, p=[0.82, 0.18]) if rng.random() < 0.92 else rng.choice(["PC-CDE-PA", "PC-ENC-SR"])


def transporte_para(puesto):
    t = TIPO_PUESTO[puesto]
    if t == "AÉREO":
        return "AER"
    if t == "FLUVIAL":
        return "FLU"
    return rng.choice(["TPA", "OMN", "PIE"], p=[0.45, 0.37, 0.18])


def tipo_doc_para(nac):
    if rng.random() < 0.003:
        return "DVE"
    if nac == "PRY":
        return rng.choice(["CIP", "PAS"], p=[0.62, 0.38])
    if nac in MERCOSUR:
        return rng.choice(["CIM", "PAS"], p=[0.55, 0.45])
    return "PAS"


def estado_doc():
    return rng.choice(["VIGENTE", "VENCIDO", "EXTRAVIADO", "ROBADO", "ADULTERADO"],
                      p=[0.9840, 0.0090, 0.0030, 0.0025, 0.0015])


# ---------------------------------------------------------------------------
# 3. Viajeros y viajes
# ---------------------------------------------------------------------------
viajeros = []   # dict por viajero
movs = []       # lista de movimientos (limpios)
cont_vj = 0


def nuevo_viajero(perfil, nac):
    global cont_vj
    cont_vj += 1
    v = {"codigo": f"VJ-{cont_vj:06d}", "perfil": perfil, "nac": nac,
         "rango": rng.choice(RANGOS, p=P_RANGOS), "doc": tipo_doc_para(nac),
         "categorias": [("NACIONAL" if nac == "PRY" else "TURISTA", INICIO)]}
    viajeros.append(v)
    return v


def categoria_en(v, ts):
    cat = v["categorias"][0][0]
    for c, desde in v["categorias"]:
        if ts >= desde:
            cat = c
    return cat


PLAZO = {"TURISTA": 90, "RESIDENTE TEMPORAL": 730, "RESIDENTE PERMANENTE": None, "NACIONAL": None}


def registrar_viaje(v, puesto, inicio, dias_estadia, motivo, transporte, forzar_ts_vuelta=None):
    """Un viaje = dos movimientos. Extranjero: ENTRADA y luego SALIDA. Paraguayo: SALIDA y luego ENTRADA."""
    nac = v["nac"]
    primero, segundo = ("SALIDA", "ENTRADA") if nac == "PRY" else ("ENTRADA", "SALIDA")
    h, m, s = hora_cruce(puesto)
    ts1 = datetime.combine(inicio, datetime.min.time()) + timedelta(hours=h, minutes=m, seconds=s)
    if forzar_ts_vuelta is not None:
        ts2 = forzar_ts_vuelta
    else:
        h2, m2, s2 = hora_cruce(puesto)
        ts2 = datetime.combine(inicio + timedelta(days=int(dias_estadia)), datetime.min.time()) + \
            timedelta(hours=h2, minutes=m2, seconds=s2)
        if ts2 <= ts1:
            ts2 = ts1 + timedelta(hours=int(rng.integers(2, 10)))
    puesto_vuelta = puesto if rng.random() < 0.85 or TIPO_PUESTO[puesto] != "AÉREO" else rng.choice(AEREOS)
    for sentido, ts, pc in ((primero, ts1, puesto), (segundo, ts2, puesto_vuelta)):
        if ts > FIN:
            continue  # el viajero sigue en el país / afuera al cierre del periodo
        cat = categoria_en(v, ts)
        movs.append({
            "ts": ts, "puesto": pc, "sentido": sentido, "viajero": v["codigo"], "nac": nac,
            "rango": v["rango"], "categoria": cat, "doc": v["doc"], "estado": estado_doc(),
            "motivo": motivo, "transporte": transporte if pc == puesto else transporte_para(pc),
            "plazo": PLAZO[cat] if sentido == "ENTRADA" and nac != "PRY" else None,
            "perfil": v["perfil"],
        })


def dia_aleatorio():
    return fechas[rng.choice(DIAS, p=peso_dia)]


# 3.a Fronterizos: cruzan muchas veces por compras, trabajo o negocios; algunos con ráfagas
for _ in range(700):
    nac = rng.choice(["PRY", "BRA", "ARG"], p=[0.48, 0.32, 0.20])
    v = nuevo_viajero("fronterizo", nac)
    puesto = puesto_para(nac, "fronterizo")
    motivo = rng.choice(["NEG", "TRB", "TUR"], p=[0.45, 0.30, 0.25])
    n = max(3, int(rng.poisson(13)))
    dias_viaje = [dia_aleatorio() for _ in range(n)]
    if rng.random() < 0.30:  # ráfaga: 6 a 10 cruces de ida y vuelta en menos de 30 días (P5)
        centro = dia_aleatorio()
        dias_viaje += [centro + timedelta(days=int(d)) for d in rng.integers(0, 28, int(rng.integers(3, 6)))]
    for d in sorted(dias_viaje):
        if d > FIN.date():
            continue
        registrar_viaje(v, puesto, d, rng.choice([0, 0, 0, 1, 2]), motivo, transporte_para(puesto))

# 3.b Viajeros ocasionales (turismo, negocios, tránsito)
for _ in range(10500):
    nac = elegir(NACIONALIDADES)
    v = nuevo_viajero("ocasional", nac)
    for _ in range(1 + int(rng.poisson(0.25))):
        puesto = puesto_para(nac, "ocasional")
        motivo = rng.choice(["TUR", "NEG", "TRA", "EST"], p=[0.66, 0.22, 0.10, 0.02])
        estadia = {"TUR": rng.integers(2, 21), "NEG": rng.integers(1, 8), "TRA": rng.integers(0, 3),
                   "EST": rng.integers(15, 60)}[motivo]
        if nac != "PRY" and motivo in ("TUR", "TRA") and rng.random() < 0.045:  # permanencia excedida
            estadia = (90 if motivo == "TUR" else 10) + int(rng.integers(1, 120))
            if motivo == "TRA":
                motivo = "TUR"
        registrar_viaje(v, puesto, dia_aleatorio(), estadia, motivo, transporte_para(puesto))

# 3.c Migrantes: llegan como turistas y cambian de categoría (alimenta la SCD tipo 2)
for _ in range(450):
    nac = rng.choice(["BRA", "ARG", "BOL", "VEN", "COL", "CHN", "TWN", "KOR", "PER", "ESP"],
                     p=[0.25, 0.20, 0.12, 0.10, 0.08, 0.06, 0.06, 0.05, 0.04, 0.04])
    v = nuevo_viajero("migrante", nac)
    cambio = datetime(2024, 11, 1) + timedelta(days=int(rng.integers(0, 520)))
    v["categorias"].append(("RESIDENTE TEMPORAL", cambio))
    if rng.random() < 0.25:
        v["categorias"].append(("RESIDENTE PERMANENTE", cambio + timedelta(days=int(rng.integers(200, 500)))))
    puesto = puesto_para(nac, "migrante")
    for d in sorted(dia_aleatorio() for _ in range(int(rng.integers(3, 9)))):
        motivo = rng.choice(["TRB", "EST", "RES", "TUR"], p=[0.45, 0.15, 0.25, 0.15])
        registrar_viaje(v, puesto, d, rng.integers(5, 40), motivo, transporte_para(puesto))

mov = pd.DataFrame(movs).sort_values("ts").reset_index(drop=True)
mov.insert(0, "id_movimiento", [f"MOV-{i + 1:07d}" for i in range(len(mov))])

# Minutos de control (los documentos observados demoran más)
base = np.where(mov["puesto"].map(TIPO_PUESTO) == "AÉREO", rng.gamma(4, 1.0, len(mov)), rng.gamma(2.5, 1.0, len(mov)))
base = base + np.where(mov["estado"] != "VIGENTE", rng.uniform(5, 20, len(mov)), 0)
mov["minutos"] = np.round(np.clip(base, 0.5, None), 1)

# ---------------------------------------------------------------------------
# 4. Alertas (independientes de la nacionalidad)
# ---------------------------------------------------------------------------
# Cruces del mismo viajero en los 30 días previos (conducta, no origen)
mov["n_30d"] = 0
for vj, g in mov.groupby("viajero"):
    t = g["ts"].values
    izq = np.searchsorted(t, t - np.timedelta64(30, "D"))
    mov.loc[g.index, "n_30d"] = np.arange(len(t)) - izq + 1

# Permanencia excedida en un viaje anterior del mismo viajero (marca para la próxima entrada)
excedio_antes = set()
mov["excedio_antes"] = False
ultima_entrada = {}
for i, r in mov.iterrows():
    if r["nac"] == "PRY":
        continue
    if r["sentido"] == "ENTRADA":
        if r["viajero"] in excedio_antes:
            mov.at[i, "excedio_antes"] = True
        ultima_entrada[r["viajero"]] = (r["ts"], r["plazo"])
    elif r["viajero"] in ultima_entrada:
        t0, plazo = ultima_entrada.pop(r["viajero"])
        if plazo and (r["ts"] - t0).days > plazo:
            excedio_antes.add(r["viajero"])

TIPOS_ALERTA = {  # codigo: (nivel, p_inspeccion, p_confirmada, p_rechazo_si_confirmada_en_entrada)
    "INT-SLTD": ("ALTO", 0.92, 0.66, 0.70), "INT-ROJ": ("CRÍTICO", 1.00, 0.42, 0.90),
    "ONU-SAN": ("CRÍTICO", 1.00, 0.18, 0.80), "NAC-CAP": ("ALTO", 0.95, 0.55, 0.20),
    "NAC-VIG": ("ALTO", 0.85, 0.12, 0.30), "DGM-DOC": ("MEDIO", 0.70, 0.48, 0.60),
    "OAAF-PAT": ("MEDIO", 0.60, 0.17, 0.25), "DGM-PER": ("BAJO", 0.40, 0.33, 0.50),
}
alertas = []
u = rng.random(len(mov))
for i, r in mov.iterrows():
    tipos = []
    if r["estado"] in ("ROBADO", "EXTRAVIADO") and u[i] < 0.92:
        tipos.append("INT-SLTD")
    elif r["estado"] == "ADULTERADO" and u[i] < 0.85:
        tipos.append("DGM-DOC")
    elif r["estado"] == "VENCIDO" and u[i] < 0.35:
        tipos.append("DGM-DOC")
    if r["n_30d"] >= 8 and rng.random() < 0.10:
        tipos.append("OAAF-PAT")
    if r["excedio_antes"] and rng.random() < 0.55:
        tipos.append("DGM-PER")
    p_lista = 0.027 * (1.9 if r["ts"].hour < 6 and TIPO_PUESTO[r["puesto"]] != "AÉREO" else 1.0)
    if rng.random() < p_lista:
        tipos.append(rng.choice(["NAC-VIG", "NAC-CAP", "INT-ROJ", "ONU-SAN"], p=[0.56, 0.26, 0.12, 0.06]))
    for tp in tipos:
        nivel, p_ins, p_conf, p_rech = TIPOS_ALERTA[tp]
        insp = rng.random() < p_ins
        conf = insp and rng.random() < p_conf
        rech = conf and r["sentido"] == "ENTRADA" and rng.random() < p_rech
        resultado = ("RECHAZO DE INGRESO" if rech else "CONFIRMADA" if conf else
                     "DESCARTADA" if insp else "SIN INSPECCIÓN")
        alertas.append({
            "id_movimiento": r["id_movimiento"], "ts": r["ts"] + timedelta(seconds=int(rng.integers(10, 240))),
            "puesto": r["puesto"], "viajero": r["viajero"], "tipo": tp, "nivel": nivel,
            "doc": r["doc"], "estado": r["estado"], "insp": bool(insp), "resultado": resultado,
            "minutos": round(float(rng.uniform(12, 95)), 1) if insp else None,
        })
ale = pd.DataFrame(alertas).sort_values("ts").reset_index(drop=True)
ale.insert(0, "id_alerta", [f"ALR-{i + 1:06d}" for i in range(len(ale))])

# ---------------------------------------------------------------------------
# 5. Formato "sistema fuente" + defectos deliberados
# ---------------------------------------------------------------------------
defectos = Counter()
csv = pd.DataFrame({
    "id_movimiento": mov["id_movimiento"],
    "fecha_hora": mov["ts"].dt.strftime("%Y-%m-%d %H:%M:%S"),
    "puesto": mov["puesto"],
    "sentido": mov["sentido"],
    "codigo_viajero": mov["viajero"],
    "nacionalidad": mov["nac"],
    "rango_etario": mov["rango"],
    "categoria_migratoria": mov["categoria"],
    "tipo_documento": mov["doc"].map(DOCS),
    "estado_documento": mov["estado"],
    "motivo_viaje": mov["motivo"].map(MOTIVOS),
    "medio_transporte": mov["transporte"].map(TRANSPORTES),
    "plazo_autorizado_dias": mov["plazo"].map(lambda x: "" if pd.isna(x) else str(int(x))),
    "minutos_control": mov["minutos"].map(lambda x: f"{x:.1f}"),
})
n = len(csv)


def filas(prop=None, cant=None, mascara=None):
    idx = csv.index if mascara is None else csv.index[mascara]
    k = cant if cant is not None else int(round(len(idx) * prop))
    return rng.choice(idx, size=min(k, len(idx)), replace=False)


# Fechas en formatos mixtos
ix = filas(0.07)
csv.loc[ix, "fecha_hora"] = mov.loc[ix, "ts"].dt.strftime("%d/%m/%Y %H:%M")
defectos["CSV fecha_hora en formato dd/mm/aaaa hh:mm"] = len(ix)
ix = filas(0.03, mascara=csv["fecha_hora"].str.match(r"^\d{4}-"))
csv.loc[ix, "fecha_hora"] = mov.loc[ix, "ts"].dt.strftime("%Y-%m-%dT%H:%M:%S")
defectos["CSV fecha_hora en formato ISO con 'T'"] = len(ix)
ix = filas(cant=30)
csv.loc[ix, "fecha_hora"] = rng.choice(["", "31/02/2025 10:00", "sin dato", "2025-13-01 08:00:00"], len(ix))
defectos["CSV fecha_hora vacía o inválida (no convertible)"] = len(ix)

# Puesto: inconsistencias de texto y códigos huérfanos
for cod, variantes, prop in (("PC-CDE-PA", ["CDE", "Ciudad del Este", " ciudad del este ", "Pte. Amistad"], 0.06),
                             ("PC-ENC-SR", ["Encarnación", "ENCARNACION", "encarnacion "], 0.05),
                             ("PC-ASU-AE", ["Aeropuerto Silvio Pettirossi", "Aeropuerto Luque", "ASU"], 0.04),
                             ("PC-PJC-FS", ["PJC", "Pedro Juan Caballero"], 0.04)):
    ix = filas(prop, mascara=csv["puesto"] == cod)
    csv.loc[ix, "puesto"] = rng.choice(variantes, len(ix))
    defectos[f"CSV puesto escrito como texto libre en vez de '{cod}'"] = len(ix)
ix = filas(cant=180)
csv.loc[ix, "puesto"] = rng.choice(["PC-HUM-01", "PC-ALB-02", "PC-XXX-99"], len(ix))
defectos["CSV puesto con código huérfano (no existe en el catálogo)"] = len(ix)

# Sentido con variantes
ix = filas(0.05)
csv.loc[ix, "sentido"] = csv.loc[ix, "sentido"].map(
    lambda s: rng.choice(["E", "entrada", "Entrada", "ING"]) if s == "ENTRADA" else rng.choice(["S", "salida", "Salida", "EGR"]))
defectos["CSV sentido con variantes (E, S, entrada, Salida, ING, EGR...)"] = len(ix)

# Nacionalidad: nulos, nombres en vez de código, inválidos
ix = filas(0.005)
csv.loc[ix, "nacionalidad"] = ""
defectos["CSV nacionalidad vacía"] = len(ix)
ix = filas(0.02, mascara=csv["nacionalidad"].isin(list(NOMBRE_PAIS)))
csv.loc[ix, "nacionalidad"] = csv.loc[ix, "nacionalidad"].map(lambda c: rng.choice([NOMBRE_PAIS[c], NOMBRE_PAIS[c].lower(), c.lower()]))
defectos["CSV nacionalidad como nombre o en minúsculas (Brasil, argentina, bra)"] = len(ix)
ix = filas(cant=40)
csv.loc[ix, "nacionalidad"] = "XXX"
defectos["CSV nacionalidad con código inexistente (XXX)"] = len(ix)

# Motivo y transporte: nulos y variantes de escritura
ix = filas(0.007)
csv.loc[ix, "motivo_viaje"] = ""
defectos["CSV motivo_viaje vacío"] = len(ix)
ix = filas(0.03)
csv.loc[ix, "motivo_viaje"] = csv.loc[ix, "motivo_viaje"].map(lambda s: rng.choice([s.upper(), s.lower(), f" {s} "]) if s else s)
defectos["CSV motivo_viaje en mayúsculas/minúsculas o con espacios"] = len(ix)
ix = filas(0.02, mascara=csv["medio_transporte"].isin(["Ómnibus", "Aéreo"]))
csv.loc[ix, "medio_transporte"] = csv.loc[ix, "medio_transporte"].map({"Ómnibus": "Omnibus", "Aéreo": "Aereo"})
defectos["CSV medio_transporte sin tilde (Omnibus, Aereo)"] = len(ix)

# Minutos de control: nulos, negativos y outliers
ix = filas(0.01)
csv.loc[ix, "minutos_control"] = ""
defectos["CSV minutos_control vacío"] = len(ix)
ix = filas(cant=90)
csv.loc[ix, "minutos_control"] = rng.choice(["-1.0", "-3.5", "0.0"], len(ix))
defectos["CSV minutos_control negativo o cero"] = len(ix)
ix = filas(cant=45)
csv.loc[ix, "minutos_control"] = rng.choice(["999.0", "1440.0", "600.0"], len(ix))
defectos["CSV minutos_control outlier (>= 600 min)"] = len(ix)

# Código de viajero vacío y plazo faltante en entradas de extranjeros
ix = filas(cant=70)
csv.loc[ix, "codigo_viajero"] = ""
defectos["CSV codigo_viajero vacío"] = len(ix)
ix = filas(0.006, mascara=csv["plazo_autorizado_dias"] != "")
csv.loc[ix, "plazo_autorizado_dias"] = ""
defectos["CSV plazo_autorizado_dias faltante en una ENTRADA de extranjero"] = len(ix)

# Duplicados exactos (reenvío del lote)
dup = csv.loc[filas(cant=650)]
csv = pd.concat([csv, dup]).sort_values("id_movimiento", kind="stable").reset_index(drop=True)
defectos["CSV filas duplicadas exactas (mismo id_movimiento)"] = len(dup)

# ---------------------------------------------------------------------------
# 6. JSON de alertas (anidado) + defectos
# ---------------------------------------------------------------------------
ids_mov = set(mov["id_movimiento"])
registros = []
for _, a in ale.iterrows():
    registros.append({
        "id_alerta": a["id_alerta"],
        "id_movimiento": a["id_movimiento"],
        "emitida": a["ts"].strftime("%Y-%m-%dT%H:%M:%S"),
        "puesto": a["puesto"],
        "viajero": a["viajero"],
        "tipo": {"codigo": a["tipo"], "nivel": a["nivel"]},
        "documento": {"tipo": DOCS[a["doc"]], "estado": a["estado"]},
        "inspeccion": {"secundaria": a["insp"], "resultado": a["resultado"], "minutos": a["minutos"]},
    })
m = len(registros)
for i in rng.choice(m, int(m * 0.05), replace=False):
    registros[i]["emitida"] = datetime.fromisoformat(registros[i]["emitida"]).strftime("%d/%m/%Y %H:%M")
defectos["JSON emitida en formato dd/mm/aaaa hh:mm"] = int(m * 0.05)
for i in rng.choice(m, int(m * 0.04), replace=False):
    registros[i]["tipo"]["codigo"] = registros[i]["tipo"]["codigo"].lower()
defectos["JSON tipo.codigo en minúsculas"] = int(m * 0.04)
for i in rng.choice(m, int(m * 0.03), replace=False):
    registros[i]["tipo"]["nivel"] = registros[i]["tipo"]["nivel"].capitalize().replace("Crítico", "Critico")
defectos["JSON tipo.nivel con mayúsculas/acentos distintos"] = int(m * 0.03)
huerf = rng.choice(m, int(m * 0.01), replace=False)
for i in huerf:
    registros[i]["id_movimiento"] = f"MOV-9{int(rng.integers(0, 999999)):06d}"
defectos["JSON id_movimiento huérfano (no existe en el CSV)"] = len(huerf)
for i in rng.choice(np.flatnonzero([r["inspeccion"]["secundaria"] for r in registros]), 25, replace=False):
    registros[i]["inspeccion"]["resultado"] = None
defectos["JSON inspeccion.resultado nulo con inspección secundaria realizada"] = 25
cde = [i for i in rng.choice(m, int(m * 0.08), replace=False) if registros[i]["puesto"] == "PC-CDE-PA"]
for i in cde:
    registros[i]["puesto"] = "CDE"
defectos["JSON puesto escrito 'CDE' en vez de 'PC-CDE-PA'"] = len(cde)
dups = [dict(registros[i]) for i in rng.choice(m, int(m * 0.012), replace=False)]
registros += dups
registros.sort(key=lambda r: r["id_alerta"])
defectos["JSON alertas duplicadas (mismo id_alerta)"] = len(dups)
with open(SALIDA / "alertas_inspeccion.json", "w", encoding="utf-8") as f:
    json.dump({"servicio": "Servicio de Alertas OAAF (sintético)", "generado": "2026-10-01T06:00:00",
               "cantidad": len(registros), "alertas": registros}, f, ensure_ascii=False, indent=1)

# ---------------------------------------------------------------------------
# 7. Catálogo de puestos (Excel) + defectos
# ---------------------------------------------------------------------------
cat = pd.DataFrame([{
    "codigo_puesto": p[0], "nombre_puesto": p[1], "tipo_puesto": p[2], "ciudad": p[3],
    "departamento": p[4], "pais_limitrofe": p[5], "dotacion_personal": p[6],
    "latitud": p[7], "longitud": p[8], "fecha_actualizacion": "2024-09-15"} for p in PUESTOS])
cat = cat.astype({"latitud": object, "longitud": object, "dotacion_personal": object})
cat.loc[cat.codigo_puesto == "PC-CDE-PA", "ciudad"] = "CDE"
cat.loc[cat.codigo_puesto == "PC-ENC-SR", "ciudad"] = " Encarnación "
cat.loc[cat.codigo_puesto == "PC-MGZ-AE", "departamento"] = "Alto Parana"
cat.loc[cat.codigo_puesto == "PC-FAL-SI", "tipo_puesto"] = "terrestre"
cat.loc[cat.codigo_puesto == "PC-SDG-TE", "latitud"] = "-24,0603"
cat.loc[cat.codigo_puesto == "PC-SDG-TE", "longitud"] = "-54,3083"
cat.loc[cat.codigo_puesto == "PC-ASU-FL", "dotacion_personal"] = None
corr = cat[cat.codigo_puesto == "PC-PJC-FS"].copy()        # la fila vieja tenía un error de carga
cat.loc[cat.codigo_puesto == "PC-PJC-FS", "departamento"] = "Amambai"
corr["fecha_actualizacion"] = "2025-03-10"                  # la corrección llega después (SCD tipo 1)
cat = pd.concat([cat, corr], ignore_index=True)
defectos["XLSX ciudad abreviada ('CDE')"] = 1
defectos["XLSX ciudad con espacios (' Encarnación ')"] = 1
defectos["XLSX departamento sin tilde ('Alto Parana')"] = 1
defectos["XLSX tipo_puesto en minúsculas ('terrestre')"] = 1
defectos["XLSX coordenadas como texto con coma decimal"] = 1
defectos["XLSX dotacion_personal vacía"] = 1
defectos["XLSX puesto repetido: fila vieja con error ('Amambai') y fila corregida posterior"] = 1
with pd.ExcelWriter(SALIDA / "catalogo_puestos.xlsx", engine="openpyxl") as w:
    cat.to_excel(w, sheet_name="puestos", index=False)
cat.to_csv(SALIDA / "catalogo_puestos.csv", index=False, encoding="utf-8")

csv.to_csv(SALIDA / "movimientos_migratorios.csv", index=False, encoding="utf-8")

# ---------------------------------------------------------------------------
# 8. Documentación de defectos y cifras de control
# ---------------------------------------------------------------------------
def miles(x):
    return f"{x:,}".replace(",", ".")


ctrl = {
    "Filas del CSV de movimientos (con duplicados)": len(csv),
    "Movimientos únicos (id_movimiento distintos)": csv["id_movimiento"].nunique(),
    "Viajeros distintos": mov["viajero"].nunique(),
    "Alertas en el JSON (con duplicados)": len(registros),
    "Alertas únicas": len(ale),
    "Filas del catálogo de puestos (Excel)": len(cat),
    "Puestos distintos": cat["codigo_puesto"].nunique(),
}
with open(SALIDA / "defectos_inyectados.md", "w", encoding="utf-8") as f:
    f.write("# Defectos inyectados en el dataset sintético OAAF\n\n")
    f.write(f"Generado con `generar_datos_oaaf.py`, semilla {SEMILLA}. Periodo 01/10/2024 – 30/09/2026.\n\n")
    f.write("## Cifras de control\n\n| Concepto | Cantidad |\n|---|---:|\n")
    for k, v in ctrl.items():
        f.write(f"| {k} | {miles(v)} |\n")
    f.write("\n## Defectos deliberados\n\n| Defecto | Filas afectadas |\n|---|---:|\n")
    for k, v in defectos.items():
        f.write(f"| {k} | {miles(v)} |\n")
    f.write("\nUna misma fila puede tener más de un defecto. Las cantidades son de inyección; "
            "el perfilado del ETL mide lo que efectivamente queda en los archivos.\n")

print("Archivos generados en", SALIDA)
for k, v in ctrl.items():
    print(f"  {k}: {miles(v)}")
print("  Alertas por tipo:", {str(k): int(v) for k, v in Counter(ale["tipo"]).items()})
