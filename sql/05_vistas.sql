-- =====================================================================
-- 05_vistas.sql - Vistas del proyecto
-- =====================================================================

DROP VIEW IF EXISTS v_vencimientos_renta_fija, v_cumplimiento_perfil,
                    v_portafolio_cliente, v_posicion_actual, v_tenencia CASCADE;

-- Cantidad que cada cuenta posee de cada activo (compras - ventas)
CREATE VIEW v_tenencia AS
SELECT id_cuenta, id_activo,
       SUM(CASE WHEN tipo_transaccion = 'COMPRA' THEN cantidad ELSE -cantidad END) AS cantidad
FROM transaccion
GROUP BY id_cuenta, id_activo
HAVING SUM(CASE WHEN tipo_transaccion = 'COMPRA' THEN cantidad ELSE -cantidad END) > 0;

-- Posiciones de cada cliente valoradas hoy en USD
CREATE VIEW v_posicion_actual AS
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       cu.id_cuenta,
       a.id_activo,
       a.nombre       AS activo,
       ta.nombre_tipo AS tipo_activo,
       ta.clase_activo,
       p.cantidad,
       p.valor_usd
FROM fn_posiciones(CURRENT_DATE) p
JOIN cuenta cu      ON cu.id_cuenta = p.id_cuenta
JOIN cliente cl     ON cl.id_cliente = cu.id_cliente
JOIN activo a       ON a.id_activo = p.id_activo
JOIN tipo_activo ta ON ta.id_tipo_activo = a.id_tipo_activo;

-- Valor de cada cliente por categoria (tipos de activo + efectivo)
CREATE VIEW v_portafolio_cliente AS
SELECT id_cliente, tipo_activo AS categoria, SUM(valor_usd) AS valor_usd
FROM v_posicion_actual
GROUP BY id_cliente, tipo_activo
UNION ALL
SELECT id_cliente, 'EFECTIVO', SUM(saldo_efectivo)
FROM cuenta
GROUP BY id_cliente;

-- Porcentaje en renta variable de cada cliente frente al limite de su perfil (Regla 2)
CREATE VIEW v_cumplimiento_perfil AS
SELECT cl.id_cliente,
       cl.nombres || ' ' || cl.apellidos AS cliente,
       pr.nombre_perfil,
       pr.limite_max_renta_var AS limite_pct,
       SUM(p.valor_usd) AS valor_total_usd,
       ROUND(100 * SUM(CASE WHEN p.categoria IN ('ACCION', 'FONDO') THEN p.valor_usd ELSE 0 END)
             / SUM(p.valor_usd), 2) AS pct_renta_variable
FROM cliente cl
JOIN perfil_riesgo pr       ON pr.id_perfil = cl.id_perfil
JOIN v_portafolio_cliente p ON p.id_cliente = cl.id_cliente
GROUP BY cl.id_cliente, cl.nombres, cl.apellidos, pr.nombre_perfil, pr.limite_max_renta_var;

-- CDT y TES que los clientes aun poseen, con los dias que faltan para su vencimiento
CREATE VIEW v_vencimientos_renta_fija AS
SELECT p.cliente,
       ase.nombres || ' ' || ase.apellidos AS asesor,
       p.id_cuenta,
       p.activo,
       p.tipo_activo,
       COALESCE(c.fecha_vencimiento, s.fecha_vencimiento) AS fecha_vencimiento,
       COALESCE(c.fecha_vencimiento, s.fecha_vencimiento) - CURRENT_DATE AS dias_al_vencimiento,
       p.valor_usd
FROM v_posicion_actual p
JOIN cliente cl  ON cl.id_cliente = p.id_cliente
JOIN asesor ase  ON ase.id_asesor = cl.id_asesor
LEFT JOIN cdt c  ON c.id_activo = p.id_activo
LEFT JOIN tes s  ON s.id_activo = p.id_activo
WHERE p.clase_activo = 'RENTA_FIJA';
