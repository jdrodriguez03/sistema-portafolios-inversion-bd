-- =====================================================================
-- concurrencia/sesion_sin_bloqueo.sql   (CASO 1: anomalia)
-- Se ejecuta dos veces en paralelo:
--   psql -v sesion=A -v espera=0 -f sesion_sin_bloqueo.sql
--   psql -v sesion=B -v espera=1 -f sesion_sin_bloqueo.sql
-- Cada sesion quiere comprar por 700 USD. Saldo inicial: 1000 USD.
-- =====================================================================
\set QUIET on
\pset pager off
\pset tuples_only on
SELECT pg_sleep(:espera);

BEGIN;
-- 1. La aplicacion lee el saldo (lectura normal, sin bloqueo)
SELECT saldo AS saldo_leido FROM demo.cuenta_sin_control WHERE id = 1 \gset
SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS t \gset
\echo [:t] Sesion :sesion lee saldo = :saldo_leido

-- 2. La aplicacion valida en su codigo: 700 <= saldo leido
SELECT CASE WHEN :saldo_leido >= 700 THEN 'APROBADA' ELSE 'RECHAZADA' END AS decision \gset
\echo [:t] Sesion :sesion valida la compra de 700: :decision

-- 3. Tiempo de procesamiento (la otra sesion trabaja en paralelo)
SELECT pg_sleep(2);

-- 4. Escribe el nuevo saldo calculado con el valor que leyo
UPDATE demo.cuenta_sin_control SET saldo = :saldo_leido - 700 WHERE id = 1;
INSERT INTO demo.compra_sin_control (sesion, monto) VALUES (:'sesion', 700);
COMMIT;
SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS t \gset
\echo [:t] Sesion :sesion COMMIT. Escribio saldo = :saldo_leido - 700
