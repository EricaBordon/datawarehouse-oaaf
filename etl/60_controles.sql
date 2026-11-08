-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H3 — ETL Script 60: CONTROLES Y CIERRE
-- Concilia lo leído contra lo cargado (no se pierde ninguna fila sin
-- explicación), revisa integridad y cierra la ejecución en meta.ejecucion.
-- Todos los controles deben dar "OK".
-- =====================================================================

CREATE OR REPLACE TABLE meta.control_carga AS
WITH n AS (
    SELECT
        (SELECT count(*) FROM stg.stg_movimiento)                          AS mov_leidos,
        (SELECT count(*) FROM stg.cuarentena_movimiento)                   AS mov_cuarentena,
        (SELECT count(*) FROM dw.fact_movimiento_migratorio)               AS mov_cargados,
        (SELECT count(*) FROM stg.stg_alerta)                              AS ale_leidas,
        (SELECT count(*) FROM stg.cuarentena_alerta)                       AS ale_cuarentena,
        (SELECT count(*) FROM dw.fact_alerta)                              AS ale_cargadas,
        (SELECT count(DISTINCT codigo_puesto) FROM stg.stg_puesto)         AS puestos_fuente,
        (SELECT count(*) FROM dw.dim_puesto_control WHERE sk_puesto <> -1) AS puestos_dim
)
SELECT * FROM (
    SELECT 1 AS orden, 'Movimientos: leídos = cargados + cuarentena' AS control,
           format('{} = {} + {}', mov_leidos, mov_cargados, mov_cuarentena) AS detalle,
           mov_leidos = mov_cargados + mov_cuarentena AS ok FROM n
    UNION ALL
    SELECT 2, 'Alertas: leídas = cargadas + cuarentena',
           format('{} = {} + {}', ale_leidas, ale_cargadas, ale_cuarentena),
           ale_leidas = ale_cargadas + ale_cuarentena FROM n
    UNION ALL
    SELECT 3, 'Puestos: códigos distintos de la fuente = filas de la dimensión',
           format('{} = {}', puestos_fuente, puestos_dim), puestos_fuente = puestos_dim FROM n
    UNION ALL
    SELECT 4, 'Sin movimientos duplicados en el hecho',
           format('{} repetidos', count(*) - count(DISTINCT dd_id_movimiento)),
           count(*) = count(DISTINCT dd_id_movimiento) FROM dw.fact_movimiento_migratorio
    UNION ALL
    SELECT 5, 'dim_viajero: una sola versión vigente por viajero',
           format('{} viajeros con más de una vigente', count(*)), count(*) = 0
    FROM (SELECT nk_viajero FROM dw.dim_viajero WHERE es_vigente GROUP BY 1 HAVING count(*) > 1)
    UNION ALL
    SELECT 6, 'dim_viajero: vigencias sin huecos ni solapamientos',
           format('{} cortes incorrectos', count(*)), count(*) = 0
    FROM (SELECT fecha_inicio_vigencia,
                 lag(fecha_fin_vigencia) OVER (PARTITION BY nk_viajero ORDER BY nro_version) AS fin_anterior
          FROM dw.dim_viajero WHERE sk_viajero <> -1)
    WHERE fin_anterior IS NOT NULL AND fecha_inicio_vigencia <> fin_anterior + 1
    UNION ALL
    SELECT 7, 'Cada movimiento apunta a la versión del viajero vigente en su fecha',
           format('{} fuera de vigencia', count(*)), count(*) = 0
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_viajero v USING (sk_viajero)
    WHERE f.sk_viajero <> -1
      AND f.fecha_hora_movimiento::DATE NOT BETWEEN v.fecha_inicio_vigencia AND v.fecha_fin_vigencia
    UNION ALL
    SELECT 8, 'ind_alerta del movimiento coincide con las alertas cargadas',
           format('{} movimientos marcados vs {} con alerta', sum(ind_alerta),
                  (SELECT count(DISTINCT dd_id_movimiento) FROM dw.fact_alerta
                   WHERE dd_id_movimiento IN (SELECT dd_id_movimiento FROM dw.fact_movimiento_migratorio))),
           sum(ind_alerta) = (SELECT count(DISTINCT dd_id_movimiento) FROM dw.fact_alerta
                              WHERE dd_id_movimiento IN (SELECT dd_id_movimiento FROM dw.fact_movimiento_migratorio))
    FROM dw.fact_movimiento_migratorio
    UNION ALL
    SELECT 9, 'Permanencias no negativas',
           format('{} negativas', count(*) FILTER (WHERE dias_permanencia < 0)),
           count(*) FILTER (WHERE dias_permanencia < 0) = 0 FROM dw.fact_movimiento_migratorio
);

-- Uso del miembro NO DEFINIDO (sk = -1): no es error, es dato faltante en la fuente
CREATE OR REPLACE TABLE meta.uso_no_definido AS
SELECT 'fact_movimiento_migratorio' AS hecho, dimension, filas_con_menos_uno
FROM (
    SELECT count(*) FILTER (WHERE sk_tiempo = -1)     AS tiempo,
           count(*) FILTER (WHERE sk_puesto = -1)     AS puesto,
           count(*) FILTER (WHERE sk_viajero = -1)    AS viajero,
           count(*) FILTER (WHERE sk_pais = -1)       AS pais,
           count(*) FILTER (WHERE sk_documento = -1)  AS documento,
           count(*) FILTER (WHERE sk_motivo = -1)     AS motivo,
           count(*) FILTER (WHERE sk_transporte = -1) AS transporte
    FROM dw.fact_movimiento_migratorio
) UNPIVOT (filas_con_menos_uno FOR dimension IN (tiempo, puesto, viajero, pais, documento, motivo, transporte))
UNION ALL
SELECT 'fact_alerta', dimension, filas_con_menos_uno
FROM (
    SELECT count(*) FILTER (WHERE sk_tiempo = -1)      AS tiempo,
           count(*) FILTER (WHERE sk_puesto = -1)      AS puesto,
           count(*) FILTER (WHERE sk_viajero = -1)     AS viajero,
           count(*) FILTER (WHERE sk_pais = -1)        AS pais,
           count(*) FILTER (WHERE sk_documento = -1)   AS documento,
           count(*) FILTER (WHERE sk_tipo_alerta = -1) AS tipo_alerta
    FROM dw.fact_alerta
) UNPIVOT (filas_con_menos_uno FOR dimension IN (tiempo, puesto, viajero, pais, documento, tipo_alerta));

-- Cierre de la ejecución
UPDATE meta.ejecucion
SET fin              = now(),
    filas_leidas     = (SELECT count(*) FROM stg.stg_movimiento) + (SELECT count(*) FROM stg.stg_alerta),
    filas_cargadas   = (SELECT count(*) FROM dw.fact_movimiento_migratorio) + (SELECT count(*) FROM dw.fact_alerta),
    filas_cuarentena = (SELECT count(*) FROM stg.cuarentena_movimiento) + (SELECT count(*) FROM stg.cuarentena_alerta),
    estado           = CASE WHEN (SELECT bool_and(ok) FROM meta.control_carga) THEN 'OK' ELSE 'ERROR' END
WHERE dw_id_ejecucion = (SELECT max(dw_id_ejecucion) FROM meta.ejecucion);

-- Resultados
SELECT control, detalle, CASE WHEN ok THEN 'OK' ELSE 'ERROR' END AS resultado
FROM meta.control_carga ORDER BY orden;
