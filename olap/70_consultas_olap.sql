-- =====================================================================
-- DATAWAREHOUSE OAAF — Script 70: CONSULTAS OLAP (preguntas P1 a P7)
-- Cada pregunta del acta queda como una VISTA en el esquema "olap":
--   * en DBeaver: SELECT * FROM olap.p1_flujo_por_puesto;
--   * en Power BI: se importan las vistas directamente.
-- Operadores usados: CUBE, ROLLUP, GROUPING SETS, drill-across entre los
-- dos hechos (P2) y funciones de ventana (P5, P7).
-- Requiere el ETL completo (scripts 10 a 60). Idempotente.
-- Convención: en las filas de subtotal la columna agrupada dice "(Total)".
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS olap;

-- ---------------------------------------------------------------------
-- P1. ¿Qué puestos concentran el flujo migratorio por mes y sentido?
--     Indicador: movimientos y % sobre el total nacional.
--     Operador: CUBE (puesto x sentido) -> todas las combinaciones de
--     subtotales: puesto y sentido, solo puesto, solo sentido y total.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p1_flujo_por_puesto AS
WITH cubo AS (
    SELECT CASE WHEN grouping(p.nombre_puesto) = 1 THEN '(Total)' ELSE p.nombre_puesto END AS puesto,
           CASE WHEN grouping(f.sentido)       = 1 THEN '(Total)' ELSE f.sentido       END AS sentido,
           sum(f.cantidad_movimientos) AS movimientos
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_puesto_control p USING (sk_puesto)
    GROUP BY CUBE (p.nombre_puesto, f.sentido)
)
SELECT puesto, sentido, movimientos,
       round(100.0 * movimientos /
             (SELECT movimientos FROM cubo WHERE puesto = '(Total)' AND sentido = '(Total)'), 1) AS pct_total_nacional
FROM cubo;

-- P1 por mes (para el gráfico de tendencia): % de cada puesto sobre el
-- total nacional del mismo mes y sentido.
CREATE OR REPLACE VIEW olap.p1_flujo_mensual AS
SELECT t.anio_mes, f.sentido, p.nombre_puesto AS puesto,
       sum(f.cantidad_movimientos) AS movimientos,
       round(100.0 * sum(f.cantidad_movimientos)
             / sum(sum(f.cantidad_movimientos)) OVER (PARTITION BY t.anio_mes, f.sentido), 1) AS pct_total_nacional
FROM dw.fact_movimiento_migratorio f
JOIN dw.dim_tiempo t USING (sk_tiempo)
JOIN dw.dim_puesto_control p USING (sk_puesto)
GROUP BY t.anio_mes, f.sentido, p.nombre_puesto;

-- ---------------------------------------------------------------------
-- P2. ¿En qué puestos y franjas horarias se generan más alertas?
--     Indicador: alertas cada 10.000 movimientos.
--     Operador: DRILL-ACROSS. Cada hecho se agrega por separado sobre las
--     MISMAS dimensiones conformadas (puesto y tiempo) con GROUPING SETS,
--     y después se combinan los dos resultados por esas columnas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p2_alertas_por_franja AS
WITH mov AS (
    SELECT CASE WHEN grouping(p.nombre_puesto) = 1 THEN '(Total)' ELSE p.nombre_puesto END AS puesto,
           CASE WHEN grouping(t.franja_horaria) = 1 THEN '(Total)' ELSE t.franja_horaria END AS franja_horaria,
           sum(f.cantidad_movimientos) AS movimientos
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_tiempo t USING (sk_tiempo)
    JOIN dw.dim_puesto_control p USING (sk_puesto)
    GROUP BY GROUPING SETS ((p.nombre_puesto, t.franja_horaria), (p.nombre_puesto), (t.franja_horaria), ())
),
ale AS (
    SELECT CASE WHEN grouping(p.nombre_puesto) = 1 THEN '(Total)' ELSE p.nombre_puesto END AS puesto,
           CASE WHEN grouping(t.franja_horaria) = 1 THEN '(Total)' ELSE t.franja_horaria END AS franja_horaria,
           sum(a.cantidad_alertas) AS alertas
    FROM dw.fact_alerta a
    JOIN dw.dim_tiempo t USING (sk_tiempo)
    JOIN dw.dim_puesto_control p USING (sk_puesto)
    GROUP BY GROUPING SETS ((p.nombre_puesto, t.franja_horaria), (p.nombre_puesto), (t.franja_horaria), ())
)
SELECT mov.puesto, mov.franja_horaria, mov.movimientos,
       coalesce(ale.alertas, 0) AS alertas,
       round(coalesce(ale.alertas, 0) * 10000.0 / mov.movimientos, 1) AS alertas_cada_10k
FROM mov
LEFT JOIN ale USING (puesto, franja_horaria);

-- Detalle por tipo de alerta (la tercera dimensión de P2)
CREATE OR REPLACE VIEW olap.p2_alertas_por_tipo_y_franja AS
SELECT ta.tipo_alerta, ta.nivel_riesgo, t.franja_horaria, count(*) AS alertas
FROM dw.fact_alerta a
JOIN dw.dim_tiempo t USING (sk_tiempo)
JOIN dw.dim_tipo_alerta ta USING (sk_tipo_alerta)
GROUP BY ALL;

-- ---------------------------------------------------------------------
-- P3. ¿Qué tipos de alerta terminan con más frecuencia en inspección
--     secundaria confirmada o en rechazo de ingreso?
--     Indicador: tasa de confirmación % = confirmadas / emitidas.
--     Operador: ROLLUP (tipo de alerta -> puesto): detalle por tipo y
--     puesto, subtotal por tipo y total general.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p3_tasa_confirmacion AS
SELECT CASE WHEN grouping(ta.tipo_alerta)   = 1 THEN '(Total)' ELSE ta.tipo_alerta   END AS tipo_alerta,
       CASE WHEN grouping(p.nombre_puesto)  = 1 THEN '(Total)' ELSE p.nombre_puesto  END AS puesto,
       sum(a.cantidad_alertas)                                     AS alertas_emitidas,
       sum(a.ind_inspeccion_secundaria)                            AS con_inspeccion,
       sum(a.ind_confirmada)                                       AS confirmadas,
       sum(a.ind_rechazo_ingreso)                                  AS rechazos_ingreso,
       round(100.0 * sum(a.ind_confirmada) / sum(a.cantidad_alertas), 1)      AS tasa_confirmacion_pct,
       round(100.0 * sum(a.ind_rechazo_ingreso) / sum(a.cantidad_alertas), 1) AS tasa_rechazo_pct
FROM dw.fact_alerta a
JOIN dw.dim_tipo_alerta ta USING (sk_tipo_alerta)
JOIN dw.dim_puesto_control p USING (sk_puesto)
GROUP BY ROLLUP (ta.tipo_alerta, p.nombre_puesto);

-- P3 por trimestre (la dimensión tiempo del acta)
CREATE OR REPLACE VIEW olap.p3_tasa_confirmacion_trimestral AS
SELECT t.anio, t.trimestre, ta.tipo_alerta,
       count(*) AS alertas_emitidas,
       round(100.0 * avg(a.ind_confirmada), 1) AS tasa_confirmacion_pct
FROM dw.fact_alerta a
JOIN dw.dim_tiempo t USING (sk_tiempo)
JOIN dw.dim_tipo_alerta ta USING (sk_tipo_alerta)
GROUP BY ALL;

-- ---------------------------------------------------------------------
-- P4. ¿Qué tipos de documento presentan más observaciones (extraviado,
--     robado, adulterado, vencido)?
--     Indicador: documentos observados cada 10.000 movimientos.
--     Operador: ROLLUP (tipo de documento -> estado). El denominador es
--     el total de movimientos de ese mismo tipo de documento.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p4_documentos_observados AS
WITH base AS (
    SELECT d.tipo_documento, d.estado_documento, d.es_observado, f.cantidad_movimientos
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_documento d USING (sk_documento)
),
por_tipo AS (
    SELECT tipo_documento, sum(cantidad_movimientos) AS movimientos_tipo FROM base GROUP BY 1
)
SELECT CASE WHEN grouping(b.tipo_documento)   = 1 THEN '(Total)' ELSE b.tipo_documento   END AS tipo_documento,
       CASE WHEN grouping(b.estado_documento) = 1 THEN '(Total)' ELSE b.estado_documento END AS estado_documento,
       sum(b.cantidad_movimientos) AS documentos_observados,
       round(sum(b.cantidad_movimientos) * 10000.0 /
             CASE WHEN grouping(b.tipo_documento) = 1 THEN (SELECT sum(movimientos_tipo) FROM por_tipo)
                  ELSE any_value(pt.movimientos_tipo) END, 1) AS observados_cada_10k
FROM base b
JOIN por_tipo pt USING (tipo_documento)
WHERE b.es_observado
GROUP BY ROLLUP (b.tipo_documento, b.estado_documento);

-- P4 por puesto y mes
CREATE OR REPLACE VIEW olap.p4_observados_por_puesto_mes AS
SELECT t.anio_mes, p.nombre_puesto AS puesto,
       sum(f.cantidad_movimientos) AS movimientos,
       sum(f.cantidad_movimientos) FILTER (WHERE d.es_observado) AS documentos_observados,
       round(coalesce(sum(f.cantidad_movimientos) FILTER (WHERE d.es_observado), 0) * 10000.0
             / sum(f.cantidad_movimientos), 1) AS observados_cada_10k
FROM dw.fact_movimiento_migratorio f
JOIN dw.dim_documento d USING (sk_documento)
JOIN dw.dim_tiempo t USING (sk_tiempo)
JOIN dw.dim_puesto_control p USING (sk_puesto)
GROUP BY ALL;

-- ---------------------------------------------------------------------
-- P5. ¿Cuántos viajeros muestran patrones de cruce frecuente en poco
--     tiempo, y en qué puestos?
--     Indicador: viajeros con 6 o más cruces en 30 días, por puesto y mes.
--     Técnica: función de ventana con RANGE de 30 días por viajero (sobre
--     el código natural, para sumar todas sus versiones SCD 2) + ROLLUP.
--     El viajero se cuenta en el puesto y mes donde alcanza el 6.º cruce.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p5_cruce_frecuente AS
WITH ventana AS (
    SELECT v.nk_viajero, f.sk_puesto, f.sk_tiempo,
           count(*) OVER (PARTITION BY v.nk_viajero ORDER BY f.fecha_hora_movimiento
                          RANGE BETWEEN INTERVAL 30 DAY PRECEDING AND CURRENT ROW) AS cruces_30d
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_viajero v USING (sk_viajero)
    WHERE f.sk_viajero <> -1
),
deteccion AS (   -- primera vez de cada viajero en cada mes con 6 o más cruces en 30 días
    SELECT nk_viajero, sk_puesto, sk_tiempo
    FROM ventana
    WHERE cruces_30d >= 6
    QUALIFY row_number() OVER (PARTITION BY nk_viajero, sk_tiempo // 10000 ORDER BY sk_tiempo) = 1
)
SELECT CASE WHEN grouping(p.nombre_puesto) = 1 THEN '(Total)' ELSE p.nombre_puesto END AS puesto,
       CASE WHEN grouping(t.anio_mes)      = 1 THEN '(Total)' ELSE t.anio_mes      END AS anio_mes,
       count(DISTINCT d.nk_viajero) AS viajeros_frecuentes
FROM deteccion d
JOIN dw.dim_puesto_control p USING (sk_puesto)
JOIN dw.dim_tiempo t USING (sk_tiempo)
GROUP BY ROLLUP (p.nombre_puesto, t.anio_mes);

-- ---------------------------------------------------------------------
-- P6. ¿Cuál es la permanencia promedio por motivo de viaje y categoría
--     migratoria, y cuántas exceden el plazo autorizado?
--     Indicadores: permanencia promedio (días) y % de permanencias excedidas.
--     Operador: GROUPING SETS -> motivo x categoría, solo motivo, solo
--     categoría y total. La categoría es la VIGENTE en cada cruce (SCD 2).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p6_permanencia AS
SELECT CASE WHEN grouping(mo.motivo_viaje)        = 1 THEN '(Total)' ELSE mo.motivo_viaje        END AS motivo_viaje,
       CASE WHEN grouping(v.categoria_migratoria) = 1 THEN '(Total)' ELSE v.categoria_migratoria END AS categoria_migratoria,
       count(*)                                              AS salidas_con_permanencia,
       round(avg(f.dias_permanencia), 1)                     AS permanencia_promedio_dias,
       sum(f.ind_permanencia_excedida)                       AS permanencias_excedidas,
       round(100.0 * avg(f.ind_permanencia_excedida), 1)     AS pct_excedidas,
       round(avg(f.dias_excedidos) FILTER (WHERE f.ind_permanencia_excedida = 1), 1) AS dias_excedidos_promedio
FROM dw.fact_movimiento_migratorio f
JOIN dw.dim_motivo mo USING (sk_motivo)
JOIN dw.dim_viajero v USING (sk_viajero)
WHERE f.dias_permanencia IS NOT NULL
GROUP BY GROUPING SETS ((mo.motivo_viaje, v.categoria_migratoria), (mo.motivo_viaje), (v.categoria_migratoria), ());

-- ---------------------------------------------------------------------
-- P7. ¿Cómo varía el flujo por región de origen y motivo de viaje a lo
--     largo del año?
--     Indicadores: movimientos por mes y variación % contra el mismo mes
--     del año anterior.
--     Operador: GROUPING SETS por (mes, región), (mes, motivo) y (mes) +
--     comparación con el mismo mes de 12 meses antes.
--     Limitación: los datos empiezan el 01/10/2024, así que octubre de 2024
--     no tiene las salidas y regresos de viajes iniciados antes de esa fecha.
--     Por eso la variación de octubre de 2025 (+31 %) está inflada y no
--     debe leerse como crecimiento real; desde noviembre la comparación es válida.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW olap.p7_variacion_interanual AS
WITH mensual AS (
    SELECT t.anio, t.mes,
           CASE WHEN grouping(pa.region) = 0 THEN 'Región'
                WHEN grouping(mo.motivo_viaje) = 0 THEN 'Motivo'
                ELSE '(Total)' END                              AS dimension,
           coalesce(CASE WHEN grouping(pa.region) = 0 THEN pa.region END,
                    CASE WHEN grouping(mo.motivo_viaje) = 0 THEN mo.motivo_viaje END,
                    '(Total)')                                  AS valor,
           sum(f.cantidad_movimientos)                          AS movimientos
    FROM dw.fact_movimiento_migratorio f
    JOIN dw.dim_tiempo t USING (sk_tiempo)
    JOIN dw.dim_pais pa USING (sk_pais)
    JOIN dw.dim_motivo mo USING (sk_motivo)
    GROUP BY GROUPING SETS ((t.anio, t.mes, pa.region), (t.anio, t.mes, mo.motivo_viaje), (t.anio, t.mes))
)
SELECT a.dimension, a.valor, a.anio, a.mes,
       printf('%d-%02d', a.anio, a.mes)                          AS anio_mes,
       a.movimientos,
       b.movimientos                                             AS movimientos_anio_anterior,
       round(100.0 * (a.movimientos - b.movimientos) / b.movimientos, 1) AS variacion_interanual_pct
FROM mensual a
LEFT JOIN mensual b
       ON b.dimension = a.dimension AND b.valor = a.valor
      AND b.anio = a.anio - 1 AND b.mes = a.mes;

-- =====================================================================
-- CONSULTAS PARA VER LOS RESULTADOS (ejecutar una por una con Ctrl + Enter)
-- =====================================================================
-- P1: ranking de puestos (total de ambos sentidos)
SELECT * FROM olap.p1_flujo_por_puesto WHERE sentido = '(Total)' ORDER BY movimientos DESC;

-- P2: puesto x franja, de mayor a menor tasa de alertas
SELECT * FROM olap.p2_alertas_por_franja
WHERE puesto <> '(Total)' AND franja_horaria <> '(Total)' AND movimientos >= 300
ORDER BY alertas_cada_10k DESC LIMIT 10;

-- P2: solo por franja horaria (subtotales del GROUPING SETS)
SELECT * FROM olap.p2_alertas_por_franja WHERE puesto = '(Total)' ORDER BY franja_horaria;

-- P3: tasa de confirmación por tipo de alerta (subtotales del ROLLUP)
SELECT tipo_alerta, alertas_emitidas, confirmadas, rechazos_ingreso, tasa_confirmacion_pct, tasa_rechazo_pct
FROM olap.p3_tasa_confirmacion WHERE puesto = '(Total)' ORDER BY tasa_confirmacion_pct DESC;

-- P4: documentos observados por tipo y estado
SELECT * FROM olap.p4_documentos_observados ORDER BY tipo_documento, documentos_observados DESC;

-- P5: viajeros frecuentes por puesto (subtotal del ROLLUP) y total
SELECT puesto, viajeros_frecuentes FROM olap.p5_cruce_frecuente
WHERE anio_mes = '(Total)' ORDER BY viajeros_frecuentes DESC;

-- P6: permanencia por motivo y categoría
SELECT * FROM olap.p6_permanencia ORDER BY motivo_viaje, categoria_migratoria;

-- P7: variación interanual por región (meses con año anterior disponible)
SELECT anio_mes, valor AS region, movimientos, movimientos_anio_anterior, variacion_interanual_pct
FROM olap.p7_variacion_interanual
WHERE dimension = 'Región' AND movimientos_anio_anterior IS NOT NULL
ORDER BY valor, anio_mes;
