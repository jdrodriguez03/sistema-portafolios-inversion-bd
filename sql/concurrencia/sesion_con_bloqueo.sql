-- =====================================================================
-- concurrencia/sesion_con_bloqueo.sql   (CASO 2: solucion con FOR UPDATE)
-- Se ejecuta dos veces en paralelo sobre la tabla REAL:
--   psql -v sesion=A -v espera=0 -f sesion_con_bloqueo.sql
--   psql -v sesion=B -v espera=1 -f sesion_con_bloqueo.sql
-- Ambas sesiones compran SPY por ~60 % del saldo de la misma cuenta:
-- alcanza para una compra, no para dos.
-- =====================================================================
\set QUIET on
\pset pager off
\pset tuples_only on
\set ON_ERROR_STOP off

-- Parametros (ambas sesiones calculan lo mismo: solo ven datos confirmados)
SELECT c.id_cuenta AS cta, af.id_activo AS act, fn_precio(af.id_activo) AS precio,
       FLOOR(c.saldo_efectivo * 0.60 / (fn_precio(af.id_activo) * 1.005)) AS cant,
       c.saldo_efectivo AS saldo_inicial
FROM cuenta c CROSS JOIN accion_fondo af
WHERE c.estado = 'ACTIVA' AND af.ticker = 'SPY'
ORDER BY c.saldo_efectivo DESC, c.id_cuenta LIMIT 1 \gset

SELECT pg_sleep(:espera);
SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS t \gset
\echo [:t] Sesion :sesion inicia: compra de :cant SPY a :precio en la cuenta :cta (saldo confirmado :saldo_inicial)

BEGIN;
-- El trigger trg_transaccion_validar ejecuta SELECT ... FOR UPDATE sobre
-- la cuenta. Si otra sesion la tiene bloqueada, esta instruccion ESPERA.
INSERT INTO transaccion (id_cuenta, id_activo, tipo_transaccion, cantidad, precio_unitario)
VALUES (:cta, :act, 'COMPRA', :cant, :precio);

\if :ERROR
    \set motivo :LAST_ERROR_MESSAGE
    ROLLBACK;
    SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS t \gset
    \echo [:t] Sesion :sesion RECHAZADA tras esperar el bloqueo. Motivo: :motivo
    \echo [:t] Sesion :sesion ROLLBACK
\else
    SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS t \gset
    SELECT saldo_efectivo AS saldo_visto FROM cuenta WHERE id_cuenta = :cta \gset
    \echo [:t] Sesion :sesion compra aceptada. Saldo dentro de su transaccion = :saldo_visto
    -- Tiempo de procesamiento antes de confirmar (mantiene el bloqueo)
    SELECT pg_sleep(3);
    COMMIT;
    SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS t \gset
    \echo [:t] Sesion :sesion COMMIT (libera el bloqueo)
\endif
