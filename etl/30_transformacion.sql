-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H3 — ETL Script 30: TRANSFORMACIÓN
-- Limpia y estandariza lo que vino en staging. Produce:
--   stg.mov_limpio / stg.alerta_limpia / stg.puesto_limpio  (datos listos)
--   stg.cuarentena_movimiento / stg.cuarentena_alerta       (filas rechazadas)
-- Reglas:
--   * Se RECHAZA (cuarentena) lo que no se puede corregir ni ubicar en el
--     tiempo: duplicados, fecha no convertible, sentido desconocido.
--   * Se CORRIGE lo que tiene una forma correcta conocida: formatos de
--     fecha, códigos escritos como texto, mayúsculas, tildes, espacios.
--   * Se CONSERVA con miembro "NO DEFINIDO" (sk = -1, en el script 50)
--     lo que falta o es huérfano: puesto inexistente, nacionalidad, motivo.
--   * Se ANULA la métrica inválida pero se conserva el movimiento:
--     minutos de control <= 0 o >= 600.
-- =====================================================================
-- ---------------------------------------------------------------------
-- 0. Tablas de equivalencias (texto sucio -> código del catálogo)
--    La clave se compara normalizada: sin tildes, en mayúsculas, sin espacios
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.map_puesto (alias_norm VARCHAR PRIMARY KEY, codigo_puesto VARCHAR);
INSERT INTO stg.map_puesto VALUES
    ('CDE', 'PC-CDE-PA'), ('CIUDAD DEL ESTE', 'PC-CDE-PA'), ('PTE. AMISTAD', 'PC-CDE-PA'),
    ('PUENTE DE LA AMISTAD', 'PC-CDE-PA'), ('ENCARNACION', 'PC-ENC-SR'),
    ('AEROPUERTO SILVIO PETTIROSSI', 'PC-ASU-AE'), ('AEROPUERTO LUQUE', 'PC-ASU-AE'), ('ASU', 'PC-ASU-AE'),
    ('PJC', 'PC-PJC-FS'), ('PEDRO JUAN CABALLERO', 'PC-PJC-FS');
-- además, cada código del catálogo se mapea a sí mismo
INSERT INTO stg.map_puesto
SELECT DISTINCT upper(trim(codigo_puesto)), trim(codigo_puesto) FROM stg.stg_puesto
WHERE upper(trim(codigo_puesto)) NOT IN (SELECT alias_norm FROM stg.map_puesto);

CREATE OR REPLACE TABLE stg.map_pais AS
SELECT nk_pais AS alias_norm, nk_pais FROM dw.dim_pais WHERE sk_pais <> -1
UNION
SELECT upper(strip_accents(nombre_pais)), nk_pais FROM dw.dim_pais WHERE sk_pais <> -1;

-- ---------------------------------------------------------------------
-- 1. MOVIMIENTOS
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.mov_tipado AS
SELECT
    s.*,
    row_number() OVER (PARTITION BY s.id_movimiento ORDER BY s.dw_nro_fila) AS nro_aparicion,
    coalesce(try_strptime(s.fecha_hora, '%Y-%m-%d %H:%M:%S'),
             try_strptime(s.fecha_hora, '%Y-%m-%dT%H:%M:%S'),
             try_strptime(s.fecha_hora, '%d/%m/%Y %H:%M'))                    AS ts_movimiento,
    CASE WHEN upper(trim(s.sentido)) IN ('ENTRADA', 'E', 'ING', 'INGRESO') THEN 'ENTRADA'
         WHEN upper(trim(s.sentido)) IN ('SALIDA', 'S', 'EGR', 'EGRESO')   THEN 'SALIDA'
    END                                                                       AS sentido_std,
    mp.codigo_puesto                                                          AS codigo_puesto,
    trim(s.puesto)                                                            AS puesto_original,
    mpa.nk_pais                                                               AS nk_pais,
    nullif(trim(s.codigo_viajero), '')                                        AS nk_viajero,
    upper(strip_accents(trim(s.motivo_viaje)))                                AS motivo_norm,
    upper(strip_accents(trim(s.medio_transporte)))                            AS transporte_norm,
    upper(strip_accents(trim(s.tipo_documento)))                              AS tipo_doc_norm,
    upper(trim(s.estado_documento))                                           AS estado_doc_norm,
    upper(trim(s.categoria_migratoria))                                       AS categoria_std,
    nullif(trim(s.rango_etario), '')                                          AS rango_std,
    try_cast(s.plazo_autorizado_dias AS SMALLINT)                             AS plazo_dias,
    try_cast(s.minutos_control AS DECIMAL(6,1))                               AS minutos_original
FROM stg.stg_movimiento s
LEFT JOIN stg.map_puesto mp  ON mp.alias_norm  = upper(strip_accents(trim(s.puesto)))
LEFT JOIN stg.map_pais   mpa ON mpa.alias_norm = upper(strip_accents(trim(s.nacionalidad)));

-- Cuarentena: una sola causa por fila, por orden de precedencia
CREATE OR REPLACE TABLE stg.cuarentena_movimiento AS
SELECT CASE WHEN nro_aparicion > 1    THEN 'DUPLICADO'
            WHEN ts_movimiento IS NULL THEN 'FECHA_INVALIDA'
            WHEN sentido_std IS NULL   THEN 'SENTIDO_INVALIDO'
       END AS motivo_cuarentena,
       * EXCLUDE (nro_aparicion)
FROM stg.mov_tipado
WHERE nro_aparicion > 1 OR ts_movimiento IS NULL OR sentido_std IS NULL;

CREATE OR REPLACE TABLE stg.mov_limpio AS
SELECT
    id_movimiento,
    ts_movimiento,
    sentido_std          AS sentido,
    codigo_puesto,                       -- NULL = huérfano -> sk -1
    puesto_original,
    nk_viajero,                          -- NULL -> sk -1
    nk_pais,                             -- NULL -> sk -1
    rango_std            AS rango_etario,
    categoria_std        AS categoria_migratoria,
    tipo_doc_norm,
    estado_doc_norm,
    motivo_norm,
    transporte_norm,
    plazo_dias,
    CASE WHEN minutos_original > 0 AND minutos_original < 600 THEN minutos_original END AS minutos_control,
    (minutos_original IS NOT NULL AND NOT (minutos_original > 0 AND minutos_original < 600)) AS minutos_anulado,
    dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen
FROM stg.mov_tipado
WHERE nro_aparicion = 1 AND ts_movimiento IS NOT NULL AND sentido_std IS NOT NULL;

-- ---------------------------------------------------------------------
-- 2. ALERTAS
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.alerta_tipada AS
SELECT
    a.*,
    row_number() OVER (PARTITION BY a.id_alerta ORDER BY a.dw_nro_fila) AS nro_aparicion,
    coalesce(try_strptime(a.emitida, '%Y-%m-%dT%H:%M:%S'),
             try_strptime(a.emitida, '%Y-%m-%d %H:%M:%S'),
             try_strptime(a.emitida, '%d/%m/%Y %H:%M'))                       AS ts_emision,
    upper(trim(a.tipo_codigo))                                                AS nk_tipo_alerta,
    mp.codigo_puesto                                                          AS codigo_puesto,
    nullif(trim(a.viajero), '')                                               AS nk_viajero,
    upper(strip_accents(trim(a.documento_tipo)))                              AS tipo_doc_norm,
    upper(trim(a.documento_estado))                                           AS estado_doc_norm,
    lower(trim(a.inspeccion_secundaria)) = 'true'                             AS hubo_inspeccion,
    upper(trim(a.inspeccion_resultado))                                       AS resultado_norm,
    try_cast(a.inspeccion_minutos AS DECIMAL(6,1))                            AS minutos_inspeccion
FROM stg.stg_alerta a
LEFT JOIN stg.map_puesto mp ON mp.alias_norm = upper(strip_accents(trim(a.puesto)));

CREATE OR REPLACE TABLE stg.cuarentena_alerta AS
SELECT CASE WHEN nro_aparicion > 1 THEN 'DUPLICADO'
            WHEN ts_emision IS NULL THEN 'FECHA_INVALIDA'
       END AS motivo_cuarentena,
       * EXCLUDE (nro_aparicion)
FROM stg.alerta_tipada
WHERE nro_aparicion > 1 OR ts_emision IS NULL;

CREATE OR REPLACE TABLE stg.alerta_limpia AS
SELECT
    id_alerta,
    id_movimiento,
    id_movimiento IN (SELECT id_movimiento FROM stg.mov_limpio) AS movimiento_encontrado,
    ts_emision,
    codigo_puesto,
    nk_viajero,
    nk_tipo_alerta,
    tipo_doc_norm,
    estado_doc_norm,
    -- Resultado nulo: si hubo inspección queda como NO INFORMADO (no cuenta como confirmada)
    CASE WHEN resultado_norm IS NOT NULL THEN resultado_norm
         WHEN hubo_inspeccion            THEN 'NO INFORMADO'
         ELSE 'SIN INSPECCIÓN' END                                  AS resultado_inspeccion,
    CASE WHEN hubo_inspeccion THEN 1 ELSE 0 END                      AS ind_inspeccion_secundaria,
    CASE WHEN resultado_norm IN ('CONFIRMADA', 'RECHAZO DE INGRESO') THEN 1 ELSE 0 END AS ind_confirmada,
    CASE WHEN resultado_norm = 'RECHAZO DE INGRESO' THEN 1 ELSE 0 END AS ind_rechazo_ingreso,
    minutos_inspeccion,
    dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen
FROM stg.alerta_tipada
WHERE nro_aparicion = 1 AND ts_emision IS NOT NULL;

-- ---------------------------------------------------------------------
-- 3. PUESTOS (Excel): se queda la versión más reciente de cada código
--    (SCD tipo 1: la corrección posterior reemplaza a la anterior)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE stg.puesto_limpio AS
SELECT
    trim(codigo_puesto)                                              AS nk_puesto,
    trim(nombre_puesto)                                              AS nombre_puesto,
    upper(strip_accents(trim(tipo_puesto)))                          AS tipo_norm,
    CASE upper(strip_accents(trim(ciudad))) WHEN 'CDE' THEN 'Ciudad del Este'
         ELSE trim(ciudad) END                                       AS ciudad,
    CASE upper(strip_accents(trim(departamento)))
         WHEN 'ALTO PARANA' THEN 'Alto Paraná'  WHEN 'ITAPUA'   THEN 'Itapúa'
         WHEN 'CANINDEYU'   THEN 'Canindeyú'    WHEN 'AMAMBAI'  THEN 'Amambay'
         ELSE trim(departamento) END                                 AS departamento,
    trim(pais_limitrofe)                                             AS pais_limitrofe,
    try_cast(try_cast(dotacion_personal AS DOUBLE) AS SMALLINT)      AS dotacion_personal,
    try_cast(replace(latitud,  ',', '.') AS DECIMAL(9,6))            AS latitud,
    try_cast(replace(longitud, ',', '.') AS DECIMAL(9,6))            AS longitud,
    try_cast(fecha_actualizacion AS DATE)                            AS fecha_actualizacion,
    dw_id_ejecucion, dw_fecha_carga, dw_archivo_origen
FROM stg.stg_puesto
QUALIFY row_number() OVER (PARTITION BY trim(codigo_puesto)
                           ORDER BY try_cast(fecha_actualizacion AS DATE) DESC) = 1;

-- Control de la transformación
SELECT 'mov_limpio' AS tabla, count(*) AS filas FROM stg.mov_limpio UNION ALL
SELECT 'cuarentena_movimiento', count(*) FROM stg.cuarentena_movimiento UNION ALL
SELECT 'alerta_limpia', count(*) FROM stg.alerta_limpia UNION ALL
SELECT 'cuarentena_alerta', count(*) FROM stg.cuarentena_alerta UNION ALL
SELECT 'puesto_limpio', count(*) FROM stg.puesto_limpio;





