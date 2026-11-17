-- =====================================================================
-- 08_transacciones.sql
-- Transacciones y propiedades ACID sobre la operacion de compra.
--
-- La compra es una operacion de varias acciones que deben ocurrir juntas:
--   1. bloquear la cuenta y validar el saldo (monto + comision)
--   2. registrar la transaccion (con su comision generada)
--   3. descontar el efectivo de la cuenta
-- Si cualquiera falla, ninguna debe quedar aplicada.
--
-- El escenario de concurrencia (dos sesiones simultaneas) esta en
-- sql/concurrencia/ y lo ejecuta run_all.ps1 (paso "concurrencia").
-- =====================================================================
\pset pager off
\set ON_ERROR_STOP off

-- Cuenta de prueba: la cuenta activa con mayor saldo. Activo: SPY.
SELECT id_cuenta AS cta FROM cuenta WHERE estado = 'ACTIVA'
ORDER BY saldo_efectivo DESC, id_cuenta LIMIT 1 \gset
SELECT id_activo AS spy FROM accion_fondo WHERE ticker = 'SPY' \gset
\echo 'Cuenta de prueba:' :cta '  Activo (SPY):' :spy

-- =====================================================================
-- A1. Transaccion exitosa: aporte de efectivo + compra (COMMIT)
-- Atomicidad y durabilidad: o quedan ambas operaciones o ninguna; tras el
-- COMMIT quedan registradas en el WAL y sobreviven a un reinicio.
-- =====================================================================
\echo
\echo '=== A1. Aporte + compra en una sola transaccion (COMMIT) ==='
SELECT id_cuenta, saldo_efectivo AS saldo_antes FROM cuenta WHERE id_cuenta = :cta;

BEGIN;
INSERT INTO movimiento_efectivo (id_cuenta, tipo_movimiento, monto)
VALUES (:cta, 'DEPOSITO', 1000.00);

CALL sp_registrar_compra(:cta, :spy, 1);

-- Dentro de la transaccion ya se ven los cambios (para esta sesion)
SELECT saldo_efectivo AS saldo_dentro_de_la_transaccion FROM cuenta WHERE id_cuenta = :cta;
COMMIT;

SELECT id_cuenta, saldo_efectivo AS saldo_despues FROM cuenta WHERE id_cuenta = :cta;
SELECT id_transaccion, tipo_transaccion, cantidad, precio_unitario, monto, comision, fecha_hora
FROM transaccion WHERE id_cuenta = :cta ORDER BY id_transaccion DESC LIMIT 1;

-- =====================================================================
-- A2. Atomicidad ante un fallo: el deposito se deshace si la compra falla
-- El trigger lanza una excepcion (saldo insuficiente), la transaccion
-- queda abortada y el ROLLBACK revierte TAMBIEN el deposito previo.
-- =====================================================================
\echo
\echo '=== A2. Deposito + compra imposible: se revierte todo (ROLLBACK) ==='
SELECT saldo_efectivo AS saldo_antes,
       (SELECT COUNT(*) FROM movimiento_efectivo WHERE id_cuenta = :cta) AS movimientos_antes
FROM cuenta WHERE id_cuenta = :cta \gset
\echo 'Saldo antes:' :saldo_antes '  Movimientos antes:' :movimientos_antes

BEGIN;
INSERT INTO movimiento_efectivo (id_cuenta, tipo_movimiento, monto)
VALUES (:cta, 'DEPOSITO', 500.00);
-- Compra que cuesta mucho mas que el saldo disponible -> ERROR del trigger
INSERT INTO transaccion (id_cuenta, id_activo, tipo_transaccion, cantidad, precio_unitario)
VALUES (:cta, :spy, 'COMPRA', 1000000, 500);
-- La transaccion ya esta abortada: cualquier instruccion falla hasta el ROLLBACK
SELECT saldo_efectivo FROM cuenta WHERE id_cuenta = :cta;
ROLLBACK;

SELECT saldo_efectivo AS saldo_despues,
       saldo_efectivo = :saldo_antes AS saldo_sin_cambios,
       (SELECT COUNT(*) FROM movimiento_efectivo WHERE id_cuenta = :cta) AS movimientos_despues
FROM cuenta WHERE id_cuenta = :cta;

-- =====================================================================
-- A3. Consistencia: las reglas impiden estados invalidos aun fuera de
-- los triggers de compra.
-- =====================================================================
\echo
\echo '=== A3. Consistencia: intentos que la base rechaza ==='
-- Editar el saldo directamente (redundancia controlada)
UPDATE cuenta SET saldo_efectivo = saldo_efectivo + 1000000 WHERE id_cuenta = :cta;
-- Borrar una transaccion del historial
DELETE FROM transaccion WHERE id_cuenta = :cta;
-- Retirar mas de lo disponible
INSERT INTO movimiento_efectivo (id_cuenta, tipo_movimiento, monto)
VALUES (:cta, 'RETIRO', 99999999);

-- =====================================================================
-- A4. Auditoria: el saldo almacenado sigue coincidiendo con el historial
-- =====================================================================
\echo
\echo '=== A4. Saldo almacenado vs. reconstruido (deben coincidir) ==='
SELECT id_cuenta, saldo_efectivo, fn_efectivo(id_cuenta) AS reconstruido,
       saldo_efectivo = fn_efectivo(id_cuenta) AS coinciden
FROM cuenta WHERE id_cuenta = :cta;

-- Nivel de aislamiento en uso
SHOW transaction_isolation;
