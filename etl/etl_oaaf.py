"""
DATAWAREHOUSE OAAF — Hito H3 — Orquestador del ETL (Python 3.12 + pandas + DuckDB)
Cátedra Datawarehouse (22891) · Uninorte · Alumna: Érica Bordón

Ejecuta el ETL completo en orden:
  10 Extracción a staging  (CSV y JSON con DuckDB; Excel con pandas)
  20 Perfilado de calidad
  30 Transformación y cuarentena
  40 Carga de dimensiones (SCD1 puesto, SCD2 viajero)
  50 Carga de hechos
  60 Controles de conciliación y cierre de la ejecución

Requisitos:  pip install duckdb pandas openpyxl
Antes de correrlo: haber ejecutado los scripts 01 y 02 del H2 sobre la misma base,
y CERRAR la conexión en DBeaver (DuckDB no permite dos programas escribiendo a la vez).

Uso (desde la carpeta del proyecto):
    python etl/etl_oaaf.py
    python etl/etl_oaaf.py --db C:/DW_OAAF/dw_oaaf.duckdb --fuentes C:/DW_OAAF/fuentes
"""
import argparse
import re
import sys
import time
from pathlib import Path

import duckdb
import pandas as pd

CARPETA_ETL = Path(__file__).resolve().parent
CARPETA_PROYECTO = CARPETA_ETL.parent
PASOS = [
    ("20_perfilado.sql", "Perfilado de calidad"),
    ("30_transformacion.sql", "Transformación y cuarentena"),
    ("40_carga_dimensiones.sql", "Carga de dimensiones (SCD1 / SCD2)"),
    ("50_carga_hechos.sql", "Carga de hechos"),
    ("60_controles.sql", "Controles de conciliación"),
]


def leer_sql(nombre):
    return (CARPETA_ETL / nombre).read_text(encoding="utf-8")


def mostrar(df, max_filas=40):
    with pd.option_context("display.max_rows", max_filas, "display.max_columns", 10,
                           "display.width", 160, "display.max_colwidth", 70):
        print(df.to_string(index=False))


def main():
    ap = argparse.ArgumentParser(description="ETL del Datawarehouse OAAF")
    ap.add_argument("--db", default=str(CARPETA_PROYECTO / "dw_oaaf.duckdb"), help="archivo .duckdb")
    ap.add_argument("--fuentes", default=str(CARPETA_PROYECTO / "fuentes"), help="carpeta de archivos fuente")
    args = ap.parse_args()

    fuentes = Path(args.fuentes)
    faltan = [f for f in ("movimientos_migratorios.csv", "alertas_inspeccion.json", "catalogo_puestos.xlsx")
              if not (fuentes / f).exists()]
    if faltan:
        sys.exit(f"ERROR: no encuentro {faltan} en {fuentes}")

    try:
        con = duckdb.connect(args.db)
    except duckdb.IOException as e:
        sys.exit(f"ERROR: no pude abrir {args.db}.\n¿Está abierta en DBeaver? Desconectala y volvé a intentar.\n{e}")

    try:
        con.execute("SELECT 1 FROM dw.dim_tiempo LIMIT 1")
    except duckdb.Error:
        sys.exit("ERROR: la base no tiene el modelo. Ejecutá antes los scripts 01 y 02 del H2.")

    inicio_total = time.time()
    try:
        # ---- 10. EXTRACCIÓN -------------------------------------------------
        print("\n[10] Extracción a staging")
        id_ejec = con.execute("SELECT coalesce(max(dw_id_ejecucion), 0) + 1 FROM meta.ejecucion").fetchone()[0]

        # Excel con pandas (no necesita la extensión excel de DuckDB)
        df_puesto = pd.read_excel(fuentes / "catalogo_puestos.xlsx", sheet_name="puestos", dtype=str)
        df_puesto["dw_id_ejecucion"] = id_ejec
        df_puesto["dw_fecha_carga"] = pd.Timestamp.now()
        df_puesto["dw_archivo_origen"] = "catalogo_puestos.xlsx"
        con.execute("CREATE SCHEMA IF NOT EXISTS stg")
        con.register("df_puesto", df_puesto)
        con.execute("CREATE OR REPLACE TABLE stg.stg_puesto AS SELECT * FROM df_puesto")
        con.unregister("df_puesto")

        # CSV y JSON: el mismo script 10 que se usa en DBeaver, sin el bloque de Excel
        sql = leer_sql("10_staging.sql")
        sql = re.sub(r"SET VARIABLE ruta = '.*?';", f"SET VARIABLE ruta = '{fuentes.resolve().as_posix()}';", sql)
        sql = re.sub(r"-- \[EXCEL-INICIO\].*?-- \[EXCEL-FIN\]", "", sql, flags=re.S)
        mostrar(con.execute(sql).fetchdf())

        # ---- 20 a 60 -------------------------------------------------------
        for archivo, titulo in PASOS:
            t0 = time.time()
            print(f"\n[{archivo[:2]}] {titulo}")
            mostrar(con.execute(leer_sql(archivo)).fetchdf())
            print(f"     ({time.time() - t0:.1f} s)")

        estado = con.execute("SELECT estado FROM meta.ejecucion ORDER BY dw_id_ejecucion DESC LIMIT 1").fetchone()[0]
        print(f"\nETL terminado en {time.time() - inicio_total:.1f} s — estado de la ejecución: {estado}")
        return 0 if estado == "OK" else 1
    except Exception as e:  # deja constancia del error en el linaje
        try:
            con.execute("UPDATE meta.ejecucion SET fin = now(), estado = 'ERROR' "
                        "WHERE dw_id_ejecucion = (SELECT max(dw_id_ejecucion) FROM meta.ejecucion) "
                        "AND estado = 'EN CURSO'")
        finally:
            print(f"\nERROR durante el ETL: {e}")
        return 1
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
