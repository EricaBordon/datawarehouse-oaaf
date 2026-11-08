-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H2 — Script 03: prueba del modelo
-- Inserta filas de ejemplo dentro de una transacción, prueba las
-- restricciones, el SCD tipo 1, el SCD tipo 2 y una consulta drill-across,
-- y al final hace ROLLBACK (no deja datos). Requiere scripts 01 y 02.
-- Ejecutar con Alt + X en DBeaver.
-- =====================================================================

BEGIN TRANSACTION;

-- Puesto de ejemplo (en H3 vienen del Excel de puestos)
INSERT INTO dw.dim_puesto_control VALUES
    (nextval('dw.seq_sk_puesto'), 'PC-CDE-PA', 'Puente de la Amistad', 'TERRESTRE',
     'Ciudad del Este', 'Alto Paraná', 'Brasil', 12, -25.509, -54.600, 0, now(), 'prueba');

-- SCD tipo 1: corrección de un error de carga -> se sobrescribe
UPDATE dw.dim_puesto_control SET departamento = 'Alto Paraná' WHERE nk_puesto = 'PC-CDE-PA';

-- SCD tipo 2: el viajero VJ-000001 entra como TURISTA y el 01/03/2025
-- pasa a RESIDENTE TEMPORAL -> se cierra la versión 1 y se abre la 2
INSERT INTO dw.dim_viajero VALUES
    (nextval('dw.seq_sk_viajero'), 'VJ-000001', '30-44', 'TURISTA',
     DATE '2024-10-01', DATE '9999-12-31', TRUE, 1, 0, now(), 'prueba');

UPDATE dw.dim_viajero
SET fecha_fin_vigencia = DATE '2025-02-28', es_vigente = FALSE
WHERE nk_viajero = 'VJ-000001' AND es_vigente;

INSERT INTO dw.dim_viajero VALUES
    (nextval('dw.seq_sk_viajero'), 'VJ-000001', '30-44', 'RESIDENTE TEMPORAL',
     DATE '2025-03-01', DATE '9999-12-31', TRUE, 2, 0, now(), 'prueba');

SELECT sk_viajero, nk_viajero, categoria_migratoria, fecha_inicio_vigencia,
       fecha_fin_vigencia, es_vigente, nro_version
FROM dw.dim_viajero WHERE nk_viajero = 'VJ-000001' ORDER BY nro_version;

-- Movimientos: el ETL busca la versión del viajero vigente en la fecha del cruce
INSERT INTO dw.fact_movimiento_migratorio
    (dd_id_movimiento, sk_tiempo, sk_puesto, sk_viajero, sk_pais, sk_documento,
     sk_motivo, sk_transporte, sentido, fecha_hora_movimiento, minutos_control,
     plazo_autorizado_dias, dias_permanencia, dias_excedidos,
     ind_permanencia_excedida, ind_alerta, dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen)
SELECT m.id, CAST(strftime(m.ts, '%Y%m%d%H') AS INTEGER), p.sk_puesto, v.sk_viajero,
       3, m.sk_doc, 1, 2, m.sentido, m.ts, m.minutos, m.plazo, m.perm, m.exc,
       m.ind_exc, m.ind_alerta, 0, now(), 'prueba'
FROM (VALUES
        ('MOV-0000001', TIMESTAMP '2024-11-10 08:15:00', 'ENTRADA', 1,  4.5, 90,   NULL, NULL, 0, 0),
        ('MOV-0000002', TIMESTAMP '2025-02-20 19:40:00', 'SALIDA',  1,  3.0, NULL, 102,  12,   1, 0),
        ('MOV-0000003', TIMESTAMP '2025-04-05 02:10:00', 'ENTRADA', 4, 18.0, 365,  NULL, NULL, 0, 1)
     ) AS m(id, ts, sentido, sk_doc, minutos, plazo, perm, exc, ind_exc, ind_alerta)
JOIN dw.dim_puesto_control p ON p.nk_puesto = 'PC-CDE-PA'
JOIN dw.dim_viajero v
  ON v.nk_viajero = 'VJ-000001'
 AND CAST(m.ts AS DATE) BETWEEN v.fecha_inicio_vigencia AND v.fecha_fin_vigencia;

-- Alerta ligada al tercer movimiento (documento robado)
INSERT INTO dw.fact_alerta
    (dd_id_alerta, dd_id_movimiento, sk_tiempo, sk_puesto, sk_viajero, sk_pais,
     sk_documento, sk_tipo_alerta, resultado_inspeccion, ind_inspeccion_secundaria,
     ind_confirmada, ind_rechazo_ingreso, minutos_inspeccion)
SELECT 'ALR-000001', f.dd_id_movimiento, f.sk_tiempo, f.sk_puesto, f.sk_viajero,
       f.sk_pais, f.sk_documento, 1, 'CONFIRMADA', 1, 1, 0, 35.0
FROM dw.fact_movimiento_migratorio f
WHERE f.dd_id_movimiento = 'MOV-0000003';

-- La versión del viajero cambió entre el movimiento 2 y el 3
SELECT f.dd_id_movimiento, f.sentido, t.fecha, t.franja_horaria,
       v.categoria_migratoria, v.nro_version, d.tipo_documento, d.estado_documento
FROM dw.fact_movimiento_migratorio f
JOIN dw.dim_tiempo    t ON t.sk_tiempo    = f.sk_tiempo
JOIN dw.dim_viajero   v ON v.sk_viajero   = f.sk_viajero
JOIN dw.dim_documento d ON d.sk_documento = f.sk_documento
ORDER BY f.fecha_hora_movimiento;

-- Drill-across (P2): alertas cada 10.000 movimientos por puesto y franja.
-- Se agrega cada hecho por separado sobre las dimensiones conformadas
-- y después se combinan los resultados.
WITH mov AS (
    SELECT f.sk_puesto, t.franja_horaria, sum(f.cantidad_movimientos) AS movimientos
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_tiempo t USING (sk_tiempo)
    GROUP BY ALL
),
alr AS (
    SELECT a.sk_puesto, t.franja_horaria, sum(a.cantidad_alertas) AS alertas
    FROM dw.fact_alerta a
    JOIN dw.dim_tiempo t USING (sk_tiempo)
    GROUP BY ALL
)
SELECT p.nombre_puesto, mov.franja_horaria, mov.movimientos,
       coalesce(alr.alertas, 0) AS alertas,
       round(coalesce(alr.alertas, 0) * 10000.0 / mov.movimientos, 1) AS alertas_cada_10k
FROM mov
LEFT JOIN alr USING (sk_puesto, franja_horaria)
JOIN dw.dim_puesto_control p USING (sk_puesto)
ORDER BY alertas_cada_10k DESC;

ROLLBACK;

-- Prueba de integridad referencial: este INSERT debe FALLAR porque el
-- puesto 999 no existe (el ETL tiene que mapear huérfanos a -1).
-- Descomentar para ver el error "Violates foreign key constraint":
-- INSERT INTO dw.fact_movimiento_migratorio
--     (dd_id_movimiento, sk_puesto, sentido, fecha_hora_movimiento)
-- VALUES ('MOV-ERR', 999, 'ENTRADA', now());

-- Después del ROLLBACK los hechos quedan vacíos
SELECT (SELECT count(*) FROM dw.fact_movimiento_migratorio) AS movimientos,
       (SELECT count(*) FROM dw.fact_alerta)                AS alertas;

