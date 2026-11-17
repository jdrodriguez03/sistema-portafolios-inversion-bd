-- =====================================================================
-- concurrencia/00_preparar.sql
-- Prepara la demostracion de concurrencia.
--
-- Escenario: dos asesores registran al mismo tiempo una compra sobre la
-- misma cuenta. El saldo alcanza para UNA compra, no para dos.
--
-- Caso 1 (sesion_sin_bloqueo.sql): una tabla de demostracion sin
--   control, donde la "aplicacion" lee el saldo, valida y luego escribe.
--   Ambas sesiones leen el mismo saldo, ambas aprueban y una escritura
--   pisa a la otra: ACTUALIZACION PERDIDA (lost update). Se aprueban dos
--   compras con dinero para una.
--
-- Caso 2 (sesion_con_bloqueo.sql): la tabla real. El trigger de la
--   compra bloquea la fila de la cuenta con SELECT ... FOR UPDATE. La
--   segunda sesion espera a que la primera confirme, relee el saldo ya
--   descontado y es rechazada por saldo insuficiente.
--
-- Ambos casos corren en READ COMMITTED (nivel por defecto de PostgreSQL).
-- =====================================================================
DROP SCHEMA IF EXISTS demo CASCADE;
CREATE SCHEMA demo;

-- Cuenta de demostracion SIN triggers ni bloqueos (simula una aplicacion
-- que valida el saldo en su propio codigo)
CREATE TABLE demo.cuenta_sin_control (
    id    INTEGER PRIMARY KEY,
    saldo NUMERIC(15,2) NOT NULL
);
INSERT INTO demo.cuenta_sin_control VALUES (1, 1000.00);

CREATE TABLE demo.compra_sin_control (
    id      SERIAL PRIMARY KEY,
    sesion  TEXT,
    monto   NUMERIC(15,2),
    momento TIMESTAMP DEFAULT clock_timestamp()
);
