-- =====================================================================
-- 02_funciones_triggers.sql
-- Funciones, procedimiento almacenado y triggers del dominio.
-- Se ejecuta DESPUES de 01_ddl.sql y ANTES de cargar datos, porque los
-- triggers mantienen el saldo de efectivo durante la carga.
--
-- Contenido
--   A. Funciones de consulta: fn_trm, fn_precio, fn_tenencia,
--      fn_efectivo, fn_posiciones, fn_valor_cuenta, fn_rentabilidad_cliente
--   B. Triggers de reglas de negocio:
--      trg_transaccion_validar      (Reglas 4, 5, 6, 7, 11)
--      trg_movimiento_aplicar       (depositos y retiros)
--      trg_rendimiento_aplicar      (Regla 8)
--      trg_cuenta_proteger_saldo    (redundancia controlada)
--      trg_*_inmutable              (historial no modificable)
--      trg_activo_subtipo           (especializacion total, Regla 12)
--   C. Procedimiento: sp_registrar_compra
-- =====================================================================


-- =====================================================================
-- A. FUNCIONES DE CONSULTA
-- =====================================================================

-- TRM vigente en una fecha (pesos por dolar). Si la fecha no esta
-- cubierta por ningun rango se usa la ultima TRM publicada antes.
CREATE OR REPLACE FUNCTION fn_trm(p_fecha DATE)
RETURNS NUMERIC
LANGUAGE sql AS $$
    SELECT t.valor_cop
    FROM trm t
    WHERE t.fecha_desde <= p_fecha
    ORDER BY t.fecha_desde DESC
    LIMIT 1;
$$;

-- Precio de cierre mas reciente de una accion/fondo a una fecha (Regla 9)
CREATE OR REPLACE FUNCTION fn_precio(p_id_activo INTEGER, p_fecha DATE DEFAULT CURRENT_DATE)
RETURNS NUMERIC
LANGUAGE sql AS $$
    SELECT ph.precio_cierre
    FROM precio_historico ph
    WHERE ph.id_activo = p_id_activo
      AND ph.fecha <= p_fecha
    ORDER BY ph.fecha DESC
    LIMIT 1;
$$;

-- Cantidad que una cuenta posee actualmente de un activo
-- (compras menos ventas). La tenencia NO se almacena: se deriva.
CREATE OR REPLACE FUNCTION fn_tenencia(p_id_cuenta INTEGER, p_id_activo INTEGER)
RETURNS NUMERIC
LANGUAGE sql AS $$
    SELECT COALESCE(SUM(CASE WHEN t.tipo_transaccion = 'COMPRA'
                             THEN t.cantidad ELSE -t.cantidad END), 0)
    FROM transaccion t
    WHERE t.id_cuenta = p_id_cuenta
      AND t.id_activo = p_id_activo;
$$;

-- Efectivo (USD) de una cuenta al cierre de una fecha, reconstruido
-- desde el historial. Con CURRENT_DATE debe coincidir con
-- cuenta.saldo_efectivo (consulta de auditoria en 06_consultas.sql).
CREATE OR REPLACE FUNCTION fn_efectivo(p_id_cuenta INTEGER, p_fecha DATE DEFAULT CURRENT_DATE)
RETURNS NUMERIC
LANGUAGE sql AS $$
    SELECT
        COALESCE((SELECT SUM(CASE WHEN m.tipo_movimiento = 'DEPOSITO'
                                  THEN m.monto ELSE -m.monto END)
                  FROM movimiento_efectivo m
                  WHERE m.id_cuenta = p_id_cuenta
                    AND m.fecha_hora::date <= p_fecha), 0)
      + COALESCE((SELECT SUM(r.monto)
                  FROM rendimiento r
                  WHERE r.id_cuenta = p_id_cuenta
                    AND r.fecha <= p_fecha), 0)
      + COALESCE((SELECT SUM(CASE WHEN t.tipo_transaccion = 'COMPRA'
                                  THEN -(t.monto + t.comision)
                                  ELSE  (t.monto - t.comision) END)
                  FROM transaccion t
                  WHERE t.id_cuenta = p_id_cuenta
                    AND t.fecha_hora::date <= p_fecha), 0);
$$;

-- Posiciones valoradas en USD al cierre de una fecha.
--   Renta variable: cantidad x ultimo precio disponible (Regla 9).
--   Renta fija (compra y retencion, Reglas 6 y 7): cada compra es un
--   lote con su tasa pactada. El valor invertido se lleva a COP con la
--   TRM del dia de compra, se capitaliza a la tasa efectiva anual hasta
--   la fecha (o hasta el vencimiento) y se devuelve a USD con la TRM de
--   la fecha de valoracion:
--     valor = monto_usd x TRM(compra) x (1 + tasa)^(dias/365) / TRM(fecha)
-- p_id_cuenta = NULL valora todas las cuentas.
CREATE OR REPLACE FUNCTION fn_posiciones(p_fecha DATE DEFAULT CURRENT_DATE,
                                         p_id_cuenta INTEGER DEFAULT NULL)
RETURNS TABLE (id_cuenta INTEGER, id_activo INTEGER, cantidad NUMERIC, valor_usd NUMERIC)
LANGUAGE sql AS $$
    -- Renta variable
    SELECT t.id_cuenta,
           t.id_activo,
           SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END),
           ROUND(SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END)
                 * COALESCE(fn_precio(t.id_activo, p_fecha), 0), 2)
    FROM transaccion t
    JOIN accion_fondo af ON af.id_activo = t.id_activo
    WHERE t.fecha_hora::date <= p_fecha
      AND (p_id_cuenta IS NULL OR t.id_cuenta = p_id_cuenta)
    GROUP BY t.id_cuenta, t.id_activo
    HAVING SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) > 0

    UNION ALL

    -- Renta fija: compras de CDT y TES aun no redimidas a la fecha
    SELECT t.id_cuenta,
           t.id_activo,
           SUM(t.cantidad),
           ROUND(SUM(t.monto * fn_trm(t.fecha_hora::date)
                     * POWER(1 + t.tasa_pactada,
                             (LEAST(p_fecha, COALESCE(c.fecha_vencimiento, s.fecha_vencimiento))
                              - t.fecha_hora::date) / 365.0))
                 / fn_trm(p_fecha), 2)
    FROM transaccion t
    LEFT JOIN cdt c ON c.id_activo = t.id_activo
    LEFT JOIN tes s ON s.id_activo = t.id_activo
    WHERE t.tipo_transaccion = 'COMPRA'
      AND t.tasa_pactada IS NOT NULL
      AND t.fecha_hora::date <= p_fecha
      AND (p_id_cuenta IS NULL OR t.id_cuenta = p_id_cuenta)
      AND NOT EXISTS (SELECT 1
                      FROM transaccion v
                      WHERE v.id_cuenta = t.id_cuenta
                        AND v.id_activo = t.id_activo
                        AND v.tipo_transaccion = 'VENTA'
                        AND v.fecha_hora::date <= p_fecha)
    GROUP BY t.id_cuenta, t.id_activo;
$$;

-- Valor total de una cuenta (efectivo + posiciones) en USD a una fecha
CREATE OR REPLACE FUNCTION fn_valor_cuenta(p_id_cuenta INTEGER, p_fecha DATE DEFAULT CURRENT_DATE)
RETURNS NUMERIC
LANGUAGE sql AS $$
    SELECT fn_efectivo(p_id_cuenta, p_fecha)
         + COALESCE((SELECT SUM(p.valor_usd)
                     FROM fn_posiciones(p_fecha, p_id_cuenta) p), 0);
$$;

-- Rentabilidad (%) de un cliente en un periodo (Preguntas 2 y 6).
--   Vi = valor de sus cuentas al cierre de p_desde
--   Vf = valor de sus cuentas al cierre de p_hasta
--   F  = aportes netos del periodo (depositos - retiros)
--   rentabilidad = (Vf - Vi - F) / (Vi + F) x 100
-- Los aportes no son ganancia: por eso se restan del resultado y se
-- suman al capital invertido. Devuelve NULL si no hubo capital.
CREATE OR REPLACE FUNCTION fn_rentabilidad_cliente(p_id_cliente INTEGER,
                                                   p_desde DATE,
                                                   p_hasta DATE DEFAULT CURRENT_DATE)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_inicial NUMERIC;
    v_final   NUMERIC;
    v_aportes NUMERIC;
BEGIN
    IF p_hasta <= p_desde THEN
        RAISE EXCEPTION 'El periodo es invalido: % a %', p_desde, p_hasta;
    END IF;

    SELECT COALESCE(SUM(fn_valor_cuenta(c.id_cuenta, p_desde)), 0),
           COALESCE(SUM(fn_valor_cuenta(c.id_cuenta, p_hasta)), 0)
    INTO v_inicial, v_final
    FROM cuenta c
    WHERE c.id_cliente = p_id_cliente;

    SELECT COALESCE(SUM(CASE WHEN m.tipo_movimiento = 'DEPOSITO'
                             THEN m.monto ELSE -m.monto END), 0)
    INTO v_aportes
    FROM movimiento_efectivo m
    JOIN cuenta c ON c.id_cuenta = m.id_cuenta
    WHERE c.id_cliente = p_id_cliente
      AND m.fecha_hora::date > p_desde
      AND m.fecha_hora::date <= p_hasta;

    IF v_inicial + v_aportes <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((v_final - v_inicial - v_aportes) / (v_inicial + v_aportes) * 100, 2);
END;
$$;


-- =====================================================================
-- B. TRIGGERS DE REGLAS DE NEGOCIO
-- =====================================================================

-- ---------------------------------------------------------------------
-- B1. Validacion y efecto de cada compra/venta
--   Regla 4 : la compra exige saldo suficiente (monto + comision)
--   Regla 5 : la comision se calcula sola (columna generada)
--   Regla 6 : CDT/TES no se venden antes del vencimiento
--   Regla 7 : toda compra de CDT/TES fija su tasa pactada
--   Regla 11: no se vende mas de lo que se posee
--   Ademas: la fecha no puede ser futura ni anterior a la apertura.
-- La fila de la cuenta se bloquea con FOR UPDATE: dos compras
-- simultaneas sobre la misma cuenta se ejecutan una tras otra y la
-- segunda ve el saldo ya descontado (evita la actualizacion perdida).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_transaccion_validar()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_saldo     NUMERIC;
    v_estado    VARCHAR;
    v_apertura  DATE;
    v_tipo      SMALLINT;
    v_venc      DATE;
    v_es_rf     BOOLEAN;
    v_monto     NUMERIC;
    v_comision  NUMERIC;
    v_tenencia  NUMERIC;
BEGIN
    -- Bloqueo de la cuenta durante toda la transaccion
    SELECT c.saldo_efectivo, c.estado, c.fecha_apertura
    INTO v_saldo, v_estado, v_apertura
    FROM cuenta c
    WHERE c.id_cuenta = NEW.id_cuenta
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La cuenta % no existe', NEW.id_cuenta;
    END IF;
    IF v_estado <> 'ACTIVA' THEN
        RAISE EXCEPTION 'La cuenta % esta % y no admite transacciones', NEW.id_cuenta, v_estado;
    END IF;
    IF NEW.fecha_hora::date < v_apertura THEN
        RAISE EXCEPTION 'La transaccion (%) es anterior a la apertura de la cuenta (%)',
            NEW.fecha_hora::date, v_apertura;
    END IF;
    IF NEW.fecha_hora > CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'No se aceptan transacciones con fecha futura (%)', NEW.fecha_hora;
    END IF;

    -- Tipo del activo y, si es renta fija, su vencimiento
    SELECT a.id_tipo_activo, COALESCE(c.fecha_vencimiento, s.fecha_vencimiento)
    INTO v_tipo, v_venc
    FROM activo a
    LEFT JOIN cdt c ON c.id_activo = a.id_activo
    LEFT JOIN tes s ON s.id_activo = a.id_activo
    WHERE a.id_activo = NEW.id_activo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El activo % no existe', NEW.id_activo;
    END IF;

    v_es_rf    := v_tipo IN (3, 4);
    -- En un trigger BEFORE las columnas generadas aun no existen:
    -- se calculan con la misma expresion del DDL.
    v_monto    := ROUND(NEW.cantidad * NEW.precio_unitario, 2);
    v_comision := ROUND(NEW.cantidad * NEW.precio_unitario * NEW.tasa_comision, 2);

    IF NEW.tipo_transaccion = 'COMPRA' THEN
        IF v_es_rf THEN
            IF NEW.tasa_pactada IS NULL THEN
                RAISE EXCEPTION 'Regla 7: la compra de CDT/TES debe indicar la tasa pactada';
            END IF;
            IF NEW.fecha_hora::date >= v_venc THEN
                RAISE EXCEPTION 'No se puede comprar un titulo vencido (vence %)', v_venc;
            END IF;
        ELSIF NEW.tasa_pactada IS NOT NULL THEN
            RAISE EXCEPTION 'La tasa pactada solo aplica a CDT y TES';
        END IF;

        IF v_saldo < v_monto + v_comision THEN
            RAISE EXCEPTION 'Regla 4: saldo insuficiente en la cuenta %. Disponible: %, requerido: %',
                NEW.id_cuenta, v_saldo, v_monto + v_comision;
        END IF;

        UPDATE cuenta
        SET saldo_efectivo = saldo_efectivo - (v_monto + v_comision)
        WHERE id_cuenta = NEW.id_cuenta;

    ELSE  -- VENTA
        IF NEW.tasa_pactada IS NOT NULL THEN
            RAISE EXCEPTION 'La tasa pactada solo se registra en la compra';
        END IF;

        v_tenencia := fn_tenencia(NEW.id_cuenta, NEW.id_activo);
        IF NEW.cantidad > v_tenencia THEN
            RAISE EXCEPTION 'Regla 11: se intenta vender % pero la cuenta % solo posee %',
                NEW.cantidad, NEW.id_cuenta, v_tenencia;
        END IF;

        IF v_es_rf THEN
            IF NEW.fecha_hora::date < v_venc THEN
                RAISE EXCEPTION 'Regla 6: el CDT/TES no puede liquidarse antes de su vencimiento (%)', v_venc;
            END IF;
            IF NEW.cantidad <> v_tenencia THEN
                RAISE EXCEPTION 'La redencion de un CDT/TES debe ser por el total de la posicion (%)', v_tenencia;
            END IF;
        END IF;

        UPDATE cuenta
        SET saldo_efectivo = saldo_efectivo + (v_monto - v_comision)
        WHERE id_cuenta = NEW.id_cuenta;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_transaccion_validar ON transaccion;
CREATE TRIGGER trg_transaccion_validar
    BEFORE INSERT ON transaccion
    FOR EACH ROW EXECUTE FUNCTION trg_fn_transaccion_validar();

-- ---------------------------------------------------------------------
-- B2. Depositos y retiros: actualizan el saldo; el retiro exige fondos.
--   La fecha no puede ser futura ni anterior a la apertura de la cuenta.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_movimiento_aplicar()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_saldo    NUMERIC;
    v_estado   VARCHAR;
    v_apertura DATE;
BEGIN
    SELECT c.saldo_efectivo, c.estado, c.fecha_apertura
    INTO v_saldo, v_estado, v_apertura
    FROM cuenta c
    WHERE c.id_cuenta = NEW.id_cuenta
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La cuenta % no existe', NEW.id_cuenta;
    END IF;
    IF v_estado = 'CERRADA' THEN
        RAISE EXCEPTION 'La cuenta % esta cerrada', NEW.id_cuenta;
    END IF;
    IF NEW.fecha_hora::date < v_apertura THEN
        RAISE EXCEPTION 'El movimiento (%) es anterior a la apertura de la cuenta (%)',
            NEW.fecha_hora::date, v_apertura;
    END IF;
    IF NEW.fecha_hora > CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'No se aceptan movimientos con fecha futura (%)', NEW.fecha_hora;
    END IF;

    IF NEW.tipo_movimiento = 'RETIRO' THEN
        IF v_saldo < NEW.monto THEN
            RAISE EXCEPTION 'Saldo insuficiente para retirar % de la cuenta %. Disponible: %',
                NEW.monto, NEW.id_cuenta, v_saldo;
        END IF;
        UPDATE cuenta SET saldo_efectivo = saldo_efectivo - NEW.monto
        WHERE id_cuenta = NEW.id_cuenta;
    ELSE
        UPDATE cuenta SET saldo_efectivo = saldo_efectivo + NEW.monto
        WHERE id_cuenta = NEW.id_cuenta;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_movimiento_aplicar ON movimiento_efectivo;
CREATE TRIGGER trg_movimiento_aplicar
    BEFORE INSERT ON movimiento_efectivo
    FOR EACH ROW EXECUTE FUNCTION trg_fn_movimiento_aplicar();

-- ---------------------------------------------------------------------
-- B3. Rendimientos (Regla 8): se abonan como ingreso de la cuenta.
--   DIVIDENDO solo para acciones/fondos; INTERES solo para CDT/TES.
--   La cuenta debe haber comprado el activo antes de recibir el pago.
--   La fecha del pago no puede ser futura.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_rendimiento_aplicar()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_tipo SMALLINT;
BEGIN
    IF NEW.fecha > CURRENT_DATE THEN
        RAISE EXCEPTION 'No se aceptan rendimientos con fecha futura (%)', NEW.fecha;
    END IF;

    SELECT a.id_tipo_activo INTO v_tipo
    FROM activo a
    WHERE a.id_activo = NEW.id_activo;

    IF NEW.tipo_rendimiento = 'DIVIDENDO' AND v_tipo NOT IN (1, 2) THEN
        RAISE EXCEPTION 'Los dividendos solo aplican a acciones y fondos';
    END IF;
    IF NEW.tipo_rendimiento = 'INTERES' AND v_tipo NOT IN (3, 4) THEN
        RAISE EXCEPTION 'Los intereses solo aplican a CDT y TES';
    END IF;

    IF NOT EXISTS (SELECT 1
                   FROM transaccion t
                   WHERE t.id_cuenta = NEW.id_cuenta
                     AND t.id_activo = NEW.id_activo
                     AND t.tipo_transaccion = 'COMPRA'
                     AND t.fecha_hora::date <= NEW.fecha) THEN
        RAISE EXCEPTION 'La cuenta % no habia comprado el activo % antes del %',
            NEW.id_cuenta, NEW.id_activo, NEW.fecha;
    END IF;

    UPDATE cuenta SET saldo_efectivo = saldo_efectivo + NEW.monto
    WHERE id_cuenta = NEW.id_cuenta;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rendimiento_aplicar ON rendimiento;
CREATE TRIGGER trg_rendimiento_aplicar
    BEFORE INSERT ON rendimiento
    FOR EACH ROW EXECUTE FUNCTION trg_fn_rendimiento_aplicar();

-- ---------------------------------------------------------------------
-- B4. Proteccion de la redundancia controlada cuenta.saldo_efectivo
--   El saldo nace en 0 y solo cambia desde los triggers anteriores.
--   pg_trigger_depth() vale 1 cuando el UPDATE lo lanza el usuario y 2
--   cuando lo lanza otro trigger.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_cuenta_proteger_saldo()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.saldo_efectivo <> 0 THEN
            RAISE EXCEPTION 'Una cuenta nueva inicia con saldo 0; registre un DEPOSITO en movimiento_efectivo';
        END IF;
    ELSIF NEW.saldo_efectivo <> OLD.saldo_efectivo
          AND pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'El saldo no se modifica directamente; registre un movimiento, transaccion o rendimiento';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cuenta_proteger_saldo ON cuenta;
CREATE TRIGGER trg_cuenta_proteger_saldo
    BEFORE INSERT OR UPDATE OF saldo_efectivo ON cuenta
    FOR EACH ROW EXECUTE FUNCTION trg_fn_cuenta_proteger_saldo();

-- ---------------------------------------------------------------------
-- B5. Historial inmutable: transacciones, movimientos y rendimientos no
--   se editan ni se borran (trazabilidad). Un error se corrige con la
--   operacion contraria. Asi el saldo almacenado nunca se desincroniza.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_registro_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Los registros de % son inmutables: no se permite %', TG_TABLE_NAME, TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS trg_transaccion_inmutable ON transaccion;
CREATE TRIGGER trg_transaccion_inmutable
    BEFORE UPDATE OR DELETE ON transaccion
    FOR EACH ROW EXECUTE FUNCTION trg_fn_registro_inmutable();

DROP TRIGGER IF EXISTS trg_movimiento_inmutable ON movimiento_efectivo;
CREATE TRIGGER trg_movimiento_inmutable
    BEFORE UPDATE OR DELETE ON movimiento_efectivo
    FOR EACH ROW EXECUTE FUNCTION trg_fn_registro_inmutable();

DROP TRIGGER IF EXISTS trg_rendimiento_inmutable ON rendimiento;
CREATE TRIGGER trg_rendimiento_inmutable
    BEFORE UPDATE OR DELETE ON rendimiento
    FOR EACH ROW EXECUTE FUNCTION trg_fn_registro_inmutable();

-- ---------------------------------------------------------------------
-- B6. Especializacion TOTAL de ACTIVO (Regla 12)
--   Todo activo debe tener su fila en el subtipo que indica su tipo.
--   Es un trigger de restriccion DIFERIDO: se evalua al hacer COMMIT,
--   lo que permite insertar primero el activo y luego el subtipo dentro
--   de la misma transaccion (BEGIN ... COMMIT).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_activo_subtipo()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_existe BOOLEAN;
BEGIN
    IF NEW.id_tipo_activo IN (1, 2) THEN
        SELECT EXISTS (SELECT 1 FROM accion_fondo x WHERE x.id_activo = NEW.id_activo) INTO v_existe;
    ELSIF NEW.id_tipo_activo = 3 THEN
        SELECT EXISTS (SELECT 1 FROM cdt x WHERE x.id_activo = NEW.id_activo) INTO v_existe;
    ELSE
        SELECT EXISTS (SELECT 1 FROM tes x WHERE x.id_activo = NEW.id_activo) INTO v_existe;
    END IF;

    IF NOT v_existe THEN
        RAISE EXCEPTION 'Regla 12: el activo % (%) no tiene registro en la tabla de su tipo',
            NEW.id_activo, NEW.nombre;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_activo_subtipo ON activo;
CREATE CONSTRAINT TRIGGER trg_activo_subtipo
    AFTER INSERT ON activo
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION trg_fn_activo_subtipo();


-- =====================================================================
-- C. PROCEDIMIENTO ALMACENADO
-- =====================================================================

-- Registra una compra. Si no se indica precio usa el ultimo precio de
-- cierre disponible (Regla 9). El trigger valida saldo y demas reglas y
-- descuenta el efectivo: registro de la orden y descuento del saldo
-- ocurren en la misma transaccion (atomicidad).
--   CALL sp_registrar_compra(1, 3, 10);                    -- 10 acciones
--   CALL sp_registrar_compra(1, 12, 1, 2500.00, 0.1150);   -- un CDT
CREATE OR REPLACE PROCEDURE sp_registrar_compra(
    p_id_cuenta    INTEGER,
    p_id_activo    INTEGER,
    p_cantidad     NUMERIC,
    p_precio       NUMERIC DEFAULT NULL,
    p_tasa_pactada NUMERIC DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_precio NUMERIC := COALESCE(p_precio, fn_precio(p_id_activo, CURRENT_DATE));
    v_id     INTEGER;
    v_total  NUMERIC;
BEGIN
    IF v_precio IS NULL THEN
        RAISE EXCEPTION 'No hay precio disponible para el activo %; indique p_precio', p_id_activo;
    END IF;

    INSERT INTO transaccion (id_cuenta, id_activo, tipo_transaccion, cantidad, precio_unitario, tasa_pactada)
    VALUES (p_id_cuenta, p_id_activo, 'COMPRA', p_cantidad, v_precio, p_tasa_pactada)
    RETURNING id_transaccion, monto + comision INTO v_id, v_total;

    RAISE NOTICE 'Compra % registrada: % unidades a % USD. Total descontado (con comision): % USD',
        v_id, p_cantidad, v_precio, v_total;
END;
$$;
