-- =====================================================================
-- 03_carga_catalogos.sql
-- Catalogos con identificadores fijos (los CHECK del DDL dependen de
-- los id de tipo_activo).
-- =====================================================================

INSERT INTO perfil_riesgo (id_perfil, nombre_perfil, limite_max_renta_var) VALUES
    (1, 'CONSERVADOR',  20.00),   -- Regla 2: maximo 20 % en renta variable
    (2, 'MODERADO',     50.00),   -- Regla 2: maximo 50 %
    (3, 'AGRESIVO',    100.00);   -- Regla 2: sin limite

INSERT INTO tipo_activo (id_tipo_activo, nombre_tipo, clase_activo) VALUES
    (1, 'ACCION', 'RENTA_VARIABLE'),
    (2, 'FONDO',  'RENTA_VARIABLE'),
    (3, 'CDT',    'RENTA_FIJA'),
    (4, 'TES',    'RENTA_FIJA');
