-- =====================================================================
-- 07_optimizacion.sql
-- Pruebas de optimizacion con EXPLAIN (ANALYZE, BUFFERS).
--
-- Las pruebas se hacen en el esquema "opt" con COPIAS de las tablas, para
-- no alterar los datos ni los indices de la base real. Al final el
-- esquema se elimina.
--
--   Prueba 1: valoracion de posiciones con el precio mas reciente
--             (diseno preliminar con id_precio vs. clave (id_activo, fecha))
--   Prueba 2: historial de transacciones de un cliente (Pregunta 7)
--             con volumen ampliado, sin y con indice (id_cuenta, fecha_hora)
--   Prueba 3: hipotesis RECHAZADA: indice sobre tipo_transaccion
--             (columna de baja selectividad, Pregunta 9)
-- =====================================================================
\pset pager off
-- Sin paralelismo: en Windows el arranque de procesos paralelos agrega
-- variaciones de tiempo que no dependen del plan. Asi las mediciones
-- antes/despues son comparables.
SET max_parallel_workers_per_gather = 0;

DROP SCHEMA IF EXISTS opt CASCADE;
CREATE SCHEMA opt;

-- =====================================================================
-- PRUEBA 1. Precio mas reciente por posicion
-- ---------------------------------------------------------------------
-- Consulta: valor actual de cada posicion de renta variable (base de la
-- Pregunta 1). Para cada par (cuenta, activo) busca el ultimo cierre.
--
-- Escenario ANTES: el diseno preliminar (diagrama inicial) tenia
-- precio_historico con clave sustituta id_precio y sin indice sobre
-- (id_activo, fecha). Se recrea esa tabla en opt.precio_preliminar.
--
-- Hipotesis: buscar "el ultimo precio de un activo" exige filtrar por
-- id_activo y ordenar por fecha. Sin un indice que tenga ese orden, el
-- motor recorre y ordena la tabla completa UNA VEZ POR POSICION. Un
-- indice B-tree (id_activo, fecha) permite saltar al activo y leer la
-- fecha mas reciente directamente (Index Scan Backward + Limit).
-- Es exactamente la clave primaria compuesta del diseno final.
-- =====================================================================
\echo
\echo '=============================================================='
\echo 'PRUEBA 1 - ANTES: diseno preliminar (PK id_precio, sin indice por activo y fecha)'
\echo '=============================================================='
CREATE TABLE opt.precio_preliminar (
    id_precio     SERIAL PRIMARY KEY,
    id_activo     INTEGER NOT NULL,
    fecha         DATE    NOT NULL,
    precio_cierre NUMERIC(15,4) NOT NULL
);
INSERT INTO opt.precio_preliminar (id_activo, fecha, precio_cierre)
SELECT id_activo, fecha, precio_cierre FROM precio_historico ORDER BY random();
ANALYZE opt.precio_preliminar;
SELECT COUNT(*) AS filas_precio FROM opt.precio_preliminar;

-- Calentamiento (para que ambas mediciones partan con la tabla en cache)
SELECT COUNT(*) FROM opt.precio_preliminar;

EXPLAIN (ANALYZE, BUFFERS, COSTS)
WITH tenencia AS (
    SELECT t.id_cuenta, t.id_activo,
           SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) AS cantidad
    FROM transaccion t
    JOIN accion_fondo af ON af.id_activo = t.id_activo
    GROUP BY t.id_cuenta, t.id_activo
    HAVING SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) > 0
)
SELECT te.id_cuenta, te.id_activo, te.cantidad,
       te.cantidad * (SELECT p.precio_cierre
                      FROM opt.precio_preliminar p
                      WHERE p.id_activo = te.id_activo
                      ORDER BY p.fecha DESC
                      LIMIT 1) AS valor_usd
FROM tenencia te;

\echo
\echo '=============================================================='
\echo 'PRUEBA 1 - DESPUES: indice B-tree (id_activo, fecha) = PK del diseno final'
\echo '=============================================================='
CREATE INDEX ix_opt_precio_activo_fecha ON opt.precio_preliminar (id_activo, fecha);
ANALYZE opt.precio_preliminar;

EXPLAIN (ANALYZE, BUFFERS, COSTS)
WITH tenencia AS (
    SELECT t.id_cuenta, t.id_activo,
           SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) AS cantidad
    FROM transaccion t
    JOIN accion_fondo af ON af.id_activo = t.id_activo
    GROUP BY t.id_cuenta, t.id_activo
    HAVING SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) > 0
)
SELECT te.id_cuenta, te.id_activo, te.cantidad,
       te.cantidad * (SELECT p.precio_cierre
                      FROM opt.precio_preliminar p
                      WHERE p.id_activo = te.id_activo
                      ORDER BY p.fecha DESC
                      LIMIT 1) AS valor_usd
FROM tenencia te;


-- =====================================================================
-- PRUEBA 2. Historial de transacciones de un cliente (Pregunta 7)
-- ---------------------------------------------------------------------
-- Con los datos actuales (~1 500 transacciones) cualquier plan es rapido.
-- Para evaluar el comportamiento cuando la firma crezca se crea una
-- copia ampliada (x150): mismas cuentas, operaciones desplazadas en el
-- tiempo. La copia no tiene indices ni triggers.
--
-- Hipotesis: la consulta filtra por id_cuenta (pocas cuentas por cliente,
-- alta selectividad: ~1/80 de las filas) y ordena por fecha_hora. Sin
-- indice el motor lee toda la tabla y ordena. Un indice compuesto
-- (id_cuenta, fecha_hora) permite leer solo las filas de esas cuentas y
-- ya en orden de fecha, eliminando el recorrido completo.
-- =====================================================================
\echo
\echo '=============================================================='
\echo 'PRUEBA 2 - ANTES: copia ampliada de transaccion sin indice'
\echo '=============================================================='
CREATE TABLE opt.transaccion AS
SELECT ROW_NUMBER() OVER () AS id_transaccion,
       t.id_cuenta, t.id_activo, t.tipo_transaccion,
       t.fecha_hora - (g * INTERVAL '7 days') AS fecha_hora,
       t.cantidad, t.precio_unitario, t.monto, t.comision
FROM transaccion t
CROSS JOIN generate_series(0, 149) AS g;
ANALYZE opt.transaccion;
SELECT COUNT(*) AS filas_transaccion_ampliada FROM opt.transaccion;
SELECT COUNT(*) FROM opt.transaccion;   -- calentamiento

-- Cliente con mas operaciones (se fija en una variable de psql)
SELECT cu.id_cliente AS cliente_prueba
FROM transaccion t JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
GROUP BY cu.id_cliente ORDER BY COUNT(*) DESC, cu.id_cliente LIMIT 1 \gset
\echo 'Cliente de prueba:' :cliente_prueba

EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT t.fecha_hora, t.id_cuenta, t.tipo_transaccion, t.id_activo, t.cantidad, t.monto, t.comision
FROM opt.transaccion t
JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
WHERE cu.id_cliente = :cliente_prueba
ORDER BY t.id_cuenta, t.fecha_hora;

\echo
\echo '=============================================================='
\echo 'PRUEBA 2 - DESPUES: indice compuesto (id_cuenta, fecha_hora)'
\echo '=============================================================='
CREATE INDEX ix_opt_transaccion_cuenta_fecha ON opt.transaccion (id_cuenta, fecha_hora);
ANALYZE opt.transaccion;

EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT t.fecha_hora, t.id_cuenta, t.tipo_transaccion, t.id_activo, t.cantidad, t.monto, t.comision
FROM opt.transaccion t
JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
WHERE cu.id_cliente = :cliente_prueba
ORDER BY t.id_cuenta, t.fecha_hora;


-- =====================================================================
-- PRUEBA 3. Hipotesis que se RECHAZA (indice poco selectivo)
-- ---------------------------------------------------------------------
-- Consulta: monto comprado por activo (base de la Pregunta 9, solo
-- compras).
-- Hipotesis: un indice sobre tipo_transaccion aceleraria el filtro
-- tipo_transaccion = 'COMPRA'.
-- Prediccion: la columna solo tiene dos valores y la mayoria de filas son
-- compras (baja selectividad). Leer el indice y luego casi todas las
-- paginas de la tabla cuesta mas que un recorrido secuencial, asi que el
-- planificador lo ignorara. Si se confirma, el indice NO se crea en la
-- base real (ocuparia espacio y haria mas lentas las escrituras).
-- =====================================================================
\echo
\echo '=============================================================='
\echo 'PRUEBA 3 - ANTES: sin indice por tipo_transaccion'
\echo '=============================================================='
SELECT tipo_transaccion, COUNT(*) AS filas,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM opt.transaccion GROUP BY tipo_transaccion;

EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT t.id_activo, COUNT(*) AS compras, SUM(t.monto) AS monto_usd
FROM opt.transaccion t
WHERE t.tipo_transaccion = 'COMPRA'
GROUP BY t.id_activo;

\echo
\echo '=============================================================='
\echo 'PRUEBA 3 - DESPUES: indice sobre tipo_transaccion'
\echo '=============================================================='
CREATE INDEX ix_opt_transaccion_tipo ON opt.transaccion (tipo_transaccion);
ANALYZE opt.transaccion;

EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT t.id_activo, COUNT(*) AS compras, SUM(t.monto) AS monto_usd
FROM opt.transaccion t
WHERE t.tipo_transaccion = 'COMPRA'
GROUP BY t.id_activo;

\echo
\echo '--- Control: forzando el uso del indice (solo para comparar) ---'
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS)
SELECT t.id_activo, COUNT(*) AS compras, SUM(t.monto) AS monto_usd
FROM opt.transaccion t
WHERE t.tipo_transaccion = 'COMPRA'
GROUP BY t.id_activo;
RESET enable_seqscan;

\echo
\echo '--- Tamano de los indices creados en la prueba ---'
SELECT indexrelname AS indice, pg_size_pretty(pg_relation_size(indexrelid)) AS tamano
FROM pg_stat_user_indexes WHERE schemaname = 'opt' ORDER BY 1;

-- ---------------------------------------------------------------------
-- Aplicacion a la base real
-- ---------------------------------------------------------------------
-- Prueba 1: el diseno final ya tiene PRIMARY KEY (id_activo, fecha) en
--           precio_historico; no hace falta crear nada.
-- Prueba 2: se crea el indice en la tabla real, pensando en el
--           crecimiento. Lo usan el historial (C07), fn_tenencia (en cada
--           venta) y fn_efectivo.
-- Prueba 3: no se crea indice sobre tipo_transaccion.
\echo
\echo '--- Indice aplicado a la base real ---'
CREATE INDEX IF NOT EXISTS ix_transaccion_cuenta_fecha ON transaccion (id_cuenta, fecha_hora);
ANALYZE transaccion;

DROP SCHEMA opt CASCADE;
