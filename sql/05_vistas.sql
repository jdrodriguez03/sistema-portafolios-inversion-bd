-- =====================================================================
-- 05_vistas.sql
-- Vistas reutilizables. Se ejecuta despues de cargar los datos (solo
-- por orden logico: las vistas no dependen de los datos).
--
--   v_tenencia               cantidad neta por cuenta y activo
--   v_posicion_actual        posiciones valoradas hoy en USD
--   v_portafolio_cliente     composicion por cliente (incluye efectivo)
--   v_cumplimiento_perfil    control del limite de renta variable
--   v_vencimientos_renta_fija CDT y TES vigentes con dias al vencimiento
-- =====================================================================

DROP VIEW IF EXISTS v_vencimientos_renta_fija, v_cumplimiento_perfil,
                    v_portafolio_cliente, v_posicion_actual, v_tenencia CASCADE;

-- ---------------------------------------------------------------------
-- v_tenencia: lo que cada cuenta posee de cada activo.
-- La tenencia no es una tabla: se deriva de las transacciones, asi no
-- puede contradecir al historial (Regla 11).
-- ---------------------------------------------------------------------
CREATE VIEW v_tenencia AS
SELECT t.id_cuenta,
       t.id_activo,
       SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) AS cantidad
FROM transaccion t
GROUP BY t.id_cuenta, t.id_activo
HAVING SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) > 0;

-- ---------------------------------------------------------------------
-- v_posicion_actual: cada posicion con su valor en USD al dia de hoy
-- (precio mas reciente para renta variable; capitalizacion a la tasa
-- pactada y TRM para renta fija). Base de las preguntas 1, 3, 4 y 8.
-- ---------------------------------------------------------------------
CREATE VIEW v_posicion_actual AS
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       cu.id_cuenta,
       cu.nombre_cuenta,
       a.id_activo,
       a.nombre       AS activo,
       ta.nombre_tipo AS tipo_activo,
       ta.clase_activo,
       p.cantidad,
       p.valor_usd
FROM fn_posiciones(CURRENT_DATE) p
JOIN cuenta      cu ON cu.id_cuenta      = p.id_cuenta
JOIN cliente     cl ON cl.id_cliente     = cu.id_cliente
JOIN activo      a  ON a.id_activo       = p.id_activo
JOIN tipo_activo ta ON ta.id_tipo_activo = a.id_tipo_activo;

-- ---------------------------------------------------------------------
-- v_portafolio_cliente: valor y porcentaje por categoria para cada
-- cliente. El efectivo cuenta como una categoria mas del portafolio.
-- El porcentaje se calcula con una funcion de ventana.
-- ---------------------------------------------------------------------
CREATE VIEW v_portafolio_cliente AS
WITH componentes AS (
    SELECT pa.id_cliente, pa.tipo_activo AS categoria, SUM(pa.valor_usd) AS valor_usd
    FROM v_posicion_actual pa
    GROUP BY pa.id_cliente, pa.tipo_activo
    UNION ALL
    SELECT cu.id_cliente, 'EFECTIVO', SUM(cu.saldo_efectivo)
    FROM cuenta cu
    GROUP BY cu.id_cliente
)
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       co.categoria,
       co.valor_usd,
       ROUND(100 * co.valor_usd
             / NULLIF(SUM(co.valor_usd) OVER (PARTITION BY cl.id_cliente), 0), 2) AS porcentaje
FROM componentes co
JOIN cliente cl ON cl.id_cliente = co.id_cliente;

-- ---------------------------------------------------------------------
-- v_cumplimiento_perfil (Regla 2, Pregunta 3)
-- Compara el % en renta variable (acciones + fondos) con el limite del
-- perfil. Es una vista de control y no un bloqueo en la compra porque el
-- porcentaje cambia con los precios aunque el cliente no opere.
-- ---------------------------------------------------------------------
CREATE VIEW v_cumplimiento_perfil AS
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       pr.nombre_perfil,
       pr.limite_max_renta_var           AS limite_pct,
       COALESCE(SUM(pc.valor_usd), 0)    AS valor_total_usd,
       COALESCE(SUM(pc.valor_usd) FILTER (WHERE pc.categoria IN ('ACCION', 'FONDO')), 0)
                                         AS valor_renta_variable_usd,
       COALESCE(ROUND(100 * SUM(pc.valor_usd) FILTER (WHERE pc.categoria IN ('ACCION', 'FONDO'))
                      / NULLIF(SUM(pc.valor_usd), 0), 2), 0) AS pct_renta_variable,
       CASE WHEN COALESCE(100 * SUM(pc.valor_usd) FILTER (WHERE pc.categoria IN ('ACCION', 'FONDO'))
                          / NULLIF(SUM(pc.valor_usd), 0), 0) <= pr.limite_max_renta_var
            THEN 'CUMPLE' ELSE 'EXCEDE' END AS estado
FROM cliente cl
JOIN perfil_riesgo pr ON pr.id_perfil = cl.id_perfil
LEFT JOIN v_portafolio_cliente pc ON pc.id_cliente = cl.id_cliente
GROUP BY cl.id_cliente, cl.nombres, cl.apellidos, pr.nombre_perfil, pr.limite_max_renta_var;

-- ---------------------------------------------------------------------
-- v_vencimientos_renta_fija (Pregunta 4)
-- CDT y TES que los clientes aun poseen, con dias al vencimiento.
-- ---------------------------------------------------------------------
CREATE VIEW v_vencimientos_renta_fija AS
SELECT pa.id_cliente,
       pa.cliente,
       ase.nombres || ' ' || ase.apellidos AS asesor,
       pa.id_cuenta,
       pa.activo,
       pa.tipo_activo,
       rf.fecha_vencimiento,
       rf.fecha_vencimiento - CURRENT_DATE AS dias_al_vencimiento,
       pa.valor_usd                        AS valor_actual_usd
FROM v_posicion_actual pa
JOIN (SELECT c.id_activo, c.fecha_vencimiento FROM cdt c
      UNION ALL
      SELECT s.id_activo, s.fecha_vencimiento FROM tes s) rf ON rf.id_activo = pa.id_activo
JOIN cliente cl  ON cl.id_cliente = pa.id_cliente
JOIN asesor  ase ON ase.id_asesor = cl.id_asesor;
