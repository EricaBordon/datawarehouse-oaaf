-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H3 — ETL Script 50: CARGA DE HECHOS
-- Busca la clave subrogada (sk) de cada dimensión y calcula las métricas
-- derivadas. Lo que no encuentra su dimensión va al miembro -1.
-- =====================================================================

DELETE FROM dw.fact_alerta;
DELETE FROM dw.fact_movimiento_migratorio;

-- ---------------------------------------------------------------------
-- 1. FACT_MOVIMIENTO_MIGRATORIO
-- ---------------------------------------------------------------------
INSERT INTO dw.fact_movimiento_migratorio
    (dd_id_movimiento, sk_tiempo, sk_puesto, sk_viajero, sk_pais, sk_documento, sk_motivo,
     sk_transporte, sentido, fecha_hora_movimiento, cantidad_movimientos, minutos_control,
     plazo_autorizado_dias, dias_permanencia, dias_excedidos, ind_permanencia_excedida,
     ind_alerta, dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
WITH secuencia AS (
    -- Para cada viajero, el movimiento anterior: permite emparejar ENTRADA -> SALIDA
    SELECT m.*,
           lag(sentido)       OVER w AS sentido_anterior,
           lag(ts_movimiento) OVER w AS ts_anterior,
           lag(plazo_dias)    OVER w AS plazo_anterior
    FROM stg.mov_limpio m
    WINDOW w AS (PARTITION BY nk_viajero ORDER BY ts_movimiento)
),
calculo AS (
    SELECT s.*,
           -- Permanencia: solo en la SALIDA de un extranjero cuyo movimiento anterior fue su ENTRADA
           CASE WHEN s.nk_viajero IS NOT NULL AND s.sentido = 'SALIDA' AND s.sentido_anterior = 'ENTRADA'
                     AND s.categoria_migratoria <> 'NACIONAL'
                THEN date_diff('day', s.ts_anterior::DATE, s.ts_movimiento::DATE) END AS dias_perm,
           -- Plazo: en la ENTRADA el otorgado; en la SALIDA se repite el de su ENTRADA
           CASE WHEN s.sentido = 'ENTRADA' THEN s.plazo_dias
                WHEN s.sentido_anterior = 'ENTRADA' AND s.categoria_migratoria <> 'NACIONAL' THEN s.plazo_anterior
           END AS plazo_aplicable
    FROM secuencia s
)
SELECT
    c.id_movimiento,
    coalesce(t.sk_tiempo, -1),
    coalesce(p.sk_puesto, -1),
    coalesce(v.sk_viajero, -1),
    coalesce(pa.sk_pais, -1),
    coalesce(d.sk_documento, -1),
    coalesce(mo.sk_motivo, -1),
    coalesce(tr.sk_transporte, -1),
    c.sentido,
    c.ts_movimiento,
    1,
    c.minutos_control,
    c.plazo_aplicable,
    c.dias_perm,
    CASE WHEN c.dias_perm IS NOT NULL AND c.plazo_aplicable IS NOT NULL
         THEN greatest(c.dias_perm - c.plazo_aplicable, 0) END,
    CASE WHEN c.dias_perm > c.plazo_aplicable THEN 1 ELSE 0 END,
    CASE WHEN c.id_movimiento IN (SELECT id_movimiento FROM stg.alerta_limpia) THEN 1 ELSE 0 END,
    c.dw_id_ejecucion, c.dw_fecha_carga, c.dw_archivo_origen
FROM calculo c
LEFT JOIN dw.dim_tiempo         t  ON t.sk_tiempo = CAST(strftime(c.ts_movimiento, '%Y%m%d%H') AS INTEGER)
LEFT JOIN dw.dim_puesto_control p  ON p.nk_puesto = c.codigo_puesto
LEFT JOIN dw.dim_viajero        v  ON v.nk_viajero = c.nk_viajero
                                  AND c.ts_movimiento::DATE BETWEEN v.fecha_inicio_vigencia AND v.fecha_fin_vigencia
LEFT JOIN dw.dim_pais           pa ON pa.nk_pais = c.nk_pais
LEFT JOIN dw.dim_documento      d  ON upper(strip_accents(d.tipo_documento)) = c.tipo_doc_norm
                                  AND d.estado_documento = c.estado_doc_norm
LEFT JOIN dw.dim_motivo         mo ON upper(strip_accents(mo.motivo_viaje)) = c.motivo_norm
LEFT JOIN dw.dim_transporte     tr ON upper(strip_accents(tr.medio_transporte)) = c.transporte_norm;

-- ---------------------------------------------------------------------
-- 2. FACT_ALERTA
--    Si la alerta encuentra su movimiento, hereda viajero y país de ese
--    movimiento (mismas claves conformadas -> drill-across exacto).
--    Si el movimiento es huérfano (o le falta ese dato), se busca el viajero
--    por su código y fecha, y el país por la nacionalidad más frecuente del viajero.
-- ---------------------------------------------------------------------
INSERT INTO dw.fact_alerta
    (dd_id_alerta, dd_id_movimiento, sk_tiempo, sk_puesto, sk_viajero, sk_pais, sk_documento,
     sk_tipo_alerta, resultado_inspeccion, cantidad_alertas, ind_inspeccion_secundaria,
     ind_confirmada, ind_rechazo_ingreso, minutos_inspeccion,
     dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
WITH nacionalidad_viajero AS (
    SELECT nk_viajero, mode(nk_pais) AS nk_pais
    FROM stg.mov_limpio WHERE nk_viajero IS NOT NULL AND nk_pais IS NOT NULL
    GROUP BY nk_viajero
)
SELECT
    a.id_alerta,
    a.id_movimiento,
    coalesce(t.sk_tiempo, -1),
    coalesce(p.sk_puesto, nullif(f.sk_puesto, -1), -1),
    coalesce(nullif(f.sk_viajero, -1), v.sk_viajero, -1),
    coalesce(nullif(f.sk_pais, -1), pa.sk_pais, -1),
    coalesce(d.sk_documento, nullif(f.sk_documento, -1), -1),
    coalesce(ta.sk_tipo_alerta, -1),
    a.resultado_inspeccion,
    1,
    a.ind_inspeccion_secundaria,
    a.ind_confirmada,
    a.ind_rechazo_ingreso,
    a.minutos_inspeccion,
    a.dw_id_ejecucion, a.dw_fecha_carga, a.dw_archivo_origen
FROM stg.alerta_limpia a
LEFT JOIN dw.fact_movimiento_migratorio f ON f.dd_id_movimiento = a.id_movimiento
LEFT JOIN dw.dim_tiempo         t  ON t.sk_tiempo = CAST(strftime(a.ts_emision, '%Y%m%d%H') AS INTEGER)
LEFT JOIN dw.dim_puesto_control p  ON p.nk_puesto = a.codigo_puesto
LEFT JOIN dw.dim_viajero        v  ON v.nk_viajero = a.nk_viajero
                                  AND a.ts_emision::DATE BETWEEN v.fecha_inicio_vigencia AND v.fecha_fin_vigencia
LEFT JOIN nacionalidad_viajero  nv ON nv.nk_viajero = a.nk_viajero
LEFT JOIN dw.dim_pais           pa ON pa.nk_pais = nv.nk_pais
LEFT JOIN dw.dim_documento      d  ON upper(strip_accents(d.tipo_documento)) = a.tipo_doc_norm
                                  AND d.estado_documento = a.estado_doc_norm
LEFT JOIN dw.dim_tipo_alerta    ta ON ta.nk_tipo_alerta = a.nk_tipo_alerta;

-- Controles
SELECT 'fact_movimiento_migratorio' AS tabla, count(*) AS filas FROM dw.fact_movimiento_migratorio UNION ALL
SELECT 'fact_alerta', count(*) FROM dw.fact_alerta;
