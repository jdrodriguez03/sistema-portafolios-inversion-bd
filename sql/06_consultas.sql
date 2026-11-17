-- =====================================================================
-- 06_consultas.sql - Consultas del proyecto
-- Cada consulta indica la pregunta de informacion (P1..P9) que responde.
-- =====================================================================

-- C01 | P1: Valor actual del portafolio de cada cliente por tipo de activo
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       SUM(CASE WHEN p.categoria = 'ACCION'   THEN p.valor_usd ELSE 0 END) AS acciones_usd,
       SUM(CASE WHEN p.categoria = 'FONDO'    THEN p.valor_usd ELSE 0 END) AS fondos_usd,
       SUM(CASE WHEN p.categoria = 'CDT'      THEN p.valor_usd ELSE 0 END) AS cdt_usd,
       SUM(CASE WHEN p.categoria = 'TES'      THEN p.valor_usd ELSE 0 END) AS tes_usd,
       SUM(CASE WHEN p.categoria = 'EFECTIVO' THEN p.valor_usd ELSE 0 END) AS efectivo_usd,
       SUM(p.valor_usd) AS total_usd
FROM v_portafolio_cliente p
JOIN cliente cl ON cl.id_cliente = p.id_cliente
GROUP BY cl.id_cliente, cl.nombres, cl.apellidos
ORDER BY total_usd DESC;


-- C02 | P2: Rentabilidad de cada cliente en los ultimos 12 meses
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       pr.nombre_perfil,
       fn_rentabilidad_cliente(cl.id_cliente, CURRENT_DATE - 365, CURRENT_DATE) AS rentabilidad_pct
FROM cliente cl
JOIN perfil_riesgo pr ON pr.id_perfil = cl.id_perfil
ORDER BY rentabilidad_pct DESC;


-- C03a | P3: Porcentaje del portafolio de cada cliente en cada tipo de activo
SELECT cl.nombres || ' ' || cl.apellidos AS cliente,
       p.categoria,
       p.valor_usd,
       ROUND(100 * p.valor_usd / t.total, 2) AS porcentaje
FROM v_portafolio_cliente p
JOIN cliente cl ON cl.id_cliente = p.id_cliente
JOIN (SELECT id_cliente, SUM(valor_usd) AS total
      FROM v_portafolio_cliente
      GROUP BY id_cliente) t ON t.id_cliente = p.id_cliente
ORDER BY cliente, porcentaje DESC;


-- C03b | P3: Clientes que cumplen o exceden el limite de renta variable de su perfil
SELECT cliente, nombre_perfil, limite_pct, pct_renta_variable, valor_total_usd,
       CASE WHEN pct_renta_variable <= limite_pct THEN 'CUMPLE' ELSE 'EXCEDE' END AS estado
FROM v_cumplimiento_perfil
ORDER BY estado DESC, pct_renta_variable DESC;


-- C04 | P4: CDT y TES que vencen en los proximos 30, 60 y 90 dias
SELECT CASE WHEN dias_al_vencimiento <= 30 THEN 'Hasta 30 dias'
            WHEN dias_al_vencimiento <= 60 THEN 'De 31 a 60 dias'
            ELSE 'De 61 a 90 dias'
       END AS ventana,
       cliente, asesor, tipo_activo, activo, fecha_vencimiento, dias_al_vencimiento, valor_usd
FROM v_vencimientos_renta_fija
WHERE dias_al_vencimiento BETWEEN 0 AND 90
ORDER BY dias_al_vencimiento;


-- C05 | P5: Comisiones generadas por cada asesor, mes a mes, en los ultimos 12 meses
SELECT ase.nombres || ' ' || ase.apellidos AS asesor,
       DATE_TRUNC('month', t.fecha_hora) AS mes,
       COUNT(*) AS transacciones,
       SUM(t.comision) AS comision_usd
FROM transaccion t
JOIN cuenta cu  ON cu.id_cuenta = t.id_cuenta
JOIN cliente cl ON cl.id_cliente = cu.id_cliente
JOIN asesor ase ON ase.id_asesor = cl.id_asesor
WHERE t.fecha_hora >= CURRENT_DATE - 365
GROUP BY ase.id_asesor, ase.nombres, ase.apellidos, DATE_TRUNC('month', t.fecha_hora)
ORDER BY asesor, mes;


-- C06 | P6: Los 3 clientes con mayor y los 3 con menor rentabilidad (CTE + RANK)
WITH rentabilidad AS (
    SELECT cl.nombres || ' ' || cl.apellidos AS cliente,
           fn_rentabilidad_cliente(cl.id_cliente, CURRENT_DATE - 365, CURRENT_DATE) AS rentabilidad_pct
    FROM cliente cl
),
ranking AS (
    SELECT cliente, rentabilidad_pct,
           RANK() OVER (ORDER BY rentabilidad_pct DESC) AS puesto_mayor,
           RANK() OVER (ORDER BY rentabilidad_pct ASC)  AS puesto_menor
    FROM rentabilidad
)
SELECT cliente, rentabilidad_pct, puesto_mayor AS puesto
FROM ranking
WHERE puesto_mayor <= 3 OR puesto_menor <= 3
ORDER BY rentabilidad_pct DESC;


-- C07 | P7: Historial de compras y ventas de un cliente, con el flujo de caja acumulado
--           (cambiar el 1 por el id del cliente que se quiera consultar)
SELECT t.fecha_hora,
       t.tipo_transaccion,
       a.nombre AS activo,
       t.cantidad,
       t.precio_unitario,
       t.monto,
       t.comision,
       SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN -(t.monto + t.comision)
                ELSE t.monto - t.comision END)
           OVER (ORDER BY t.fecha_hora) AS flujo_acumulado_usd
FROM transaccion t
JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
JOIN activo a  ON a.id_activo = t.id_activo
WHERE cu.id_cliente = 1
ORDER BY t.fecha_hora;


-- C08 | P8: Numero de clientes y valor administrado (AUM) por asesor
WITH valor_cuenta AS (
    SELECT id_cuenta, id_cliente, fn_valor_cuenta(id_cuenta) AS valor_usd
    FROM cuenta
)
SELECT ase.nombres || ' ' || ase.apellidos AS asesor,
       COUNT(DISTINCT cl.id_cliente) AS clientes,
       COALESCE(SUM(vc.valor_usd), 0) AS aum_usd
FROM asesor ase
LEFT JOIN cliente cl      ON cl.id_asesor = ase.id_asesor
LEFT JOIN valor_cuenta vc ON vc.id_cliente = cl.id_cliente
GROUP BY ase.id_asesor, ase.nombres, ase.apellidos
ORDER BY aum_usd DESC;


-- C09a | P9: Los 5 activos mas comprados en los ultimos 12 meses
SELECT a.nombre AS activo, COUNT(*) AS operaciones, SUM(t.monto) AS monto_usd
FROM transaccion t
JOIN activo a ON a.id_activo = t.id_activo
WHERE t.tipo_transaccion = 'COMPRA'
  AND t.fecha_hora >= CURRENT_DATE - 365
GROUP BY a.nombre
ORDER BY monto_usd DESC
LIMIT 5;


-- C09b | P9: Los 5 activos mas vendidos en los ultimos 12 meses
SELECT a.nombre AS activo, COUNT(*) AS operaciones, SUM(t.monto) AS monto_usd
FROM transaccion t
JOIN activo a ON a.id_activo = t.id_activo
WHERE t.tipo_transaccion = 'VENTA'
  AND t.fecha_hora >= CURRENT_DATE - 365
GROUP BY a.nombre
ORDER BY monto_usd DESC
LIMIT 5;


-- C10 | Apoyo a P5: Asesores cuya comision total supera el promedio (HAVING + subconsulta)
SELECT ase.nombres || ' ' || ase.apellidos AS asesor,
       SUM(t.comision) AS comision_total_usd
FROM transaccion t
JOIN cuenta cu  ON cu.id_cuenta = t.id_cuenta
JOIN cliente cl ON cl.id_cliente = cu.id_cliente
JOIN asesor ase ON ase.id_asesor = cl.id_asesor
GROUP BY ase.id_asesor, ase.nombres, ase.apellidos
HAVING SUM(t.comision) > (SELECT SUM(t2.comision) / COUNT(DISTINCT cl2.id_asesor)
                          FROM transaccion t2
                          JOIN cuenta cu2  ON cu2.id_cuenta = t2.id_cuenta
                          JOIN cliente cl2 ON cl2.id_cliente = cu2.id_cliente)
ORDER BY comision_total_usd DESC;


-- C11 | Apoyo a P2: Precio promedio mensual de cada activo y su variacion (CTE + LAG)
WITH promedio_mes AS (
    SELECT af.ticker,
           DATE_TRUNC('month', ph.fecha) AS mes,
           ROUND(AVG(ph.precio_cierre), 2) AS precio_promedio
    FROM precio_historico ph
    JOIN accion_fondo af ON af.id_activo = ph.id_activo
    WHERE ph.fecha >= CURRENT_DATE - 180
    GROUP BY af.ticker, DATE_TRUNC('month', ph.fecha)
)
SELECT ticker, mes, precio_promedio,
       LAG(precio_promedio) OVER (PARTITION BY ticker ORDER BY mes) AS mes_anterior,
       ROUND(100 * (precio_promedio / LAG(precio_promedio) OVER (PARTITION BY ticker ORDER BY mes) - 1), 2) AS variacion_pct
FROM promedio_mes
ORDER BY ticker, mes;


-- C12 | Apoyo a P1: Ganancia o perdida no realizada de cada posicion en acciones y fondos
WITH costo AS (
    SELECT id_cuenta, id_activo, SUM(monto) / SUM(cantidad) AS costo_promedio
    FROM transaccion
    WHERE tipo_transaccion = 'COMPRA'
    GROUP BY id_cuenta, id_activo
)
SELECT p.cliente,
       p.activo,
       p.cantidad,
       ROUND(c.costo_promedio, 2) AS costo_promedio_usd,
       ROUND(p.valor_usd / p.cantidad, 2) AS precio_actual_usd,
       ROUND(p.valor_usd - p.cantidad * c.costo_promedio, 2) AS ganancia_usd
FROM v_posicion_actual p
JOIN costo c ON c.id_cuenta = p.id_cuenta AND c.id_activo = p.id_activo
WHERE p.clase_activo = 'RENTA_VARIABLE'
ORDER BY ganancia_usd DESC;


-- C13 | Apoyo a P7: Clientes sin compras ni ventas en los ultimos 90 dias (NOT EXISTS)
SELECT cl.id_cliente, cl.nombres || ' ' || cl.apellidos AS cliente
FROM cliente cl
WHERE NOT EXISTS (SELECT 1
                  FROM transaccion t
                  JOIN cuenta cu ON cu.id_cuenta = t.id_cuenta
                  WHERE cu.id_cliente = cl.id_cliente
                    AND t.fecha_hora >= CURRENT_DATE - 90)
ORDER BY cl.id_cliente;


-- C14 | Apoyo a P9: Activos que estan en 3 o mas cuentas (GROUP BY + HAVING)
SELECT a.nombre AS activo, COUNT(*) AS cuentas, SUM(te.cantidad) AS cantidad_total
FROM v_tenencia te
JOIN activo a ON a.id_activo = te.id_activo
GROUP BY a.nombre
HAVING COUNT(*) >= 3
ORDER BY cuentas DESC;


-- C15 | Control: cuentas cuyo saldo guardado no coincide con el historial (debe dar 0 filas)
SELECT id_cuenta, saldo_efectivo, fn_efectivo(id_cuenta) AS saldo_reconstruido
FROM cuenta
WHERE saldo_efectivo <> fn_efectivo(id_cuenta);
