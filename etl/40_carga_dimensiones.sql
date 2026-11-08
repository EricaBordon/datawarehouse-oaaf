-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H3 — ETL Script 40: CARGA DE DIMENSIONES
--   dim_puesto_control -> SCD tipo 1 (upsert: inserta nuevos, sobrescribe cambios)
--   dim_viajero        -> SCD tipo 2 (una versión por cada categoría migratoria)
-- Las dimensiones estáticas (tiempo, país, documento, motivo, transporte,
-- tipo de alerta) ya se cargaron en el script 02 del H2.
-- Carga completa e idempotente: primero se vacían los hechos (que apuntan
-- a las dimensiones) y se vuelven a cargar en el script 50.
-- =====================================================================

DELETE FROM dw.fact_alerta;
DELETE FROM dw.fact_movimiento_migratorio;

-- ---------------------------------------------------------------------
-- 1. DIM_PUESTO_CONTROL — SCD tipo 1
--    Si el código ya existe se sobrescriben sus atributos (conserva su sk);
--    si es nuevo se inserta con un sk nuevo de la secuencia.
-- ---------------------------------------------------------------------
INSERT INTO dw.dim_puesto_control
    (sk_puesto, nk_puesto, nombre_puesto, tipo_puesto, ciudad, departamento, pais_limitrofe,
     dotacion_personal, latitud, longitud, dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
SELECT nextval('dw.seq_sk_puesto'), nk_puesto, nombre_puesto,
       CASE tipo_norm WHEN 'AEREO' THEN 'AÉREO' ELSE tipo_norm END,
       ciudad, departamento, pais_limitrofe, dotacion_personal, latitud, longitud,
       dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen
FROM stg.puesto_limpio
ORDER BY nk_puesto
ON CONFLICT (nk_puesto) DO UPDATE SET
    nombre_puesto     = excluded.nombre_puesto,
    tipo_puesto       = excluded.tipo_puesto,
    ciudad            = excluded.ciudad,
    departamento      = excluded.departamento,
    pais_limitrofe    = excluded.pais_limitrofe,
    dotacion_personal = excluded.dotacion_personal,
    latitud           = excluded.latitud,
    longitud          = excluded.longitud,
    dw_id_ejecucion   = excluded.dw_id_ejecucion,
    dw_fecha_carga    = excluded.dw_fecha_carga,
    dw_archivo_origen = excluded.dw_archivo_origen;

-- ---------------------------------------------------------------------
-- 2. DIM_VIAJERO — SCD tipo 2
--    Se recorre la historia de cada viajero en orden de fecha. Cada vez que
--    cambia su categoría migratoria empieza una versión nueva:
--      fecha_inicio_vigencia = primer cruce con la nueva categoría
--      fecha_fin_vigencia    = día anterior al inicio de la versión siguiente
--                              (9999-12-31 si es la versión actual)
--    La primera versión vale desde 1900-01-01 para cubrir todo el pasado.
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_viajero WHERE sk_viajero <> -1;

INSERT INTO dw.dim_viajero
    (sk_viajero, nk_viajero, rango_etario, categoria_migratoria, fecha_inicio_vigencia,
     fecha_fin_vigencia, es_vigente, nro_version, dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
WITH historia AS (
    SELECT nk_viajero, ts_movimiento, categoria_migratoria, rango_etario,
           CASE WHEN categoria_migratoria IS DISTINCT FROM
                     lag(categoria_migratoria) OVER (PARTITION BY nk_viajero ORDER BY ts_movimiento)
                THEN 1 ELSE 0 END AS es_cambio
    FROM stg.mov_limpio
    WHERE nk_viajero IS NOT NULL AND categoria_migratoria IS NOT NULL
),
numerada AS (
    SELECT *, sum(es_cambio) OVER (PARTITION BY nk_viajero ORDER BY ts_movimiento
                                   ROWS UNBOUNDED PRECEDING) AS nro_version
    FROM historia
),
versiones AS (
    SELECT nk_viajero, nro_version,
           any_value(categoria_migratoria)               AS categoria_migratoria,
           arg_max(rango_etario, ts_movimiento)           AS rango_etario,
           min(ts_movimiento)::DATE                       AS primer_cruce
    FROM numerada
    GROUP BY nk_viajero, nro_version
),
con_vigencia AS (
    SELECT *,
           CASE WHEN nro_version = 1 THEN DATE '1900-01-01' ELSE primer_cruce END AS fecha_inicio_vigencia,
           coalesce(lead(primer_cruce) OVER (PARTITION BY nk_viajero ORDER BY nro_version) - INTERVAL 1 DAY,
                    DATE '9999-12-31')::DATE                                     AS fecha_fin_vigencia
    FROM versiones
)
SELECT row_number() OVER (ORDER BY nk_viajero, nro_version)::INTEGER AS sk_viajero,
       nk_viajero, coalesce(rango_etario, 'NO DEFINIDO'), categoria_migratoria,
       fecha_inicio_vigencia, fecha_fin_vigencia,
       fecha_fin_vigencia = DATE '9999-12-31'                         AS es_vigente,
       nro_version,
       (SELECT max(dw_id_ejecucion) FROM meta.ejecucion), now(), 'movimientos_migratorios.csv'
FROM con_vigencia;

-- Controles
SELECT 'dim_puesto_control' AS dimension, count(*) AS filas FROM dw.dim_puesto_control UNION ALL
SELECT 'dim_viajero (versiones)', count(*) FROM dw.dim_viajero UNION ALL
SELECT 'dim_viajero (viajeros distintos)', count(DISTINCT nk_viajero) FROM dw.dim_viajero UNION ALL
SELECT 'dim_viajero (viajeros con más de una versión)',
       count(DISTINCT nk_viajero) FILTER (WHERE nro_version > 1) FROM dw.dim_viajero;
