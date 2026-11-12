-- =====================================================================
-- DATAWAREHOUSE OAAF — Script 80: EXPORTACIÓN PARA POWER BI
-- Exporta el esquema estrella (2 hechos + 8 dimensiones) a CSV, igual que
-- el dataset del tutorial de Power BI de la cátedra: UTF-8, separador
-- coma, punto decimal, fechas ISO. Sin columnas de linaje (dw_*).
-- También exporta las vistas OLAP de P5 y P7, que usan ventanas de 30
-- días y comparaciones interanuales más simples de resolver en SQL.
-- Requiere: ETL completo (10 a 60) y script 70 (vistas OLAP).
-- ANTES DE EJECUTAR: crear la carpeta C:\DW_OAAF\powerbi\datos
-- =====================================================================

SET VARIABLE ruta_pbi = 'C:/DW_OAAF/powerbi/datos';

-- Hechos
COPY (SELECT * EXCLUDE (dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
      FROM dw.fact_movimiento_migratorio ORDER BY fecha_hora_movimiento)
TO (getvariable('ruta_pbi') || '/fact_movimiento_migratorio.csv') (HEADER, DELIMITER ',');

COPY (SELECT * EXCLUDE (dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
      FROM dw.fact_alerta ORDER BY dd_id_alerta)
TO (getvariable('ruta_pbi') || '/fact_alerta.csv') (HEADER, DELIMITER ',');

-- Dimensiones (todas incluyen la fila -1 "NO DEFINIDO")
COPY (SELECT * FROM dw.dim_tiempo ORDER BY sk_tiempo)
TO (getvariable('ruta_pbi') || '/dim_tiempo.csv') (HEADER, DELIMITER ',');

COPY (SELECT * EXCLUDE (dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
      FROM dw.dim_puesto_control ORDER BY sk_puesto)
TO (getvariable('ruta_pbi') || '/dim_puesto_control.csv') (HEADER, DELIMITER ',');

COPY (SELECT * EXCLUDE (dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
      FROM dw.dim_viajero ORDER BY sk_viajero)
TO (getvariable('ruta_pbi') || '/dim_viajero.csv') (HEADER, DELIMITER ',');

COPY (SELECT * FROM dw.dim_pais ORDER BY sk_pais)
TO (getvariable('ruta_pbi') || '/dim_pais.csv') (HEADER, DELIMITER ',');

COPY (SELECT * FROM dw.dim_documento ORDER BY sk_documento)
TO (getvariable('ruta_pbi') || '/dim_documento.csv') (HEADER, DELIMITER ',');

COPY (SELECT * FROM dw.dim_motivo ORDER BY sk_motivo)
TO (getvariable('ruta_pbi') || '/dim_motivo.csv') (HEADER, DELIMITER ',');

COPY (SELECT * FROM dw.dim_tipo_alerta ORDER BY sk_tipo_alerta)
TO (getvariable('ruta_pbi') || '/dim_tipo_alerta.csv') (HEADER, DELIMITER ',');

COPY (SELECT * FROM dw.dim_transporte ORDER BY sk_transporte)
TO (getvariable('ruta_pbi') || '/dim_transporte.csv') (HEADER, DELIMITER ',');

-- Vistas OLAP de apoyo (sin filas de subtotal: Power BI calcula sus totales)
COPY (SELECT * FROM olap.p5_cruce_frecuente
      WHERE puesto <> '(Total)' AND anio_mes <> '(Total)' ORDER BY anio_mes, puesto)
TO (getvariable('ruta_pbi') || '/olap_p5_cruce_frecuente.csv') (HEADER, DELIMITER ',');

COPY (SELECT * FROM olap.p7_variacion_interanual ORDER BY dimension, valor, anio_mes)
TO (getvariable('ruta_pbi') || '/olap_p7_variacion_interanual.csv') (HEADER, DELIMITER ',');

-- Control: filas exportadas por archivo (deben coincidir con las tablas)
SELECT 'fact_movimiento_migratorio' AS archivo, count(*) AS filas FROM dw.fact_movimiento_migratorio UNION ALL  -- 50.956
SELECT 'fact_alerta',        count(*) FROM dw.fact_alerta        UNION ALL  -- 1.999
SELECT 'dim_tiempo',         count(*) FROM dw.dim_tiempo         UNION ALL  -- 26.305
SELECT 'dim_puesto_control', count(*) FROM dw.dim_puesto_control UNION ALL  -- 9
SELECT 'dim_viajero',        count(*) FROM dw.dim_viajero        UNION ALL  -- 12.065
SELECT 'dim_pais',           count(*) FROM dw.dim_pais           UNION ALL  -- 23
SELECT 'dim_documento',      count(*) FROM dw.dim_documento      UNION ALL  -- 21
SELECT 'dim_motivo',         count(*) FROM dw.dim_motivo         UNION ALL  -- 7
SELECT 'dim_tipo_alerta',    count(*) FROM dw.dim_tipo_alerta    UNION ALL  -- 9
SELECT 'dim_transporte',     count(*) FROM dw.dim_transporte;               -- 6
