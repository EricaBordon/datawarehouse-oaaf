-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H3 — ETL Script 20: PERFILADO DE CALIDAD
-- Mide los problemas de cada fuente ANTES de limpiar. No modifica datos:
-- guarda los resultados en meta.perfil_calidad para el informe.
-- =====================================================================

CREATE TABLE IF NOT EXISTS meta.perfil_calidad (
    dw_id_ejecucion BIGINT,
    fuente          VARCHAR,
    control         VARCHAR,
    filas           BIGINT
);
DELETE FROM meta.perfil_calidad
WHERE dw_id_ejecucion = (SELECT max(dw_id_ejecucion) FROM meta.ejecucion);

-- ---------------------------------------------------------------------
-- 1. CSV de movimientos
-- ---------------------------------------------------------------------
INSERT INTO meta.perfil_calidad
WITH m AS (SELECT * FROM stg.stg_movimiento),
dup AS (SELECT count(*) - count(DISTINCT id_movimiento) AS n FROM m)
SELECT (SELECT max(dw_id_ejecucion) FROM meta.ejecucion), 'movimientos_migratorios.csv', control, filas
FROM (
    SELECT '01 Filas leídas' AS control, count(*) AS filas FROM m UNION ALL
    SELECT '02 id_movimiento distintos', count(DISTINCT id_movimiento) FROM m UNION ALL
    SELECT '03 Filas duplicadas (mismo id_movimiento)', (SELECT n FROM dup) UNION ALL
    SELECT '04 Fecha en formato ISO aaaa-mm-dd hh:mm:ss',
           count(*) FILTER (WHERE fecha_hora ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') FROM m UNION ALL
    SELECT '05 Fecha en formato ISO con T',
           count(*) FILTER (WHERE fecha_hora ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') FROM m UNION ALL
    SELECT '06 Fecha en formato dd/mm/aaaa hh:mm',
           count(*) FILTER (WHERE fecha_hora ~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$') FROM m UNION ALL
    SELECT '07 Fecha vacía o no convertible',
           count(*) FILTER (WHERE coalesce(try_strptime(fecha_hora, '%Y-%m-%d %H:%M:%S'),
                                           try_strptime(fecha_hora, '%Y-%m-%dT%H:%M:%S'),
                                           try_strptime(fecha_hora, '%d/%m/%Y %H:%M')) IS NULL) FROM m UNION ALL
    SELECT '08 Puesto que no es un código del catálogo',
           count(*) FILTER (WHERE puesto NOT IN (SELECT codigo_puesto FROM stg.stg_puesto)) FROM m UNION ALL
    SELECT '09 Sentido distinto de ENTRADA/SALIDA',
           count(*) FILTER (WHERE sentido NOT IN ('ENTRADA', 'SALIDA')) FROM m UNION ALL
    SELECT '10 Nacionalidad vacía', count(*) FILTER (WHERE nacionalidad IS NULL OR trim(nacionalidad) = '') FROM m UNION ALL
    SELECT '11 Nacionalidad que no es un código ISO del catálogo',
           count(*) FILTER (WHERE nacionalidad NOT IN (SELECT nk_pais FROM dw.dim_pais)) FROM m UNION ALL
    SELECT '12 Motivo vacío', count(*) FILTER (WHERE motivo_viaje IS NULL OR trim(motivo_viaje) = '') FROM m UNION ALL
    SELECT '13 Motivo escrito distinto al catálogo',
           count(*) FILTER (WHERE motivo_viaje NOT IN (SELECT motivo_viaje FROM dw.dim_motivo)) FROM m UNION ALL
    SELECT '14 Medio de transporte escrito distinto al catálogo',
           count(*) FILTER (WHERE medio_transporte NOT IN (SELECT medio_transporte FROM dw.dim_transporte)) FROM m UNION ALL
    SELECT '15 Código de viajero vacío', count(*) FILTER (WHERE codigo_viajero IS NULL OR trim(codigo_viajero) = '') FROM m UNION ALL
    SELECT '16 Minutos de control vacío', count(*) FILTER (WHERE minutos_control IS NULL) FROM m UNION ALL
    SELECT '17 Minutos de control <= 0', count(*) FILTER (WHERE try_cast(minutos_control AS DOUBLE) <= 0) FROM m UNION ALL
    SELECT '18 Minutos de control >= 600 (outlier)', count(*) FILTER (WHERE try_cast(minutos_control AS DOUBLE) >= 600) FROM m UNION ALL
    SELECT '19 ENTRADA de extranjero sin plazo autorizado',
           count(*) FILTER (WHERE sentido = 'ENTRADA' AND categoria_migratoria IN ('TURISTA', 'RESIDENTE TEMPORAL')
                              AND plazo_autorizado_dias IS NULL) FROM m
);

-- ---------------------------------------------------------------------
-- 2. JSON de alertas
-- ---------------------------------------------------------------------
INSERT INTO meta.perfil_calidad
WITH a AS (SELECT * FROM stg.stg_alerta)
SELECT (SELECT max(dw_id_ejecucion) FROM meta.ejecucion), 'alertas_inspeccion.json', control, filas
FROM (
    SELECT '01 Filas leídas' AS control, count(*) AS filas FROM a UNION ALL
    SELECT '02 id_alerta distintos', count(DISTINCT id_alerta) FROM a UNION ALL
    SELECT '03 Alertas duplicadas (mismo id_alerta)', count(*) - count(DISTINCT id_alerta) FROM a UNION ALL
    SELECT '04 Fecha de emisión en formato dd/mm/aaaa hh:mm',
           count(*) FILTER (WHERE emitida ~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$') FROM a UNION ALL
    SELECT '05 Movimiento huérfano (no existe en el CSV)',
           count(*) FILTER (WHERE id_movimiento NOT IN (SELECT id_movimiento FROM stg.stg_movimiento)) FROM a UNION ALL
    SELECT '06 Código de tipo de alerta en minúsculas',
           count(*) FILTER (WHERE tipo_codigo <> upper(tipo_codigo)) FROM a UNION ALL
    SELECT '07 Código de tipo de alerta inexistente',
           count(*) FILTER (WHERE upper(trim(tipo_codigo)) NOT IN (SELECT nk_tipo_alerta FROM dw.dim_tipo_alerta)) FROM a UNION ALL
    SELECT '08 Puesto que no es un código del catálogo',
           count(*) FILTER (WHERE puesto NOT IN (SELECT codigo_puesto FROM stg.stg_puesto)) FROM a UNION ALL
    SELECT '09 Resultado de inspección nulo', count(*) FILTER (WHERE inspeccion_resultado IS NULL) FROM a
);

-- ------------------------------------------------------------------
---
-- 3. Excel de puestos
-- ---------------------------------------------------------------------
INSERT INTO meta.perfil_calidad
WITH p AS (SELECT * FROM stg.stg_puesto)
SELECT (SELECT max(dw_id_ejecucion) FROM meta.ejecucion), 'catalogo_puestos.xlsx', control, filas
FROM (
    SELECT '01 Filas leídas' AS control, count(*) AS filas FROM p UNION ALL
    SELECT '02 Códigos de puesto distintos', count(DISTINCT codigo_puesto) FROM p UNION ALL
    SELECT '03 Códigos repetidos (versiones del mismo puesto)', count(*) - count(DISTINCT codigo_puesto) FROM p UNION ALL
    SELECT '04 Coordenadas con coma decimal', count(*) FILTER (WHERE latitud LIKE '%,%' OR longitud LIKE '%,%') FROM p UNION ALL
    SELECT '05 Dotación de personal vacía', count(*) FILTER (WHERE dotacion_personal IS NULL OR trim(dotacion_personal) = '') FROM p UNION ALL
    SELECT '06 Texto con espacios sobrantes',
           count(*) FILTER (WHERE ciudad <> trim(ciudad) OR departamento <> trim(departamento)) FROM p
);

-- Resultado del perfilado de esta ejecución
SELECT fuente, control, filas
FROM meta.perfil_calidad
WHERE dw_id_ejecucion = (SELECT max(dw_id_ejecucion) FROM meta.ejecucion)
ORDER BY fuente DESC, control;
