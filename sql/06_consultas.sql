-- =====================================================================
-- 06_consultas.sql
-- Portafolio de consultas. Cada una indica la pregunta de informacion
-- (P1..P9 del Entregable 1) que responde y las tecnicas SQL que usa.
--
--  C01 P1  Valor del portafolio por tipo ....... vista, agregacion condicional
--  C02 P2  Rentabilidad 12 meses .............. funcion, JOIN
--  C03 P3  Diversificacion vs. perfil ......... vistas, ventana (en la vista)
--  C04 P4  Vencimientos 30/60/90 .............. vista, CASE
--  C05 P5  Comisiones por asesor y mes ........ JOIN 4 tablas, GROUP BY, ventana
--  C06 P6  Mayor y menor rentabilidad ......... CTE, RANK
--  C07 P7  Historial de un cliente ............ JOIN, ventanas (SUM, LAG)
--  C08 P8  Clientes y AUM por asesor .......... CTE, LEFT JOIN, ventana
--  C09 P9  Activos mas comprados/vendidos ..... CTE, RANK con PARTITION BY
--  C10 --  Asesores sobre el promedio ......... HAVING con subconsulta
--  C11 --  Variacion mensual de precios ....... DISTINCT ON, LAG
--  C12 --  Ganancia no realizada .............. CTE, JOIN con vista
--  C13 --  Clientes sin operar en 90 dias ..... subconsulta correlacionada
--  C14 --  Activos mas difundidos ............. GROUP BY, HAVING
--  C15 --  Auditoria del saldo ................ funcion, control de integridad
-- =====================================================================


-- ---------------------------------------------------------------------
-- C01 | P1: Valor actual del portafolio de cada cliente, por tipo de activo
-- Una fila por cliente y una columna por tipo (agregacion con FILTER).
-- ---------------------------------------------------------------------
SELECT pc.id_cliente,
       pc.cliente,
       COALESCE(SUM(pc.valor_usd) FILTER (WHERE pc.categoria = 'ACCION'),   0) AS acciones_usd,
       COALESCE(SUM(pc.valor_usd) FILTER (WHERE pc.categoria = 'FONDO'),    0) AS fondos_usd,
       COALESCE(SUM(pc.valor_usd) FILTER (WHERE pc.categoria = 'CDT'),      0) AS cdt_usd,
       COALESCE(SUM(pc.valor_usd) FILTER (WHERE pc.categoria = 'TES'),      0) AS tes_usd,
       COALESCE(SUM(pc.valor_usd) FILTER (WHERE pc.categoria = 'EFECTIVO'), 0) AS efectivo_usd,
       SUM(pc.valor_usd)                                                       AS total_usd
FROM v_portafolio_cliente pc
GROUP BY pc.id_cliente, pc.cliente
ORDER BY total_usd DESC;


-- ---------------------------------------------------------------------
-- C02 | P2: Rentabilidad de cada cliente en los ultimos 12 meses
-- fn_rentabilidad_cliente descuenta los aportes del periodo.
-- ---------------------------------------------------------------------
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       pr.nombre_perfil,
       fn_rentabilidad_cliente(cl.id_cliente,
                               (CURRENT_DATE - INTERVAL '12 months')::date,
                               CURRENT_DATE) AS rentabilidad_12m_pct
FROM cliente cl
JOIN perfil_riesgo pr ON pr.id_perfil = cl.id_perfil
ORDER BY rentabilidad_12m_pct DESC NULLS LAST;


-- ---------------------------------------------------------------------
-- C03 | P3: Porcentaje del portafolio por tipo de activo y cumplimiento
--           del limite de diversificacion del perfil (Regla 2)
-- ---------------------------------------------------------------------
-- C03a. Composicion porcentual de cada cliente
SELECT pc.cliente, pc.categoria, pc.valor_usd, pc.porcentaje
FROM v_portafolio_cliente pc
ORDER BY pc.cliente, pc.porcentaje DESC;

-- C03b. Cumplimiento del limite (primero los que lo exceden)
SELECT cp.cliente, cp.nombre_perfil, cp.limite_pct, cp.pct_renta_variable,
       cp.valor_total_usd, cp.estado
FROM v_cumplimiento_perfil cp
ORDER BY cp.estado DESC, cp.pct_renta_variable DESC;


-- ---------------------------------------------------------------------
-- C04 | P4: CDT y TES que vencen en los proximos 30/60/90 dias
-- ---------------------------------------------------------------------
SELECT CASE WHEN v.dias_al_vencimiento <= 30 THEN '1. Hasta 30 dias'
            WHEN v.dias_al_vencimiento <= 60 THEN '2. De 31 a 60 dias'
            ELSE                                  '3. De 61 a 90 dias'
       END AS ventana,
       v.cliente, v.asesor, v.tipo_activo, v.activo,
       v.fecha_vencimiento, v.dias_al_vencimiento, v.valor_actual_usd
FROM v_vencimientos_renta_fija v
WHERE v.dias_al_vencimiento BETWEEN 0 AND 90
ORDER BY v.dias_al_vencimiento;


-- ---------------------------------------------------------------------
-- C05 | P5: Comisiones generadas por cada asesor, mes a mes, en los
--           ultimos 12 meses, con su acumulado
-- JOIN de 4 tablas; SUM(SUM()) OVER calcula el acumulado por asesor.
-- ---------------------------------------------------------------------
SELECT ase.id_asesor,
       ase.nombres || ' ' || ase.apellidos           AS asesor,
       DATE_TRUNC('month', t.fecha_hora)::date       AS mes,
       COUNT(*)                                      AS transacciones,
       SUM(t.comision)                               AS comision_mes_usd,
       SUM(SUM(t.comision)) OVER (PARTITION BY ase.id_asesor
                                  ORDER BY DATE_TRUNC('month', t.fecha_hora)) AS comision_acumulada_usd
FROM transaccion t
JOIN cuenta  cu  ON cu.id_cuenta  = t.id_cuenta
JOIN cliente cl  ON cl.id_cliente = cu.id_cliente
JOIN asesor  ase ON ase.id_asesor = cl.id_asesor
WHERE t.fecha_hora >= CURRENT_DATE - INTERVAL '12 months'
GROUP BY ase.id_asesor, ase.nombres, ase.apellidos, DATE_TRUNC('month', t.fecha_hora)
ORDER BY asesor, mes;


-- ---------------------------------------------------------------------
-- C06 | P6: Clientes con mayor y menor rentabilidad en el periodo
-- La CTE calcula la rentabilidad una sola vez; RANK ordena en ambos
-- sentidos y se conservan los 3 primeros de cada extremo.
-- ---------------------------------------------------------------------
WITH rentabilidad AS (
    SELECT cl.id_cliente,
           cl.nombres || ' ' || cl.apellidos AS cliente,
           fn_rentabilidad_cliente(cl.id_cliente,
                                   (CURRENT_DATE - INTERVAL '12 months')::date,
                                   CURRENT_DATE) AS rentabilidad_pct
    FROM cliente cl
),
ranking AS (
    SELECT r.*,
           RANK() OVER (ORDER BY r.rentabilidad_pct DESC) AS puesto_mayor,
           RANK() OVER (ORDER BY r.rentabilidad_pct ASC)  AS puesto_menor
    FROM rentabilidad r
    WHERE r.rentabilidad_pct IS NOT NULL
)
SELECT CASE WHEN k.puesto_mayor <= 3 THEN 'MAYOR RENTABILIDAD'
            ELSE 'MENOR RENTABILIDAD' END AS grupo,
       k.cliente,
       k.rentabilidad_pct,
       k.puesto_mayor AS puesto_general
FROM ranking k
WHERE k.puesto_mayor <= 3 OR k.puesto_menor <= 3
ORDER BY k.rentabilidad_pct DESC;


-- ---------------------------------------------------------------------
-- C07 | P7: Historial completo de compras y ventas de un cliente
-- Cambiar el id en el WHERE para consultar otro cliente.
-- Ventanas: flujo de caja acumulado y dias desde la operacion anterior.
-- ---------------------------------------------------------------------
SELECT t.fecha_hora,
       cu.nombre_cuenta,
       t.tipo_transaccion,
       ta.nombre_tipo AS tipo_activo,
       a.nombre       AS activo,
       t.cantidad,
       t.precio_unitario,
       t.monto,
       t.comision,
       SUM(CASE WHEN t.tipo_transaccion = 'COMPRA'
                THEN -(t.monto + t.comision) ELSE t.monto - t.comision END)
           OVER (ORDER BY t.fecha_hora, t.id_transaccion) AS flujo_caja_acumulado_usd,
       t.fecha_hora::date
           - LAG(t.fecha_hora::date) OVER (ORDER BY t.fecha_hora, t.id_transaccion) AS dias_desde_anterior
FROM transaccion t
JOIN cuenta      cu ON cu.id_cuenta      = t.id_cuenta
JOIN activo      a  ON a.id_activo       = t.id_activo
JOIN tipo_activo ta ON ta.id_tipo_activo = a.id_tipo_activo
WHERE cu.id_cliente = 1
ORDER BY t.fecha_hora, t.id_transaccion;


-- ---------------------------------------------------------------------
-- C08 | P8: Clientes que gestiona cada asesor y valor que administra (AUM)
-- LEFT JOIN para incluir asesores sin clientes; la ventana calcula la
-- participacion de cada asesor en el AUM de la firma.
-- ---------------------------------------------------------------------
WITH valor_cuenta AS (
    SELECT cu.id_cuenta, cu.id_cliente, fn_valor_cuenta(cu.id_cuenta) AS valor_usd
    FROM cuenta cu
)
SELECT ase.id_asesor,
       ase.nombres || ' ' || ase.apellidos AS asesor,
       COUNT(DISTINCT cl.id_cliente)       AS clientes,
       COUNT(vc.id_cuenta)                 AS cuentas,
       COALESCE(SUM(vc.valor_usd), 0)      AS aum_usd,
       ROUND(100 * COALESCE(SUM(vc.valor_usd), 0)
             / NULLIF(SUM(SUM(vc.valor_usd)) OVER (), 0), 2) AS pct_aum_firma
FROM asesor ase
LEFT JOIN cliente      cl ON cl.id_asesor  = ase.id_asesor
LEFT JOIN valor_cuenta vc ON vc.id_cliente = cl.id_cliente
GROUP BY ase.id_asesor, ase.nombres, ase.apellidos
ORDER BY aum_usd DESC;


-- ---------------------------------------------------------------------
-- C09 | P9: Activos mas comprados y mas vendidos en los ultimos 12 meses
-- RANK con PARTITION BY genera un ranking separado para compras y ventas.
-- ---------------------------------------------------------------------
WITH movimiento_activo AS (
    SELECT t.tipo_transaccion,
           a.nombre       AS activo,
           ta.nombre_tipo AS tipo_activo,
           COUNT(*)       AS operaciones,
           SUM(t.monto)   AS monto_usd
    FROM transaccion t
    JOIN activo      a  ON a.id_activo       = t.id_activo
    JOIN tipo_activo ta ON ta.id_tipo_activo = a.id_tipo_activo
    WHERE t.fecha_hora >= CURRENT_DATE - INTERVAL '12 months'
    GROUP BY t.tipo_transaccion, a.nombre, ta.nombre_tipo
),
ranking AS (
    SELECT m.*,
           RANK() OVER (PARTITION BY m.tipo_transaccion ORDER BY m.monto_usd DESC) AS puesto
    FROM movimiento_activo m
)
SELECT k.tipo_transaccion, k.puesto, k.activo, k.tipo_activo, k.operaciones, k.monto_usd
FROM ranking k
WHERE k.puesto <= 5
ORDER BY k.tipo_transaccion, k.puesto;


-- ---------------------------------------------------------------------
-- C10 | Apoyo a P5: asesores cuya comision total supera el promedio
--       de comision por asesor (HAVING con subconsulta)
-- ---------------------------------------------------------------------
SELECT ase.nombres || ' ' || ase.apellidos AS asesor,
       COUNT(*)                            AS transacciones,
       SUM(t.comision)                     AS comision_total_usd
FROM transaccion t
JOIN cuenta  cu  ON cu.id_cuenta  = t.id_cuenta
JOIN cliente cl  ON cl.id_cliente = cu.id_cliente
JOIN asesor  ase ON ase.id_asesor = cl.id_asesor
GROUP BY ase.id_asesor, ase.nombres, ase.apellidos
HAVING SUM(t.comision) > (SELECT AVG(x.total)
                          FROM (SELECT SUM(t2.comision) AS total
                                FROM transaccion t2
                                JOIN cuenta  cu2 ON cu2.id_cuenta  = t2.id_cuenta
                                JOIN cliente cl2 ON cl2.id_cliente = cu2.id_cliente
                                GROUP BY cl2.id_asesor) x)
ORDER BY comision_total_usd DESC;


-- ---------------------------------------------------------------------
-- C11 | Apoyo a P2: variacion mensual del precio de cada accion/fondo
--       en los ultimos 6 meses
-- DISTINCT ON toma el ultimo cierre de cada mes; LAG trae el del mes
-- anterior para calcular el cambio porcentual.
-- ---------------------------------------------------------------------
WITH cierre_mes AS (
    SELECT DISTINCT ON (ph.id_activo, DATE_TRUNC('month', ph.fecha))
           ph.id_activo,
           DATE_TRUNC('month', ph.fecha)::date AS mes,
           ph.precio_cierre
    FROM precio_historico ph
    WHERE ph.fecha >= DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '6 months'
    ORDER BY ph.id_activo, DATE_TRUNC('month', ph.fecha), ph.fecha DESC
)
SELECT af.ticker,
       cm.mes,
       cm.precio_cierre,
       LAG(cm.precio_cierre) OVER (PARTITION BY cm.id_activo ORDER BY cm.mes) AS cierre_mes_anterior,
       ROUND(100 * (cm.precio_cierre
                    / LAG(cm.precio_cierre) OVER (PARTITION BY cm.id_activo ORDER BY cm.mes) - 1), 2)
           AS variacion_pct
FROM cierre_mes cm
JOIN accion_fondo af ON af.id_activo = cm.id_activo
ORDER BY af.ticker, cm.mes;


-- ---------------------------------------------------------------------
-- C12 | Apoyo a P1 y P2: ganancia o perdida no realizada por posicion
--       de renta variable (valor actual frente al costo promedio)
-- ---------------------------------------------------------------------
WITH costo AS (
    SELECT t.id_cuenta,
           t.id_activo,
           SUM(t.monto) / SUM(t.cantidad) AS costo_promedio
    FROM transaccion t
    WHERE t.tipo_transaccion = 'COMPRA'
    GROUP BY t.id_cuenta, t.id_activo
)
SELECT pa.cliente,
       pa.activo,
       pa.cantidad,
       ROUND(co.costo_promedio, 4)                             AS costo_promedio_usd,
       ROUND(pa.valor_usd / pa.cantidad, 4)                    AS precio_actual_usd,
       ROUND(pa.valor_usd - pa.cantidad * co.costo_promedio, 2) AS ganancia_no_realizada_usd,
       ROUND(100 * (pa.valor_usd / (pa.cantidad * co.costo_promedio) - 1), 2) AS ganancia_pct
FROM v_posicion_actual pa
JOIN costo co ON co.id_cuenta = pa.id_cuenta AND co.id_activo = pa.id_activo
WHERE pa.clase_activo = 'RENTA_VARIABLE'
ORDER BY ganancia_no_realizada_usd DESC;


-- ---------------------------------------------------------------------
-- C13 | Apoyo a P7: clientes sin compras ni ventas en los ultimos 90 dias
--       (subconsulta correlacionada con NOT EXISTS)
-- ---------------------------------------------------------------------
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos   AS cliente,
       ase.nombres || ' ' || ase.apellidos AS asesor,
       (SELECT MAX(t.fecha_hora)::date
        FROM transaccion t
        JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
        WHERE cu.id_cliente = cl.id_cliente) AS ultima_operacion
FROM cliente cl
JOIN asesor ase ON ase.id_asesor = cl.id_asesor
WHERE NOT EXISTS (SELECT 1
                  FROM transaccion t
                  JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
                  WHERE cu.id_cliente = cl.id_cliente
                    AND t.fecha_hora >= CURRENT_DATE - INTERVAL '90 days')
ORDER BY ultima_operacion NULLS FIRST;


-- ---------------------------------------------------------------------
-- C14 | Apoyo a P9: activos presentes en 3 o mas cuentas y cuanto
--       suman (GROUP BY + HAVING sobre la vista de tenencia)
-- ---------------------------------------------------------------------
SELECT a.nombre          AS activo,
       ta.nombre_tipo    AS tipo_activo,
       COUNT(*)          AS cuentas_tenedoras,
       SUM(te.cantidad)  AS cantidad_total
FROM v_tenencia te
JOIN activo      a  ON a.id_activo       = te.id_activo
JOIN tipo_activo ta ON ta.id_tipo_activo = a.id_tipo_activo
GROUP BY a.nombre, ta.nombre_tipo
HAVING COUNT(*) >= 3
ORDER BY cuentas_tenedoras DESC, activo;


-- ---------------------------------------------------------------------
-- C15 | Auditoria de integridad: el saldo almacenado debe coincidir con
--       el reconstruido desde el historial. Debe devolver 0 filas.
-- ---------------------------------------------------------------------
SELECT cu.id_cuenta,
       cu.saldo_efectivo            AS saldo_almacenado,
       fn_efectivo(cu.id_cuenta)    AS saldo_reconstruido,
       cu.saldo_efectivo - fn_efectivo(cu.id_cuenta) AS diferencia
FROM cuenta cu
WHERE cu.saldo_efectivo <> fn_efectivo(cu.id_cuenta);
