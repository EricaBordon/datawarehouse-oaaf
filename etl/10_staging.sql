-- DATAWAREHOUSE OAAF — Hito H3 — ETL Script 10: EXTRACCIÓN (staging)
-- Lee las tres fuentes "tal cual vienen", todo como texto (all_varchar),
-- sin limpiar nada. Agrega columnas de linaje y registra la ejecución.
-- Requiere: scripts 01 y 02 del H2 ya ejecutados.
-- DBeaver: ejecutar completo con Alt + X (Editor SQL -> Ejecutar script).
-- =====================================================================

-- PASO 0 — Carpeta donde están los archivos fuente (CAMBIAR SI HACE FALTA)
-- Usar barras "/" aunque sea Windows.
SET VARIABLE ruta = 'C:/DW_OAAF/fuentes';
SELECT getvariable('ruta') AS ruta_configurada;

-- PASO 1 — Registrar la ejecución en meta.ejecucion (linaje)
CREATE SCHEMA IF NOT EXISTS stg;
INSERT INTO meta.ejecucion (dw_id_ejecucion, proceso, inicio, estado)
SELECT coalesce(max(dw_id_ejecucion), 0) + 1, 'etl_oaaf_completo', now(), 'EN CURSO'
FROM meta.ejecucion;

SET VARIABLE id_ejecucion = (SELECT max(dw_id_ejecucion) FROM meta.ejecucion);

-- PASO 2 — Fuente 1: CSV de movimientos (sistema de control fronterizo)
CREATE OR REPLACE TABLE stg.stg_movimiento AS
SELECT *,
       row_number() OVER ()                AS dw_nro_fila,
       getvariable('id_ejecucion')::BIGINT AS dw_id_ejecucion,
       now()::TIMESTAMP                    AS dw_fecha_carga,
       'movimientos_migratorios.csv'       AS dw_archivo_origen
FROM read_csv(getvariable('ruta') || '/movimientos_migratorios.csv',
              all_varchar = true, header = true);

-- PASO 3 — Fuente 2: JSON de alertas (anidado). unnest() abre la lista
-- "alertas" y la notación a.tipo.codigo entra en los objetos internos.
CREATE OR REPLACE TABLE stg.stg_alerta AS
SELECT a.id_alerta::VARCHAR               AS id_alerta,
       a.id_movimiento::VARCHAR           AS id_movimiento,
       a.emitida::VARCHAR                 AS emitida,
       a.puesto::VARCHAR                  AS puesto,
       a.viajero::VARCHAR                 AS viajero,
       a.tipo.codigo::VARCHAR             AS tipo_codigo,
       a.tipo.nivel::VARCHAR              AS tipo_nivel,
       a.documento.tipo::VARCHAR          AS documento_tipo,
       a.documento.estado::VARCHAR        AS documento_estado,
       a.inspeccion.secundaria::VARCHAR   AS inspeccion_secundaria,
       a.inspeccion.resultado::VARCHAR    AS inspeccion_resultado,
       a.inspeccion.minutos::VARCHAR      AS inspeccion_minutos,
       row_number() OVER ()                AS dw_nro_fila,
       getvariable('id_ejecucion')::BIGINT AS dw_id_ejecucion,
       now()::TIMESTAMP                    AS dw_fecha_carga,
       'alertas_inspeccion.json'           AS dw_archivo_origen
FROM (SELECT unnest(alertas) AS a
      FROM read_json(getvariable('ruta') || '/alertas_inspeccion.json'));

-- PASO 4 — Fuente 3: catálogo de puestos (Excel)
-- [EXCEL-INICIO]
INSTALL excel;
LOAD excel;
CREATE OR REPLACE TABLE stg.stg_puesto AS
SELECT *,
       getvariable('id_ejecucion')::BIGINT AS dw_id_ejecucion,
       now()::TIMESTAMP                    AS dw_fecha_carga,
       'catalogo_puestos.xlsx'             AS dw_archivo_origen
FROM read_xlsx(getvariable('ruta') || '/catalogo_puestos.xlsx', all_varchar = true);
-- [EXCEL-FIN]
-- CONTINGENCIA: si "INSTALL excel" falla (sin internet), borrar el bloque
-- de arriba y usar el mismo catálogo exportado a CSV:
-- CREATE OR REPLACE TABLE stg.stg_puesto AS
-- SELECT *, getvariable('id_ejecucion')::BIGINT AS dw_id_ejecucion,
--        now()::TIMESTAMP AS dw_fecha_carga, 'catalogo_puestos.csv' AS dw_archivo_origen
-- FROM read_csv(getvariable('ruta') || '/catalogo_puestos.csv', all_varchar = true);

-- PASO 5 — Controles de extracción
SELECT 'stg_movimiento' AS tabla, count(*) AS filas FROM stg.stg_movimiento UNION ALL  -- 51.636
SELECT 'stg_alerta',              count(*)          FROM stg.stg_alerta     UNION ALL  -- 2.022
SELECT 'stg_puesto',              count(*)          FROM stg.stg_puesto;               -- 9
