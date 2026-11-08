-- =====================================================================
-- DATAWAREHOUSE OAAF — Oficina de Análisis Antiterrorista de Fronteras
-- Hito H2 — Script 01: DDL del modelo dimensional (esquema estrella)
-- Cátedra Datawarehouse (22891) · Uninorte · Lic. Walter Romero
-- Alumna: Érica Bordón · Motor: DuckDB 1.5 · Cliente: DBeaver
--
-- Modelo: constelación de 2 tablas de hechos que comparten
-- dimensiones conformadas (tiempo, puesto, viajero, país, documento).
--   fact_movimiento_migratorio  -> grano: 1 fila por movimiento migratorio
--                                  (un viajero, en un puesto, en un sentido,
--                                   en una fecha y hora)
--   fact_alerta                 -> grano: 1 fila por alerta emitida
--
-- Convenciones (las mismas del laboratorio Ñandutí):
--   sk_  clave subrogada (surrogate key), entera, generada en el DW
--   nk_  clave natural (código del sistema fuente)
--   dd_  dimensión degenerada (identificador que queda en el hecho)
--   ind_ indicador 0/1 (se suma para contar, se promedia para tasas)
--   dw_  columnas de linaje (ejecución, fecha de carga, archivo origen)
--   Fila sk = -1 'NO DEFINIDO' en cada dimensión para huérfanos y nulos.
--
-- Ejecución: seleccionar todo (Ctrl + A) y Alt + X en DBeaver.
-- El script es idempotente: se puede correr varias veces.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS stg;   -- staging (crudo, se llena en H3)
CREATE SCHEMA IF NOT EXISTS dw;    -- modelo dimensional
CREATE SCHEMA IF NOT EXISTS meta;  -- linaje y control de ejecuciones

-- Se borran primero los hechos (tienen FK hacia las dimensiones)
DROP TABLE IF EXISTS dw.fact_alerta;
DROP TABLE IF EXISTS dw.fact_movimiento_migratorio;
DROP TABLE IF EXISTS dw.dim_tiempo;
DROP TABLE IF EXISTS dw.dim_puesto_control;
DROP TABLE IF EXISTS dw.dim_viajero;
DROP TABLE IF EXISTS dw.dim_pais;
DROP TABLE IF EXISTS dw.dim_documento;
DROP TABLE IF EXISTS dw.dim_motivo;
DROP TABLE IF EXISTS dw.dim_tipo_alerta;
DROP TABLE IF EXISTS dw.dim_transporte;
DROP SEQUENCE IF EXISTS dw.seq_sk_puesto;
DROP SEQUENCE IF EXISTS dw.seq_sk_viajero;
DROP SEQUENCE IF EXISTS dw.seq_sk_pais;

-- Secuencias para las dimensiones que se cargan desde las fuentes
CREATE SEQUENCE dw.seq_sk_puesto  START 1;
CREATE SEQUENCE dw.seq_sk_viajero START 1;
CREATE SEQUENCE dw.seq_sk_pais    START 1;

-- ---------------------------------------------------------------------
-- 0. META — control de ejecuciones del ETL (linaje)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta.ejecucion (
    dw_id_ejecucion  BIGINT PRIMARY KEY,
    proceso          VARCHAR NOT NULL,   -- ej. 'carga_fact_movimiento'
    inicio           TIMESTAMP NOT NULL,
    fin              TIMESTAMP,
    filas_leidas     BIGINT,
    filas_cargadas   BIGINT,
    filas_cuarentena BIGINT,
    estado           VARCHAR             -- 'OK', 'ERROR', 'EN CURSO'
);

-- ---------------------------------------------------------------------
-- 1. DIM_TIEMPO — dimensión conformada. Grano: una fila por hora.
--    sk_tiempo = AAAAMMDDHH (ej. 2025071514 = 15/07/2025 de 14:00 a 14:59)
--    Responde "cuándo" y la franja horaria (P2).
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_tiempo (
    sk_tiempo        INTEGER PRIMARY KEY,
    fecha            DATE,
    hora             TINYINT,            -- 0 a 23
    franja_horaria   VARCHAR(30),        -- Madrugada / Mañana / Tarde / Noche
    dia              TINYINT,
    dia_semana       TINYINT,            -- 1 = lunes ... 7 = domingo (ISO)
    nombre_dia       VARCHAR(10),
    es_fin_semana    BOOLEAN,
    es_feriado       BOOLEAN,
    nombre_feriado   VARCHAR(60),
    semana_iso       TINYINT,
    mes              TINYINT,
    nombre_mes       VARCHAR(12),
    anio_mes         VARCHAR(7),         -- '2025-07', para ejes de gráficos
    trimestre        TINYINT,
    semestre         TINYINT,
    anio             SMALLINT
);

-- ---------------------------------------------------------------------
-- 2. DIM_PUESTO_CONTROL — dimensión conformada. SCD tipo 1.
--    Fuente: catálogo de puestos (Excel). Una corrección de ciudad o
--    departamento sobrescribe el valor anterior (error de carga).
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_puesto_control (
    sk_puesto          INTEGER PRIMARY KEY,
    nk_puesto          VARCHAR(20) NOT NULL UNIQUE,   -- ej. 'PC-CDE-PA'
    nombre_puesto      VARCHAR(100) NOT NULL,
    tipo_puesto        VARCHAR(15) NOT NULL,          -- AÉREO / TERRESTRE / FLUVIAL
    ciudad             VARCHAR(60) NOT NULL,
    departamento       VARCHAR(60) NOT NULL,
    pais_limitrofe     VARCHAR(40) NOT NULL,          -- 'Brasil', 'Argentina', 'Bolivia', 'N/A (aéreo)'
    dotacion_personal  SMALLINT,
    latitud            DECIMAL(9,6),
    longitud           DECIMAL(9,6),
    dw_id_ejecucion    BIGINT,
    dw_fecha_carga     TIMESTAMP,
    dw_archivo_origen  VARCHAR
);

-- ---------------------------------------------------------------------
-- 3. DIM_VIAJERO — dimensión conformada. SCD tipo 2.
--    La categoría migratoria cambia con el tiempo (turista -> residente
--    temporal -> residente permanente). Cada cambio genera una fila nueva;
--    el hecho apunta a la versión vigente en la fecha del cruce (P6).
--    Sin nombres ni números de documento: solo código seudónimo.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_viajero (
    sk_viajero              INTEGER PRIMARY KEY,
    nk_viajero              VARCHAR(20) NOT NULL,     -- código seudónimo, ej. 'VJ-004512'
    rango_etario            VARCHAR(15) NOT NULL,     -- '18-29', '30-44', '45-59', '60+', 'Menor'
    categoria_migratoria    VARCHAR(30) NOT NULL,     -- TURISTA / RESIDENTE TEMPORAL / RESIDENTE PERMANENTE / NACIONAL
    fecha_inicio_vigencia   DATE NOT NULL,
    fecha_fin_vigencia      DATE NOT NULL,            -- 9999-12-31 = versión actual
    es_vigente              BOOLEAN NOT NULL,
    nro_version             SMALLINT NOT NULL,
    dw_id_ejecucion         BIGINT,
    dw_fecha_carga          TIMESTAMP,
    dw_archivo_origen       VARCHAR,
    UNIQUE (nk_viajero, nro_version)
);

-- ---------------------------------------------------------------------
-- 4. DIM_PAIS — dimensión conformada (nacionalidad del viajero).
--    Uso solo descriptivo: el riesgo NUNCA se mide por nacionalidad.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_pais (
    sk_pais          INTEGER PRIMARY KEY,
    nk_pais          VARCHAR(3) NOT NULL UNIQUE,      -- código ISO 3166-1 alfa-3
    nombre_pais      VARCHAR(60) NOT NULL,
    region           VARCHAR(40) NOT NULL,            -- América del Sur, Europa, Asia...
    es_mercosur      BOOLEAN NOT NULL,                -- miembro pleno o asociado
    es_limitrofe     BOOLEAN NOT NULL                 -- limita con Paraguay
);

-- ---------------------------------------------------------------------
-- 5. DIM_DOCUMENTO — dimensión conformada. Combina tipo y estado del
--    documento presentado (P4). Catálogo estático.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_documento (
    sk_documento      INTEGER PRIMARY KEY,
    nk_documento      VARCHAR(10) NOT NULL UNIQUE,    -- ej. 'PAS-ROB'
    tipo_documento    VARCHAR(40) NOT NULL,           -- Pasaporte, Cédula de identidad MERCOSUR...
    estado_documento  VARCHAR(15) NOT NULL,           -- VIGENTE, VENCIDO, EXTRAVIADO, ROBADO, ADULTERADO
    es_observado      BOOLEAN NOT NULL                -- TRUE si el estado no es VIGENTE
);

-- ---------------------------------------------------------------------
-- 6. DIM_MOTIVO — motivo de viaje declarado (P6, P7). Catálogo estático.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_motivo (
    sk_motivo         INTEGER PRIMARY KEY,
    nk_motivo         VARCHAR(5) NOT NULL UNIQUE,     -- TUR, NEG, TRA, TRB, EST, RES
    motivo_viaje      VARCHAR(30) NOT NULL,
    plazo_referencia_dias SMALLINT                    -- plazo habitual del motivo (informativo)
);

-- ---------------------------------------------------------------------
-- 7. DIM_TIPO_ALERTA — tipo de alerta, nivel de riesgo y organismo
--    emisor (P2, P3). Catálogo estático.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_tipo_alerta (
    sk_tipo_alerta    INTEGER PRIMARY KEY,
    nk_tipo_alerta    VARCHAR(10) NOT NULL UNIQUE,    -- ej. 'INT-SLTD'
    tipo_alerta       VARCHAR(80) NOT NULL,
    nivel_riesgo      VARCHAR(10) NOT NULL,           -- BAJO / MEDIO / ALTO / CRÍTICO
    orden_nivel       TINYINT NOT NULL,               -- 1 a 4, para ordenar en gráficos
    organismo_emisor  VARCHAR(80) NOT NULL,
    ambito_emisor     VARCHAR(15) NOT NULL            -- NACIONAL / INTERNACIONAL
);

-- ---------------------------------------------------------------------
-- 8. DIM_TRANSPORTE — medio de transporte del cruce. Catálogo estático.
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_transporte (
    sk_transporte     INTEGER PRIMARY KEY,
    nk_transporte     VARCHAR(5) NOT NULL UNIQUE,     -- AER, TPA, OMN, FLU, PIE
    medio_transporte  VARCHAR(30) NOT NULL,
    via               VARCHAR(15) NOT NULL            -- AÉREA / TERRESTRE / FLUVIAL
);

-- ---------------------------------------------------------------------
-- 9. FACT_MOVIMIENTO_MIGRATORIO — hechos principales (~50.000 filas).
--    Grano: un viajero, en un puesto, en un sentido, en una fecha y hora.
--    Fuente: CSV del sistema de control fronterizo.
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_movimiento_migratorio (
    -- Dimensión degenerada (clave del sistema fuente; evita duplicados)
    dd_id_movimiento        VARCHAR(20) PRIMARY KEY,

    -- Claves foráneas a las dimensiones (nunca NULL: se usa -1)
    sk_tiempo               INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_tiempo (sk_tiempo),
    sk_puesto               INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_puesto_control (sk_puesto),
    sk_viajero              INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_viajero (sk_viajero),
    sk_pais                 INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_pais (sk_pais),
    sk_documento            INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_documento (sk_documento),
    sk_motivo               INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_motivo (sk_motivo),
    sk_transporte           INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_transporte (sk_transporte),

    -- Atributos degenerados
    sentido                 VARCHAR(7) NOT NULL CHECK (sentido IN ('ENTRADA', 'SALIDA')),
    fecha_hora_movimiento   TIMESTAMP NOT NULL,       -- para ventanas de 30 días (P5)

    -- Métricas
    cantidad_movimientos    SMALLINT NOT NULL DEFAULT 1, -- aditiva (siempre 1)
    minutos_control         DECIMAL(6,1),             -- aditiva: duración del control
    plazo_autorizado_dias   SMALLINT,                 -- no aditiva: plazo otorgado al ingresar
    dias_permanencia        SMALLINT,                 -- semi-aditiva: en SALIDA, días desde su ENTRADA
    dias_excedidos          SMALLINT,                 -- aditiva: max(0, permanencia - plazo)
    ind_permanencia_excedida TINYINT NOT NULL DEFAULT 0 CHECK (ind_permanencia_excedida IN (0, 1)),
    ind_alerta              TINYINT NOT NULL DEFAULT 0 CHECK (ind_alerta IN (0, 1)),

    -- Linaje
    dw_id_ejecucion         BIGINT,
    dw_fecha_carga          TIMESTAMP,
    dw_archivo_origen       VARCHAR
);

-- ---------------------------------------------------------------------
-- 10. FACT_ALERTA — hechos secundarios (~2.000 filas).
--     Grano: una alerta emitida sobre un viajero en un movimiento.
--     Fuente: JSON del servicio de alertas.
--     Comparte dimensiones conformadas con fact_movimiento_migratorio
--     (tiempo, puesto, viajero, país, documento) -> drill-across (P3, P4).
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_alerta (
    dd_id_alerta            VARCHAR(20) PRIMARY KEY,
    dd_id_movimiento        VARCHAR(20),              -- movimiento que disparó la alerta (puede ser NULL)

    sk_tiempo               INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_tiempo (sk_tiempo),
    sk_puesto               INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_puesto_control (sk_puesto),
    sk_viajero              INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_viajero (sk_viajero),
    sk_pais                 INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_pais (sk_pais),
    sk_documento            INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_documento (sk_documento),
    sk_tipo_alerta          INTEGER NOT NULL DEFAULT -1 REFERENCES dw.dim_tipo_alerta (sk_tipo_alerta),

    resultado_inspeccion    VARCHAR(30),              -- degenerado: SIN INSPECCIÓN / DESCARTADA / CONFIRMADA / RECHAZO DE INGRESO

    -- Métricas
    cantidad_alertas        SMALLINT NOT NULL DEFAULT 1,
    ind_inspeccion_secundaria TINYINT NOT NULL DEFAULT 0 CHECK (ind_inspeccion_secundaria IN (0, 1)),
    ind_confirmada          TINYINT NOT NULL DEFAULT 0 CHECK (ind_confirmada IN (0, 1)),
    ind_rechazo_ingreso     TINYINT NOT NULL DEFAULT 0 CHECK (ind_rechazo_ingreso IN (0, 1)),
    minutos_inspeccion      DECIMAL(6,1),

    dw_id_ejecucion         BIGINT,
    dw_fecha_carga          TIMESTAMP,
    dw_archivo_origen       VARCHAR
);

-- ---------------------------------------------------------------------
-- 11. Miembro NO DEFINIDO (sk = -1) en cada dimensión
-- ---------------------------------------------------------------------
INSERT INTO dw.dim_tiempo VALUES
    (-1, NULL, NULL, 'NO DEFINIDO', NULL, NULL, 'NO DEF.', NULL, NULL, NULL,
     NULL, NULL, 'NO DEFINIDO', 'NO DEF.', NULL, NULL, NULL);
INSERT INTO dw.dim_puesto_control VALUES
    (-1, 'NO DEFINIDO', 'NO DEFINIDO', 'NO DEFINIDO', 'NO DEFINIDO', 'NO DEFINIDO',
     'NO DEFINIDO', NULL, NULL, NULL, 0, now(), 'miembro_no_definido');
INSERT INTO dw.dim_viajero VALUES
    (-1, 'NO DEFINIDO', 'NO DEFINIDO', 'NO DEFINIDO', DATE '1900-01-01', DATE '9999-12-31',
     TRUE, 1, 0, now(), 'miembro_no_definido');
INSERT INTO dw.dim_pais          VALUES (-1, 'ND', 'NO DEFINIDO', 'NO DEFINIDO', FALSE, FALSE);
INSERT INTO dw.dim_documento     VALUES (-1, 'ND', 'NO DEFINIDO', 'NO DEFINIDO', FALSE);
INSERT INTO dw.dim_motivo        VALUES (-1, 'ND', 'NO DEFINIDO', NULL);
INSERT INTO dw.dim_tipo_alerta   VALUES (-1, 'ND', 'NO DEFINIDO', 'NO DEF.', 0, 'NO DEFINIDO', 'NO DEFINIDO');
INSERT INTO dw.dim_transporte    VALUES (-1, 'ND', 'NO DEFINIDO', 'NO DEFINIDO');

-- Verificación: 10 tablas en el esquema dw
SELECT table_name, estimated_size AS filas
FROM duckdb_tables()
WHERE schema_name = 'dw'
ORDER BY table_name;
