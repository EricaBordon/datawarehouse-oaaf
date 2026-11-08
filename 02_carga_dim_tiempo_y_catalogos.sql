-- =====================================================================
-- DATAWAREHOUSE OAAF — Hito H2 — Script 02
-- Carga de dim_tiempo (generada) y de las dimensiones estáticas
-- (catálogos que no vienen de las fuentes operativas).
-- Requiere haber corrido 01_ddl_dw_oaaf.sql. Idempotente.
-- dim_puesto_control y dim_viajero se cargan en el ETL (H3) desde el
-- Excel de puestos y el CSV de movimientos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. DIM_TIEMPO: una fila por hora, 01/01/2024 a 31/12/2026
--    (cubre el periodo oct-2024 a sep-2026, el año anterior para P7 	
--     y las salidas posteriores al cierre). 3 años x 24 h = 26.304 filas.
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_tiempo WHERE sk_tiempo <> -1;

INSERT INTO dw.dim_tiempo
WITH horas AS (
    SELECT ts::TIMESTAMP AS ts
    FROM generate_series(TIMESTAMP '2024-01-01 00:00:00',
                         TIMESTAMP '2026-12-31 23:00:00',
                         INTERVAL 1 HOUR) AS t(ts)
),
feriados (fecha, nombre_feriado) AS (
    VALUES
    -- Feriados fijos de Paraguay (Ley 1601/2000 y modificaciones), 2024-2026
    (DATE '2024-01-01', 'Año Nuevo'),            (DATE '2025-01-01', 'Año Nuevo'),            (DATE '2026-01-01', 'Año Nuevo'),
    (DATE '2024-03-01', 'Día de los Héroes'),    (DATE '2025-03-01', 'Día de los Héroes'),    (DATE '2026-03-01', 'Día de los Héroes'),
    (DATE '2024-03-28', 'Jueves Santo'),         (DATE '2025-04-17', 'Jueves Santo'),         (DATE '2026-04-02', 'Jueves Santo'),
    (DATE '2024-03-29', 'Viernes Santo'),        (DATE '2025-04-18', 'Viernes Santo'),        (DATE '2026-04-03', 'Viernes Santo'),
    (DATE '2024-05-01', 'Día del Trabajador'),   (DATE '2025-05-01', 'Día del Trabajador'),   (DATE '2026-05-01', 'Día del Trabajador'),
    (DATE '2024-05-14', 'Independencia Nacional'), (DATE '2025-05-14', 'Independencia Nacional'), (DATE '2026-05-14', 'Independencia Nacional'),
    (DATE '2024-05-15', 'Independencia Nacional'), (DATE '2025-05-15', 'Independencia Nacional'), (DATE '2026-05-15', 'Independencia Nacional'),
    (DATE '2024-06-12', 'Paz del Chaco'),        (DATE '2025-06-12', 'Paz del Chaco'),        (DATE '2026-06-12', 'Paz del Chaco'),
    (DATE '2024-08-15', 'Fundación de Asunción'), (DATE '2025-08-15', 'Fundación de Asunción'), (DATE '2026-08-15', 'Fundación de Asunción'),
    (DATE '2024-09-29', 'Victoria de Boquerón'), (DATE '2025-09-29', 'Victoria de Boquerón'), (DATE '2026-09-29', 'Victoria de Boquerón'),
    (DATE '2024-12-08', 'Virgen de Caacupé'),    (DATE '2025-12-08', 'Virgen de Caacupé'),    (DATE '2026-12-08', 'Virgen de Caacupé'),
    (DATE '2024-12-25', 'Navidad'),              (DATE '2025-12-25', 'Navidad'),              (DATE '2026-12-25', 'Navidad')
)
SELECT
    CAST(strftime(h.ts, '%Y%m%d%H') AS INTEGER)          AS sk_tiempo,
    CAST(h.ts AS DATE)                                    AS fecha,
    hour(h.ts)                                            AS hora,
    CASE
        WHEN hour(h.ts) BETWEEN 0  AND 5  THEN 'Madrugada (00-06)'
        WHEN hour(h.ts) BETWEEN 6  AND 11 THEN 'Mañana (06-12)'
        WHEN hour(h.ts) BETWEEN 12 AND 17 THEN 'Tarde (12-18)'
        ELSE                                   'Noche (18-24)'
    END                                                   AS franja_horaria,
    day(h.ts)                                             AS dia,
    isodow(h.ts)                                          AS dia_semana,
    CASE isodow(h.ts) WHEN 1 THEN 'Lunes' WHEN 2 THEN 'Martes' WHEN 3 THEN 'Miércoles'
                      WHEN 4 THEN 'Jueves' WHEN 5 THEN 'Viernes' WHEN 6 THEN 'Sábado'
                      ELSE 'Domingo' END                  AS nombre_dia,
    isodow(h.ts) IN (6, 7)                                AS es_fin_semana,
    f.fecha IS NOT NULL                                   AS es_feriado,
    f.nombre_feriado,
    weekofyear(h.ts)                                      AS semana_iso,
    month(h.ts)                                           AS mes,
    CASE month(h.ts) WHEN 1 THEN 'Enero' WHEN 2 THEN 'Febrero' WHEN 3 THEN 'Marzo'
                     WHEN 4 THEN 'Abril' WHEN 5 THEN 'Mayo' WHEN 6 THEN 'Junio'
                     WHEN 7 THEN 'Julio' WHEN 8 THEN 'Agosto' WHEN 9 THEN 'Septiembre'
                     WHEN 10 THEN 'Octubre' WHEN 11 THEN 'Noviembre' ELSE 'Diciembre' END AS nombre_mes,
    strftime(h.ts, '%Y-%m')                               AS anio_mes,
    quarter(h.ts)                                         AS trimestre,
    CASE WHEN month(h.ts) <= 6 THEN 1 ELSE 2 END          AS semestre,
    year(h.ts)                                            AS anio
FROM horas h
LEFT JOIN feriados f ON f.fecha = CAST(h.ts AS DATE);

-- ---------------------------------------------------------------------
-- 2. DIM_DOCUMENTO: 4 tipos x 5 estados = 20 combinaciones
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_documento WHERE sk_documento <> -1;

INSERT INTO dw.dim_documento
WITH tipos (orden, cod, tipo_documento) AS (
    VALUES (1, 'PAS', 'Pasaporte'),
           (2, 'CIM', 'Cédula de identidad MERCOSUR'),
           (3, 'CIP', 'Cédula de identidad paraguaya'),
           (4, 'DVE', 'Documento de viaje de emergencia')
),
estados (orden, cod, estado_documento) AS (
    VALUES (1, 'VIG', 'VIGENTE'),
           (2, 'VEN', 'VENCIDO'),
           (3, 'EXT', 'EXTRAVIADO'),
           (4, 'ROB', 'ROBADO'),
           (5, 'ADU', 'ADULTERADO')
)
SELECT (t.orden - 1) * 5 + e.orden       AS sk_documento,
       t.cod || '-' || e.cod             AS nk_documento,
       t.tipo_documento,
       e.estado_documento,
       e.estado_documento <> 'VIGENTE'   AS es_observado
FROM tipos t CROSS JOIN estados e;

-- ---------------------------------------------------------------------
-- 3. DIM_MOTIVO
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_motivo WHERE sk_motivo <> -1;

INSERT INTO dw.dim_motivo VALUES
    (1, 'TUR', 'Turismo',     90),
    (2, 'NEG', 'Negocios',    90),
    (3, 'TRA', 'Tránsito',     3),
    (4, 'TRB', 'Trabajo',    365),
    (5, 'EST', 'Estudio',    365),
    (6, 'RES', 'Residencia', 730);

-- ---------------------------------------------------------------------
-- 4. DIM_TRANSPORTE
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_transporte WHERE sk_transporte <> -1;

INSERT INTO dw.dim_transporte VALUES
    (1, 'AER', 'Aéreo',                 'AÉREA'),
    (2, 'TPA', 'Terrestre particular',  'TERRESTRE'),
    (3, 'OMN', 'Ómnibus',               'TERRESTRE'),
    (4, 'FLU', 'Fluvial',               'FLUVIAL'),
    (5, 'PIE', 'A pie',                 'TERRESTRE');

-- ---------------------------------------------------------------------
-- 5. DIM_TIPO_ALERTA (organismos y tipos ficticios a fines académicos)
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_tipo_alerta WHERE sk_tipo_alerta <> -1;

INSERT INTO dw.dim_tipo_alerta VALUES
    (1, 'INT-SLTD', 'Documento en base de documentos robados o extraviados', 'ALTO',    3, 'INTERPOL',                          'INTERNACIONAL'),
    (2, 'INT-ROJ',  'Notificación roja (búsqueda para detención)',           'CRÍTICO', 4, 'INTERPOL',                          'INTERNACIONAL'),
    (3, 'ONU-SAN',  'Coincidencia en lista de sanciones',                     'CRÍTICO', 4, 'Consejo de Seguridad de la ONU',    'INTERNACIONAL'),
    (4, 'NAC-CAP',  'Orden de captura vigente',                               'ALTO',    3, 'Poder Judicial / Policía Nacional', 'NACIONAL'),
    (5, 'NAC-VIG',  'Lista de vigilancia nacional',                           'ALTO',    3, 'SENAD / Policía Nacional',          'NACIONAL'),
    (6, 'DGM-DOC',  'Inconsistencia documental',                              'MEDIO',   2, 'Dirección Nacional de Migraciones', 'NACIONAL'),
    (7, 'OAAF-PAT', 'Patrón de viaje irregular',                              'MEDIO',   2, 'OAAF (análisis interno)',           'NACIONAL'),
    (8, 'DGM-PER',  'Permanencia excedida en viaje anterior',                 'BAJO',    1, 'Dirección Nacional de Migraciones', 'NACIONAL');

-- ---------------------------------------------------------------------
-- 6. DIM_PAIS (catálogo de nacionalidades, ISO 3166-1 alfa-3)
-- ---------------------------------------------------------------------
DELETE FROM dw.dim_pais WHERE sk_pais <> -1;

INSERT INTO dw.dim_pais VALUES
    ( 1, 'PRY', 'Paraguay',        'América del Sur',   TRUE,  FALSE),
    ( 2, 'ARG', 'Argentina',       'América del Sur',   TRUE,  TRUE),
    ( 3, 'BRA', 'Brasil',          'América del Sur',   TRUE,  TRUE),
    ( 4, 'BOL', 'Bolivia',         'América del Sur',   TRUE,  TRUE),
    ( 5, 'URY', 'Uruguay',         'América del Sur',   TRUE,  FALSE),
    ( 6, 'CHL', 'Chile',           'América del Sur',   TRUE,  FALSE),
    ( 7, 'PER', 'Perú',            'América del Sur',   TRUE,  FALSE),
    ( 8, 'COL', 'Colombia',        'América del Sur',   TRUE,  FALSE),
    ( 9, 'VEN', 'Venezuela',       'América del Sur',   FALSE, FALSE),
    (10, 'USA', 'Estados Unidos',  'América del Norte', FALSE, FALSE),
    (11, 'MEX', 'México',          'América del Norte', FALSE, FALSE),
    (12, 'ESP', 'España',          'Europa',            FALSE, FALSE),
    (13, 'DEU', 'Alemania',        'Europa',            FALSE, FALSE),
    (14, 'ITA', 'Italia',          'Europa',            FALSE, FALSE),
    (15, 'FRA', 'Francia',         'Europa',            FALSE, FALSE),
    (16, 'CHN', 'China',           'Asia',              FALSE, FALSE),
    (17, 'TWN', 'Taiwán',          'Asia',              FALSE, FALSE),
    (18, 'KOR', 'Corea del Sur',   'Asia',              FALSE, FALSE),
    (19, 'JPN', 'Japón',           'Asia',              FALSE, FALSE),
    (20, 'LBN', 'Líbano',          'Medio Oriente',     FALSE, FALSE),
    (21, 'ZAF', 'Sudáfrica',       'África',            FALSE, FALSE),
    (22, 'AUS', 'Australia',       'Oceanía',           FALSE, FALSE);
-- Nota: MERCOSUR incluye miembros plenos y Estados asociados.

-- ---------------------------------------------------------------------
-- 7. Verificación de conteos
-- ---------------------------------------------------------------------
SELECT 'dim_tiempo'      AS tabla, count(*) AS filas FROM dw.dim_tiempo      UNION ALL  -- 26.305 (26.304 + fila -1)
SELECT 'dim_documento',            count(*)          FROM dw.dim_documento   UNION ALL  -- 21
SELECT 'dim_motivo',               count(*)          FROM dw.dim_motivo      UNION ALL  -- 7
SELECT 'dim_transporte',           count(*)          FROM dw.dim_transporte  UNION ALL  -- 6
SELECT 'dim_tipo_alerta',          count(*)          FROM dw.dim_tipo_alerta UNION ALL  -- 9
SELECT 'dim_pais',                 count(*)          FROM dw.dim_pais;                  -- 23
