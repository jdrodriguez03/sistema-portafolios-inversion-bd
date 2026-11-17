--
-- PostgreSQL database dump
--

\restrict BFkbLWVcO243u3cEfHwS2kt05vhnKq3Lx5RcSLqbRxKGZABiLg4GMEpdYbIgcFa

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_efectivo(integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_efectivo(p_id_cuenta integer, p_fecha date DEFAULT CURRENT_DATE) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT
        COALESCE((SELECT SUM(CASE WHEN m.tipo_movimiento = 'DEPOSITO'
                                  THEN m.monto ELSE -m.monto END)
                  FROM movimiento_efectivo m
                  WHERE m.id_cuenta = p_id_cuenta
                    AND m.fecha_hora < p_fecha + 1), 0)
      + COALESCE((SELECT SUM(r.monto)
                  FROM rendimiento r
                  WHERE r.id_cuenta = p_id_cuenta
                    AND r.fecha <= p_fecha), 0)
      + COALESCE((SELECT SUM(CASE WHEN t.tipo_transaccion = 'COMPRA'
                                  THEN -(t.monto + t.comision)
                                  ELSE  (t.monto - t.comision) END)
                  FROM transaccion t
                  WHERE t.id_cuenta = p_id_cuenta
                    AND t.fecha_hora < p_fecha + 1), 0);
$$;


--
-- Name: fn_posiciones(date, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_posiciones(p_fecha date DEFAULT CURRENT_DATE, p_id_cuenta integer DEFAULT NULL::integer) RETURNS TABLE(id_cuenta integer, id_activo integer, cantidad numeric, valor_usd numeric)
    LANGUAGE sql STABLE
    AS $$
    -- Renta variable
    SELECT t.id_cuenta,
           t.id_activo,
           SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END),
           ROUND(SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END)
                 * COALESCE(fn_precio(t.id_activo, p_fecha), 0), 2)
    FROM transaccion t
    JOIN accion_fondo af ON af.id_activo = t.id_activo
    WHERE t.fecha_hora < p_fecha + 1
      AND (p_id_cuenta IS NULL OR t.id_cuenta = p_id_cuenta)
    GROUP BY t.id_cuenta, t.id_activo
    HAVING SUM(CASE WHEN t.tipo_transaccion = 'COMPRA' THEN t.cantidad ELSE -t.cantidad END) > 0

    UNION ALL

    -- Renta fija: lotes comprados y aun no redimidos a la fecha
    SELECT t.id_cuenta,
           t.id_activo,
           SUM(t.cantidad),
           ROUND(SUM(t.monto * fn_trm(t.fecha_hora::date)
                     * POWER(1 + t.tasa_pactada,
                             (LEAST(p_fecha, rf.fecha_vencimiento) - t.fecha_hora::date) / 365.0))
                 / fn_trm(p_fecha), 2)
    FROM transaccion t
    JOIN (SELECT c.id_activo, c.fecha_vencimiento FROM cdt c
          UNION ALL
          SELECT s.id_activo, s.fecha_vencimiento FROM tes s) rf
      ON rf.id_activo = t.id_activo
    WHERE t.tipo_transaccion = 'COMPRA'
      AND t.fecha_hora < p_fecha + 1
      AND (p_id_cuenta IS NULL OR t.id_cuenta = p_id_cuenta)
      AND NOT EXISTS (SELECT 1
                      FROM transaccion v
                      WHERE v.id_cuenta = t.id_cuenta
                        AND v.id_activo = t.id_activo
                        AND v.tipo_transaccion = 'VENTA'
                        AND v.fecha_hora < p_fecha + 1)
    GROUP BY t.id_cuenta, t.id_activo;
$$;


--
-- Name: fn_precio(integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_precio(p_id_activo integer, p_fecha date DEFAULT CURRENT_DATE) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT ph.precio_cierre
    FROM precio_historico ph
    WHERE ph.id_activo = p_id_activo
      AND ph.fecha <= p_fecha
    ORDER BY ph.fecha DESC
    LIMIT 1;
$$;


--
-- Name: fn_rentabilidad_cliente(integer, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_rentabilidad_cliente(p_id_cliente integer, p_desde date, p_hasta date DEFAULT CURRENT_DATE) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
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
      AND m.fecha_hora >= p_desde + 1
      AND m.fecha_hora <  p_hasta + 1;

    IF v_inicial + v_aportes <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((v_final - v_inicial - v_aportes) / (v_inicial + v_aportes) * 100, 2);
END;
$$;


--
-- Name: fn_tenencia(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_tenencia(p_id_cuenta integer, p_id_activo integer) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE(SUM(CASE WHEN t.tipo_transaccion = 'COMPRA'
                             THEN t.cantidad ELSE -t.cantidad END), 0)
    FROM transaccion t
    WHERE t.id_cuenta = p_id_cuenta
      AND t.id_activo = p_id_activo;
$$;


--
-- Name: fn_trm(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_trm(p_fecha date) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT t.valor_cop
    FROM trm t
    WHERE t.fecha_desde <= p_fecha
    ORDER BY t.fecha_desde DESC
    LIMIT 1;
$$;


--
-- Name: fn_valor_cuenta(integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_valor_cuenta(p_id_cuenta integer, p_fecha date DEFAULT CURRENT_DATE) RETURNS numeric
    LANGUAGE sql STABLE
    AS $$
    SELECT fn_efectivo(p_id_cuenta, p_fecha)
         + COALESCE((SELECT SUM(p.valor_usd)
                     FROM fn_posiciones(p_fecha, p_id_cuenta) p), 0);
$$;


--
-- Name: sp_registrar_compra(integer, integer, numeric, numeric, numeric); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_registrar_compra(IN p_id_cuenta integer, IN p_id_activo integer, IN p_cantidad numeric, IN p_precio numeric DEFAULT NULL::numeric, IN p_tasa_pactada numeric DEFAULT NULL::numeric)
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: trg_fn_activo_subtipo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_activo_subtipo() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: trg_fn_cuenta_proteger_saldo(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_cuenta_proteger_saldo() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.saldo_efectivo <> 0 THEN
            RAISE EXCEPTION 'Una cuenta nueva inicia con saldo 0; registre un DEPOSITO en movimiento_efectivo';
        END IF;
    ELSIF NEW.saldo_efectivo IS DISTINCT FROM OLD.saldo_efectivo
          AND pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'El saldo no se modifica directamente; registre un movimiento, transaccion o rendimiento';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: trg_fn_movimiento_aplicar(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_movimiento_aplicar() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: trg_fn_registro_inmutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_registro_inmutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'Los registros de % son inmutables: no se permite %', TG_TABLE_NAME, TG_OP;
END;
$$;


--
-- Name: trg_fn_rendimiento_aplicar(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_rendimiento_aplicar() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_tipo SMALLINT;
BEGIN
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


--
-- Name: trg_fn_transaccion_validar(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_fn_transaccion_validar() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accion_fondo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accion_fondo (
    id_activo integer NOT NULL,
    id_tipo_activo smallint NOT NULL,
    ticker character varying(10) NOT NULL,
    mercado character varying(20) NOT NULL,
    CONSTRAINT accion_fondo_id_tipo_activo_check CHECK ((id_tipo_activo = ANY (ARRAY[1, 2])))
);


--
-- Name: TABLE accion_fondo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.accion_fondo IS 'Subtipo: acciones y fondos indexados (renta variable, USD)';


--
-- Name: activo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activo (
    id_activo integer NOT NULL,
    id_tipo_activo smallint NOT NULL,
    nombre character varying(150) NOT NULL,
    fecha_registro date DEFAULT CURRENT_DATE NOT NULL
);


--
-- Name: TABLE activo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.activo IS 'Supertipo de la especializacion disjunta y total de activos';


--
-- Name: activo_id_activo_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.activo ALTER COLUMN id_activo ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.activo_id_activo_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: asesor; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asesor (
    id_asesor integer NOT NULL,
    tipo_documento character varying(3) DEFAULT 'CC'::character varying NOT NULL,
    numero_documento character varying(20) NOT NULL,
    nombres character varying(100) NOT NULL,
    apellidos character varying(100) NOT NULL,
    email character varying(150) NOT NULL,
    telefono character varying(20),
    fecha_ingreso date DEFAULT CURRENT_DATE NOT NULL,
    CONSTRAINT asesor_email_check CHECK (((email)::text ~~ '%_@_%._%'::text)),
    CONSTRAINT asesor_tipo_documento_check CHECK (((tipo_documento)::text = ANY ((ARRAY['CC'::character varying, 'CE'::character varying, 'PA'::character varying])::text[])))
);


--
-- Name: TABLE asesor; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.asesor IS 'Asesores financieros de la firma';


--
-- Name: asesor_id_asesor_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.asesor ALTER COLUMN id_asesor ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.asesor_id_asesor_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cdt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cdt (
    id_activo integer NOT NULL,
    id_tipo_activo smallint NOT NULL,
    entidad_emisora character varying(100) NOT NULL,
    fecha_emision date NOT NULL,
    fecha_vencimiento date NOT NULL,
    CONSTRAINT cdt_id_tipo_activo_check CHECK ((id_tipo_activo = 3)),
    CONSTRAINT ck_cdt_fechas CHECK ((fecha_vencimiento > fecha_emision))
);


--
-- Name: TABLE cdt; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cdt IS 'Subtipo: certificados de deposito a termino (COP)';


--
-- Name: cliente; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cliente (
    id_cliente integer NOT NULL,
    id_perfil smallint NOT NULL,
    id_asesor integer NOT NULL,
    tipo_documento character varying(3) DEFAULT 'CC'::character varying NOT NULL,
    numero_documento character varying(20) NOT NULL,
    nombres character varying(100) NOT NULL,
    apellidos character varying(100) NOT NULL,
    email character varying(150) NOT NULL,
    telefono character varying(20),
    fecha_nacimiento date NOT NULL,
    fecha_vinculacion date DEFAULT CURRENT_DATE NOT NULL,
    CONSTRAINT ck_cliente_mayor_edad CHECK ((fecha_vinculacion >= (fecha_nacimiento + '18 years'::interval))),
    CONSTRAINT cliente_email_check CHECK (((email)::text ~~ '%_@_%._%'::text)),
    CONSTRAINT cliente_tipo_documento_check CHECK (((tipo_documento)::text = ANY ((ARRAY['CC'::character varying, 'CE'::character varying, 'PA'::character varying])::text[])))
);


--
-- Name: TABLE cliente; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cliente IS 'Clientes personas naturales; un perfil y un asesor por cliente';


--
-- Name: cliente_id_cliente_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.cliente ALTER COLUMN id_cliente ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.cliente_id_cliente_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cuenta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cuenta (
    id_cuenta integer NOT NULL,
    id_cliente integer NOT NULL,
    nombre_cuenta character varying(100) NOT NULL,
    fecha_apertura date DEFAULT CURRENT_DATE NOT NULL,
    saldo_efectivo numeric(15,2) DEFAULT 0 NOT NULL,
    estado character varying(10) DEFAULT 'ACTIVA'::character varying NOT NULL,
    CONSTRAINT cuenta_estado_check CHECK (((estado)::text = ANY ((ARRAY['ACTIVA'::character varying, 'INACTIVA'::character varying, 'CERRADA'::character varying])::text[]))),
    CONSTRAINT cuenta_saldo_efectivo_check CHECK ((saldo_efectivo >= (0)::numeric))
);


--
-- Name: TABLE cuenta; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cuenta IS 'Cuenta/portafolio de un cliente; saldo en USD mantenido por triggers';


--
-- Name: COLUMN cuenta.saldo_efectivo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.cuenta.saldo_efectivo IS 'Redundancia controlada; solo la modifican los triggers';


--
-- Name: cuenta_id_cuenta_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.cuenta ALTER COLUMN id_cuenta ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.cuenta_id_cuenta_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: movimiento_efectivo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.movimiento_efectivo (
    id_movimiento integer NOT NULL,
    id_cuenta integer NOT NULL,
    tipo_movimiento character varying(10) NOT NULL,
    fecha_hora timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    monto numeric(15,2) NOT NULL,
    CONSTRAINT movimiento_efectivo_monto_check CHECK ((monto > (0)::numeric)),
    CONSTRAINT movimiento_efectivo_tipo_movimiento_check CHECK (((tipo_movimiento)::text = ANY ((ARRAY['DEPOSITO'::character varying, 'RETIRO'::character varying])::text[])))
);


--
-- Name: TABLE movimiento_efectivo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.movimiento_efectivo IS 'Depositos y retiros de efectivo de una cuenta';


--
-- Name: movimiento_efectivo_id_movimiento_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.movimiento_efectivo ALTER COLUMN id_movimiento ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.movimiento_efectivo_id_movimiento_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: perfil_riesgo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.perfil_riesgo (
    id_perfil smallint NOT NULL,
    nombre_perfil character varying(20) NOT NULL,
    limite_max_renta_var numeric(5,2) NOT NULL,
    CONSTRAINT perfil_riesgo_limite_max_renta_var_check CHECK (((limite_max_renta_var >= (0)::numeric) AND (limite_max_renta_var <= (100)::numeric))),
    CONSTRAINT perfil_riesgo_nombre_perfil_check CHECK (((nombre_perfil)::text = ANY ((ARRAY['CONSERVADOR'::character varying, 'MODERADO'::character varying, 'AGRESIVO'::character varying])::text[])))
);


--
-- Name: TABLE perfil_riesgo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.perfil_riesgo IS 'Catalogo de perfiles de riesgo y su limite de renta variable';


--
-- Name: precio_historico; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.precio_historico (
    id_activo integer NOT NULL,
    fecha date NOT NULL,
    precio_cierre numeric(15,4) NOT NULL,
    CONSTRAINT precio_historico_precio_cierre_check CHECK ((precio_cierre > (0)::numeric))
);


--
-- Name: TABLE precio_historico; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.precio_historico IS 'Precio de cierre diario en USD por accion/fondo (yfinance)';


--
-- Name: rendimiento; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rendimiento (
    id_rendimiento integer NOT NULL,
    id_cuenta integer NOT NULL,
    id_activo integer NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    tipo_rendimiento character varying(10) NOT NULL,
    monto numeric(15,2) NOT NULL,
    CONSTRAINT rendimiento_monto_check CHECK ((monto > (0)::numeric)),
    CONSTRAINT rendimiento_tipo_rendimiento_check CHECK (((tipo_rendimiento)::text = ANY ((ARRAY['DIVIDENDO'::character varying, 'INTERES'::character varying])::text[])))
);


--
-- Name: TABLE rendimiento; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.rendimiento IS 'Dividendos e intereses abonados a la cuenta';


--
-- Name: rendimiento_id_rendimiento_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.rendimiento ALTER COLUMN id_rendimiento ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.rendimiento_id_rendimiento_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tes (
    id_activo integer NOT NULL,
    id_tipo_activo smallint NOT NULL,
    serie character varying(20) NOT NULL,
    tasa_cupon numeric(6,4) NOT NULL,
    fecha_emision date NOT NULL,
    fecha_vencimiento date NOT NULL,
    CONSTRAINT ck_tes_fechas CHECK ((fecha_vencimiento > fecha_emision)),
    CONSTRAINT tes_id_tipo_activo_check CHECK ((id_tipo_activo = 4)),
    CONSTRAINT tes_tasa_cupon_check CHECK (((tasa_cupon > (0)::numeric) AND (tasa_cupon < (1)::numeric)))
);


--
-- Name: TABLE tes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tes IS 'Subtipo: bonos del Tesoro de Colombia (COP)';


--
-- Name: tipo_activo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tipo_activo (
    id_tipo_activo smallint NOT NULL,
    nombre_tipo character varying(20) NOT NULL,
    clase_activo character varying(15) NOT NULL,
    CONSTRAINT tipo_activo_clase_activo_check CHECK (((clase_activo)::text = ANY ((ARRAY['RENTA_VARIABLE'::character varying, 'RENTA_FIJA'::character varying])::text[]))),
    CONSTRAINT tipo_activo_id_tipo_activo_check CHECK (((id_tipo_activo >= 1) AND (id_tipo_activo <= 4))),
    CONSTRAINT tipo_activo_nombre_tipo_check CHECK (((nombre_tipo)::text = ANY ((ARRAY['ACCION'::character varying, 'FONDO'::character varying, 'CDT'::character varying, 'TES'::character varying])::text[])))
);


--
-- Name: TABLE tipo_activo; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tipo_activo IS 'Catalogo/discriminador: 1 ACCION, 2 FONDO, 3 CDT, 4 TES';


--
-- Name: transaccion; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transaccion (
    id_transaccion integer NOT NULL,
    id_cuenta integer NOT NULL,
    id_activo integer NOT NULL,
    tipo_transaccion character varying(10) NOT NULL,
    fecha_hora timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    cantidad numeric(15,6) NOT NULL,
    precio_unitario numeric(15,4) NOT NULL,
    tasa_comision numeric(6,4) DEFAULT 0.005 NOT NULL,
    tasa_pactada numeric(6,4),
    monto numeric(15,2) GENERATED ALWAYS AS (round((cantidad * precio_unitario), 2)) STORED,
    comision numeric(15,2) GENERATED ALWAYS AS (round(((cantidad * precio_unitario) * tasa_comision), 2)) STORED,
    CONSTRAINT transaccion_cantidad_check CHECK ((cantidad > (0)::numeric)),
    CONSTRAINT transaccion_precio_unitario_check CHECK ((precio_unitario > (0)::numeric)),
    CONSTRAINT transaccion_tasa_comision_check CHECK (((tasa_comision >= (0)::numeric) AND (tasa_comision < (1)::numeric))),
    CONSTRAINT transaccion_tasa_pactada_check CHECK (((tasa_pactada > (0)::numeric) AND (tasa_pactada < (1)::numeric))),
    CONSTRAINT transaccion_tipo_transaccion_check CHECK (((tipo_transaccion)::text = ANY ((ARRAY['COMPRA'::character varying, 'VENTA'::character varying])::text[])))
);


--
-- Name: TABLE transaccion; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.transaccion IS 'Compras y ventas; monto y comision son columnas generadas';


--
-- Name: COLUMN transaccion.tasa_pactada; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.transaccion.tasa_pactada IS 'Tasa efectiva anual fijada en la compra de CDT/TES (Regla 7)';


--
-- Name: transaccion_id_transaccion_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.transaccion ALTER COLUMN id_transaccion ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.transaccion_id_transaccion_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: trm; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trm (
    fecha_desde date NOT NULL,
    fecha_hasta date NOT NULL,
    valor_cop numeric(10,2) NOT NULL,
    CONSTRAINT ck_trm_rango CHECK ((fecha_hasta >= fecha_desde)),
    CONSTRAINT trm_valor_cop_check CHECK ((valor_cop > (0)::numeric))
);


--
-- Name: TABLE trm; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.trm IS 'TRM oficial COP/USD por rango de vigencia (datos.gov.co)';


--
-- Name: v_posicion_actual; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_posicion_actual AS
 SELECT cl.id_cliente,
    (((cl.nombres)::text || ' '::text) || (cl.apellidos)::text) AS cliente,
    cu.id_cuenta,
    cu.nombre_cuenta,
    a.id_activo,
    a.nombre AS activo,
    ta.nombre_tipo AS tipo_activo,
    ta.clase_activo,
    p.cantidad,
    p.valor_usd
   FROM ((((public.fn_posiciones(CURRENT_DATE) p(id_cuenta, id_activo, cantidad, valor_usd)
     JOIN public.cuenta cu ON ((cu.id_cuenta = p.id_cuenta)))
     JOIN public.cliente cl ON ((cl.id_cliente = cu.id_cliente)))
     JOIN public.activo a ON ((a.id_activo = p.id_activo)))
     JOIN public.tipo_activo ta ON ((ta.id_tipo_activo = a.id_tipo_activo)));


--
-- Name: v_portafolio_cliente; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_portafolio_cliente AS
 WITH componentes AS (
         SELECT pa.id_cliente,
            pa.tipo_activo AS categoria,
            sum(pa.valor_usd) AS valor_usd
           FROM public.v_posicion_actual pa
          GROUP BY pa.id_cliente, pa.tipo_activo
        UNION ALL
         SELECT cu.id_cliente,
            'EFECTIVO'::character varying,
            sum(cu.saldo_efectivo) AS sum
           FROM public.cuenta cu
          GROUP BY cu.id_cliente
        )
 SELECT cl.id_cliente,
    (((cl.nombres)::text || ' '::text) || (cl.apellidos)::text) AS cliente,
    co.categoria,
    co.valor_usd,
    round((((100)::numeric * co.valor_usd) / NULLIF(sum(co.valor_usd) OVER (PARTITION BY cl.id_cliente), (0)::numeric)), 2) AS porcentaje
   FROM (componentes co
     JOIN public.cliente cl ON ((cl.id_cliente = co.id_cliente)));


--
-- Name: v_cumplimiento_perfil; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_cumplimiento_perfil AS
 SELECT cl.id_cliente,
    (((cl.nombres)::text || ' '::text) || (cl.apellidos)::text) AS cliente,
    pr.nombre_perfil,
    pr.limite_max_renta_var AS limite_pct,
    COALESCE(sum(pc.valor_usd), (0)::numeric) AS valor_total_usd,
    COALESCE(sum(pc.valor_usd) FILTER (WHERE ((pc.categoria)::text = ANY ((ARRAY['ACCION'::character varying, 'FONDO'::character varying])::text[]))), (0)::numeric) AS valor_renta_variable_usd,
    COALESCE(round((((100)::numeric * sum(pc.valor_usd) FILTER (WHERE ((pc.categoria)::text = ANY ((ARRAY['ACCION'::character varying, 'FONDO'::character varying])::text[])))) / NULLIF(sum(pc.valor_usd), (0)::numeric)), 2), (0)::numeric) AS pct_renta_variable,
        CASE
            WHEN (COALESCE((((100)::numeric * sum(pc.valor_usd) FILTER (WHERE ((pc.categoria)::text = ANY ((ARRAY['ACCION'::character varying, 'FONDO'::character varying])::text[])))) / NULLIF(sum(pc.valor_usd), (0)::numeric)), (0)::numeric) <= pr.limite_max_renta_var) THEN 'CUMPLE'::text
            ELSE 'EXCEDE'::text
        END AS estado
   FROM ((public.cliente cl
     JOIN public.perfil_riesgo pr ON ((pr.id_perfil = cl.id_perfil)))
     LEFT JOIN public.v_portafolio_cliente pc ON ((pc.id_cliente = cl.id_cliente)))
  GROUP BY cl.id_cliente, cl.nombres, cl.apellidos, pr.nombre_perfil, pr.limite_max_renta_var;


--
-- Name: v_tenencia; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_tenencia AS
 SELECT id_cuenta,
    id_activo,
    sum(
        CASE
            WHEN ((tipo_transaccion)::text = 'COMPRA'::text) THEN cantidad
            ELSE (- cantidad)
        END) AS cantidad
   FROM public.transaccion t
  GROUP BY id_cuenta, id_activo
 HAVING (sum(
        CASE
            WHEN ((tipo_transaccion)::text = 'COMPRA'::text) THEN cantidad
            ELSE (- cantidad)
        END) > (0)::numeric);


--
-- Name: v_vencimientos_renta_fija; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_vencimientos_renta_fija AS
 SELECT pa.id_cliente,
    pa.cliente,
    (((ase.nombres)::text || ' '::text) || (ase.apellidos)::text) AS asesor,
    pa.id_cuenta,
    pa.activo,
    pa.tipo_activo,
    rf.fecha_vencimiento,
    (rf.fecha_vencimiento - CURRENT_DATE) AS dias_al_vencimiento,
    pa.valor_usd AS valor_actual_usd
   FROM (((public.v_posicion_actual pa
     JOIN ( SELECT c.id_activo,
            c.fecha_vencimiento
           FROM public.cdt c
        UNION ALL
         SELECT s.id_activo,
            s.fecha_vencimiento
           FROM public.tes s) rf ON ((rf.id_activo = pa.id_activo)))
     JOIN public.cliente cl ON ((cl.id_cliente = pa.id_cliente)))
     JOIN public.asesor ase ON ((ase.id_asesor = cl.id_asesor)));


--
-- Data for Name: accion_fondo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.accion_fondo (id_activo, id_tipo_activo, ticker, mercado) FROM stdin;
1	1	EC	NYSE
2	1	CIB	NYSE
3	1	AAPL	NASDAQ
4	1	MSFT	NASDAQ
5	1	AMZN	NASDAQ
6	1	GOOGL	NASDAQ
7	1	TSLA	NASDAQ
8	1	JNJ	NYSE
9	2	SPY	NYSE ARCA
10	2	QQQ	NASDAQ
\.


--
-- Data for Name: activo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.activo (id_activo, id_tipo_activo, nombre, fecha_registro) FROM stdin;
1	1	Ecopetrol S.A. (ADR)	2024-01-02
2	1	Bancolombia S.A. (ADR)	2024-01-02
3	1	Apple Inc.	2024-01-02
4	1	Microsoft Corporation	2024-01-02
5	1	Amazon.com Inc.	2024-01-02
6	1	Alphabet Inc. Clase A	2024-01-02
7	1	Tesla Inc.	2024-01-02
8	1	Johnson & Johnson	2024-01-02
9	2	SPDR S&P 500 ETF Trust	2024-01-02
10	2	Invesco QQQ Trust (Nasdaq-100)	2024-01-02
11	4	TES 2027 (corto plazo)	2024-01-02
12	4	TES 2032 (mediano plazo)	2024-01-02
13	4	TES 2036 (largo plazo)	2024-01-02
14	3	CDT Banco de Bogota 360 dias No. 001	2025-07-09
15	3	CDT Banco Popular 180 dias No. 002	2025-09-29
16	3	CDT Banco Caja Social 720 dias No. 003	2026-03-16
17	3	CDT Itau Colombia 270 dias No. 004	2026-10-07
18	3	CDT Davivienda 360 dias No. 005	2026-02-17
19	3	CDT Banco de Occidente 270 dias No. 006	2024-08-07
20	3	CDT Banco Popular 540 dias No. 007	2024-10-11
21	3	CDT Banco Caja Social 360 dias No. 008	2025-05-16
22	3	CDT Bancolombia 360 dias No. 009	2025-12-30
23	3	CDT Itau Colombia 180 dias No. 010	2026-07-17
24	3	CDT Bancolombia 360 dias No. 011	2024-07-23
25	3	CDT Banco de Occidente 270 dias No. 012	2025-01-30
26	3	CDT Banco Caja Social 180 dias No. 013	2025-09-15
27	3	CDT BBVA Colombia 180 dias No. 014	2025-10-31
28	3	CDT Banco de Bogota 270 dias No. 015	2024-04-15
29	3	CDT Banco Popular 540 dias No. 016	2024-07-01
30	3	CDT Banco de Occidente 180 dias No. 017	2025-04-23
31	3	CDT Bancolombia 270 dias No. 018	2025-07-03
32	3	CDT Itau Colombia 720 dias No. 019	2026-03-27
33	3	CDT Banco Popular 360 dias No. 020	2026-07-14
34	3	CDT BBVA Colombia 270 dias No. 021	2024-06-03
35	3	CDT Itau Colombia 360 dias No. 022	2025-06-20
36	3	CDT Banco Caja Social 180 dias No. 023	2025-02-19
37	3	CDT Banco Popular 270 dias No. 024	2025-06-10
38	3	CDT Davivienda 360 dias No. 025	2026-01-21
39	3	CDT Bancolombia 360 dias No. 026	2026-05-14
40	3	CDT Bancolombia 180 dias No. 027	2024-05-16
41	3	CDT Banco Caja Social 180 dias No. 028	2024-07-18
42	3	CDT BBVA Colombia 180 dias No. 029	2024-11-14
43	3	CDT Banco Caja Social 180 dias No. 030	2025-02-18
44	3	CDT Banco de Bogota 540 dias No. 031	2025-10-07
45	3	CDT Bancolombia 270 dias No. 032	2026-05-27
46	3	CDT Davivienda 360 dias No. 033	2026-09-24
47	3	CDT Davivienda 270 dias No. 034	2024-07-10
48	3	CDT Itau Colombia 270 dias No. 035	2024-09-26
49	3	CDT Banco de Bogota 270 dias No. 036	2025-04-01
50	3	CDT Banco de Bogota 360 dias No. 037	2025-05-14
51	3	CDT Itau Colombia 720 dias No. 038	2025-08-14
52	3	CDT Banco Caja Social 360 dias No. 039	2025-09-26
53	3	CDT Banco de Bogota 360 dias No. 040	2026-01-02
54	3	CDT Banco Caja Social 540 dias No. 041	2026-04-27
55	3	CDT Bancolombia 720 dias No. 042	2026-10-06
56	3	CDT Banco Caja Social 180 dias No. 043	2024-07-30
57	3	CDT Bancolombia 180 dias No. 044	2024-10-29
58	3	CDT Banco de Occidente 270 dias No. 045	2025-04-28
59	3	CDT Banco Caja Social 270 dias No. 046	2025-08-25
60	3	CDT Banco Popular 360 dias No. 047	2025-06-05
61	3	CDT Banco de Occidente 720 dias No. 048	2025-11-05
62	3	CDT Itau Colombia 540 dias No. 049	2026-07-06
63	3	CDT Bancolombia 360 dias No. 050	2026-10-19
64	3	CDT Itau Colombia 720 dias No. 051	2025-07-07
65	3	CDT Davivienda 720 dias No. 052	2026-06-30
66	3	CDT Itau Colombia 270 dias No. 053	2026-08-21
67	3	CDT Itau Colombia 270 dias No. 054	2024-08-27
68	3	CDT Itau Colombia 720 dias No. 055	2024-12-18
69	3	CDT Banco Caja Social 720 dias No. 056	2026-06-22
70	3	CDT Banco de Occidente 180 dias No. 057	2026-09-25
71	3	CDT Banco Caja Social 360 dias No. 058	2025-07-31
72	3	CDT Davivienda 360 dias No. 059	2025-10-01
73	3	CDT Banco Popular 540 dias No. 060	2025-11-18
74	3	CDT Bancolombia 540 dias No. 061	2026-05-06
75	3	CDT Banco Popular 180 dias No. 062	2024-03-14
76	3	CDT BBVA Colombia 360 dias No. 063	2024-09-06
77	3	CDT Bancolombia 540 dias No. 064	2025-02-13
78	3	CDT Itau Colombia 720 dias No. 065	2025-07-07
79	3	CDT Banco Popular 720 dias No. 066	2025-10-08
80	3	CDT Banco Caja Social 540 dias No. 067	2026-01-14
81	3	CDT Banco Popular 360 dias No. 068	2026-07-15
82	3	CDT Banco Caja Social 360 dias No. 069	2026-10-01
83	3	CDT Banco Caja Social 360 dias No. 070	2024-01-29
84	3	CDT Banco Caja Social 720 dias No. 071	2024-08-26
85	3	CDT Itau Colombia 180 dias No. 072	2025-02-12
86	3	CDT Davivienda 360 dias No. 073	2025-06-05
87	3	CDT Banco de Bogota 540 dias No. 074	2025-09-16
88	3	CDT Banco de Occidente 540 dias No. 075	2025-12-30
89	3	CDT Banco Popular 360 dias No. 076	2026-07-15
90	3	CDT Itau Colombia 360 dias No. 077	2024-12-06
91	3	CDT Banco de Bogota 180 dias No. 078	2025-01-29
92	3	CDT Itau Colombia 270 dias No. 079	2025-03-13
93	3	CDT Banco Popular 360 dias No. 080	2025-05-27
94	3	CDT Davivienda 270 dias No. 081	2025-12-22
95	3	CDT BBVA Colombia 180 dias No. 082	2026-07-15
96	3	CDT Itau Colombia 540 dias No. 083	2025-04-04
97	3	CDT Bancolombia 180 dias No. 084	2025-07-02
98	3	CDT BBVA Colombia 180 dias No. 085	2026-02-03
99	3	CDT Banco Popular 360 dias No. 086	2026-05-04
100	3	CDT BBVA Colombia 270 dias No. 087	2026-05-22
101	3	CDT Banco Popular 360 dias No. 088	2024-05-20
102	3	CDT Banco de Bogota 540 dias No. 089	2024-10-07
103	3	CDT Itau Colombia 720 dias No. 090	2025-03-07
104	3	CDT Banco Caja Social 360 dias No. 091	2025-05-08
105	3	CDT Davivienda 720 dias No. 092	2025-06-26
106	3	CDT Bancolombia 720 dias No. 093	2025-08-21
107	3	CDT Bancolombia 270 dias No. 094	2026-03-27
108	3	CDT Banco de Bogota 180 dias No. 095	2026-06-04
109	3	CDT Banco Caja Social 720 dias No. 096	2026-08-03
110	3	CDT Davivienda 540 dias No. 097	2024-08-05
111	3	CDT Banco Caja Social 360 dias No. 098	2024-10-25
112	3	CDT Itau Colombia 180 dias No. 099	2025-04-16
113	3	CDT Banco Caja Social 720 dias No. 100	2025-08-05
114	3	CDT Davivienda 720 dias No. 101	2025-09-19
115	3	CDT BBVA Colombia 720 dias No. 102	2026-03-18
116	3	CDT Itau Colombia 270 dias No. 103	2026-07-08
117	3	CDT Davivienda 360 dias No. 104	2026-10-07
118	3	CDT Banco Popular 360 dias No. 105	2024-04-22
119	3	CDT Banco de Bogota 270 dias No. 106	2024-10-25
120	3	CDT Itau Colombia 360 dias No. 107	2025-12-17
121	3	CDT Banco Popular 270 dias No. 108	2026-08-06
122	3	CDT Davivienda 360 dias No. 109	2024-08-26
123	3	CDT Itau Colombia 540 dias No. 110	2025-08-06
124	3	CDT Banco de Bogota 540 dias No. 111	2026-05-11
125	3	CDT Davivienda 360 dias No. 112	2024-11-26
126	3	CDT Itau Colombia 360 dias No. 113	2025-05-01
127	3	CDT Banco de Occidente 540 dias No. 114	2025-11-05
128	3	CDT Banco Caja Social 720 dias No. 115	2026-07-02
129	3	CDT Banco de Bogota 360 dias No. 116	2024-05-01
130	3	CDT BBVA Colombia 360 dias No. 117	2024-09-13
131	3	CDT Banco de Occidente 720 dias No. 118	2025-02-21
132	3	CDT Banco Popular 270 dias No. 119	2025-08-27
133	3	CDT Davivienda 360 dias No. 120	2026-03-24
134	3	CDT Banco de Occidente 540 dias No. 121	2024-06-12
135	3	CDT Banco de Occidente 270 dias No. 122	2024-09-23
136	3	CDT Davivienda 360 dias No. 123	2025-06-05
137	3	CDT Davivienda 180 dias No. 124	2025-09-05
138	3	CDT BBVA Colombia 360 dias No. 125	2025-05-22
139	3	CDT Bancolombia 540 dias No. 126	2024-03-18
140	3	CDT Bancolombia 270 dias No. 127	2024-05-23
141	3	CDT Banco de Bogota 360 dias No. 128	2025-12-04
142	3	CDT Banco de Occidente 360 dias No. 129	2024-06-25
143	3	CDT Banco de Occidente 180 dias No. 130	2024-12-19
144	3	CDT Banco Popular 540 dias No. 131	2025-04-11
145	3	CDT Banco Popular 270 dias No. 132	2025-08-14
146	3	CDT Banco de Bogota 720 dias No. 133	2025-10-22
147	3	CDT Bancolombia 360 dias No. 134	2025-12-15
148	3	CDT Banco Caja Social 360 dias No. 135	2026-05-22
149	3	CDT Davivienda 720 dias No. 136	2025-06-06
150	3	CDT Davivienda 270 dias No. 137	2025-09-03
151	3	CDT Banco Caja Social 270 dias No. 138	2024-08-30
152	3	CDT Banco Popular 180 dias No. 139	2025-06-24
153	3	CDT Banco Caja Social 180 dias No. 140	2025-04-10
154	3	CDT Banco de Occidente 180 dias No. 141	2025-12-22
155	3	CDT Banco Popular 720 dias No. 142	2025-04-30
156	3	CDT Itau Colombia 540 dias No. 143	2025-08-07
157	3	CDT Banco Popular 540 dias No. 144	2025-11-11
158	3	CDT BBVA Colombia 540 dias No. 145	2025-03-26
159	3	CDT Davivienda 720 dias No. 146	2025-06-03
160	3	CDT Davivienda 270 dias No. 147	2025-05-27
161	3	CDT Banco Caja Social 540 dias No. 148	2025-09-02
162	3	CDT Banco Caja Social 180 dias No. 149	2026-06-23
163	3	CDT Davivienda 270 dias No. 150	2026-03-16
164	3	CDT Banco de Occidente 360 dias No. 151	2026-05-07
165	3	CDT Banco Popular 180 dias No. 152	2024-01-30
166	3	CDT BBVA Colombia 720 dias No. 153	2024-04-10
167	3	CDT Davivienda 360 dias No. 154	2024-05-30
168	3	CDT Banco de Bogota 180 dias No. 155	2024-08-27
169	3	CDT Davivienda 540 dias No. 156	2024-12-04
170	3	CDT Davivienda 270 dias No. 157	2025-03-17
171	3	CDT Banco de Bogota 270 dias No. 158	2025-07-10
172	3	CDT Banco de Bogota 540 dias No. 159	2025-11-11
173	3	CDT Banco Caja Social 270 dias No. 160	2026-03-17
174	3	CDT BBVA Colombia 360 dias No. 161	2024-05-30
175	3	CDT BBVA Colombia 360 dias No. 162	2024-11-26
176	3	CDT Banco de Occidente 180 dias No. 163	2025-02-18
177	3	CDT BBVA Colombia 180 dias No. 164	2025-06-12
178	3	CDT Banco Popular 540 dias No. 165	2025-08-27
179	3	CDT Itau Colombia 720 dias No. 166	2026-01-23
180	3	CDT Banco de Occidente 360 dias No. 167	2026-03-17
181	3	CDT Bancolombia 360 dias No. 168	2026-05-21
182	3	CDT Davivienda 360 dias No. 169	2026-07-15
183	3	CDT Davivienda 720 dias No. 170	2025-06-24
184	3	CDT Banco de Occidente 360 dias No. 171	2024-07-12
185	3	CDT Banco Caja Social 180 dias No. 172	2025-11-06
186	3	CDT Itau Colombia 360 dias No. 173	2025-05-27
187	3	CDT Banco Popular 540 dias No. 174	2025-10-30
188	3	CDT BBVA Colombia 360 dias No. 175	2025-12-19
189	3	CDT Banco de Occidente 540 dias No. 176	2026-06-18
190	3	CDT Itau Colombia 360 dias No. 177	2026-10-12
191	3	CDT Itau Colombia 360 dias No. 178	2024-12-16
192	3	CDT BBVA Colombia 360 dias No. 179	2025-07-17
193	3	CDT BBVA Colombia 270 dias No. 180	2025-10-08
194	3	CDT BBVA Colombia 720 dias No. 181	2026-06-16
195	3	CDT Bancolombia 270 dias No. 182	2026-10-16
196	3	CDT Banco Popular 270 dias No. 183	2026-01-12
197	3	CDT Itau Colombia 180 dias No. 184	2026-08-05
198	3	CDT Bancolombia 360 dias No. 185	2025-01-16
199	3	CDT Davivienda 180 dias No. 186	2025-03-21
200	3	CDT Banco Caja Social 270 dias No. 187	2025-05-21
201	3	CDT Itau Colombia 270 dias No. 188	2025-09-15
202	3	CDT Banco de Bogota 180 dias No. 189	2026-07-07
203	3	CDT Banco de Bogota 270 dias No. 190	2024-04-19
204	3	CDT Banco de Occidente 180 dias No. 191	2024-09-06
205	3	CDT Bancolombia 720 dias No. 192	2025-02-07
206	3	CDT Bancolombia 720 dias No. 193	2025-04-02
207	3	CDT Bancolombia 270 dias No. 194	2025-10-14
208	3	CDT Banco Popular 720 dias No. 195	2026-04-30
209	3	CDT BBVA Colombia 360 dias No. 196	2026-07-31
210	3	CDT Banco Popular 720 dias No. 197	2024-08-05
211	3	CDT Banco Popular 270 dias No. 198	2026-11-12
212	3	CDT Banco Caja Social 360 dias No. 199	2024-02-12
213	3	CDT Davivienda 720 dias No. 200	2024-07-26
214	3	CDT Banco Caja Social 360 dias No. 201	2025-04-15
215	3	CDT Banco de Bogota 720 dias No. 202	2025-12-05
216	3	CDT Itau Colombia 360 dias No. 203	2026-01-23
217	3	CDT Banco de Bogota 360 dias No. 204	2026-05-21
218	3	CDT Bancolombia 360 dias No. 205	2024-12-20
219	3	CDT Davivienda 360 dias No. 206	2025-08-28
220	3	CDT Banco Caja Social 360 dias No. 207	2025-11-11
221	3	CDT Itau Colombia 540 dias No. 208	2024-08-13
222	3	CDT Banco de Bogota 360 dias No. 209	2026-01-26
223	3	CDT Banco Caja Social 180 dias No. 210	2026-08-04
224	3	CDT Banco Popular 720 dias No. 211	2024-11-22
225	3	CDT Itau Colombia 360 dias No. 212	2025-03-26
226	3	CDT Banco de Bogota 360 dias No. 213	2025-05-29
227	3	CDT Davivienda 360 dias No. 214	2026-03-04
228	3	CDT Banco de Bogota 270 dias No. 215	2024-07-30
229	3	CDT Banco de Bogota 180 dias No. 216	2024-09-13
230	3	CDT BBVA Colombia 540 dias No. 217	2025-03-18
231	3	CDT Banco de Occidente 360 dias No. 218	2025-05-12
232	3	CDT Banco de Occidente 180 dias No. 219	2025-09-05
233	3	CDT Itau Colombia 720 dias No. 220	2025-10-22
234	3	CDT Banco de Bogota 540 dias No. 221	2026-02-17
235	3	CDT Banco Popular 540 dias No. 222	2026-07-07
236	3	CDT Banco Caja Social 180 dias No. 223	2025-06-17
237	3	CDT Bancolombia 270 dias No. 224	2025-09-05
238	3	CDT Banco de Bogota 270 dias No. 225	2025-11-20
239	3	CDT Banco de Occidente 180 dias No. 226	2026-05-26
240	3	CDT Banco Popular 360 dias No. 227	2026-06-15
241	3	CDT Bancolombia 360 dias No. 228	2024-08-29
242	3	CDT Bancolombia 360 dias No. 229	2024-11-12
243	3	CDT Davivienda 360 dias No. 230	2025-01-10
244	3	CDT Banco de Bogota 720 dias No. 231	2025-06-05
245	3	CDT Banco Caja Social 360 dias No. 232	2026-05-15
246	3	CDT Banco Caja Social 720 dias No. 233	2026-08-26
247	3	CDT Davivienda 360 dias No. 234	2025-10-10
248	3	CDT Davivienda 270 dias No. 235	2026-01-09
249	3	CDT Banco de Occidente 360 dias No. 236	2024-04-29
250	3	CDT BBVA Colombia 360 dias No. 237	2025-06-16
251	3	CDT Bancolombia 720 dias No. 238	2025-12-08
252	3	CDT Banco Popular 720 dias No. 239	2026-03-30
253	3	CDT Banco Popular 270 dias No. 240	2026-06-12
254	3	CDT Itau Colombia 270 dias No. 241	2026-08-25
255	3	CDT Davivienda 720 dias No. 242	2024-12-10
256	3	CDT Banco Caja Social 180 dias No. 243	2025-02-12
257	3	CDT Banco Popular 180 dias No. 244	2025-07-14
258	3	CDT Banco de Occidente 720 dias No. 245	2025-08-25
259	3	CDT Banco de Bogota 360 dias No. 246	2026-07-10
260	3	CDT Banco Caja Social 360 dias No. 247	2024-11-25
261	3	CDT BBVA Colombia 360 dias No. 248	2025-09-15
262	3	CDT Itau Colombia 720 dias No. 249	2025-02-07
263	3	CDT Davivienda 180 dias No. 250	2025-05-22
264	3	CDT BBVA Colombia 270 dias No. 251	2025-09-22
265	3	CDT Banco Caja Social 360 dias No. 252	2026-03-18
266	3	CDT Banco Popular 360 dias No. 253	2026-10-15
267	3	CDT Banco de Occidente 360 dias No. 254	2025-08-12
268	3	CDT Banco Caja Social 180 dias No. 255	2026-11-06
269	3	CDT BBVA Colombia 180 dias No. 256	2025-07-03
270	3	CDT Banco Popular 270 dias No. 257	2025-09-16
271	3	CDT BBVA Colombia 720 dias No. 258	2024-09-26
272	3	CDT Bancolombia 270 dias No. 259	2025-04-16
273	3	CDT Davivienda 270 dias No. 260	2026-03-10
274	3	CDT Banco Popular 540 dias No. 261	2024-02-27
275	3	CDT Banco Caja Social 180 dias No. 262	2024-10-11
276	3	CDT Davivienda 270 dias No. 263	2025-02-13
277	3	CDT Banco Popular 720 dias No. 264	2025-03-31
278	3	CDT BBVA Colombia 540 dias No. 265	2025-10-14
279	3	CDT BBVA Colombia 360 dias No. 266	2026-02-13
280	3	CDT Banco Caja Social 180 dias No. 267	2025-03-27
281	3	CDT BBVA Colombia 360 dias No. 268	2025-06-09
282	3	CDT Banco Caja Social 270 dias No. 269	2025-09-05
283	3	CDT Davivienda 540 dias No. 270	2024-10-04
284	3	CDT BBVA Colombia 720 dias No. 271	2024-12-27
285	3	CDT Banco de Occidente 540 dias No. 272	2025-03-27
286	3	CDT Banco de Occidente 540 dias No. 273	2025-07-07
287	3	CDT Banco Caja Social 540 dias No. 274	2025-08-18
288	3	CDT Bancolombia 359 dias No. 275	2026-01-02
289	3	CDT Banco de Bogota 360 dias No. 276	2024-02-22
290	3	CDT Banco Caja Social 540 dias No. 277	2024-06-25
291	3	CDT Bancolombia 360 dias No. 278	2025-06-20
292	3	CDT Banco Popular 360 dias No. 279	2026-02-26
293	3	CDT Banco de Occidente 360 dias No. 280	2026-05-05
294	3	CDT Davivienda 180 dias No. 281	2026-06-16
295	3	CDT Banco de Bogota 360 dias No. 282	2026-08-31
296	3	CDT BBVA Colombia 180 dias No. 283	2024-02-07
297	3	CDT Banco de Occidente 720 dias No. 284	2024-05-17
298	3	CDT Bancolombia 720 dias No. 285	2024-08-07
299	3	CDT Itau Colombia 540 dias No. 286	2026-04-22
300	3	CDT Bancolombia 720 dias No. 287	2026-09-25
301	3	CDT Banco de Bogota 540 dias No. 288	2024-09-18
302	3	CDT Bancolombia 270 dias No. 289	2024-11-18
303	3	CDT Banco Caja Social 720 dias No. 290	2025-05-21
304	3	CDT Itau Colombia 270 dias No. 291	2025-07-17
305	3	CDT Bancolombia 179 dias No. 292	2026-08-03
306	3	CDT Itau Colombia 540 dias No. 293	2026-08-10
307	3	CDT Banco Popular 180 dias No. 294	2026-11-16
308	3	CDT Banco de Bogota 360 dias No. 295	2025-06-04
309	3	CDT Banco de Bogota 270 dias No. 296	2026-01-16
310	3	CDT Banco de Bogota 540 dias No. 297	2026-03-25
311	3	CDT Banco de Occidente 180 dias No. 298	2026-06-08
312	3	CDT Banco de Occidente 540 dias No. 299	2025-10-06
313	3	CDT Davivienda 360 dias No. 300	2026-06-23
314	3	CDT BBVA Colombia 360 dias No. 301	2026-10-15
315	3	CDT Itau Colombia 360 dias No. 302	2025-07-17
316	3	CDT Davivienda 270 dias No. 303	2025-12-17
317	3	CDT Davivienda 357 dias No. 304	2026-01-20
318	3	CDT Itau Colombia 180 dias No. 305	2024-05-22
319	3	CDT BBVA Colombia 180 dias No. 306	2024-11-11
320	3	CDT Banco de Bogota 270 dias No. 307	2025-04-28
321	3	CDT BBVA Colombia 540 dias No. 308	2026-05-11
322	3	CDT Banco de Bogota 180 dias No. 309	2026-07-08
323	3	CDT Banco Caja Social 180 dias No. 310	2026-09-16
324	3	CDT Banco Popular 360 dias No. 311	2024-08-20
325	3	CDT Banco de Bogota 720 dias No. 312	2024-12-18
326	3	CDT Banco Popular 720 dias No. 313	2025-02-27
327	3	CDT Davivienda 720 dias No. 314	2025-04-22
328	3	CDT Banco Popular 360 dias No. 315	2025-07-07
329	3	CDT Davivienda 180 dias No. 316	2025-10-24
330	3	CDT BBVA Colombia 360 dias No. 317	2025-12-29
331	3	CDT Davivienda 180 dias No. 318	2026-06-09
332	3	CDT Banco de Bogota 540 dias No. 319	2026-10-29
333	3	CDT Banco de Bogota 360 dias No. 320	2025-05-06
334	3	CDT BBVA Colombia 180 dias No. 321	2025-07-22
335	3	CDT Davivienda 720 dias No. 322	2025-10-10
336	3	CDT Itau Colombia 270 dias No. 323	2025-12-02
337	3	CDT Banco Caja Social 270 dias No. 324	2026-03-23
338	3	CDT Bancolombia 360 dias No. 325	2026-10-13
339	3	CDT Banco de Bogota 270 dias No. 326	2025-02-04
340	3	CDT Banco Caja Social 360 dias No. 327	2026-02-10
341	3	CDT BBVA Colombia 360 dias No. 328	2026-07-31
342	3	CDT BBVA Colombia 180 dias No. 329	2025-01-31
343	3	CDT Banco de Bogota 270 dias No. 330	2025-08-11
344	3	CDT Banco Popular 360 dias No. 331	2025-11-14
345	3	CDT Banco Popular 270 dias No. 332	2026-08-07
346	3	CDT Banco Caja Social 360 dias No. 333	2026-09-30
\.


--
-- Data for Name: asesor; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.asesor (id_asesor, tipo_documento, numero_documento, nombres, apellidos, email, telefono, fecha_ingreso) FROM stdin;
1	CC	230410946	Laura Monica	Salazar Pardo	laura.salazar@firmaasesora.com.co	6076803055	2018-10-20
2	CC	525254513	Adriana	Mejia Ortiz	adriana.mejia@firmaasesora.com.co	6024409545	2015-10-03
3	CC	1062882747	Carlos	Velez Londono	carlos.velez@firmaasesora.com.co	6054916365	2020-04-13
4	CC	173895737	Oscar	Ospina Restrepo	oscar.ospina@firmaasesora.com.co	6054412579	2020-02-18
5	CC	802087753	Marcela Claudia	Vargas Gomez	marcela.vargas@firmaasesora.com.co	6025345153	2020-08-14
6	CC	923632563	Claudia	Pardo Lopez	claudia.pardo@firmaasesora.com.co	6076401105	2023-10-16
\.


--
-- Data for Name: cdt; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.cdt (id_activo, id_tipo_activo, entidad_emisora, fecha_emision, fecha_vencimiento) FROM stdin;
14	3	Banco de Bogota	2025-07-09	2026-07-04
15	3	Banco Popular	2025-09-29	2026-03-28
16	3	Banco Caja Social	2026-03-16	2028-03-05
17	3	Itau Colombia	2026-10-07	2027-07-04
18	3	Davivienda	2026-02-17	2027-02-12
19	3	Banco de Occidente	2024-08-07	2025-05-04
20	3	Banco Popular	2024-10-11	2026-04-04
21	3	Banco Caja Social	2025-05-16	2026-05-11
22	3	Bancolombia	2025-12-30	2026-12-25
23	3	Itau Colombia	2026-07-17	2027-01-13
24	3	Bancolombia	2024-07-23	2025-07-18
25	3	Banco de Occidente	2025-01-30	2025-10-27
26	3	Banco Caja Social	2025-09-15	2026-03-14
27	3	BBVA Colombia	2025-10-31	2026-04-29
28	3	Banco de Bogota	2024-04-15	2025-01-10
29	3	Banco Popular	2024-07-01	2025-12-23
30	3	Banco de Occidente	2025-04-23	2025-10-20
31	3	Bancolombia	2025-07-03	2026-03-30
32	3	Itau Colombia	2026-03-27	2028-03-16
33	3	Banco Popular	2026-07-14	2027-07-09
34	3	BBVA Colombia	2024-06-03	2025-02-28
35	3	Itau Colombia	2025-06-20	2026-06-15
36	3	Banco Caja Social	2025-02-19	2025-08-18
37	3	Banco Popular	2025-06-10	2026-03-07
38	3	Davivienda	2026-01-21	2027-01-16
39	3	Bancolombia	2026-05-14	2027-05-09
40	3	Bancolombia	2024-05-16	2024-11-12
41	3	Banco Caja Social	2024-07-18	2025-01-14
42	3	BBVA Colombia	2024-11-14	2025-05-13
43	3	Banco Caja Social	2025-02-18	2025-08-17
44	3	Banco de Bogota	2025-10-07	2027-03-31
45	3	Bancolombia	2026-05-27	2027-02-21
46	3	Davivienda	2026-09-24	2027-09-19
47	3	Davivienda	2024-07-10	2025-04-06
48	3	Itau Colombia	2024-09-26	2025-06-23
49	3	Banco de Bogota	2025-04-01	2025-12-27
50	3	Banco de Bogota	2025-05-14	2026-05-09
51	3	Itau Colombia	2025-08-14	2027-08-04
52	3	Banco Caja Social	2025-09-26	2026-09-21
53	3	Banco de Bogota	2026-01-02	2026-12-28
54	3	Banco Caja Social	2026-04-27	2027-10-19
55	3	Bancolombia	2026-10-06	2028-09-25
56	3	Banco Caja Social	2024-07-30	2025-01-26
57	3	Bancolombia	2024-10-29	2025-04-27
58	3	Banco de Occidente	2025-04-28	2026-01-23
59	3	Banco Caja Social	2025-08-25	2026-05-22
60	3	Banco Popular	2025-06-05	2026-05-31
61	3	Banco de Occidente	2025-11-05	2027-10-26
62	3	Itau Colombia	2026-07-06	2027-12-28
63	3	Bancolombia	2026-10-19	2027-10-14
64	3	Itau Colombia	2025-07-07	2027-06-27
65	3	Davivienda	2026-06-30	2028-06-19
66	3	Itau Colombia	2026-08-21	2027-05-18
67	3	Itau Colombia	2024-08-27	2025-05-24
68	3	Itau Colombia	2024-12-18	2026-12-08
69	3	Banco Caja Social	2026-06-22	2028-06-11
70	3	Banco de Occidente	2026-09-25	2027-03-24
71	3	Banco Caja Social	2025-07-31	2026-07-26
72	3	Davivienda	2025-10-01	2026-09-26
73	3	Banco Popular	2025-11-18	2027-05-12
74	3	Bancolombia	2026-05-06	2027-10-28
75	3	Banco Popular	2024-03-14	2024-09-10
76	3	BBVA Colombia	2024-09-06	2025-09-01
77	3	Bancolombia	2025-02-13	2026-08-07
78	3	Itau Colombia	2025-07-07	2027-06-27
79	3	Banco Popular	2025-10-08	2027-09-28
80	3	Banco Caja Social	2026-01-14	2027-07-08
81	3	Banco Popular	2026-07-15	2027-07-10
82	3	Banco Caja Social	2026-10-01	2027-09-26
83	3	Banco Caja Social	2024-01-29	2025-01-23
84	3	Banco Caja Social	2024-08-26	2026-08-16
85	3	Itau Colombia	2025-02-12	2025-08-11
86	3	Davivienda	2025-06-05	2026-05-31
87	3	Banco de Bogota	2025-09-16	2027-03-10
88	3	Banco de Occidente	2025-12-30	2027-06-23
89	3	Banco Popular	2026-07-15	2027-07-10
90	3	Itau Colombia	2024-12-06	2025-12-01
91	3	Banco de Bogota	2025-01-29	2025-07-28
92	3	Itau Colombia	2025-03-13	2025-12-08
93	3	Banco Popular	2025-05-27	2026-05-22
94	3	Davivienda	2025-12-22	2026-09-18
95	3	BBVA Colombia	2026-07-15	2027-01-11
96	3	Itau Colombia	2025-04-04	2026-09-26
97	3	Bancolombia	2025-07-02	2025-12-29
98	3	BBVA Colombia	2026-02-03	2026-08-02
99	3	Banco Popular	2026-05-04	2027-04-29
100	3	BBVA Colombia	2026-05-22	2027-02-16
101	3	Banco Popular	2024-05-20	2025-05-15
102	3	Banco de Bogota	2024-10-07	2026-03-31
103	3	Itau Colombia	2025-03-07	2027-02-25
104	3	Banco Caja Social	2025-05-08	2026-05-03
105	3	Davivienda	2025-06-26	2027-06-16
106	3	Bancolombia	2025-08-21	2027-08-11
107	3	Bancolombia	2026-03-27	2026-12-22
108	3	Banco de Bogota	2026-06-04	2026-12-01
109	3	Banco Caja Social	2026-08-03	2028-07-23
110	3	Davivienda	2024-08-05	2026-01-27
111	3	Banco Caja Social	2024-10-25	2025-10-20
112	3	Itau Colombia	2025-04-16	2025-10-13
113	3	Banco Caja Social	2025-08-05	2027-07-26
114	3	Davivienda	2025-09-19	2027-09-09
115	3	BBVA Colombia	2026-03-18	2028-03-07
116	3	Itau Colombia	2026-07-08	2027-04-04
117	3	Davivienda	2026-10-07	2027-10-02
118	3	Banco Popular	2024-04-22	2025-04-17
119	3	Banco de Bogota	2024-10-25	2025-07-22
120	3	Itau Colombia	2025-12-17	2026-12-12
121	3	Banco Popular	2026-08-06	2027-05-03
122	3	Davivienda	2024-08-26	2025-08-21
123	3	Itau Colombia	2025-08-06	2027-01-28
124	3	Banco de Bogota	2026-05-11	2027-11-02
125	3	Davivienda	2024-11-26	2025-11-21
126	3	Itau Colombia	2025-05-01	2026-04-26
127	3	Banco de Occidente	2025-11-05	2027-04-29
128	3	Banco Caja Social	2026-07-02	2028-06-21
129	3	Banco de Bogota	2024-05-01	2025-04-26
130	3	BBVA Colombia	2024-09-13	2025-09-08
131	3	Banco de Occidente	2025-02-21	2027-02-11
132	3	Banco Popular	2025-08-27	2026-05-24
133	3	Davivienda	2026-03-24	2027-03-19
134	3	Banco de Occidente	2024-06-12	2025-12-04
135	3	Banco de Occidente	2024-09-23	2025-06-20
136	3	Davivienda	2025-06-05	2026-05-31
137	3	Davivienda	2025-09-05	2026-03-04
138	3	BBVA Colombia	2025-05-22	2026-05-17
139	3	Bancolombia	2024-03-18	2025-09-09
140	3	Bancolombia	2024-05-23	2025-02-17
141	3	Banco de Bogota	2025-12-04	2026-11-29
142	3	Banco de Occidente	2024-06-25	2025-06-20
143	3	Banco de Occidente	2024-12-19	2025-06-17
144	3	Banco Popular	2025-04-11	2026-10-03
145	3	Banco Popular	2025-08-14	2026-05-11
146	3	Banco de Bogota	2025-10-22	2027-10-12
147	3	Bancolombia	2025-12-15	2026-12-10
148	3	Banco Caja Social	2026-05-22	2027-05-17
149	3	Davivienda	2025-06-06	2027-05-27
150	3	Davivienda	2025-09-03	2026-05-31
151	3	Banco Caja Social	2024-08-30	2025-05-27
152	3	Banco Popular	2025-06-24	2025-12-21
153	3	Banco Caja Social	2025-04-10	2025-10-07
154	3	Banco de Occidente	2025-12-22	2026-06-20
155	3	Banco Popular	2025-04-30	2027-04-20
156	3	Itau Colombia	2025-08-07	2027-01-29
157	3	Banco Popular	2025-11-11	2027-05-05
158	3	BBVA Colombia	2025-03-26	2026-09-17
159	3	Davivienda	2025-06-03	2027-05-24
160	3	Davivienda	2025-05-27	2026-02-21
161	3	Banco Caja Social	2025-09-02	2027-02-24
162	3	Banco Caja Social	2026-06-23	2026-12-20
163	3	Davivienda	2026-03-16	2026-12-11
164	3	Banco de Occidente	2026-05-07	2027-05-02
165	3	Banco Popular	2024-01-30	2024-07-28
166	3	BBVA Colombia	2024-04-10	2026-03-31
167	3	Davivienda	2024-05-30	2025-05-25
168	3	Banco de Bogota	2024-08-27	2025-02-23
169	3	Davivienda	2024-12-04	2026-05-28
170	3	Davivienda	2025-03-17	2025-12-12
171	3	Banco de Bogota	2025-07-10	2026-04-06
172	3	Banco de Bogota	2025-11-11	2027-05-05
173	3	Banco Caja Social	2026-03-17	2026-12-12
174	3	BBVA Colombia	2024-05-30	2025-05-25
175	3	BBVA Colombia	2024-11-26	2025-11-21
176	3	Banco de Occidente	2025-02-18	2025-08-17
177	3	BBVA Colombia	2025-06-12	2025-12-09
178	3	Banco Popular	2025-08-27	2027-02-18
179	3	Itau Colombia	2026-01-23	2028-01-13
180	3	Banco de Occidente	2026-03-17	2027-03-12
181	3	Bancolombia	2026-05-21	2027-05-16
182	3	Davivienda	2026-07-15	2027-07-10
183	3	Davivienda	2025-06-24	2027-06-14
184	3	Banco de Occidente	2024-07-12	2025-07-07
185	3	Banco Caja Social	2025-11-06	2026-05-05
186	3	Itau Colombia	2025-05-27	2026-05-22
187	3	Banco Popular	2025-10-30	2027-04-23
188	3	BBVA Colombia	2025-12-19	2026-12-14
189	3	Banco de Occidente	2026-06-18	2027-12-10
190	3	Itau Colombia	2026-10-12	2027-10-07
191	3	Itau Colombia	2024-12-16	2025-12-11
192	3	BBVA Colombia	2025-07-17	2026-07-12
193	3	BBVA Colombia	2025-10-08	2026-07-05
194	3	BBVA Colombia	2026-06-16	2028-06-05
195	3	Bancolombia	2026-10-16	2027-07-13
196	3	Banco Popular	2026-01-12	2026-10-09
197	3	Itau Colombia	2026-08-05	2027-02-01
198	3	Bancolombia	2025-01-16	2026-01-11
199	3	Davivienda	2025-03-21	2025-09-17
200	3	Banco Caja Social	2025-05-21	2026-02-15
201	3	Itau Colombia	2025-09-15	2026-06-12
202	3	Banco de Bogota	2026-07-07	2027-01-03
203	3	Banco de Bogota	2024-04-19	2025-01-14
204	3	Banco de Occidente	2024-09-06	2025-03-05
205	3	Bancolombia	2025-02-07	2027-01-28
206	3	Bancolombia	2025-04-02	2027-03-23
207	3	Bancolombia	2025-10-14	2026-07-11
208	3	Banco Popular	2026-04-30	2028-04-19
209	3	BBVA Colombia	2026-07-31	2027-07-26
210	3	Banco Popular	2024-08-05	2026-07-26
211	3	Banco Popular	2026-11-12	2027-08-09
212	3	Banco Caja Social	2024-02-12	2025-02-06
213	3	Davivienda	2024-07-26	2026-07-16
214	3	Banco Caja Social	2025-04-15	2026-04-10
215	3	Banco de Bogota	2025-12-05	2027-11-25
216	3	Itau Colombia	2026-01-23	2027-01-18
217	3	Banco de Bogota	2026-05-21	2027-05-16
218	3	Bancolombia	2024-12-20	2025-12-15
219	3	Davivienda	2025-08-28	2026-08-23
220	3	Banco Caja Social	2025-11-11	2026-11-06
221	3	Itau Colombia	2024-08-13	2026-02-04
222	3	Banco de Bogota	2026-01-26	2027-01-21
223	3	Banco Caja Social	2026-08-04	2027-01-31
224	3	Banco Popular	2024-11-22	2026-11-12
225	3	Itau Colombia	2025-03-26	2026-03-21
226	3	Banco de Bogota	2025-05-29	2026-05-24
227	3	Davivienda	2026-03-04	2027-02-27
228	3	Banco de Bogota	2024-07-30	2025-04-26
229	3	Banco de Bogota	2024-09-13	2025-03-12
230	3	BBVA Colombia	2025-03-18	2026-09-09
231	3	Banco de Occidente	2025-05-12	2026-05-07
232	3	Banco de Occidente	2025-09-05	2026-03-04
233	3	Itau Colombia	2025-10-22	2027-10-12
234	3	Banco de Bogota	2026-02-17	2027-08-11
235	3	Banco Popular	2026-07-07	2027-12-29
236	3	Banco Caja Social	2025-06-17	2025-12-14
237	3	Bancolombia	2025-09-05	2026-06-02
238	3	Banco de Bogota	2025-11-20	2026-08-17
239	3	Banco de Occidente	2026-05-26	2026-11-22
240	3	Banco Popular	2026-06-15	2027-06-10
241	3	Bancolombia	2024-08-29	2025-08-24
242	3	Bancolombia	2024-11-12	2025-11-07
243	3	Davivienda	2025-01-10	2026-01-05
244	3	Banco de Bogota	2025-06-05	2027-05-26
245	3	Banco Caja Social	2026-05-15	2027-05-10
246	3	Banco Caja Social	2026-08-26	2028-08-15
247	3	Davivienda	2025-10-10	2026-10-05
248	3	Davivienda	2026-01-09	2026-10-06
249	3	Banco de Occidente	2024-04-29	2025-04-24
250	3	BBVA Colombia	2025-06-16	2026-06-11
251	3	Bancolombia	2025-12-08	2027-11-28
252	3	Banco Popular	2026-03-30	2028-03-19
253	3	Banco Popular	2026-06-12	2027-03-09
254	3	Itau Colombia	2026-08-25	2027-05-22
255	3	Davivienda	2024-12-10	2026-11-30
256	3	Banco Caja Social	2025-02-12	2025-08-11
257	3	Banco Popular	2025-07-14	2026-01-10
258	3	Banco de Occidente	2025-08-25	2027-08-15
259	3	Banco de Bogota	2026-07-10	2027-07-05
260	3	Banco Caja Social	2024-11-25	2025-11-20
261	3	BBVA Colombia	2025-09-15	2026-09-10
262	3	Itau Colombia	2025-02-07	2027-01-28
263	3	Davivienda	2025-05-22	2025-11-18
264	3	BBVA Colombia	2025-09-22	2026-06-19
265	3	Banco Caja Social	2026-03-18	2027-03-13
266	3	Banco Popular	2026-10-15	2027-10-10
267	3	Banco de Occidente	2025-08-12	2026-08-07
268	3	Banco Caja Social	2026-11-06	2027-05-05
269	3	BBVA Colombia	2025-07-03	2025-12-30
270	3	Banco Popular	2025-09-16	2026-06-13
271	3	BBVA Colombia	2024-09-26	2026-09-16
272	3	Bancolombia	2025-04-16	2026-01-11
273	3	Davivienda	2026-03-10	2026-12-05
274	3	Banco Popular	2024-02-27	2025-08-20
275	3	Banco Caja Social	2024-10-11	2025-04-09
276	3	Davivienda	2025-02-13	2025-11-10
277	3	Banco Popular	2025-03-31	2027-03-21
278	3	BBVA Colombia	2025-10-14	2027-04-07
279	3	BBVA Colombia	2026-02-13	2027-02-08
280	3	Banco Caja Social	2025-03-27	2025-09-23
281	3	BBVA Colombia	2025-06-09	2026-06-04
282	3	Banco Caja Social	2025-09-05	2026-06-02
283	3	Davivienda	2024-10-04	2026-03-28
284	3	BBVA Colombia	2024-12-27	2026-12-17
285	3	Banco de Occidente	2025-03-27	2026-09-18
286	3	Banco de Occidente	2025-07-07	2026-12-29
287	3	Banco Caja Social	2025-08-18	2027-02-09
288	3	Bancolombia	2026-01-02	2026-12-27
289	3	Banco de Bogota	2024-02-22	2025-02-16
290	3	Banco Caja Social	2024-06-25	2025-12-17
291	3	Bancolombia	2025-06-20	2026-06-15
292	3	Banco Popular	2026-02-26	2027-02-21
293	3	Banco de Occidente	2026-05-05	2027-04-30
294	3	Davivienda	2026-06-16	2026-12-13
295	3	Banco de Bogota	2026-08-31	2027-08-26
296	3	BBVA Colombia	2024-02-07	2024-08-05
297	3	Banco de Occidente	2024-05-17	2026-05-07
298	3	Bancolombia	2024-08-07	2026-07-28
299	3	Itau Colombia	2026-04-22	2027-10-14
300	3	Bancolombia	2026-09-25	2028-09-14
301	3	Banco de Bogota	2024-09-18	2026-03-12
302	3	Bancolombia	2024-11-18	2025-08-15
303	3	Banco Caja Social	2025-05-21	2027-05-11
304	3	Itau Colombia	2025-07-17	2026-04-13
305	3	Bancolombia	2026-08-03	2027-01-29
306	3	Itau Colombia	2026-08-10	2028-02-01
307	3	Banco Popular	2026-11-16	2027-05-15
308	3	Banco de Bogota	2025-06-04	2026-05-30
309	3	Banco de Bogota	2026-01-16	2026-10-13
310	3	Banco de Bogota	2026-03-25	2027-09-16
311	3	Banco de Occidente	2026-06-08	2026-12-05
312	3	Banco de Occidente	2025-10-06	2027-03-30
313	3	Davivienda	2026-06-23	2027-06-18
314	3	BBVA Colombia	2026-10-15	2027-10-10
315	3	Itau Colombia	2025-07-17	2026-07-12
316	3	Davivienda	2025-12-17	2026-09-13
317	3	Davivienda	2026-01-20	2027-01-12
318	3	Itau Colombia	2024-05-22	2024-11-18
319	3	BBVA Colombia	2024-11-11	2025-05-10
320	3	Banco de Bogota	2025-04-28	2026-01-23
321	3	BBVA Colombia	2026-05-11	2027-11-02
322	3	Banco de Bogota	2026-07-08	2027-01-04
323	3	Banco Caja Social	2026-09-16	2027-03-15
324	3	Banco Popular	2024-08-20	2025-08-15
325	3	Banco de Bogota	2024-12-18	2026-12-08
326	3	Banco Popular	2025-02-27	2027-02-17
327	3	Davivienda	2025-04-22	2027-04-12
328	3	Banco Popular	2025-07-07	2026-07-02
329	3	Davivienda	2025-10-24	2026-04-22
330	3	BBVA Colombia	2025-12-29	2026-12-24
331	3	Davivienda	2026-06-09	2026-12-06
332	3	Banco de Bogota	2026-10-29	2028-04-21
333	3	Banco de Bogota	2025-05-06	2026-05-01
334	3	BBVA Colombia	2025-07-22	2026-01-18
335	3	Davivienda	2025-10-10	2027-09-30
336	3	Itau Colombia	2025-12-02	2026-08-29
337	3	Banco Caja Social	2026-03-23	2026-12-18
338	3	Bancolombia	2026-10-13	2027-10-08
339	3	Banco de Bogota	2025-02-04	2025-11-01
340	3	Banco Caja Social	2026-02-10	2027-02-05
341	3	BBVA Colombia	2026-07-31	2027-07-26
342	3	BBVA Colombia	2025-01-31	2025-07-30
343	3	Banco de Bogota	2025-08-11	2026-05-08
344	3	Banco Popular	2025-11-14	2026-11-09
345	3	Banco Popular	2026-08-07	2027-05-04
346	3	Banco Caja Social	2026-09-30	2027-09-25
\.


--
-- Data for Name: cliente; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.cliente (id_cliente, id_perfil, id_asesor, tipo_documento, numero_documento, nombres, apellidos, email, telefono, fecha_nacimiento, fecha_vinculacion) FROM stdin;
1	3	3	CC	114985539	Camila	Giraldo Garcia	camila.giraldo1@outlook.com	3018663770	1997-02-23	2025-06-20
2	3	3	CC	1187140015	Rafael Mauricio	Acosta Vargas	rafael.acosta2@outlook.com	3101555481	1999-08-26	2025-06-07
3	2	4	CC	1061230891	Nicolas	Zapata Restrepo	nicolas.zapata3@outlook.com	3181564049	1971-12-16	2024-08-01
4	1	4	CC	1116326317	Carlos	Rincon Zapata	carlos.rincon4@outlook.com	3114264621	1982-12-16	2024-07-06
5	2	1	CC	10459496	Daniela	Gomez Martinez	daniela.gomez5@hotmail.com	3153596457	1994-04-08	2024-04-08
6	2	5	CC	1066538156	Claudia	Cortes Pardo	claudia.cortes6@hotmail.com	3242416554	1989-04-16	2024-05-23
7	2	1	CC	667139295	Felipe	Cortes Mejia	felipe.cortes7@gmail.com	3111861935	1964-09-26	2025-02-09
8	2	2	CC	662130049	Camila Adriana	Moreno Acosta	camila.moreno8@hotmail.com	3238274727	1986-08-19	2024-05-06
9	1	1	CC	83342339	Nicolas Juan	Gutierrez Jimenez	nicolas.gutierrez9@hotmail.com	3071343426	1957-11-18	2024-07-06
10	1	5	CC	305755231	Natalia	Restrepo Londono	natalia.restrepo10@outlook.com	3126772469	1979-05-14	2024-07-20
11	2	2	CC	1045200467	Alejandro	Moreno Restrepo	alejandro.moreno11@gmail.com	3076543899	1988-05-27	2025-07-01
12	2	4	CC	346637656	Paula	Rojas Pardo	paula.rojas12@hotmail.com	3095944247	1962-10-23	2024-08-11
13	1	4	CC	377810448	Carlos	Lopez Castro	carlos.lopez13@hotmail.com	3142072316	1977-12-26	2024-03-09
14	2	1	CE	561993560	Sebastian Juan	Gomez Castro	sebastian.gomez14@hotmail.com	3296877173	1958-02-08	2024-01-24
15	3	5	CC	91627690	Nicolas	Rincon Cardenas	nicolas.rincon15@gmail.com	3259409777	1993-04-20	2024-11-22
16	3	4	CC	133761009	Jorge	Velez Rojas	jorge.velez16@gmail.com	3166349960	1956-05-23	2025-03-25
17	3	1	CC	130570794	Rafael	Ramirez Gutierrez	rafael.ramirez17@outlook.com	3241483086	1965-10-04	2024-04-30
18	2	5	CC	914059353	Oscar	Jimenez Torres	oscar.jimenez18@hotmail.com	3265277759	1966-09-01	2024-05-08
19	1	5	CC	685909076	Carolina	Castro Diaz	carolina.castro19@hotmail.com	3159731684	1966-09-02	2024-03-31
20	2	4	CC	531422992	Valentina	Gomez Salazar	valentina.gomez20@outlook.com	3254900916	1998-09-28	2024-08-18
21	3	3	CC	1028041805	Marcela	Gutierrez Zapata	marcela.gutierrez21@gmail.com	3187850588	1967-03-21	2024-11-14
22	2	4	CC	306268102	Diana	Ospina Diaz	diana.ospina22@outlook.com	3207598076	1956-09-07	2024-04-18
23	1	1	CC	1102556945	Monica	Acosta Hernandez	monica.acosta23@hotmail.com	3233721443	1979-06-18	2024-06-01
24	3	4	CC	30291201	Alejandro	Jimenez Ramirez	alejandro.jimenez24@hotmail.com	3081495142	1982-06-26	2025-05-17
25	3	3	CC	14279281	Daniela Laura	Restrepo Acosta	daniela.restrepo25@gmail.com	3016474258	1978-05-07	2024-03-11
26	2	3	CC	756892809	Jorge	Salazar Lopez	jorge.salazar26@outlook.com	3252384950	1962-09-17	2025-06-04
27	3	2	CC	579735994	Maria	Giraldo Vargas	maria.giraldo27@hotmail.com	3277762381	1965-06-14	2024-08-25
28	1	2	CC	829539076	Oscar	Rojas Castro	oscar.rojas28@gmail.com	3148456619	1991-11-24	2025-04-04
29	1	4	CE	274647734	Miguel Felipe	Gutierrez Giraldo	miguel.gutierrez29@hotmail.com	3152593937	1995-07-13	2025-04-15
30	2	3	CC	1183409144	Adriana	Pardo Salazar	adriana.pardo30@gmail.com	3045230777	1977-11-11	2025-03-19
31	3	4	CC	1032079332	Gloria	Giraldo Zapata	gloria.giraldo31@hotmail.com	3151298434	1976-01-02	2025-05-08
32	2	5	CC	412980915	Gloria	Martinez Gutierrez	gloria.martinez32@gmail.com	3226191677	1961-03-11	2024-01-22
33	1	5	CC	242048259	Monica	Gutierrez Garcia	monica.gutierrez33@outlook.com	3256763948	1957-03-18	2025-03-12
34	2	5	CC	88845852	Hernan Ricardo	Velez Diaz	hernan.velez34@outlook.com	3055590830	1956-08-26	2024-05-20
35	3	5	CC	892312242	Catalina Claudia	Rodriguez Velez	catalina.rodriguez35@hotmail.com	3089765137	1998-09-25	2025-06-07
36	3	4	CC	177649655	Ricardo	Rojas Hernandez	ricardo.rojas36@hotmail.com	3008781431	1971-09-17	2024-07-05
37	1	4	CC	1059225217	Gabriel Jorge	Giraldo Pardo	gabriel.giraldo37@gmail.com	3093568720	1978-11-13	2024-11-29
38	1	1	CC	308905425	Santiago Alejandro	Velez Hernandez	santiago.velez38@gmail.com	3227944378	1963-08-06	2025-01-03
39	2	5	CC	1115046667	Rafael	Vargas Torres	rafael.vargas39@gmail.com	3281675668	1984-11-24	2024-04-08
40	2	1	CC	562392286	Claudia	Rincon Velez	claudia.rincon40@hotmail.com	3133863352	1965-09-07	2024-02-06
41	3	5	CC	996525528	Angela Luisa	Ospina Castro	angela.ospina41@hotmail.com	3114540890	1974-11-24	2024-08-02
42	2	4	CC	447158589	Gloria	Lopez Hernandez	gloria.lopez42@hotmail.com	3147127492	1982-01-18	2024-07-17
43	3	3	CC	240774649	Carolina	Suarez Garcia	carolina.suarez43@hotmail.com	3286473593	1977-08-13	2024-08-14
44	3	1	CC	1138281981	Marcela	Gutierrez Velez	marcela.gutierrez44@hotmail.com	3192825314	1972-05-02	2024-04-16
45	1	2	CC	1171322205	Ivan	Cardenas Suarez	ivan.cardenas45@outlook.com	3002193284	1963-01-04	2024-11-21
46	2	3	CC	729221166	Laura	Pardo Londono	laura.pardo46@gmail.com	3139624957	1985-04-11	2024-11-16
47	2	2	CC	254205809	Adriana Paula	Ortiz Ramirez	adriana.ortiz47@hotmail.com	3088808472	1985-09-01	2025-01-24
48	2	5	CC	66473979	Carolina	Pardo Ospina	carolina.pardo48@hotmail.com	3083853179	1965-09-04	2025-06-20
49	3	2	CC	870962304	Laura	Zapata Castro	laura.zapata49@outlook.com	3115284062	1967-01-09	2024-09-16
50	2	3	CC	970775721	Santiago Rafael	Lopez Londono	santiago.lopez50@gmail.com	3071788770	1977-12-15	2024-02-16
51	2	3	CC	103640513	Carolina Diana	Cardenas Salazar	carolina.cardenas51@hotmail.com	3284992785	1959-12-24	2024-09-26
52	1	3	CC	1006482264	Rafael	Gutierrez Jimenez	rafael.gutierrez52@hotmail.com	3024974284	1955-07-13	2024-02-11
53	2	5	CC	372744165	Gabriel	Jimenez Diaz	gabriel.jimenez53@hotmail.com	3238958451	1977-02-24	2024-01-20
54	1	3	CC	825062773	Adriana	Garcia Gomez	adriana.garcia54@outlook.com	3091352534	1995-07-22	2025-05-25
55	2	2	CC	395773399	Sofia	Cardenas Acosta	sofia.cardenas55@outlook.com	3215071051	1955-01-11	2025-06-29
56	1	3	CC	1036749042	Sebastian	Restrepo Cortes	sebastian.restrepo56@outlook.com	3075957493	1955-10-17	2024-05-19
57	3	2	CC	156579939	Miguel	Ortiz Zapata	miguel.ortiz57@outlook.com	3297886067	1983-08-24	2024-10-11
58	1	5	CC	1186649165	Ricardo	Lopez Cardenas	ricardo.lopez58@gmail.com	3253782960	1999-05-23	2024-08-07
59	2	3	CC	1189137029	Nicolas Rafael	Jimenez Ramirez	nicolas.jimenez59@gmail.com	3241628272	1999-05-12	2025-01-23
60	2	2	CE	278512508	David Fernando	Acosta Mejia	david.acosta60@gmail.com	3286661299	1995-08-22	2025-01-22
\.


--
-- Data for Name: cuenta; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.cuenta (id_cuenta, id_cliente, nombre_cuenta, fecha_apertura, saldo_efectivo, estado) FROM stdin;
35	28	Inversion de largo plazo	2026-04-23	83098.32	ACTIVA
28	24	Portafolio principal	2025-05-19	11946.35	ACTIVA
53	41	Portafolio principal	2024-08-13	9827.99	ACTIVA
31	26	Portafolio principal	2025-06-05	9722.45	ACTIVA
43	35	Portafolio principal	2025-06-16	1014.77	ACTIVA
34	28	Portafolio principal	2025-04-08	13981.63	ACTIVA
6	6	Portafolio principal	2024-05-29	109428.08	ACTIVA
32	27	Portafolio principal	2024-08-30	17660.87	ACTIVA
49	39	Portafolio principal	2024-04-15	9090.95	ACTIVA
64	48	Portafolio principal	2025-06-27	8192.38	ACTIVA
2	2	Portafolio principal	2025-06-09	1242.37	ACTIVA
33	27	Fondo educativo	2025-06-23	7195.57	ACTIVA
37	30	Portafolio principal	2025-03-21	29366.99	ACTIVA
18	16	Portafolio principal	2025-04-03	78001.66	ACTIVA
29	25	Portafolio principal	2024-03-18	37806.26	ACTIVA
44	36	Portafolio principal	2024-07-08	13740.90	ACTIVA
51	40	Portafolio principal	2024-02-09	63236.05	ACTIVA
65	49	Portafolio principal	2024-09-18	50195.75	ACTIVA
21	18	Ahorro para retiro	2024-07-30	26656.02	ACTIVA
4	4	Portafolio principal	2024-07-17	16232.00	ACTIVA
8	8	Portafolio principal	2024-05-15	7154.95	ACTIVA
12	11	Portafolio principal	2025-07-07	478.33	ACTIVA
16	14	Portafolio principal	2024-01-29	15634.63	ACTIVA
38	31	Portafolio principal	2025-05-20	34886.03	ACTIVA
56	42	Portafolio en dolares	2025-06-16	70571.01	ACTIVA
67	50	Ahorro para retiro	2025-03-19	72074.59	ACTIVA
47	37	Ahorro para retiro	2026-01-12	58923.12	ACTIVA
17	15	Portafolio principal	2024-12-02	152183.24	ACTIVA
76	57	Portafolio principal	2024-10-18	220.30	ACTIVA
15	13	Portafolio principal	2024-03-13	90169.74	ACTIVA
73	54	Portafolio en dolares	2025-10-01	3662.70	ACTIVA
30	25	Portafolio en dolares	2024-06-24	177813.94	ACTIVA
46	37	Portafolio principal	2024-12-10	32648.66	ACTIVA
11	10	Portafolio en dolares	2025-06-02	17469.79	ACTIVA
23	20	Portafolio principal	2024-08-26	8277.63	ACTIVA
22	19	Portafolio principal	2024-04-12	33413.77	ACTIVA
20	18	Portafolio principal	2024-05-20	77363.47	ACTIVA
7	7	Portafolio principal	2025-02-14	107334.74	ACTIVA
9	9	Portafolio principal	2024-07-08	47166.90	ACTIVA
10	10	Portafolio principal	2024-07-22	39692.47	ACTIVA
25	21	Ahorro para retiro	2025-04-23	12687.79	ACTIVA
42	34	Portafolio principal	2024-05-28	22036.00	ACTIVA
45	36	Fondo educativo	2025-05-27	83358.87	ACTIVA
48	38	Portafolio principal	2025-01-13	30138.99	ACTIVA
57	43	Portafolio principal	2024-08-26	87697.46	ACTIVA
70	53	Portafolio principal	2024-01-31	714.38	ACTIVA
74	55	Portafolio principal	2025-07-09	68923.36	ACTIVA
58	43	Ahorro para retiro	2025-10-09	75039.36	ACTIVA
59	44	Portafolio principal	2024-04-22	61858.26	ACTIVA
63	47	Inversion de largo plazo	2025-08-07	16190.30	ACTIVA
24	21	Portafolio principal	2024-11-26	4603.24	ACTIVA
1	1	Portafolio principal	2025-06-30	21870.53	ACTIVA
3	3	Portafolio principal	2024-08-05	6569.52	ACTIVA
5	5	Portafolio principal	2024-04-08	646.04	ACTIVA
13	12	Portafolio principal	2024-08-20	38823.04	ACTIVA
14	12	Fondo educativo	2025-07-30	102880.96	ACTIVA
19	17	Portafolio principal	2024-05-06	3386.08	ACTIVA
26	22	Portafolio principal	2024-04-24	1788.28	ACTIVA
27	23	Portafolio principal	2024-06-05	64869.03	ACTIVA
36	29	Portafolio principal	2025-04-25	1153.81	ACTIVA
39	31	Inversion de largo plazo	2026-03-10	21664.56	ACTIVA
40	32	Portafolio principal	2024-01-23	44040.85	ACTIVA
41	33	Portafolio principal	2025-03-17	8946.32	ACTIVA
52	40	Fondo educativo	2024-12-18	12777.50	ACTIVA
55	42	Portafolio principal	2024-07-23	78794.04	ACTIVA
60	45	Portafolio principal	2024-12-03	30888.01	ACTIVA
61	46	Portafolio principal	2024-11-21	50473.32	ACTIVA
62	47	Portafolio principal	2025-02-05	9219.16	ACTIVA
66	50	Portafolio principal	2024-02-20	73770.95	ACTIVA
68	51	Portafolio principal	2024-10-03	15863.68	ACTIVA
69	52	Portafolio principal	2024-02-13	3226.38	ACTIVA
72	54	Portafolio principal	2025-06-04	22232.47	ACTIVA
75	56	Portafolio principal	2024-05-21	73410.72	ACTIVA
77	58	Portafolio principal	2024-08-19	184985.15	ACTIVA
78	58	Fondo educativo	2025-05-05	95225.32	ACTIVA
79	59	Portafolio principal	2025-02-03	10285.92	ACTIVA
80	60	Portafolio principal	2025-01-30	26716.16	ACTIVA
50	39	Inversion de largo plazo	2024-08-01	295.34	ACTIVA
54	41	Inversion de largo plazo	2024-11-21	55291.24	ACTIVA
71	53	Fondo educativo	2024-09-12	149213.63	ACTIVA
\.


--
-- Data for Name: movimiento_efectivo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.movimiento_efectivo (id_movimiento, id_cuenta, tipo_movimiento, fecha_hora, monto) FROM stdin;
1	40	DEPOSITO	2024-01-23 10:15:00	78117.35
2	16	DEPOSITO	2024-01-29 11:27:00	94210.99
3	70	DEPOSITO	2024-01-31 09:45:00	39784.16
4	51	DEPOSITO	2024-02-09 11:32:00	59010.02
5	69	DEPOSITO	2024-02-13 09:38:00	28009.47
6	66	DEPOSITO	2024-02-20 13:17:00	64963.25
7	15	DEPOSITO	2024-03-13 11:20:00	238612.40
8	29	DEPOSITO	2024-03-18 12:58:00	51573.00
9	5	DEPOSITO	2024-04-08 10:10:00	32578.85
10	40	DEPOSITO	2024-04-10 10:15:00	12718.42
11	22	DEPOSITO	2024-04-12 12:09:00	50030.38
12	49	DEPOSITO	2024-04-15 11:18:00	16164.64
13	59	DEPOSITO	2024-04-22 12:28:00	74789.36
14	26	DEPOSITO	2024-04-24 12:37:00	33751.59
15	66	RETIRO	2024-05-03 13:17:00	836.03
16	19	DEPOSITO	2024-05-06 11:48:00	16576.35
17	8	DEPOSITO	2024-05-15 10:31:00	43270.35
18	20	DEPOSITO	2024-05-20 11:55:00	65454.28
19	75	DEPOSITO	2024-05-21 10:20:00	130601.77
20	29	DEPOSITO	2024-05-23 12:58:00	9907.45
21	42	DEPOSITO	2024-05-28 10:29:00	68948.09
22	6	DEPOSITO	2024-05-29 10:17:00	238955.14
23	40	DEPOSITO	2024-05-30 10:15:00	19395.91
24	27	DEPOSITO	2024-06-05 12:44:00	45251.55
25	30	DEPOSITO	2024-06-24 13:05:00	223278.86
26	19	DEPOSITO	2024-06-25 11:48:00	3639.32
27	59	RETIRO	2024-07-01 12:28:00	262.91
28	15	RETIRO	2024-07-02 11:20:00	1333.17
29	9	DEPOSITO	2024-07-08 10:38:00	82377.36
30	44	DEPOSITO	2024-07-08 10:43:00	28334.43
31	49	DEPOSITO	2024-07-08 11:18:00	964.29
32	4	DEPOSITO	2024-07-17 10:03:00	13468.20
33	75	RETIRO	2024-07-17 10:20:00	4504.49
34	8	DEPOSITO	2024-07-18 10:31:00	7845.53
35	10	DEPOSITO	2024-07-22 10:45:00	36324.17
36	55	DEPOSITO	2024-07-23 12:00:00	89736.22
37	26	DEPOSITO	2024-07-24 12:37:00	2821.70
38	51	DEPOSITO	2024-07-26 11:32:00	11511.30
39	21	DEPOSITO	2024-07-30 12:02:00	131451.88
40	50	DEPOSITO	2024-08-01 11:25:00	11534.34
41	3	DEPOSITO	2024-08-05 09:56:00	21449.83
42	53	DEPOSITO	2024-08-13 11:46:00	22772.16
43	77	DEPOSITO	2024-08-19 10:34:00	140796.14
44	13	DEPOSITO	2024-08-20 11:06:00	80512.37
45	66	RETIRO	2024-08-23 13:17:00	411.91
46	16	DEPOSITO	2024-08-26 11:27:00	16949.48
47	57	DEPOSITO	2024-08-26 12:14:00	113522.12
48	23	DEPOSITO	2024-08-26 12:16:00	23479.32
49	6	RETIRO	2024-08-27 10:17:00	622.56
50	69	RETIRO	2024-08-30 09:38:00	185.25
51	32	DEPOSITO	2024-08-30 13:19:00	17621.62
52	15	DEPOSITO	2024-09-06 11:20:00	15783.38
53	71	DEPOSITO	2024-09-12 09:52:00	100286.01
54	55	DEPOSITO	2024-09-13 12:00:00	10136.36
55	26	DEPOSITO	2024-09-13 12:37:00	7748.94
56	65	DEPOSITO	2024-09-18 13:10:00	139452.65
57	59	DEPOSITO	2024-09-19 12:28:00	4582.61
58	27	DEPOSITO	2024-09-23 12:44:00	5999.83
59	68	DEPOSITO	2024-10-03 13:31:00	21454.66
60	20	DEPOSITO	2024-10-07 11:55:00	8999.27
61	4	DEPOSITO	2024-10-10 10:03:00	1574.04
62	3	DEPOSITO	2024-10-11 09:56:00	5749.78
63	66	DEPOSITO	2024-10-11 13:17:00	7900.39
64	76	DEPOSITO	2024-10-18 10:27:00	7537.03
65	21	DEPOSITO	2024-10-25 12:02:00	7513.30
66	32	DEPOSITO	2024-10-28 13:19:00	4781.79
67	5	RETIRO	2024-10-29 10:10:00	17.27
68	10	DEPOSITO	2024-10-29 10:45:00	2772.90
69	51	RETIRO	2024-11-04 11:32:00	2847.66
70	44	RETIRO	2024-11-08 10:43:00	454.37
71	57	DEPOSITO	2024-11-12 12:14:00	9901.40
72	8	DEPOSITO	2024-11-14 10:31:00	3300.70
73	71	DEPOSITO	2024-11-18 09:52:00	13257.44
74	54	DEPOSITO	2024-11-21 11:53:00	85814.61
75	61	DEPOSITO	2024-11-21 12:42:00	89505.00
76	42	DEPOSITO	2024-11-26 10:29:00	17431.19
77	24	DEPOSITO	2024-11-26 12:23:00	8309.36
78	17	DEPOSITO	2024-12-02 11:34:00	167503.43
79	29	DEPOSITO	2024-12-02 12:58:00	3048.34
80	60	DEPOSITO	2024-12-03 12:35:00	81909.34
81	40	DEPOSITO	2024-12-04 10:15:00	17980.68
82	66	RETIRO	2024-12-06 13:17:00	84.80
83	46	DEPOSITO	2024-12-10 10:57:00	55543.82
84	49	DEPOSITO	2024-12-16 11:18:00	1034.54
85	77	DEPOSITO	2024-12-18 10:34:00	7729.89
86	52	DEPOSITO	2024-12-18 11:39:00	13071.23
87	30	DEPOSITO	2024-12-19 13:05:00	16910.01
88	10	DEPOSITO	2024-12-24 10:45:00	1832.12
89	26	DEPOSITO	2024-12-24 12:37:00	2513.26
90	68	DEPOSITO	2024-12-27 13:31:00	6352.34
91	21	RETIRO	2025-01-07 12:02:00	20061.18
92	9	RETIRO	2025-01-13 10:38:00	134.91
93	48	DEPOSITO	2025-01-13 11:11:00	31448.07
94	20	RETIRO	2025-01-15 11:55:00	4739.00
95	4	DEPOSITO	2025-01-30 10:03:00	2199.99
96	75	RETIRO	2025-01-30 10:20:00	19551.39
97	80	DEPOSITO	2025-01-30 10:55:00	114032.01
98	3	RETIRO	2025-02-03 09:56:00	1223.50
99	79	DEPOSITO	2025-02-03 10:48:00	26456.63
100	62	DEPOSITO	2025-02-05 12:49:00	103779.81
101	29	DEPOSITO	2025-02-05 12:58:00	6007.92
102	49	DEPOSITO	2025-02-07 11:18:00	2773.57
103	6	RETIRO	2025-02-10 10:17:00	4973.67
104	16	DEPOSITO	2025-02-12 11:27:00	18450.31
105	15	DEPOSITO	2025-02-13 11:20:00	46025.42
106	66	DEPOSITO	2025-02-13 13:17:00	5768.59
107	7	DEPOSITO	2025-02-14 10:24:00	162318.35
108	42	DEPOSITO	2025-02-18 10:29:00	4293.20
109	8	DEPOSITO	2025-02-18 10:31:00	2584.68
110	53	RETIRO	2025-02-18 11:46:00	524.70
111	24	RETIRO	2025-02-19 12:23:00	244.83
112	77	DEPOSITO	2025-02-27 10:34:00	15513.70
113	27	RETIRO	2025-03-10 12:44:00	2818.23
114	17	DEPOSITO	2025-03-13 11:34:00	11983.67
115	41	DEPOSITO	2025-03-17 10:22:00	22902.61
116	55	DEPOSITO	2025-03-18 12:00:00	22330.15
117	79	RETIRO	2025-03-19 10:48:00	1335.76
118	67	DEPOSITO	2025-03-19 13:24:00	87421.56
119	37	DEPOSITO	2025-03-21 09:54:00	34986.11
120	54	DEPOSITO	2025-03-26 11:53:00	23786.32
121	68	DEPOSITO	2025-03-27 13:31:00	2557.27
122	66	DEPOSITO	2025-03-31 13:17:00	8730.85
123	40	RETIRO	2025-04-01 10:15:00	13246.32
124	9	DEPOSITO	2025-04-01 10:38:00	20890.16
125	19	RETIRO	2025-04-01 11:48:00	1505.23
126	61	RETIRO	2025-04-01 12:42:00	77.83
127	18	DEPOSITO	2025-04-03 11:41:00	171931.43
128	23	RETIRO	2025-04-08 12:16:00	3216.90
129	34	DEPOSITO	2025-04-08 13:33:00	10241.60
130	30	DEPOSITO	2025-04-11 13:05:00	29864.45
131	51	DEPOSITO	2025-04-15 11:32:00	14332.84
132	77	DEPOSITO	2025-04-22 10:34:00	21134.27
133	25	DEPOSITO	2025-04-23 12:30:00	17134.83
134	36	DEPOSITO	2025-04-25 09:47:00	79118.93
135	10	DEPOSITO	2025-04-28 10:48:00	5156.95
136	76	DEPOSITO	2025-05-02 10:27:00	1467.83
137	26	DEPOSITO	2025-05-02 12:37:00	2720.27
138	78	DEPOSITO	2025-05-05 10:41:00	79262.39
139	20	DEPOSITO	2025-05-08 11:55:00	7303.15
140	55	DEPOSITO	2025-05-12 12:00:00	18496.36
141	3	DEPOSITO	2025-05-16 09:56:00	4541.75
142	28	DEPOSITO	2025-05-19 12:51:00	40327.42
143	38	DEPOSITO	2025-05-20 10:01:00	68322.78
144	71	DEPOSITO	2025-05-21 09:52:00	26699.84
145	48	DEPOSITO	2025-05-21 11:11:00	5439.92
146	62	DEPOSITO	2025-05-22 12:49:00	21929.68
147	60	RETIRO	2025-05-23 12:35:00	325.61
148	45	DEPOSITO	2025-05-27 10:50:00	245211.94
149	17	DEPOSITO	2025-05-27 11:34:00	30612.04
150	53	RETIRO	2025-05-29 11:46:00	496.72
151	22	RETIRO	2025-05-29 12:09:00	11521.94
152	11	DEPOSITO	2025-06-02 10:52:00	16987.11
153	72	DEPOSITO	2025-06-04 09:59:00	19079.44
154	16	DEPOSITO	2025-06-05 11:27:00	15032.90
155	57	DEPOSITO	2025-06-05 12:14:00	22418.25
156	27	DEPOSITO	2025-06-05 12:44:00	11543.98
157	31	DEPOSITO	2025-06-05 13:12:00	29017.22
158	2	DEPOSITO	2025-06-09 09:49:00	11790.45
159	67	DEPOSITO	2025-06-09 13:24:00	23221.53
160	7	DEPOSITO	2025-06-10 10:24:00	11829.30
161	42	DEPOSITO	2025-06-12 10:29:00	19340.99
162	43	DEPOSITO	2025-06-16 10:36:00	16847.36
163	44	DEPOSITO	2025-06-16 10:43:00	7291.85
164	56	DEPOSITO	2025-06-16 12:07:00	98620.30
165	59	DEPOSITO	2025-06-16 12:28:00	8110.64
166	33	DEPOSITO	2025-06-23 13:26:00	27667.82
167	20	DEPOSITO	2025-06-26 11:55:00	15636.95
168	64	DEPOSITO	2025-06-27 13:03:00	11797.61
169	1	DEPOSITO	2025-06-30 09:42:00	38648.93
170	8	RETIRO	2025-07-02 10:31:00	5853.76
171	18	DEPOSITO	2025-07-02 11:41:00	16058.73
172	5	DEPOSITO	2025-07-03 10:10:00	9298.97
173	77	DEPOSITO	2025-07-07 10:34:00	19026.62
174	12	DEPOSITO	2025-07-07 10:59:00	23159.65
175	15	DEPOSITO	2025-07-07 11:20:00	40902.34
176	68	DEPOSITO	2025-07-07 13:31:00	2768.56
177	74	DEPOSITO	2025-07-09 10:13:00	58842.53
178	41	DEPOSITO	2025-07-10 10:22:00	2964.87
179	60	DEPOSITO	2025-07-14 12:35:00	23898.62
180	13	RETIRO	2025-07-16 11:06:00	20129.06
181	71	DEPOSITO	2025-07-17 09:52:00	9976.02
182	46	DEPOSITO	2025-07-17 10:57:00	14789.36
183	78	DEPOSITO	2025-07-22 10:41:00	12132.11
184	40	RETIRO	2025-07-29 10:15:00	6038.16
185	14	DEPOSITO	2025-07-30 11:13:00	85824.84
186	65	DEPOSITO	2025-07-30 13:10:00	12084.09
187	49	DEPOSITO	2025-07-31 11:18:00	1857.07
188	16	RETIRO	2025-08-04 11:27:00	30702.35
189	23	DEPOSITO	2025-08-06 12:16:00	2553.17
190	63	DEPOSITO	2025-08-07 12:56:00	44993.36
191	80	DEPOSITO	2025-08-11 10:55:00	5819.24
192	9	DEPOSITO	2025-08-14 10:38:00	13738.02
193	5	RETIRO	2025-08-18 10:10:00	303.07
194	51	RETIRO	2025-08-19 11:32:00	9145.48
195	75	RETIRO	2025-08-20 10:20:00	8919.33
196	20	DEPOSITO	2025-08-21 11:55:00	12783.66
197	10	DEPOSITO	2025-08-25 10:45:00	6449.49
198	60	DEPOSITO	2025-08-25 12:35:00	15833.43
199	79	DEPOSITO	2025-08-26 10:48:00	3726.81
200	42	DEPOSITO	2025-08-27 10:29:00	17038.70
201	43	RETIRO	2025-08-27 10:36:00	440.68
202	26	DEPOSITO	2025-08-27 12:37:00	9621.03
203	52	DEPOSITO	2025-08-28 11:39:00	3318.36
204	29	DEPOSITO	2025-08-28 12:58:00	3855.08
205	38	DEPOSITO	2025-09-02 10:01:00	6217.51
206	57	RETIRO	2025-09-04 12:14:00	7977.37
207	55	DEPOSITO	2025-09-05 12:00:00	6609.33
208	56	DEPOSITO	2025-09-05 12:07:00	11358.74
209	27	DEPOSITO	2025-09-05 12:44:00	9907.02
210	67	DEPOSITO	2025-09-05 13:24:00	5965.16
211	44	DEPOSITO	2025-09-11 10:43:00	1867.13
212	48	DEPOSITO	2025-09-15 11:11:00	1999.46
213	61	DEPOSITO	2025-09-15 12:42:00	11040.91
214	32	DEPOSITO	2025-09-15 13:19:00	2118.72
215	16	DEPOSITO	2025-09-16 11:27:00	24389.65
216	64	DEPOSITO	2025-09-16 13:03:00	3317.65
217	28	RETIRO	2025-09-18 12:51:00	356.96
218	21	DEPOSITO	2025-09-19 12:02:00	28672.57
219	62	DEPOSITO	2025-09-22 12:49:00	5686.27
220	70	RETIRO	2025-09-24 09:45:00	3658.78
221	19	DEPOSITO	2025-09-24 11:48:00	2261.78
222	9	DEPOSITO	2025-09-26 10:38:00	10561.00
223	37	RETIRO	2025-09-30 09:54:00	19.36
224	73	DEPOSITO	2025-10-01 10:06:00	88065.00
225	14	DEPOSITO	2025-10-01 11:13:00	7519.32
226	8	DEPOSITO	2025-10-07 10:31:00	2649.08
227	46	DEPOSITO	2025-10-08 10:57:00	14095.19
228	15	DEPOSITO	2025-10-08 11:20:00	71255.19
229	76	DEPOSITO	2025-10-09 10:27:00	1223.10
230	58	DEPOSITO	2025-10-09 12:21:00	62162.66
231	78	DEPOSITO	2025-10-10 10:41:00	21250.54
232	49	DEPOSITO	2025-10-14 11:18:00	4409.49
233	66	DEPOSITO	2025-10-14 13:17:00	18922.67
234	55	DEPOSITO	2025-10-22 12:00:00	18433.35
235	77	DEPOSITO	2025-10-24 10:34:00	26489.92
236	72	DEPOSITO	2025-10-30 09:59:00	1367.77
237	4	DEPOSITO	2025-10-31 10:03:00	3929.89
238	29	RETIRO	2025-10-31 12:58:00	5828.21
239	24	DEPOSITO	2025-11-03 12:23:00	649.78
240	13	RETIRO	2025-11-04 11:06:00	6909.10
241	25	DEPOSITO	2025-11-05 12:30:00	4402.30
242	53	DEPOSITO	2025-11-10 11:46:00	2100.66
243	36	DEPOSITO	2025-11-11 09:47:00	4760.02
244	52	DEPOSITO	2025-11-11 11:39:00	3696.20
245	14	DEPOSITO	2025-11-18 11:13:00	17420.35
246	56	DEPOSITO	2025-11-20 12:07:00	27724.90
247	43	RETIRO	2025-11-21 10:36:00	962.99
248	79	RETIRO	2025-11-26 10:48:00	8362.71
249	48	RETIRO	2025-11-28 11:11:00	1343.69
250	78	DEPOSITO	2025-12-02 10:41:00	23486.58
251	21	RETIRO	2025-12-02 12:02:00	6170.90
252	42	RETIRO	2025-12-03 10:29:00	14844.70
253	29	DEPOSITO	2025-12-04 12:58:00	8499.28
254	51	DEPOSITO	2025-12-05 11:32:00	15309.12
255	59	DEPOSITO	2025-12-08 12:28:00	18952.49
256	6	RETIRO	2025-12-15 10:17:00	12395.58
257	30	DEPOSITO	2025-12-15 13:05:00	32019.50
258	74	DEPOSITO	2025-12-17 10:13:00	12919.51
259	22	DEPOSITO	2025-12-17 12:09:00	8906.64
260	45	DEPOSITO	2025-12-19 10:50:00	45153.63
261	12	RETIRO	2025-12-22 10:59:00	76.45
262	34	DEPOSITO	2025-12-22 13:33:00	2393.58
263	33	DEPOSITO	2025-12-24 13:26:00	4083.30
264	69	RETIRO	2025-12-26 09:38:00	2085.41
265	38	RETIRO	2025-12-29 10:01:00	7985.12
266	77	DEPOSITO	2025-12-29 10:34:00	21170.10
267	3	DEPOSITO	2025-12-30 09:56:00	5016.51
268	16	DEPOSITO	2025-12-30 11:27:00	19437.53
269	64	DEPOSITO	2025-12-31 13:03:00	947.16
270	4	DEPOSITO	2026-01-02 10:03:00	985.98
271	9	DEPOSITO	2026-01-02 10:38:00	19450.98
272	68	DEPOSITO	2026-01-02 13:31:00	2639.81
273	2	DEPOSITO	2026-01-09 09:49:00	2376.90
274	58	DEPOSITO	2026-01-09 12:21:00	4475.50
275	47	DEPOSITO	2026-01-12 11:04:00	50872.26
276	15	DEPOSITO	2026-01-14 11:20:00	48104.14
277	23	RETIRO	2026-01-15 12:16:00	5966.52
278	80	RETIRO	2026-01-16 10:55:00	6489.92
279	74	DEPOSITO	2026-01-20 10:13:00	9219.27
280	73	RETIRO	2026-01-21 10:06:00	6099.13
281	7	DEPOSITO	2026-01-21 10:24:00	35691.18
282	79	DEPOSITO	2026-01-22 10:48:00	1994.73
283	42	DEPOSITO	2026-01-23 10:29:00	7958.00
284	51	DEPOSITO	2026-01-23 11:32:00	15994.24
285	63	RETIRO	2026-01-23 12:56:00	3425.82
286	53	DEPOSITO	2026-01-26 11:46:00	4281.24
287	18	DEPOSITO	2026-02-03 11:41:00	13844.07
288	76	DEPOSITO	2026-02-04 10:27:00	1448.45
289	6	RETIRO	2026-02-05 10:17:00	16053.59
290	32	DEPOSITO	2026-02-09 13:19:00	3847.19
291	79	DEPOSITO	2026-02-10 10:48:00	5078.03
292	33	RETIRO	2026-02-10 13:26:00	1618.12
293	66	DEPOSITO	2026-02-13 13:17:00	12885.03
294	2	DEPOSITO	2026-02-17 09:49:00	2500.00
295	37	RETIRO	2026-02-19 09:54:00	27.08
296	56	RETIRO	2026-02-20 12:07:00	22994.74
297	50	RETIRO	2026-02-24 11:25:00	581.38
298	69	DEPOSITO	2026-02-26 09:38:00	7431.38
299	48	RETIRO	2026-03-04 11:11:00	8875.96
300	24	DEPOSITO	2026-03-04 12:23:00	1409.43
301	34	DEPOSITO	2026-03-05 13:33:00	990.37
302	29	RETIRO	2026-03-06 12:58:00	4441.03
303	39	DEPOSITO	2026-03-10 10:08:00	149051.44
304	1	DEPOSITO	2026-03-16 09:42:00	10604.11
305	75	RETIRO	2026-03-16 10:20:00	29852.95
306	46	RETIRO	2026-03-18 10:57:00	13210.69
307	21	DEPOSITO	2026-03-18 12:02:00	27368.86
308	17	RETIRO	2026-03-20 11:34:00	16683.25
309	43	RETIRO	2026-03-23 10:36:00	285.31
310	78	DEPOSITO	2026-03-23 10:41:00	16625.49
311	73	RETIRO	2026-03-24 10:06:00	3127.33
312	72	DEPOSITO	2026-03-25 09:59:00	5221.56
313	20	DEPOSITO	2026-03-27 11:55:00	7752.89
314	59	DEPOSITO	2026-03-30 12:28:00	5925.05
315	45	RETIRO	2026-04-08 10:50:00	9607.21
316	50	DEPOSITO	2026-04-17 11:25:00	2916.79
317	47	RETIRO	2026-04-20 11:04:00	1456.35
318	24	DEPOSITO	2026-04-20 12:23:00	506.63
319	35	DEPOSITO	2026-04-23 09:40:00	83098.32
320	76	RETIRO	2026-04-24 10:27:00	87.35
321	54	RETIRO	2026-04-29 11:53:00	3657.17
322	49	DEPOSITO	2026-04-30 11:18:00	3348.84
323	21	RETIRO	2026-04-30 12:02:00	24634.35
324	18	DEPOSITO	2026-05-04 11:41:00	21060.04
325	69	DEPOSITO	2026-05-05 09:38:00	2668.41
326	14	DEPOSITO	2026-05-06 11:13:00	17839.95
327	39	DEPOSITO	2026-05-07 10:08:00	10088.09
328	60	RETIRO	2026-05-07 12:35:00	11476.78
329	75	DEPOSITO	2026-05-11 10:20:00	14282.84
330	61	RETIRO	2026-05-12 12:42:00	13729.07
331	11	RETIRO	2026-05-13 10:52:00	337.52
332	33	DEPOSITO	2026-05-13 13:26:00	2407.66
333	57	DEPOSITO	2026-05-15 12:14:00	15842.90
334	55	RETIRO	2026-05-18 12:00:00	12527.27
335	42	DEPOSITO	2026-05-21 10:29:00	9209.01
336	44	RETIRO	2026-05-21 10:43:00	2532.27
337	51	DEPOSITO	2026-05-21 11:32:00	9905.56
338	30	DEPOSITO	2026-05-22 13:05:00	24558.04
339	56	DEPOSITO	2026-05-26 12:07:00	24321.83
340	20	DEPOSITO	2026-06-04 11:55:00	4022.90
341	72	DEPOSITO	2026-06-08 09:59:00	4635.07
342	80	RETIRO	2026-06-08 10:55:00	2230.26
343	77	DEPOSITO	2026-06-09 10:34:00	10867.06
344	59	DEPOSITO	2026-06-12 12:28:00	10088.20
345	56	DEPOSITO	2026-06-15 12:07:00	13542.53
346	69	DEPOSITO	2026-06-16 09:38:00	6810.15
347	79	DEPOSITO	2026-06-17 10:48:00	3915.35
348	45	DEPOSITO	2026-06-18 10:50:00	19297.14
349	53	DEPOSITO	2026-06-18 11:46:00	3346.46
350	13	DEPOSITO	2026-06-22 11:06:00	14729.41
351	38	DEPOSITO	2026-06-23 10:01:00	10911.59
352	12	DEPOSITO	2026-06-30 10:59:00	4782.60
353	62	RETIRO	2026-06-30 12:49:00	10610.25
354	40	RETIRO	2026-07-02 10:15:00	9027.36
355	25	DEPOSITO	2026-07-02 12:30:00	5074.98
356	11	DEPOSITO	2026-07-06 10:52:00	1815.74
357	43	DEPOSITO	2026-07-07 10:36:00	2192.37
358	48	DEPOSITO	2026-07-07 11:11:00	5423.04
359	55	DEPOSITO	2026-07-07 12:00:00	7685.85
360	26	DEPOSITO	2026-07-07 12:37:00	2382.50
361	75	DEPOSITO	2026-07-08 10:20:00	15442.29
362	60	DEPOSITO	2026-07-10 12:35:00	6500.70
363	19	RETIRO	2026-07-13 11:48:00	440.90
364	42	DEPOSITO	2026-07-15 10:29:00	16293.92
365	15	DEPOSITO	2026-07-15 11:20:00	58014.09
366	17	DEPOSITO	2026-07-15 11:34:00	38986.93
367	65	DEPOSITO	2026-07-23 13:10:00	10763.67
368	49	DEPOSITO	2026-07-31 11:18:00	4426.24
369	70	RETIRO	2026-08-03 09:45:00	1749.22
370	71	DEPOSITO	2026-08-03 09:52:00	19208.84
371	20	DEPOSITO	2026-08-03 11:55:00	19374.88
372	1	DEPOSITO	2026-08-04 09:42:00	3682.46
373	9	RETIRO	2026-08-04 10:38:00	7219.95
374	47	DEPOSITO	2026-08-05 11:04:00	13586.75
375	22	DEPOSITO	2026-08-06 12:09:00	12262.92
376	80	DEPOSITO	2026-08-07 10:55:00	23804.23
377	33	DEPOSITO	2026-08-07 13:26:00	2228.71
378	71	DEPOSITO	2026-08-10 09:52:00	24178.82
379	50	DEPOSITO	2026-08-10 11:25:00	2224.53
380	2	DEPOSITO	2026-08-17 09:49:00	2854.21
381	12	DEPOSITO	2026-08-21 10:59:00	5664.89
382	59	DEPOSITO	2026-08-25 12:28:00	19819.54
383	57	DEPOSITO	2026-08-26 12:14:00	23747.32
384	40	RETIRO	2026-08-31 10:15:00	9387.76
385	75	DEPOSITO	2026-09-16 10:20:00	16252.76
386	25	RETIRO	2026-09-18 12:30:00	1949.50
387	8	DEPOSITO	2026-09-24 10:31:00	7428.19
388	66	RETIRO	2026-09-24 13:17:00	14682.76
389	13	DEPOSITO	2026-09-25 11:06:00	21699.33
390	72	DEPOSITO	2026-09-29 09:59:00	1697.96
391	16	RETIRO	2026-09-29 11:27:00	3310.73
392	15	DEPOSITO	2026-10-01 11:20:00	34075.39
393	9	DEPOSITO	2026-10-06 10:38:00	10207.00
394	12	RETIRO	2026-10-06 10:59:00	162.49
395	1	DEPOSITO	2026-10-07 09:42:00	6437.57
396	21	DEPOSITO	2026-10-07 12:02:00	8290.61
397	45	DEPOSITO	2026-10-12 10:50:00	38870.89
398	76	DEPOSITO	2026-10-13 10:27:00	703.47
399	78	DEPOSITO	2026-10-13 10:41:00	5930.06
400	73	DEPOSITO	2026-10-15 10:06:00	16338.63
401	46	DEPOSITO	2026-10-16 10:57:00	5392.85
402	7	RETIRO	2026-10-19 10:24:00	13609.25
403	11	DEPOSITO	2026-10-19 10:52:00	3010.30
404	22	RETIRO	2026-10-20 12:09:00	7893.94
405	77	DEPOSITO	2026-10-29 10:34:00	16444.07
406	42	RETIRO	2026-11-02 10:29:00	13731.81
407	71	DEPOSITO	2026-11-16 09:52:00	16183.54
408	15	DEPOSITO	2026-11-16 23:45:29.804164	1000.00
\.


--
-- Data for Name: perfil_riesgo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.perfil_riesgo (id_perfil, nombre_perfil, limite_max_renta_var) FROM stdin;
1	CONSERVADOR	20.00
2	MODERADO	50.00
3	AGRESIVO	100.00
\.


--
-- Data for Name: precio_historico; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.precio_historico (id_activo, fecha, precio_cierre) FROM stdin;
1	2024-01-02	11.9600
1	2024-01-03	12.3200
1	2024-01-04	12.2200
1	2024-01-05	12.5500
1	2024-01-08	12.2500
1	2024-01-09	12.0700
1	2024-01-10	11.9000
1	2024-01-11	12.0300
1	2024-01-12	12.1400
1	2024-01-16	11.7700
1	2024-01-17	11.6800
1	2024-01-18	11.7200
1	2024-01-19	11.6700
1	2024-01-22	11.6000
1	2024-01-23	11.6600
1	2024-01-24	11.7300
1	2024-01-25	11.9900
1	2024-01-26	12.2900
1	2024-01-29	12.2300
1	2024-01-30	12.2500
1	2024-01-31	12.0300
1	2024-02-01	12.1000
1	2024-02-02	11.7900
1	2024-02-05	11.7200
1	2024-02-06	11.9000
1	2024-02-07	11.9800
1	2024-02-08	11.9100
1	2024-02-09	11.8700
1	2024-02-12	11.9000
1	2024-02-13	11.6500
1	2024-02-14	11.6600
1	2024-02-15	11.8300
1	2024-02-16	11.8600
1	2024-02-20	11.6200
1	2024-02-21	11.9100
1	2024-02-22	11.9400
1	2024-02-23	11.8000
1	2024-02-26	11.8800
1	2024-02-27	11.9800
1	2024-02-28	11.7500
1	2024-02-29	11.7000
1	2024-03-01	11.3600
1	2024-03-04	10.7700
1	2024-03-05	10.6000
1	2024-03-06	10.6100
1	2024-03-07	10.6300
1	2024-03-08	10.5200
1	2024-03-11	10.5300
1	2024-03-12	10.5900
1	2024-03-13	10.6500
1	2024-03-14	10.7700
1	2024-03-15	11.0300
1	2024-03-18	10.8000
1	2024-03-19	10.8600
1	2024-03-20	11.0200
1	2024-03-21	10.9000
1	2024-03-22	10.8100
1	2024-03-25	11.0300
1	2024-03-26	10.9800
1	2024-03-27	11.3300
1	2024-03-28	11.8400
1	2024-04-01	12.1100
1	2024-04-02	12.7000
1	2024-04-03	12.8900
1	2024-04-04	12.1300
1	2024-04-05	12.1500
1	2024-04-08	12.0400
1	2024-04-09	12.1000
1	2024-04-10	11.8400
1	2024-04-11	12.0700
1	2024-04-12	11.7000
1	2024-04-15	11.5300
1	2024-04-16	11.5000
1	2024-04-17	11.4500
1	2024-04-18	11.3400
1	2024-04-19	11.5100
1	2024-04-22	11.5700
1	2024-04-23	11.7300
1	2024-04-24	11.6900
1	2024-04-25	11.6400
1	2024-04-26	11.8500
1	2024-04-29	12.0600
1	2024-04-30	11.6100
1	2024-05-01	11.4900
1	2024-05-02	11.5400
1	2024-05-03	11.5400
1	2024-05-06	11.6100
1	2024-05-07	11.6600
1	2024-05-08	11.7400
1	2024-05-09	11.7500
1	2024-05-10	11.6400
1	2024-05-13	11.6600
1	2024-05-14	12.0900
1	2024-05-15	12.0200
1	2024-05-16	12.0300
1	2024-05-17	12.1300
1	2024-05-20	12.3000
1	2024-05-21	12.2900
1	2024-05-22	11.8800
1	2024-05-23	11.8700
1	2024-05-24	11.9200
1	2024-05-28	12.4300
1	2024-05-29	12.3000
1	2024-05-30	12.2800
1	2024-05-31	12.3000
1	2024-06-03	12.1800
1	2024-06-04	12.0800
1	2024-06-05	12.0000
1	2024-06-06	12.0300
1	2024-06-07	11.9900
1	2024-06-10	12.1200
1	2024-06-11	11.9300
1	2024-06-12	11.8200
1	2024-06-13	11.7300
1	2024-06-14	11.6400
1	2024-06-17	11.8200
1	2024-06-18	12.0500
1	2024-06-20	12.1100
1	2024-06-21	12.0000
1	2024-06-24	12.6700
1	2024-06-25	11.1700
1	2024-06-26	11.1700
1	2024-06-27	11.1600
1	2024-06-28	11.1900
1	2024-07-01	11.1000
1	2024-07-02	11.1400
1	2024-07-03	11.2700
1	2024-07-05	11.2300
1	2024-07-08	11.2300
1	2024-07-09	11.1300
1	2024-07-10	11.1400
1	2024-07-11	11.2000
1	2024-07-12	11.1900
1	2024-07-15	11.1700
1	2024-07-16	11.0100
1	2024-07-17	10.9600
1	2024-07-18	10.8700
1	2024-07-19	10.8100
1	2024-07-22	10.8100
1	2024-07-23	10.6400
1	2024-07-24	10.6000
1	2024-07-25	10.6800
1	2024-07-26	10.7000
1	2024-07-29	10.5500
1	2024-07-30	10.4600
1	2024-07-31	10.7200
1	2024-08-01	10.4200
1	2024-08-02	9.9900
1	2024-08-05	9.7200
1	2024-08-06	10.0500
1	2024-08-07	10.1100
1	2024-08-08	10.3400
1	2024-08-09	10.4700
1	2024-08-12	10.6400
1	2024-08-13	10.5100
1	2024-08-14	10.1600
1	2024-08-15	10.3400
1	2024-08-16	10.3700
1	2024-08-19	10.4100
1	2024-08-20	10.1700
1	2024-08-21	10.1500
1	2024-08-22	10.0400
1	2024-08-23	10.2200
1	2024-08-26	10.4100
1	2024-08-27	10.2400
1	2024-08-28	10.0900
1	2024-08-29	9.9700
1	2024-08-30	9.8400
1	2024-09-03	9.4600
1	2024-09-04	9.2500
1	2024-09-05	9.2200
1	2024-09-06	9.1900
1	2024-09-09	9.0400
1	2024-09-10	8.8300
1	2024-09-11	8.9600
1	2024-09-12	9.1700
1	2024-09-13	9.1600
1	2024-09-16	9.2600
1	2024-09-17	9.2900
1	2024-09-18	9.1600
1	2024-09-19	9.1400
1	2024-09-20	9.1300
1	2024-09-23	9.2600
1	2024-09-24	9.3200
1	2024-09-25	8.7500
1	2024-09-26	8.7600
1	2024-09-27	9.0200
1	2024-09-30	8.9300
1	2024-10-01	9.0300
1	2024-10-02	9.0100
1	2024-10-03	8.9900
1	2024-10-04	9.0200
1	2024-10-07	9.0500
1	2024-10-08	8.6700
1	2024-10-09	8.6400
1	2024-10-10	8.8100
1	2024-10-11	8.7400
1	2024-10-14	8.6900
1	2024-10-15	8.3400
1	2024-10-16	8.2400
1	2024-10-17	8.1500
1	2024-10-18	8.2300
1	2024-10-21	8.0700
1	2024-10-22	8.1400
1	2024-10-23	8.0100
1	2024-10-24	8.0300
1	2024-10-25	8.1000
1	2024-10-28	8.0500
1	2024-10-29	7.9700
1	2024-10-30	7.8100
1	2024-10-31	7.7000
1	2024-11-01	7.6000
1	2024-11-04	7.6100
1	2024-11-05	7.5600
1	2024-11-06	7.5700
1	2024-11-07	7.6500
1	2024-11-08	7.3600
1	2024-11-11	7.5000
1	2024-11-12	7.4600
1	2024-11-13	7.3600
1	2024-11-14	7.7300
1	2024-11-15	7.9200
1	2024-11-18	8.1600
1	2024-11-19	8.0500
1	2024-11-20	8.0800
1	2024-11-21	8.1900
1	2024-11-22	8.3300
1	2024-11-25	8.1000
1	2024-11-26	7.9800
1	2024-11-27	8.0400
1	2024-11-29	8.0300
1	2024-12-02	7.9300
1	2024-12-03	7.9700
1	2024-12-04	7.9000
1	2024-12-05	8.0300
1	2024-12-06	7.8600
1	2024-12-09	8.2100
1	2024-12-10	8.3600
1	2024-12-11	8.3600
1	2024-12-12	8.3100
1	2024-12-13	8.2200
1	2024-12-16	7.9500
1	2024-12-17	7.8900
1	2024-12-18	7.6400
1	2024-12-19	7.6200
1	2024-12-20	7.6400
1	2024-12-23	7.5400
1	2024-12-24	7.5500
1	2024-12-26	7.5500
1	2024-12-27	7.5500
1	2024-12-30	7.6800
1	2024-12-31	7.9200
1	2025-01-02	8.2200
1	2025-01-03	8.2600
1	2025-01-06	8.3000
1	2025-01-07	8.5500
1	2025-01-08	8.4800
1	2025-01-10	8.4900
1	2025-01-13	8.5700
1	2025-01-14	8.5700
1	2025-01-15	8.6000
1	2025-01-16	8.6300
1	2025-01-17	8.4500
1	2025-01-21	8.4400
1	2025-01-22	8.2700
1	2025-01-23	8.4200
1	2025-01-24	8.4300
1	2025-01-27	8.5600
1	2025-01-28	8.6100
1	2025-01-29	9.0400
1	2025-01-30	9.6700
1	2025-01-31	9.2800
1	2025-02-03	9.6200
1	2025-02-04	9.8400
1	2025-02-05	9.4800
1	2025-02-06	9.6700
1	2025-02-07	9.6700
1	2025-02-10	9.8100
1	2025-02-11	9.8000
1	2025-02-12	9.6300
1	2025-02-13	10.2200
1	2025-02-14	10.2500
1	2025-02-18	10.8300
1	2025-02-19	10.9100
1	2025-02-20	10.9400
1	2025-02-21	10.4300
1	2025-02-24	10.3900
1	2025-02-25	10.2600
1	2025-02-26	10.1200
1	2025-02-27	9.9100
1	2025-02-28	9.8800
1	2025-03-03	9.4700
1	2025-03-04	9.1100
1	2025-03-05	9.3700
1	2025-03-06	9.5900
1	2025-03-07	9.9200
1	2025-03-10	9.7400
1	2025-03-11	9.6200
1	2025-03-12	9.7400
1	2025-03-13	9.7800
1	2025-03-14	10.1300
1	2025-03-17	10.3600
1	2025-03-18	10.3200
1	2025-03-19	10.2100
1	2025-03-20	10.1100
1	2025-03-21	10.1600
1	2025-03-24	10.0800
1	2025-03-25	10.3100
1	2025-03-26	10.4000
1	2025-03-27	10.3900
1	2025-03-28	10.2200
1	2025-03-31	10.4400
1	2025-04-01	10.6100
1	2025-04-02	10.6300
1	2025-04-03	9.5500
1	2025-04-04	9.0000
1	2025-04-07	8.8300
1	2025-04-08	8.1400
1	2025-04-09	8.9500
1	2025-04-10	8.2300
1	2025-04-11	8.8000
1	2025-04-14	8.8900
1	2025-04-15	8.8100
1	2025-04-16	8.8600
1	2025-04-17	9.1200
1	2025-04-21	9.0500
1	2025-04-22	9.0400
1	2025-04-23	9.1500
1	2025-04-24	9.2900
1	2025-04-25	9.2900
1	2025-04-28	8.4700
1	2025-04-29	8.3000
1	2025-04-30	8.1100
1	2025-05-01	8.0600
1	2025-05-02	8.1500
1	2025-05-05	7.8800
1	2025-05-06	7.8800
1	2025-05-07	7.9100
1	2025-05-08	8.0900
1	2025-05-09	8.1600
1	2025-05-12	8.2900
1	2025-05-13	8.6200
1	2025-05-14	8.6400
1	2025-05-15	8.5100
1	2025-05-16	8.6000
1	2025-05-19	8.6200
1	2025-05-20	8.5700
1	2025-05-21	8.4500
1	2025-05-22	8.4700
1	2025-05-23	8.6100
1	2025-05-27	8.7000
1	2025-05-28	8.6200
1	2025-05-29	8.7200
1	2025-05-30	8.4700
1	2025-06-02	8.5000
1	2025-06-03	8.6600
1	2025-06-04	8.6300
1	2025-06-05	8.6900
1	2025-06-06	8.9700
1	2025-06-09	8.9300
1	2025-06-10	9.0200
1	2025-06-11	9.3100
1	2025-06-12	9.3300
1	2025-06-13	9.6700
1	2025-06-16	9.5000
1	2025-06-17	9.6000
1	2025-06-18	9.7300
1	2025-06-20	9.8400
1	2025-06-23	9.4500
1	2025-06-24	9.4000
1	2025-06-25	9.3300
1	2025-06-26	9.2400
1	2025-06-27	8.9300
1	2025-06-30	8.8500
1	2025-07-01	8.9000
1	2025-07-02	9.2700
1	2025-07-03	9.1700
1	2025-07-07	8.8700
1	2025-07-08	9.1100
1	2025-07-09	8.9500
1	2025-07-10	9.0000
1	2025-07-11	9.0700
1	2025-07-14	8.9200
1	2025-07-15	8.8400
1	2025-07-16	8.8700
1	2025-07-17	8.8800
1	2025-07-18	8.8400
1	2025-07-21	8.8400
1	2025-07-22	8.7300
1	2025-07-23	8.9200
1	2025-07-24	8.6000
1	2025-07-25	8.5800
1	2025-07-28	8.5700
1	2025-07-29	8.7800
1	2025-07-30	8.5000
1	2025-07-31	8.4000
1	2025-08-01	8.2900
1	2025-08-04	8.3500
1	2025-08-05	8.4900
1	2025-08-06	8.5700
1	2025-08-07	8.5800
1	2025-08-08	8.5500
1	2025-08-11	8.5300
1	2025-08-12	8.5600
1	2025-08-13	8.7000
1	2025-08-14	8.7200
1	2025-08-15	8.9100
1	2025-08-18	8.8500
1	2025-08-19	8.9000
1	2025-08-20	8.9200
1	2025-08-21	8.9000
1	2025-08-22	9.1900
1	2025-08-25	9.2300
1	2025-08-26	9.1500
1	2025-08-27	9.2300
1	2025-08-28	9.3100
1	2025-08-29	9.4000
1	2025-09-02	9.3800
1	2025-09-03	9.0500
1	2025-09-04	9.0400
1	2025-09-05	9.0800
1	2025-09-08	9.1300
1	2025-09-09	9.2500
1	2025-09-10	9.4400
1	2025-09-11	9.2500
1	2025-09-12	9.1400
1	2025-09-15	9.2300
1	2025-09-16	9.3800
1	2025-09-17	9.3200
1	2025-09-18	9.0100
1	2025-09-19	8.8800
1	2025-09-22	9.0100
1	2025-09-23	9.3900
1	2025-09-24	9.6300
1	2025-09-25	9.5300
1	2025-09-26	9.4100
1	2025-09-29	9.1800
1	2025-09-30	9.2100
1	2025-10-01	9.2100
1	2025-10-02	9.0700
1	2025-10-03	9.1200
1	2025-10-06	9.1600
1	2025-10-07	9.0400
1	2025-10-08	9.0200
1	2025-10-09	8.9800
1	2025-10-10	8.7800
1	2025-10-13	9.0900
1	2025-10-14	8.7900
1	2025-10-15	8.9300
1	2025-10-16	8.9900
1	2025-10-17	9.0400
1	2025-10-20	8.7400
1	2025-10-21	8.6100
1	2025-10-22	8.7500
1	2025-10-23	9.1500
1	2025-10-24	9.1400
1	2025-10-27	9.3100
1	2025-10-28	9.2200
1	2025-10-29	9.3000
1	2025-10-30	9.2500
1	2025-10-31	9.3200
1	2025-11-03	9.4400
1	2025-11-04	9.2600
1	2025-11-05	9.4600
1	2025-11-06	9.6700
1	2025-11-07	9.9200
1	2025-11-10	9.8800
1	2025-11-11	10.1700
1	2025-11-12	10.1700
1	2025-11-13	10.0100
1	2025-11-14	10.3900
1	2025-11-17	10.5200
1	2025-11-18	10.6100
1	2025-11-19	10.4400
1	2025-11-20	10.1200
1	2025-11-21	9.8500
1	2025-11-24	9.6000
1	2025-11-25	9.6200
1	2025-11-26	9.8700
1	2025-11-28	9.8200
1	2025-12-01	9.9500
1	2025-12-02	9.9100
1	2025-12-03	10.1300
1	2025-12-04	10.0600
1	2025-12-05	9.8900
1	2025-12-08	9.9600
1	2025-12-09	10.0000
1	2025-12-10	9.8100
1	2025-12-11	9.8100
1	2025-12-12	9.7300
1	2025-12-15	9.6300
1	2025-12-16	9.3300
1	2025-12-17	9.3500
1	2025-12-18	9.2200
1	2025-12-19	9.2100
1	2025-12-22	9.3000
1	2025-12-23	9.4800
1	2025-12-24	9.6000
1	2025-12-26	9.6900
1	2025-12-29	9.8400
1	2025-12-30	9.8700
1	2025-12-31	10.0200
1	2026-01-02	10.2200
1	2026-01-05	10.8200
1	2026-01-06	10.9000
1	2026-01-07	10.4600
1	2026-01-08	10.7500
1	2026-01-09	10.8700
1	2026-01-12	11.1600
1	2026-01-13	11.3400
1	2026-01-14	11.5700
1	2026-01-15	11.6800
1	2026-01-16	12.2500
1	2026-01-20	12.5500
1	2026-01-21	12.8500
1	2026-01-22	12.2000
1	2026-01-23	12.5000
1	2026-01-26	12.6800
1	2026-01-27	13.0800
1	2026-01-28	12.7600
1	2026-01-29	12.7700
1	2026-01-30	12.5700
1	2026-02-02	12.3100
1	2026-02-03	12.4000
1	2026-02-04	12.2900
1	2026-02-05	11.7300
1	2026-02-06	12.2300
1	2026-02-09	12.3000
1	2026-02-10	12.0500
1	2026-02-11	12.2200
1	2026-02-12	11.8800
1	2026-02-13	11.9000
1	2026-02-17	11.9500
1	2026-02-18	12.0600
1	2026-02-19	12.5800
1	2026-02-20	12.5000
1	2026-02-23	12.6700
1	2026-02-24	12.4200
1	2026-02-25	12.5800
1	2026-02-26	12.0000
1	2026-02-27	11.8900
1	2026-03-02	12.2000
1	2026-03-03	11.6900
1	2026-03-04	11.5900
1	2026-03-05	12.6100
1	2026-03-06	12.9200
1	2026-03-09	12.8400
1	2026-03-10	12.9000
1	2026-03-11	13.5600
1	2026-03-12	13.9500
1	2026-03-13	13.8600
1	2026-03-16	14.1100
1	2026-03-17	14.7300
1	2026-03-18	14.6700
1	2026-03-19	14.6400
1	2026-03-20	14.8300
1	2026-03-23	14.3100
1	2026-03-24	14.5700
1	2026-03-25	14.9000
1	2026-03-26	14.8000
1	2026-03-27	15.0100
1	2026-03-30	14.9800
1	2026-03-31	14.9900
1	2026-04-01	14.4900
1	2026-04-02	15.1400
1	2026-04-06	14.9200
1	2026-04-07	14.7100
1	2026-04-08	14.1100
1	2026-04-09	13.9100
1	2026-04-10	14.1000
1	2026-04-13	14.1200
1	2026-04-14	13.5100
1	2026-04-15	13.1700
1	2026-04-16	13.7600
1	2026-04-17	13.5500
1	2026-04-20	13.6600
1	2026-04-21	14.1500
1	2026-04-22	14.3200
1	2026-04-23	14.4300
1	2026-04-24	13.8000
1	2026-04-27	13.7200
1	2026-04-28	13.9700
1	2026-04-29	13.7800
1	2026-04-30	14.1600
1	2026-05-01	13.9200
1	2026-05-04	14.0300
1	2026-05-05	14.2000
1	2026-05-06	13.3600
1	2026-05-07	13.0000
1	2026-05-08	12.6400
1	2026-05-11	12.7900
1	2026-05-12	13.0800
1	2026-05-13	12.8700
1	2026-05-14	13.2200
1	2026-05-15	13.0900
1	2026-05-18	13.8100
1	2026-05-19	14.0100
1	2026-05-20	13.7200
1	2026-05-21	13.8600
1	2026-05-22	13.8500
1	2026-05-26	14.8600
1	2026-05-27	14.9200
1	2026-05-28	14.7700
1	2026-05-29	14.6100
1	2026-06-01	16.2500
1	2026-06-02	15.9800
1	2026-06-03	15.5800
1	2026-06-04	15.6400
1	2026-06-05	15.1500
1	2026-06-08	15.3500
1	2026-06-09	15.8800
1	2026-06-10	16.2100
1	2026-06-11	16.2600
1	2026-06-12	16.5800
1	2026-06-15	15.6900
1	2026-06-16	15.7900
1	2026-06-17	15.6700
1	2026-06-18	16.5800
1	2026-06-22	16.2500
1	2026-06-23	15.5100
1	2026-06-24	14.5900
1	2026-06-25	14.4500
1	2026-06-26	14.7200
1	2026-06-29	14.5600
1	2026-06-30	14.2400
1	2026-07-01	14.4500
1	2026-07-02	14.7000
1	2026-07-06	14.4700
1	2026-07-07	14.6900
1	2026-07-08	15.1300
1	2026-07-09	15.3900
1	2026-07-10	15.5800
1	2026-07-13	15.8800
1	2026-07-14	16.1600
1	2026-07-15	15.9800
1	2026-07-16	15.8000
1	2026-07-17	16.0900
1	2026-07-20	16.0300
1	2026-07-21	16.5300
1	2026-07-22	16.6900
1	2026-07-23	16.3300
1	2026-07-24	16.0100
1	2026-07-27	15.8000
1	2026-07-28	15.8300
1	2026-07-29	16.4000
1	2026-07-30	17.0400
1	2026-07-31	16.7700
1	2026-08-03	16.6000
1	2026-08-04	16.3100
1	2026-08-05	16.3900
1	2026-08-06	17.4000
1	2026-08-07	16.7800
1	2026-08-10	17.0500
1	2026-08-11	17.0100
1	2026-08-12	16.9600
1	2026-08-13	17.2100
1	2026-08-14	17.1700
1	2026-08-17	17.6700
1	2026-08-18	17.6800
1	2026-08-19	17.8900
1	2026-08-20	17.6500
1	2026-08-21	17.5300
1	2026-08-24	17.3300
1	2026-08-25	16.7900
1	2026-08-26	16.5200
1	2026-08-27	16.5600
1	2026-08-28	16.5000
1	2026-08-31	16.6700
1	2026-09-01	17.4500
1	2026-09-02	17.5100
1	2026-09-03	17.2000
1	2026-09-04	17.2500
1	2026-09-08	17.7800
1	2026-09-09	17.8300
1	2026-09-10	18.0700
1	2026-09-11	17.7500
1	2026-09-14	17.7400
1	2026-09-15	18.2600
1	2026-09-16	17.4600
1	2026-09-17	17.3800
1	2026-09-18	17.5800
1	2026-09-21	16.8400
1	2026-09-22	16.9100
1	2026-09-23	16.6900
1	2026-09-24	16.3700
1	2026-09-25	16.5800
1	2026-09-28	16.7000
1	2026-09-29	16.5200
1	2026-09-30	16.4800
1	2026-10-01	16.2700
1	2026-10-02	16.6000
1	2026-10-05	17.2500
1	2026-10-06	16.9600
1	2026-10-07	16.6300
1	2026-10-08	16.9400
1	2026-10-09	16.9400
1	2026-10-12	17.2300
1	2026-10-13	17.5200
1	2026-10-14	17.9000
1	2026-10-15	17.7000
1	2026-10-16	17.9000
1	2026-10-19	17.7700
1	2026-10-20	17.6800
1	2026-10-21	17.2400
1	2026-10-22	17.0100
1	2026-10-23	17.8000
1	2026-10-26	17.4000
1	2026-10-27	17.2900
1	2026-10-28	17.6800
1	2026-10-29	17.2800
1	2026-10-30	17.1900
1	2026-11-02	16.1700
1	2026-11-03	16.5400
1	2026-11-04	15.9200
1	2026-11-05	15.5400
1	2026-11-06	15.5500
1	2026-11-09	15.6100
1	2026-11-10	15.2600
1	2026-11-11	15.3000
1	2026-11-12	15.3200
1	2026-11-13	15.4300
1	2026-11-16	14.9100
2	2024-01-02	31.2400
2	2024-01-03	31.3200
2	2024-01-04	32.8300
2	2024-01-05	34.0500
2	2024-01-08	32.8900
2	2024-01-09	32.7900
2	2024-01-10	32.5500
2	2024-01-11	31.9000
2	2024-01-12	31.8300
2	2024-01-16	31.0100
2	2024-01-17	31.3600
2	2024-01-18	32.2000
2	2024-01-19	31.9000
2	2024-01-22	31.6400
2	2024-01-23	31.1500
2	2024-01-24	31.4100
2	2024-01-25	31.1700
2	2024-01-26	31.7800
2	2024-01-29	31.6700
2	2024-01-30	31.7500
2	2024-01-31	31.4600
2	2024-02-01	32.1000
2	2024-02-02	31.9900
2	2024-02-05	31.7600
2	2024-02-06	31.7800
2	2024-02-07	31.7700
2	2024-02-08	31.3800
2	2024-02-09	31.5800
2	2024-02-12	31.5300
2	2024-02-13	30.9500
2	2024-02-14	31.6000
2	2024-02-15	31.5600
2	2024-02-16	31.7500
2	2024-02-20	31.4300
2	2024-02-21	32.2600
2	2024-02-22	32.6300
2	2024-02-23	33.2300
2	2024-02-26	33.1400
2	2024-02-27	32.6000
2	2024-02-28	32.5400
2	2024-02-29	32.5200
2	2024-03-01	32.7600
2	2024-03-04	32.6600
2	2024-03-05	32.9600
2	2024-03-06	33.4800
2	2024-03-07	33.4600
2	2024-03-08	32.6800
2	2024-03-11	32.6300
2	2024-03-12	32.3300
2	2024-03-13	32.6200
2	2024-03-14	32.4000
2	2024-03-15	32.3100
2	2024-03-18	33.1600
2	2024-03-19	33.0100
2	2024-03-20	33.8500
2	2024-03-21	34.5500
2	2024-03-22	34.7700
2	2024-03-25	34.4000
2	2024-03-26	35.0900
2	2024-03-27	34.9800
2	2024-03-28	34.2200
2	2024-04-01	34.3400
2	2024-04-02	35.1200
2	2024-04-03	35.4800
2	2024-04-04	36.7600
2	2024-04-05	36.3800
2	2024-04-08	36.2300
2	2024-04-09	36.5400
2	2024-04-10	35.8100
2	2024-04-11	35.7800
2	2024-04-12	34.5000
2	2024-04-15	33.7100
2	2024-04-16	33.4700
2	2024-04-17	33.2900
2	2024-04-18	32.2700
2	2024-04-19	32.6500
2	2024-04-22	32.7100
2	2024-04-23	32.6200
2	2024-04-24	32.0700
2	2024-04-25	31.3900
2	2024-04-26	32.8200
2	2024-04-29	33.6900
2	2024-04-30	32.7200
2	2024-05-01	32.9500
2	2024-05-02	33.4000
2	2024-05-03	33.9300
2	2024-05-06	34.2700
2	2024-05-07	34.0300
2	2024-05-08	34.0900
2	2024-05-09	34.0700
2	2024-05-10	34.2200
2	2024-05-13	34.6500
2	2024-05-14	35.0800
2	2024-05-15	35.6600
2	2024-05-16	35.9000
2	2024-05-17	36.3300
2	2024-05-20	37.3100
2	2024-05-21	37.2700
2	2024-05-22	35.9400
2	2024-05-23	35.8900
2	2024-05-24	35.3000
2	2024-05-28	35.8600
2	2024-05-29	35.0300
2	2024-05-30	35.5700
2	2024-05-31	35.4600
2	2024-06-03	35.8300
2	2024-06-04	34.8700
2	2024-06-05	35.2700
2	2024-06-06	35.3200
2	2024-06-07	35.8500
2	2024-06-10	34.7800
2	2024-06-11	33.9900
2	2024-06-12	33.3600
2	2024-06-13	32.8000
2	2024-06-14	32.4600
2	2024-06-17	32.7600
2	2024-06-18	33.1300
2	2024-06-20	32.7800
2	2024-06-21	32.5900
2	2024-06-24	33.1500
2	2024-06-25	32.7500
2	2024-06-26	32.8700
2	2024-06-27	32.1800
2	2024-06-28	32.6500
2	2024-07-01	32.4500
2	2024-07-02	33.3700
2	2024-07-03	33.0400
2	2024-07-05	33.0900
2	2024-07-08	33.4100
2	2024-07-09	33.5900
2	2024-07-10	34.2300
2	2024-07-11	34.1700
2	2024-07-12	34.5100
2	2024-07-15	33.9600
2	2024-07-16	34.3300
2	2024-07-17	33.8300
2	2024-07-18	33.2100
2	2024-07-19	33.6400
2	2024-07-22	33.9500
2	2024-07-23	33.4500
2	2024-07-24	32.8300
2	2024-07-25	32.7900
2	2024-07-26	32.9400
2	2024-07-29	32.4500
2	2024-07-30	32.5900
2	2024-07-31	33.3200
2	2024-08-01	32.8200
2	2024-08-02	31.7900
2	2024-08-05	31.0700
2	2024-08-06	31.2100
2	2024-08-07	30.7300
2	2024-08-08	31.5700
2	2024-08-09	31.5700
2	2024-08-12	32.9800
2	2024-08-13	33.5200
2	2024-08-14	33.8600
2	2024-08-15	34.3000
2	2024-08-16	33.9000
2	2024-08-19	34.7900
2	2024-08-20	33.2600
2	2024-08-21	33.1800
2	2024-08-22	32.7100
2	2024-08-23	32.9000
2	2024-08-26	33.4100
2	2024-08-27	33.2100
2	2024-08-28	33.1200
2	2024-08-29	32.5600
2	2024-08-30	33.0900
2	2024-09-03	32.8900
2	2024-09-04	32.7000
2	2024-09-05	32.8800
2	2024-09-06	32.1800
2	2024-09-09	31.4200
2	2024-09-10	31.1600
2	2024-09-11	31.5700
2	2024-09-12	31.8600
2	2024-09-13	31.8100
2	2024-09-16	31.7700
2	2024-09-17	31.5800
2	2024-09-18	31.7300
2	2024-09-19	32.2200
2	2024-09-20	32.1600
2	2024-09-23	32.4800
2	2024-09-24	32.9500
2	2024-09-25	32.7200
2	2024-09-26	33.0200
2	2024-09-27	31.9700
2	2024-09-30	31.3800
2	2024-10-01	31.2100
2	2024-10-02	31.3000
2	2024-10-03	30.9600
2	2024-10-04	31.3700
2	2024-10-07	31.0800
2	2024-10-08	31.1900
2	2024-10-09	31.5700
2	2024-10-10	31.8200
2	2024-10-11	32.3500
2	2024-10-14	32.6400
2	2024-10-15	32.2700
2	2024-10-16	32.1900
2	2024-10-17	32.1100
2	2024-10-18	33.1400
2	2024-10-21	33.3000
2	2024-10-22	32.6300
2	2024-10-23	31.0500
2	2024-10-24	31.9400
2	2024-10-25	31.3100
2	2024-10-28	31.6000
2	2024-10-29	31.1700
2	2024-10-30	32.3800
2	2024-10-31	31.9100
2	2024-11-01	31.6600
2	2024-11-04	31.7600
2	2024-11-05	32.2200
2	2024-11-06	32.2600
2	2024-11-07	32.7900
2	2024-11-08	32.2200
2	2024-11-11	32.3200
2	2024-11-12	31.3500
2	2024-11-13	31.2000
2	2024-11-14	31.4800
2	2024-11-15	31.7800
2	2024-11-18	32.8200
2	2024-11-19	32.9400
2	2024-11-20	33.4700
2	2024-11-21	32.7600
2	2024-11-22	32.7900
2	2024-11-25	33.3300
2	2024-11-26	32.5800
2	2024-11-27	32.9100
2	2024-11-29	32.7000
2	2024-12-02	32.6500
2	2024-12-03	32.6300
2	2024-12-04	32.3000
2	2024-12-05	32.9600
2	2024-12-06	32.7200
2	2024-12-09	32.6900
2	2024-12-10	32.8800
2	2024-12-11	33.3200
2	2024-12-12	33.1400
2	2024-12-13	33.1900
2	2024-12-16	32.8600
2	2024-12-17	32.5500
2	2024-12-18	31.5600
2	2024-12-19	31.8900
2	2024-12-20	32.1900
2	2024-12-23	32.1800
2	2024-12-24	32.2900
2	2024-12-26	32.4800
2	2024-12-27	32.0500
2	2024-12-30	31.6700
2	2024-12-31	31.5100
2	2025-01-02	32.3400
2	2025-01-03	31.9900
2	2025-01-06	32.3500
2	2025-01-07	32.5700
2	2025-01-08	32.4000
2	2025-01-10	32.3500
2	2025-01-13	32.3300
2	2025-01-14	32.4300
2	2025-01-15	32.5100
2	2025-01-16	32.0500
2	2025-01-17	32.1500
2	2025-01-21	32.3700
2	2025-01-22	33.0700
2	2025-01-23	34.4300
2	2025-01-24	35.6700
2	2025-01-27	36.8800
2	2025-01-28	38.6700
2	2025-01-29	40.3000
2	2025-01-30	39.8400
2	2025-01-31	39.5500
2	2025-02-03	38.9700
2	2025-02-04	39.2600
2	2025-02-05	39.1400
2	2025-02-06	39.9600
2	2025-02-07	39.3800
2	2025-02-10	39.8300
2	2025-02-11	40.0400
2	2025-02-12	39.9900
2	2025-02-13	40.3200
2	2025-02-14	40.7100
2	2025-02-18	41.0900
2	2025-02-19	41.5200
2	2025-02-20	43.4400
2	2025-02-21	42.7900
2	2025-02-24	43.1500
2	2025-02-25	43.4000
2	2025-02-26	43.2500
2	2025-02-27	41.7400
2	2025-02-28	41.7200
2	2025-03-03	40.8400
2	2025-03-04	40.7000
2	2025-03-05	41.9800
2	2025-03-06	41.5800
2	2025-03-07	41.6400
2	2025-03-10	40.4900
2	2025-03-11	41.3700
2	2025-03-12	42.3900
2	2025-03-13	41.5700
2	2025-03-14	43.1200
2	2025-03-17	43.8900
2	2025-03-18	43.0800
2	2025-03-19	42.9300
2	2025-03-20	42.6700
2	2025-03-21	42.6800
2	2025-03-24	43.2300
2	2025-03-25	43.8800
2	2025-03-26	44.2900
2	2025-03-27	43.7600
2	2025-03-28	43.7900
2	2025-03-31	40.2000
2	2025-04-01	41.3800
2	2025-04-02	42.0600
2	2025-04-03	42.2300
2	2025-04-04	40.0400
2	2025-04-07	37.5900
2	2025-04-08	36.1100
2	2025-04-09	38.9800
2	2025-04-10	36.4900
2	2025-04-11	37.7300
2	2025-04-14	38.2900
2	2025-04-15	39.0200
2	2025-04-16	39.6500
2	2025-04-17	39.5300
2	2025-04-21	40.0300
2	2025-04-22	41.3000
2	2025-04-23	41.3700
2	2025-04-24	41.6500
2	2025-04-25	42.3300
2	2025-04-28	40.6700
2	2025-04-29	40.8300
2	2025-04-30	40.3200
2	2025-05-01	40.5000
2	2025-05-02	40.9900
2	2025-05-05	40.4700
2	2025-05-06	41.1900
2	2025-05-07	40.7200
2	2025-05-08	41.1800
2	2025-05-09	41.1600
2	2025-05-12	40.3400
2	2025-05-13	41.7700
2	2025-05-14	42.3500
2	2025-05-15	42.2000
2	2025-05-16	41.5500
2	2025-05-19	41.6300
2	2025-05-20	42.1800
2	2025-05-21	41.2200
2	2025-05-22	40.5300
2	2025-05-23	41.5700
2	2025-05-27	42.2200
2	2025-05-28	42.3300
2	2025-05-29	42.4600
2	2025-05-30	41.4300
2	2025-06-02	43.4000
2	2025-06-03	43.4500
2	2025-06-04	43.5800
2	2025-06-05	43.5700
2	2025-06-06	43.0600
2	2025-06-09	41.9900
2	2025-06-10	42.0700
2	2025-06-11	42.7100
2	2025-06-12	42.6500
2	2025-06-13	42.5300
2	2025-06-16	42.6000
2	2025-06-17	42.1100
2	2025-06-18	43.2100
2	2025-06-20	43.1800
2	2025-06-23	42.6200
2	2025-06-24	44.9700
2	2025-06-25	45.2000
2	2025-06-26	45.3400
2	2025-06-27	45.0900
2	2025-06-30	46.1900
2	2025-07-01	45.7200
2	2025-07-02	46.3600
2	2025-07-03	46.0900
2	2025-07-07	44.9300
2	2025-07-08	44.9300
2	2025-07-09	44.9600
2	2025-07-10	44.7000
2	2025-07-11	44.2300
2	2025-07-14	44.7800
2	2025-07-15	44.5600
2	2025-07-16	44.2300
2	2025-07-17	46.1800
2	2025-07-18	45.9500
2	2025-07-21	45.7700
2	2025-07-22	44.6800
2	2025-07-23	44.9700
2	2025-07-24	44.2000
2	2025-07-25	44.1000
2	2025-07-28	43.7700
2	2025-07-29	44.3500
2	2025-07-30	43.7100
2	2025-07-31	43.4200
2	2025-08-01	44.1200
2	2025-08-04	44.6500
2	2025-08-05	44.9400
2	2025-08-06	45.4000
2	2025-08-07	46.6400
2	2025-08-08	47.0500
2	2025-08-11	48.0600
2	2025-08-12	48.8500
2	2025-08-13	48.4600
2	2025-08-14	48.5600
2	2025-08-15	49.5300
2	2025-08-18	49.6900
2	2025-08-19	48.7800
2	2025-08-20	49.4100
2	2025-08-21	49.8100
2	2025-08-22	49.9300
2	2025-08-25	49.6400
2	2025-08-26	50.1900
2	2025-08-27	49.5500
2	2025-08-28	49.8000
2	2025-08-29	50.4600
2	2025-09-02	49.8800
2	2025-09-03	49.5200
2	2025-09-04	50.5400
2	2025-09-05	52.1200
2	2025-09-08	52.3400
2	2025-09-09	53.2900
2	2025-09-10	53.5900
2	2025-09-11	52.3500
2	2025-09-12	51.8700
2	2025-09-15	51.7900
2	2025-09-16	51.7200
2	2025-09-17	52.0300
2	2025-09-18	51.5600
2	2025-09-19	51.8800
2	2025-09-22	52.5100
2	2025-09-23	52.5800
2	2025-09-24	52.4600
2	2025-09-25	52.4400
2	2025-09-26	51.9300
2	2025-09-29	51.5600
2	2025-09-30	51.9400
2	2025-10-01	52.0200
2	2025-10-02	51.3600
2	2025-10-03	52.1700
2	2025-10-06	52.1600
2	2025-10-07	51.9900
2	2025-10-08	52.7800
2	2025-10-09	54.4600
2	2025-10-10	52.5400
2	2025-10-13	54.9600
2	2025-10-14	54.5500
2	2025-10-15	55.4000
2	2025-10-16	56.3100
2	2025-10-17	57.0000
2	2025-10-20	55.6600
2	2025-10-21	54.0600
2	2025-10-22	55.0700
2	2025-10-23	55.8400
2	2025-10-24	56.0700
2	2025-10-27	56.9200
2	2025-10-28	56.7300
2	2025-10-29	57.4000
2	2025-10-30	57.8700
2	2025-10-31	58.0400
2	2025-11-03	57.9500
2	2025-11-04	58.0600
2	2025-11-05	59.1300
2	2025-11-06	60.2700
2	2025-11-07	63.2200
2	2025-11-10	63.5700
2	2025-11-11	63.8300
2	2025-11-12	64.1500
2	2025-11-13	62.6900
2	2025-11-14	62.9400
2	2025-11-17	62.5300
2	2025-11-18	62.7700
2	2025-11-19	62.7900
2	2025-11-20	61.5400
2	2025-11-21	60.6200
2	2025-11-24	60.6400
2	2025-11-25	60.4900
2	2025-11-26	62.7000
2	2025-11-28	63.0600
2	2025-12-01	62.3000
2	2025-12-02	64.0700
2	2025-12-03	64.0500
2	2025-12-04	64.4000
2	2025-12-05	62.4100
2	2025-12-08	62.4100
2	2025-12-09	63.5900
2	2025-12-10	64.3900
2	2025-12-11	64.1800
2	2025-12-12	63.9000
2	2025-12-15	63.0600
2	2025-12-16	62.7600
2	2025-12-17	61.8300
2	2025-12-18	61.5000
2	2025-12-19	62.6800
2	2025-12-22	62.9500
2	2025-12-23	63.6300
2	2025-12-24	64.3500
2	2025-12-26	65.3800
2	2025-12-29	64.9600
2	2025-12-30	63.9900
2	2025-12-31	63.6100
2	2026-01-02	63.2000
2	2026-01-05	66.5300
2	2026-01-06	67.1400
2	2026-01-07	67.8400
2	2026-01-08	70.1500
2	2026-01-09	70.7400
2	2026-01-12	70.9200
2	2026-01-13	73.0900
2	2026-01-14	73.5900
2	2026-01-15	73.8400
2	2026-01-16	75.7500
2	2026-01-20	77.0900
2	2026-01-21	79.5900
2	2026-01-22	78.7800
2	2026-01-23	82.0800
2	2026-01-26	83.7200
2	2026-01-27	82.8900
2	2026-01-28	83.0600
2	2026-01-29	84.5300
2	2026-01-30	81.6500
2	2026-02-02	82.5500
2	2026-02-03	82.6800
2	2026-02-04	77.9400
2	2026-02-05	76.3100
2	2026-02-06	78.3600
2	2026-02-09	79.9100
2	2026-02-10	79.8200
2	2026-02-11	79.1900
2	2026-02-12	76.7000
2	2026-02-13	77.0000
2	2026-02-17	77.9300
2	2026-02-18	77.8700
2	2026-02-19	78.9900
2	2026-02-20	79.5600
2	2026-02-23	80.4500
2	2026-02-24	75.7300
2	2026-02-25	74.3700
2	2026-02-26	69.1000
2	2026-02-27	67.8800
2	2026-03-02	66.7600
2	2026-03-03	66.2700
2	2026-03-04	67.0200
2	2026-03-05	65.1100
2	2026-03-06	65.2500
2	2026-03-09	67.4200
2	2026-03-10	70.2100
2	2026-03-11	69.1600
2	2026-03-12	66.1700
2	2026-03-13	65.8300
2	2026-03-16	68.3100
2	2026-03-17	67.9000
2	2026-03-18	68.0300
2	2026-03-19	68.8300
2	2026-03-20	68.9900
2	2026-03-23	70.5700
2	2026-03-24	71.1700
2	2026-03-25	72.9500
2	2026-03-26	70.7600
2	2026-03-27	69.9800
2	2026-03-30	69.5700
2	2026-03-31	72.8100
2	2026-04-01	72.8900
2	2026-04-02	72.1700
2	2026-04-06	72.7800
2	2026-04-07	73.1200
2	2026-04-08	75.3600
2	2026-04-09	73.8600
2	2026-04-10	74.5700
2	2026-04-13	77.2500
2	2026-04-14	77.4500
2	2026-04-15	75.0700
2	2026-04-16	75.8400
2	2026-04-17	73.8700
2	2026-04-20	74.7400
2	2026-04-21	73.2100
2	2026-04-22	73.5700
2	2026-04-23	71.8900
2	2026-04-24	71.5100
2	2026-04-27	69.4200
2	2026-04-28	68.7000
2	2026-04-29	67.2900
2	2026-04-30	68.1900
2	2026-05-01	67.0400
2	2026-05-04	65.2200
2	2026-05-05	65.8200
2	2026-05-06	66.8400
2	2026-05-07	65.1500
2	2026-05-08	65.2700
2	2026-05-11	64.3100
2	2026-05-12	64.3400
2	2026-05-13	63.6000
2	2026-05-14	64.3400
2	2026-05-15	63.1600
2	2026-05-18	64.0200
2	2026-05-19	63.7400
2	2026-05-20	65.5400
2	2026-05-21	66.3200
2	2026-05-22	65.8800
2	2026-05-26	71.7100
2	2026-05-27	70.7800
2	2026-05-28	69.1900
2	2026-05-29	68.5900
2	2026-06-01	73.3700
2	2026-06-02	73.7500
2	2026-06-03	72.2500
2	2026-06-04	72.3300
2	2026-06-05	70.8800
2	2026-06-08	71.8000
2	2026-06-09	74.9000
2	2026-06-10	75.8700
2	2026-06-11	80.8300
2	2026-06-12	80.2000
2	2026-06-15	80.1400
2	2026-06-16	79.2500
2	2026-06-17	79.9400
2	2026-06-18	81.4500
2	2026-06-22	81.2800
2	2026-06-23	80.9700
2	2026-06-24	79.2800
2	2026-06-25	78.8900
2	2026-06-26	79.2700
2	2026-06-29	79.8100
2	2026-06-30	79.4300
2	2026-07-01	78.1800
2	2026-07-02	79.1500
2	2026-07-06	80.9000
2	2026-07-07	81.0800
2	2026-07-08	80.0100
2	2026-07-09	80.9300
2	2026-07-10	82.9500
2	2026-07-13	80.4200
2	2026-07-14	82.1000
2	2026-07-15	81.5500
2	2026-07-16	79.4700
2	2026-07-17	80.4100
2	2026-07-20	80.8200
2	2026-07-21	83.6400
2	2026-07-22	84.6600
2	2026-07-23	86.7900
2	2026-07-24	86.0100
2	2026-07-27	87.9300
2	2026-07-28	89.0700
2	2026-07-29	89.4700
2	2026-07-30	93.8900
2	2026-07-31	92.5200
2	2026-08-03	91.1100
2	2026-08-04	90.0100
2	2026-08-05	90.1400
2	2026-08-06	90.2500
2	2026-08-07	88.8500
2	2026-08-10	91.4700
2	2026-08-11	98.0100
2	2026-08-12	95.7900
2	2026-08-13	96.1300
2	2026-08-14	96.3700
2	2026-08-17	96.5400
2	2026-08-18	97.6500
2	2026-08-19	99.6700
2	2026-08-20	98.6500
2	2026-08-21	101.4300
2	2026-08-24	101.8200
2	2026-08-25	103.2600
2	2026-08-26	101.0100
2	2026-08-27	98.6300
2	2026-08-28	97.2400
2	2026-08-31	96.1200
2	2026-09-01	96.2500
2	2026-09-02	98.4300
2	2026-09-03	101.8700
2	2026-09-04	100.5800
2	2026-09-08	98.6500
2	2026-09-09	100.0400
2	2026-09-10	103.1200
2	2026-09-11	102.0400
2	2026-09-14	101.8400
2	2026-09-15	100.6700
2	2026-09-16	98.3200
2	2026-09-17	98.2300
2	2026-09-18	96.6300
2	2026-09-21	97.2700
2	2026-09-22	97.9600
2	2026-09-23	95.6500
2	2026-09-24	94.2200
2	2026-09-25	95.1500
2	2026-09-28	92.3500
2	2026-09-29	93.7700
2	2026-09-30	92.8500
2	2026-10-01	91.0800
2	2026-10-02	91.9100
2	2026-10-05	96.0600
2	2026-10-06	96.5400
2	2026-10-07	93.7000
2	2026-10-08	94.0800
2	2026-10-09	94.8100
2	2026-10-12	94.9600
2	2026-10-13	95.4900
2	2026-10-14	96.9200
2	2026-10-15	97.6500
2	2026-10-16	97.9100
2	2026-10-19	95.6000
2	2026-10-20	95.8700
2	2026-10-21	97.6000
2	2026-10-22	96.6400
2	2026-10-23	98.0000
2	2026-10-26	96.4000
2	2026-10-27	95.8000
2	2026-10-28	94.6700
2	2026-10-29	93.5600
2	2026-10-30	92.0200
2	2026-11-02	92.0700
2	2026-11-03	92.7500
2	2026-11-04	94.3800
2	2026-11-05	92.2200
2	2026-11-06	92.3700
2	2026-11-09	94.9100
2	2026-11-10	91.1500
2	2026-11-11	91.9900
2	2026-11-12	88.6400
2	2026-11-13	89.5100
2	2026-11-16	87.4500
3	2024-01-02	185.6400
3	2024-01-03	184.2500
3	2024-01-04	181.9100
3	2024-01-05	181.1800
3	2024-01-08	185.5600
3	2024-01-09	185.1400
3	2024-01-10	186.1900
3	2024-01-11	185.5900
3	2024-01-12	185.9200
3	2024-01-16	183.6300
3	2024-01-17	182.6800
3	2024-01-18	188.6300
3	2024-01-19	191.5600
3	2024-01-22	193.8900
3	2024-01-23	195.1800
3	2024-01-24	194.5000
3	2024-01-25	194.1700
3	2024-01-26	192.4200
3	2024-01-29	191.7300
3	2024-01-30	188.0400
3	2024-01-31	184.4000
3	2024-02-01	186.8600
3	2024-02-02	185.8500
3	2024-02-05	187.6800
3	2024-02-06	189.3000
3	2024-02-07	189.4100
3	2024-02-08	188.3200
3	2024-02-09	188.8500
3	2024-02-12	187.1500
3	2024-02-13	185.0400
3	2024-02-14	184.1500
3	2024-02-15	183.8600
3	2024-02-16	182.3100
3	2024-02-20	181.5600
3	2024-02-21	182.3200
3	2024-02-22	184.3700
3	2024-02-23	182.5200
3	2024-02-26	181.1600
3	2024-02-27	182.6300
3	2024-02-28	181.4200
3	2024-02-29	180.7500
3	2024-03-01	179.6600
3	2024-03-04	175.1000
3	2024-03-05	170.1200
3	2024-03-06	169.1200
3	2024-03-07	169.0000
3	2024-03-08	170.7300
3	2024-03-11	172.7500
3	2024-03-12	173.2300
3	2024-03-13	171.1300
3	2024-03-14	173.0000
3	2024-03-15	172.6200
3	2024-03-18	173.7200
3	2024-03-19	176.0800
3	2024-03-20	178.6700
3	2024-03-21	171.3700
3	2024-03-22	172.2800
3	2024-03-25	170.8500
3	2024-03-26	169.7100
3	2024-03-27	173.3100
3	2024-03-28	171.4800
3	2024-04-01	170.0300
3	2024-04-02	168.8400
3	2024-04-03	169.6500
3	2024-04-04	168.8200
3	2024-04-05	169.5800
3	2024-04-08	168.4500
3	2024-04-09	169.6700
3	2024-04-10	167.7800
3	2024-04-11	175.0400
3	2024-04-12	176.5500
3	2024-04-15	172.6900
3	2024-04-16	169.3800
3	2024-04-17	168.0000
3	2024-04-18	167.0400
3	2024-04-19	165.0000
3	2024-04-22	165.8400
3	2024-04-23	166.9000
3	2024-04-24	169.0200
3	2024-04-25	169.8900
3	2024-04-26	169.3000
3	2024-04-29	173.5000
3	2024-04-30	170.3300
3	2024-05-01	169.3000
3	2024-05-02	173.0300
3	2024-05-03	183.3800
3	2024-05-06	181.7100
3	2024-05-07	182.4000
3	2024-05-08	182.7400
3	2024-05-09	184.5700
3	2024-05-10	183.0500
3	2024-05-13	186.2800
3	2024-05-14	187.4300
3	2024-05-15	189.7200
3	2024-05-16	189.8400
3	2024-05-17	189.8700
3	2024-05-20	191.0400
3	2024-05-21	192.3500
3	2024-05-22	190.9000
3	2024-05-23	186.8800
3	2024-05-24	189.9800
3	2024-05-28	189.9900
3	2024-05-29	190.2900
3	2024-05-30	191.2900
3	2024-05-31	192.2500
3	2024-06-03	194.0300
3	2024-06-04	194.3500
3	2024-06-05	195.8700
3	2024-06-06	194.4800
3	2024-06-07	196.8900
3	2024-06-10	193.1200
3	2024-06-11	207.1500
3	2024-06-12	213.0700
3	2024-06-13	214.2400
3	2024-06-14	212.4900
3	2024-06-17	216.6700
3	2024-06-18	214.2900
3	2024-06-20	209.6800
3	2024-06-21	207.4900
3	2024-06-24	208.1400
3	2024-06-25	209.0700
3	2024-06-26	213.2500
3	2024-06-27	214.1000
3	2024-06-28	210.6200
3	2024-07-01	216.7500
3	2024-07-02	220.2700
3	2024-07-03	221.5500
3	2024-07-05	226.3400
3	2024-07-08	227.8200
3	2024-07-09	228.6800
3	2024-07-10	232.9800
3	2024-07-11	227.5700
3	2024-07-12	230.5400
3	2024-07-15	234.4000
3	2024-07-16	234.8200
3	2024-07-17	228.8800
3	2024-07-18	224.1800
3	2024-07-19	224.3100
3	2024-07-22	223.9600
3	2024-07-23	225.0100
3	2024-07-24	218.5400
3	2024-07-25	217.4900
3	2024-07-26	217.9600
3	2024-07-29	218.2400
3	2024-07-30	218.8000
3	2024-07-31	222.0800
3	2024-08-01	218.3600
3	2024-08-02	219.8600
3	2024-08-05	209.2700
3	2024-08-06	207.2300
3	2024-08-07	209.8200
3	2024-08-08	213.3100
3	2024-08-09	216.2400
3	2024-08-12	217.5300
3	2024-08-13	221.2700
3	2024-08-14	221.7200
3	2024-08-15	224.7200
3	2024-08-16	226.0500
3	2024-08-19	225.8900
3	2024-08-20	226.5100
3	2024-08-21	226.4000
3	2024-08-22	224.5300
3	2024-08-23	226.8400
3	2024-08-26	227.1800
3	2024-08-27	228.0300
3	2024-08-28	226.4900
3	2024-08-29	229.7900
3	2024-08-30	229.0000
3	2024-09-03	222.7700
3	2024-09-04	220.8500
3	2024-09-05	222.3800
3	2024-09-06	220.8200
3	2024-09-09	220.9100
3	2024-09-10	220.1100
3	2024-09-11	222.6600
3	2024-09-12	222.7700
3	2024-09-13	222.5000
3	2024-09-16	216.3200
3	2024-09-17	216.7900
3	2024-09-18	220.6900
3	2024-09-19	228.8700
3	2024-09-20	228.2000
3	2024-09-23	226.4700
3	2024-09-24	227.3700
3	2024-09-25	226.3700
3	2024-09-26	227.5200
3	2024-09-27	227.7900
3	2024-09-30	233.0000
3	2024-10-01	226.2100
3	2024-10-02	226.7800
3	2024-10-03	225.6700
3	2024-10-04	226.8000
3	2024-10-07	221.6900
3	2024-10-08	225.7700
3	2024-10-09	229.5400
3	2024-10-10	229.0400
3	2024-10-11	227.5500
3	2024-10-14	231.3000
3	2024-10-15	233.8500
3	2024-10-16	231.7800
3	2024-10-17	232.1500
3	2024-10-18	235.0000
3	2024-10-21	236.4800
3	2024-10-22	235.8600
3	2024-10-23	230.7600
3	2024-10-24	230.5700
3	2024-10-25	231.4100
3	2024-10-28	233.4000
3	2024-10-29	233.6700
3	2024-10-30	230.1000
3	2024-10-31	225.9100
3	2024-11-01	222.9100
3	2024-11-04	222.0100
3	2024-11-05	223.4500
3	2024-11-06	222.7200
3	2024-11-07	227.4800
3	2024-11-08	226.9600
3	2024-11-11	224.2300
3	2024-11-12	224.2300
3	2024-11-13	225.1200
3	2024-11-14	228.2200
3	2024-11-15	225.0000
3	2024-11-18	228.0200
3	2024-11-19	228.2800
3	2024-11-20	229.0000
3	2024-11-21	228.5200
3	2024-11-22	229.8700
3	2024-11-25	232.8700
3	2024-11-26	235.0600
3	2024-11-27	234.9300
3	2024-11-29	237.3300
3	2024-12-02	239.5900
3	2024-12-03	242.6500
3	2024-12-04	243.0100
3	2024-12-05	243.0400
3	2024-12-06	242.8400
3	2024-12-09	246.7500
3	2024-12-10	247.7700
3	2024-12-11	246.4900
3	2024-12-12	247.9600
3	2024-12-13	248.1300
3	2024-12-16	251.0400
3	2024-12-17	253.4800
3	2024-12-18	248.0500
3	2024-12-19	249.7900
3	2024-12-20	254.4900
3	2024-12-23	255.2700
3	2024-12-24	258.2000
3	2024-12-26	259.0200
3	2024-12-27	255.5900
3	2024-12-30	252.2000
3	2024-12-31	250.4200
3	2025-01-02	243.8500
3	2025-01-03	243.3600
3	2025-01-06	245.0000
3	2025-01-07	242.2100
3	2025-01-08	242.7000
3	2025-01-10	236.8500
3	2025-01-13	234.4000
3	2025-01-14	233.2800
3	2025-01-15	237.8700
3	2025-01-16	228.2600
3	2025-01-17	229.9800
3	2025-01-21	222.6400
3	2025-01-22	223.8300
3	2025-01-23	223.6600
3	2025-01-24	222.7800
3	2025-01-27	229.8600
3	2025-01-28	238.2600
3	2025-01-29	239.3600
3	2025-01-30	237.5900
3	2025-01-31	236.0000
3	2025-02-03	228.0100
3	2025-02-04	232.8000
3	2025-02-05	232.4700
3	2025-02-06	233.2200
3	2025-02-07	227.6300
3	2025-02-10	227.6500
3	2025-02-11	232.6200
3	2025-02-12	236.8700
3	2025-02-13	241.5300
3	2025-02-14	244.6000
3	2025-02-18	244.4700
3	2025-02-19	244.8700
3	2025-02-20	245.8300
3	2025-02-21	245.5500
3	2025-02-24	247.1000
3	2025-02-25	247.0400
3	2025-02-26	240.3600
3	2025-02-27	237.3000
3	2025-02-28	241.8400
3	2025-03-03	238.0300
3	2025-03-04	235.9300
3	2025-03-05	235.7400
3	2025-03-06	235.3300
3	2025-03-07	239.0700
3	2025-03-10	227.4800
3	2025-03-11	220.8400
3	2025-03-12	216.9800
3	2025-03-13	209.6800
3	2025-03-14	213.4900
3	2025-03-17	214.0000
3	2025-03-18	212.6900
3	2025-03-19	215.2400
3	2025-03-20	214.1000
3	2025-03-21	218.2700
3	2025-03-24	220.7300
3	2025-03-25	223.7500
3	2025-03-26	221.5300
3	2025-03-27	223.8500
3	2025-03-28	217.9000
3	2025-03-31	222.1300
3	2025-04-01	223.1900
3	2025-04-02	223.8900
3	2025-04-03	203.1900
3	2025-04-04	188.3800
3	2025-04-07	181.4600
3	2025-04-08	172.4200
3	2025-04-09	198.8500
3	2025-04-10	190.4200
3	2025-04-11	198.1500
3	2025-04-14	202.5200
3	2025-04-15	202.1400
3	2025-04-16	194.2700
3	2025-04-17	196.9800
3	2025-04-21	193.1600
3	2025-04-22	199.7400
3	2025-04-23	204.6000
3	2025-04-24	208.3700
3	2025-04-25	209.2800
3	2025-04-28	210.1400
3	2025-04-29	211.2100
3	2025-04-30	212.5000
3	2025-05-01	213.3200
3	2025-05-02	205.3500
3	2025-05-05	198.8900
3	2025-05-06	198.5100
3	2025-05-07	196.2500
3	2025-05-08	197.4900
3	2025-05-09	198.5300
3	2025-05-12	210.7900
3	2025-05-13	212.9300
3	2025-05-14	212.3300
3	2025-05-15	211.4500
3	2025-05-16	211.2600
3	2025-05-19	208.7800
3	2025-05-20	206.8600
3	2025-05-21	202.0900
3	2025-05-22	201.3600
3	2025-05-23	195.2700
3	2025-05-27	200.2100
3	2025-05-28	200.4200
3	2025-05-29	199.9500
3	2025-05-30	200.8500
3	2025-06-02	201.7000
3	2025-06-03	203.2700
3	2025-06-04	202.8200
3	2025-06-05	200.6300
3	2025-06-06	203.9200
3	2025-06-09	201.4500
3	2025-06-10	202.6700
3	2025-06-11	198.7800
3	2025-06-12	199.2000
3	2025-06-13	196.4500
3	2025-06-16	198.4200
3	2025-06-17	195.6400
3	2025-06-18	196.5800
3	2025-06-20	201.0000
3	2025-06-23	201.5000
3	2025-06-24	200.3000
3	2025-06-25	201.5600
3	2025-06-26	201.0000
3	2025-06-27	201.0800
3	2025-06-30	205.1700
3	2025-07-01	207.8200
3	2025-07-02	212.4400
3	2025-07-03	213.5500
3	2025-07-07	209.9500
3	2025-07-08	210.0100
3	2025-07-09	211.1400
3	2025-07-10	212.4100
3	2025-07-11	211.1600
3	2025-07-14	208.6200
3	2025-07-15	209.1100
3	2025-07-16	210.1600
3	2025-07-17	210.0200
3	2025-07-18	211.1800
3	2025-07-21	212.4800
3	2025-07-22	214.4000
3	2025-07-23	214.1500
3	2025-07-24	213.7600
3	2025-07-25	213.8800
3	2025-07-28	214.0500
3	2025-07-29	211.2700
3	2025-07-30	209.0500
3	2025-07-31	207.5700
3	2025-08-01	202.3800
3	2025-08-04	203.3500
3	2025-08-05	202.9200
3	2025-08-06	213.2500
3	2025-08-07	220.0300
3	2025-08-08	229.3500
3	2025-08-11	227.1800
3	2025-08-12	229.6500
3	2025-08-13	233.3300
3	2025-08-14	232.7800
3	2025-08-15	231.5900
3	2025-08-18	230.8900
3	2025-08-19	230.5600
3	2025-08-20	226.0100
3	2025-08-21	224.9000
3	2025-08-22	227.7600
3	2025-08-25	227.1600
3	2025-08-26	229.3100
3	2025-08-27	230.4900
3	2025-08-28	232.5600
3	2025-08-29	232.1400
3	2025-09-02	229.7200
3	2025-09-03	238.4700
3	2025-09-04	239.7800
3	2025-09-05	239.6900
3	2025-09-08	237.8800
3	2025-09-09	234.3500
3	2025-09-10	226.7900
3	2025-09-11	230.0300
3	2025-09-12	234.0700
3	2025-09-15	236.7000
3	2025-09-16	238.1500
3	2025-09-17	238.9900
3	2025-09-18	237.8800
3	2025-09-19	245.5000
3	2025-09-22	256.0800
3	2025-09-23	254.4300
3	2025-09-24	252.3100
3	2025-09-25	256.8700
3	2025-09-26	255.4600
3	2025-09-29	254.4300
3	2025-09-30	254.6300
3	2025-10-01	255.4500
3	2025-10-02	257.1300
3	2025-10-03	258.0200
3	2025-10-06	256.6900
3	2025-10-07	256.4800
3	2025-10-08	258.0600
3	2025-10-09	254.0400
3	2025-10-10	245.2700
3	2025-10-13	247.6600
3	2025-10-14	247.7700
3	2025-10-15	249.3400
3	2025-10-16	247.4500
3	2025-10-17	252.2900
3	2025-10-20	262.2400
3	2025-10-21	262.7700
3	2025-10-22	258.4500
3	2025-10-23	259.5800
3	2025-10-24	262.8200
3	2025-10-27	268.8100
3	2025-10-28	269.0000
3	2025-10-29	269.7000
3	2025-10-30	271.4000
3	2025-10-31	270.3700
3	2025-11-03	269.0500
3	2025-11-04	270.0400
3	2025-11-05	270.1400
3	2025-11-06	269.7700
3	2025-11-07	268.4700
3	2025-11-10	269.4300
3	2025-11-11	275.2500
3	2025-11-12	273.4700
3	2025-11-13	272.9500
3	2025-11-14	272.4100
3	2025-11-17	267.4600
3	2025-11-18	267.4400
3	2025-11-19	268.5600
3	2025-11-20	266.2500
3	2025-11-21	271.4900
3	2025-11-24	275.9200
3	2025-11-25	276.9700
3	2025-11-26	277.5500
3	2025-11-28	278.8500
3	2025-12-01	283.1000
3	2025-12-02	286.1900
3	2025-12-03	284.1500
3	2025-12-04	280.7000
3	2025-12-05	278.7800
3	2025-12-08	277.8900
3	2025-12-09	277.1800
3	2025-12-10	278.7800
3	2025-12-11	278.0300
3	2025-12-12	278.2800
3	2025-12-15	274.1100
3	2025-12-16	274.6100
3	2025-12-17	271.8400
3	2025-12-18	272.1900
3	2025-12-19	273.6700
3	2025-12-22	270.9700
3	2025-12-23	272.3600
3	2025-12-24	273.8100
3	2025-12-26	273.4000
3	2025-12-29	273.7600
3	2025-12-30	273.0800
3	2025-12-31	271.8600
3	2026-01-02	271.0100
3	2026-01-05	267.2600
3	2026-01-06	262.3600
3	2026-01-07	260.3300
3	2026-01-08	259.0400
3	2026-01-09	259.3700
3	2026-01-12	260.2500
3	2026-01-13	261.0500
3	2026-01-14	259.9600
3	2026-01-15	258.2100
3	2026-01-16	255.5300
3	2026-01-20	246.7000
3	2026-01-21	247.6500
3	2026-01-22	248.3500
3	2026-01-23	248.0400
3	2026-01-26	255.4100
3	2026-01-27	258.2700
3	2026-01-28	256.4400
3	2026-01-29	258.2800
3	2026-01-30	259.4800
3	2026-02-02	270.0100
3	2026-02-03	269.4800
3	2026-02-04	276.4900
3	2026-02-05	275.9100
3	2026-02-06	278.1200
3	2026-02-09	274.6200
3	2026-02-10	273.6800
3	2026-02-11	275.5000
3	2026-02-12	261.7300
3	2026-02-13	255.7800
3	2026-02-17	263.8800
3	2026-02-18	264.3500
3	2026-02-19	260.5800
3	2026-02-20	264.5800
3	2026-02-23	266.1800
3	2026-02-24	272.1400
3	2026-02-25	274.2300
3	2026-02-26	272.9500
3	2026-02-27	264.1800
3	2026-03-02	264.7200
3	2026-03-03	263.7500
3	2026-03-04	262.5200
3	2026-03-05	260.2900
3	2026-03-06	257.4600
3	2026-03-09	259.8800
3	2026-03-10	260.8300
3	2026-03-11	260.8100
3	2026-03-12	255.7600
3	2026-03-13	250.1200
3	2026-03-16	252.8200
3	2026-03-17	254.2300
3	2026-03-18	249.9400
3	2026-03-19	248.9600
3	2026-03-20	247.9900
3	2026-03-23	251.4900
3	2026-03-24	251.6400
3	2026-03-25	252.6200
3	2026-03-26	252.8900
3	2026-03-27	248.8000
3	2026-03-30	246.6300
3	2026-03-31	253.7900
3	2026-04-01	255.6300
3	2026-04-02	255.9200
3	2026-04-06	258.8600
3	2026-04-07	253.5000
3	2026-04-08	258.9000
3	2026-04-09	260.4900
3	2026-04-10	260.4800
3	2026-04-13	259.2000
3	2026-04-14	258.8300
3	2026-04-15	266.4300
3	2026-04-16	263.4000
3	2026-04-17	270.2300
3	2026-04-20	273.0500
3	2026-04-21	266.1700
3	2026-04-22	273.1700
3	2026-04-23	273.4300
3	2026-04-24	271.0600
3	2026-04-27	267.6100
3	2026-04-28	270.7100
3	2026-04-29	270.1700
3	2026-04-30	271.3500
3	2026-05-01	280.1400
3	2026-05-04	276.8300
3	2026-05-05	284.1800
3	2026-05-06	287.5100
3	2026-05-07	287.4400
3	2026-05-08	293.3200
3	2026-05-11	292.6800
3	2026-05-12	294.8000
3	2026-05-13	298.8700
3	2026-05-14	298.2100
3	2026-05-15	300.2300
3	2026-05-18	297.8400
3	2026-05-19	298.9700
3	2026-05-20	302.2500
3	2026-05-21	304.9900
3	2026-05-22	308.8200
3	2026-05-26	308.3300
3	2026-05-27	310.8500
3	2026-05-28	312.5100
3	2026-05-29	312.0600
3	2026-06-01	306.3100
3	2026-06-02	315.2000
3	2026-06-03	310.2600
3	2026-06-04	311.2300
3	2026-06-05	307.3400
3	2026-06-08	301.5400
3	2026-06-09	290.5500
3	2026-06-10	291.5800
3	2026-06-11	295.6300
3	2026-06-12	291.1300
3	2026-06-15	296.4200
3	2026-06-16	299.2400
3	2026-06-17	295.9500
3	2026-06-18	298.0100
3	2026-06-22	297.0100
3	2026-06-23	294.3000
3	2026-06-24	293.0800
3	2026-06-25	275.1500
3	2026-06-26	283.7800
3	2026-06-29	281.7400
3	2026-06-30	289.3600
3	2026-07-01	294.3800
3	2026-07-02	308.6300
3	2026-07-06	312.6600
3	2026-07-07	310.6600
3	2026-07-08	313.3900
3	2026-07-09	316.2200
3	2026-07-10	315.3200
3	2026-07-13	317.3100
3	2026-07-14	314.8600
3	2026-07-15	327.5000
3	2026-07-16	333.2600
3	2026-07-17	333.7400
3	2026-07-20	326.5900
3	2026-07-21	327.7400
3	2026-07-22	325.8900
3	2026-07-23	321.6600
3	2026-07-24	333.0200
3	2026-07-27	336.9100
3	2026-07-28	340.0800
3	2026-07-29	338.1900
3	2026-07-30	333.4300
3	2026-07-31	308.9100
3	2026-08-03	303.4200
3	2026-08-04	309.3800
3	2026-08-05	311.0000
3	2026-08-06	312.4100
3	2026-08-07	313.3300
3	2026-08-10	308.2600
3	2026-08-11	304.9100
3	2026-08-12	302.2500
3	2026-08-13	305.2600
3	2026-08-14	305.9300
3	2026-08-17	305.5900
3	2026-08-18	310.0300
3	2026-08-19	316.8300
3	2026-08-20	311.3000
3	2026-08-21	309.3500
3	2026-08-24	310.3400
3	2026-08-25	309.9000
3	2026-08-26	313.4500
3	2026-08-27	314.5800
3	2026-08-28	319.7000
3	2026-08-31	316.8500
3	2026-09-01	325.1300
3	2026-09-02	324.9600
3	2026-09-03	328.2100
3	2026-09-04	319.9700
3	2026-09-08	316.2200
3	2026-09-09	315.3400
3	2026-09-10	326.5700
3	2026-09-11	332.2700
3	2026-09-14	333.0800
3	2026-09-15	331.3400
3	2026-09-16	332.4100
3	2026-09-17	337.0000
3	2026-09-18	336.1300
3	2026-09-21	338.9800
3	2026-09-22	339.7500
3	2026-09-23	337.0200
3	2026-09-24	335.9200
3	2026-09-25	341.0700
3	2026-09-28	338.4000
3	2026-09-29	329.4000
3	2026-09-30	333.0200
3	2026-10-01	330.3200
3	2026-10-02	333.6900
3	2026-10-05	332.8900
3	2026-10-06	333.6300
3	2026-10-07	336.6700
3	2026-10-08	340.4200
3	2026-10-09	336.6400
3	2026-10-12	340.9700
3	2026-10-13	341.2700
3	2026-10-14	342.9600
3	2026-10-15	342.0000
3	2026-10-16	343.4600
3	2026-10-19	342.9400
3	2026-10-20	339.5000
3	2026-10-21	343.9900
3	2026-10-22	348.2200
3	2026-10-23	347.7300
3	2026-10-26	343.9100
3	2026-10-27	347.1000
3	2026-10-28	343.8300
3	2026-10-29	348.9100
3	2026-10-30	344.6300
3	2026-11-02	338.3200
3	2026-11-03	331.9000
3	2026-11-04	349.5100
3	2026-11-05	344.1700
3	2026-11-06	342.3700
3	2026-11-09	350.6900
3	2026-11-10	348.5100
3	2026-11-11	355.6300
3	2026-11-12	354.8800
3	2026-11-13	356.2700
3	2026-11-16	352.7800
4	2024-01-02	370.8700
4	2024-01-03	370.6000
4	2024-01-04	367.9400
4	2024-01-05	367.7500
4	2024-01-08	374.6900
4	2024-01-09	375.7900
4	2024-01-10	382.7700
4	2024-01-11	384.6300
4	2024-01-12	388.4700
4	2024-01-16	390.2700
4	2024-01-17	389.4700
4	2024-01-18	393.8700
4	2024-01-19	398.6700
4	2024-01-22	396.5100
4	2024-01-23	398.9000
4	2024-01-24	402.5600
4	2024-01-25	404.8700
4	2024-01-26	403.9300
4	2024-01-29	409.7200
4	2024-01-30	408.5900
4	2024-01-31	397.5800
4	2024-02-01	403.7800
4	2024-02-02	411.2200
4	2024-02-05	405.6500
4	2024-02-06	405.4900
4	2024-02-07	414.0500
4	2024-02-08	414.1100
4	2024-02-09	420.5500
4	2024-02-12	415.2600
4	2024-02-13	406.3200
4	2024-02-14	409.4900
4	2024-02-15	406.5600
4	2024-02-16	404.0600
4	2024-02-20	402.7900
4	2024-02-21	402.1800
4	2024-02-22	411.6500
4	2024-02-23	410.3400
4	2024-02-26	407.5400
4	2024-02-27	407.4800
4	2024-02-28	407.7200
4	2024-02-29	413.6400
4	2024-03-01	415.5000
4	2024-03-04	414.9200
4	2024-03-05	402.6500
4	2024-03-06	402.0900
4	2024-03-07	409.1400
4	2024-03-08	406.2200
4	2024-03-11	404.5200
4	2024-03-12	415.2800
4	2024-03-13	415.1000
4	2024-03-14	425.2200
4	2024-03-15	416.4200
4	2024-03-18	417.3200
4	2024-03-19	421.4100
4	2024-03-20	425.2300
4	2024-03-21	429.3700
4	2024-03-22	428.7400
4	2024-03-25	422.8600
4	2024-03-26	421.6500
4	2024-03-27	421.4300
4	2024-03-28	420.7200
4	2024-04-01	424.5700
4	2024-04-02	421.4400
4	2024-04-03	420.4500
4	2024-04-04	417.8800
4	2024-04-05	425.5200
4	2024-04-08	424.5900
4	2024-04-09	426.2800
4	2024-04-10	423.2600
4	2024-04-11	427.9300
4	2024-04-12	421.9000
4	2024-04-15	413.6400
4	2024-04-16	414.5800
4	2024-04-17	411.8400
4	2024-04-18	404.2700
4	2024-04-19	399.1200
4	2024-04-22	400.9600
4	2024-04-23	407.5700
4	2024-04-24	409.0600
4	2024-04-25	399.0400
4	2024-04-26	406.3200
4	2024-04-29	402.2500
4	2024-04-30	389.3300
4	2024-05-01	394.9400
4	2024-05-02	397.8400
4	2024-05-03	406.6600
4	2024-05-06	413.5400
4	2024-05-07	409.3400
4	2024-05-08	410.5400
4	2024-05-09	412.3200
4	2024-05-10	414.7400
4	2024-05-13	413.7200
4	2024-05-14	416.5600
4	2024-05-15	423.0800
4	2024-05-16	420.9900
4	2024-05-17	420.2100
4	2024-05-20	425.3400
4	2024-05-21	429.0400
4	2024-05-22	430.5200
4	2024-05-23	427.0000
4	2024-05-24	430.1600
4	2024-05-28	430.3200
4	2024-05-29	429.1700
4	2024-05-30	414.6700
4	2024-05-31	415.1300
4	2024-06-03	413.5200
4	2024-06-04	416.0700
4	2024-06-05	424.0100
4	2024-06-06	424.5200
4	2024-06-07	423.8500
4	2024-06-10	427.8700
4	2024-06-11	432.6800
4	2024-06-12	441.0600
4	2024-06-13	441.5800
4	2024-06-14	442.5700
4	2024-06-17	448.3700
4	2024-06-18	446.3400
4	2024-06-20	445.7000
4	2024-06-21	449.7800
4	2024-06-24	447.6700
4	2024-06-25	450.9500
4	2024-06-26	452.1600
4	2024-06-27	452.8500
4	2024-06-28	446.9500
4	2024-07-01	456.7300
4	2024-07-02	459.2800
4	2024-07-03	460.7700
4	2024-07-05	467.5600
4	2024-07-08	466.2400
4	2024-07-09	459.5400
4	2024-07-10	466.2500
4	2024-07-11	454.7000
4	2024-07-12	453.5500
4	2024-07-15	453.9600
4	2024-07-16	449.5200
4	2024-07-17	443.5200
4	2024-07-18	440.3700
4	2024-07-19	437.1100
4	2024-07-22	442.9400
4	2024-07-23	444.8500
4	2024-07-24	428.9000
4	2024-07-25	418.4000
4	2024-07-26	425.2700
4	2024-07-29	426.7300
4	2024-07-30	422.9200
4	2024-07-31	418.3500
4	2024-08-01	417.1100
4	2024-08-02	408.4900
4	2024-08-05	395.1500
4	2024-08-06	399.6100
4	2024-08-07	398.4300
4	2024-08-08	402.6900
4	2024-08-09	406.0200
4	2024-08-12	406.8100
4	2024-08-13	414.0100
4	2024-08-14	416.8600
4	2024-08-15	421.0300
4	2024-08-16	418.4700
4	2024-08-19	421.5300
4	2024-08-20	424.8000
4	2024-08-21	424.1400
4	2024-08-22	415.5500
4	2024-08-23	416.7900
4	2024-08-26	413.4900
4	2024-08-27	413.8400
4	2024-08-28	410.6000
4	2024-08-29	413.1200
4	2024-08-30	417.1400
4	2024-09-03	409.4400
4	2024-09-04	408.9000
4	2024-09-05	408.3900
4	2024-09-06	401.7000
4	2024-09-09	405.7200
4	2024-09-10	414.2000
4	2024-09-11	423.0400
4	2024-09-12	427.0000
4	2024-09-13	430.5900
4	2024-09-16	431.3400
4	2024-09-17	435.1500
4	2024-09-18	430.8100
4	2024-09-19	438.6900
4	2024-09-20	435.2700
4	2024-09-23	433.5100
4	2024-09-24	429.1700
4	2024-09-25	432.1100
4	2024-09-26	431.3100
4	2024-09-27	428.0200
4	2024-09-30	430.3000
4	2024-10-01	420.6900
4	2024-10-02	417.1300
4	2024-10-03	416.5400
4	2024-10-04	416.0600
4	2024-10-07	409.5400
4	2024-10-08	414.7100
4	2024-10-09	417.4600
4	2024-10-10	415.8400
4	2024-10-11	416.3200
4	2024-10-14	419.1400
4	2024-10-15	418.7400
4	2024-10-16	416.1200
4	2024-10-17	416.7200
4	2024-10-18	418.1600
4	2024-10-21	418.7800
4	2024-10-22	427.5100
4	2024-10-23	424.6000
4	2024-10-24	424.7300
4	2024-10-25	428.1500
4	2024-10-28	426.5900
4	2024-10-29	431.9500
4	2024-10-30	432.5300
4	2024-10-31	406.3500
4	2024-11-01	410.3700
4	2024-11-04	408.4600
4	2024-11-05	411.4600
4	2024-11-06	420.1800
4	2024-11-07	425.4300
4	2024-11-08	422.5400
4	2024-11-11	418.0100
4	2024-11-12	423.0300
4	2024-11-13	425.2000
4	2024-11-14	426.8900
4	2024-11-15	415.0000
4	2024-11-18	415.7600
4	2024-11-19	417.7900
4	2024-11-20	415.4900
4	2024-11-21	412.8700
4	2024-11-22	417.0000
4	2024-11-25	418.7900
4	2024-11-26	427.9900
4	2024-11-27	422.9900
4	2024-11-29	423.4600
4	2024-12-02	430.9800
4	2024-12-03	431.2000
4	2024-12-04	437.4200
4	2024-12-05	442.6200
4	2024-12-06	443.5700
4	2024-12-09	446.0200
4	2024-12-10	443.3300
4	2024-12-11	448.9900
4	2024-12-12	449.5600
4	2024-12-13	447.2700
4	2024-12-16	451.5900
4	2024-12-17	454.4600
4	2024-12-18	437.3900
4	2024-12-19	437.0300
4	2024-12-20	436.6000
4	2024-12-23	435.2500
4	2024-12-24	439.3300
4	2024-12-26	438.1100
4	2024-12-27	430.5300
4	2024-12-30	424.8300
4	2024-12-31	421.5000
4	2025-01-02	418.5800
4	2025-01-03	423.3500
4	2025-01-06	427.8500
4	2025-01-07	422.3700
4	2025-01-08	424.5600
4	2025-01-10	418.9500
4	2025-01-13	417.1900
4	2025-01-14	415.6700
4	2025-01-15	426.3100
4	2025-01-16	424.5800
4	2025-01-17	429.0300
4	2025-01-21	428.5000
4	2025-01-22	446.2000
4	2025-01-23	446.7100
4	2025-01-24	444.0600
4	2025-01-27	434.5600
4	2025-01-28	447.2000
4	2025-01-29	442.3300
4	2025-01-30	414.9900
4	2025-01-31	415.0600
4	2025-02-03	410.9200
4	2025-02-04	412.3700
4	2025-02-05	413.2900
4	2025-02-06	415.8200
4	2025-02-07	409.7500
4	2025-02-10	412.2200
4	2025-02-11	411.4400
4	2025-02-12	409.0400
4	2025-02-13	410.5400
4	2025-02-14	408.4300
4	2025-02-18	409.6400
4	2025-02-19	414.7700
4	2025-02-20	416.1300
4	2025-02-21	408.2100
4	2025-02-24	404.0000
4	2025-02-25	397.9000
4	2025-02-26	399.7300
4	2025-02-27	392.5300
4	2025-02-28	396.9900
4	2025-03-03	388.4900
4	2025-03-04	388.6100
4	2025-03-05	401.0200
4	2025-03-06	396.8900
4	2025-03-07	393.3100
4	2025-03-10	380.1600
4	2025-03-11	380.4500
4	2025-03-12	383.2700
4	2025-03-13	378.7700
4	2025-03-14	388.5600
4	2025-03-17	388.7000
4	2025-03-18	383.5200
4	2025-03-19	387.8200
4	2025-03-20	386.8400
4	2025-03-21	391.2600
4	2025-03-24	393.0800
4	2025-03-25	395.1600
4	2025-03-26	389.9700
4	2025-03-27	390.5800
4	2025-03-28	378.8000
4	2025-03-31	375.3900
4	2025-04-01	382.1900
4	2025-04-02	382.1400
4	2025-04-03	373.1100
4	2025-04-04	359.8400
4	2025-04-07	357.8600
4	2025-04-08	354.5600
4	2025-04-09	390.4900
4	2025-04-10	381.3500
4	2025-04-11	388.4500
4	2025-04-14	387.8100
4	2025-04-15	385.7300
4	2025-04-16	371.6100
4	2025-04-17	367.7800
4	2025-04-21	359.1200
4	2025-04-22	366.8200
4	2025-04-23	374.3900
4	2025-04-24	387.3000
4	2025-04-25	391.8500
4	2025-04-28	391.1600
4	2025-04-29	394.0400
4	2025-04-30	395.2600
4	2025-05-01	425.4000
4	2025-05-02	435.2800
4	2025-05-05	436.1700
4	2025-05-06	433.3100
4	2025-05-07	433.3500
4	2025-05-08	438.1700
4	2025-05-09	438.7300
4	2025-05-12	449.2600
4	2025-05-13	449.1400
4	2025-05-14	452.9400
4	2025-05-15	453.1300
4	2025-05-16	454.2700
4	2025-05-19	458.8700
4	2025-05-20	458.1700
4	2025-05-21	452.5700
4	2025-05-22	454.8600
4	2025-05-23	450.1800
4	2025-05-27	460.6900
4	2025-05-28	457.3600
4	2025-05-29	458.6800
4	2025-05-30	460.3600
4	2025-06-02	461.9700
4	2025-06-03	462.9700
4	2025-06-04	463.8700
4	2025-06-05	467.6800
4	2025-06-06	470.3800
4	2025-06-09	472.7500
4	2025-06-10	470.9200
4	2025-06-11	472.6200
4	2025-06-12	478.8700
4	2025-06-13	474.9600
4	2025-06-16	479.1400
4	2025-06-17	478.0400
4	2025-06-18	480.2400
4	2025-06-20	477.4000
4	2025-06-23	486.0000
4	2025-06-24	490.1100
4	2025-06-25	492.2700
4	2025-06-26	497.4500
4	2025-06-27	495.9400
4	2025-06-30	497.4100
4	2025-07-01	492.0500
4	2025-07-02	491.0900
4	2025-07-03	498.8400
4	2025-07-07	497.7200
4	2025-07-08	496.6200
4	2025-07-09	503.5100
4	2025-07-10	501.4800
4	2025-07-11	503.3200
4	2025-07-14	503.0200
4	2025-07-15	505.8200
4	2025-07-16	505.6200
4	2025-07-17	511.7000
4	2025-07-18	510.0500
4	2025-07-21	510.0600
4	2025-07-22	505.2700
4	2025-07-23	505.8700
4	2025-07-24	510.8800
4	2025-07-25	513.7100
4	2025-07-28	512.5000
4	2025-07-29	512.5700
4	2025-07-30	513.2400
4	2025-07-31	533.5000
4	2025-08-01	524.1100
4	2025-08-04	535.6400
4	2025-08-05	527.7500
4	2025-08-06	524.9400
4	2025-08-07	520.8400
4	2025-08-08	522.0400
4	2025-08-11	521.7700
4	2025-08-12	529.2400
4	2025-08-13	520.5800
4	2025-08-14	522.4800
4	2025-08-15	520.1700
4	2025-08-18	517.1000
4	2025-08-19	509.7700
4	2025-08-20	505.7200
4	2025-08-21	504.2400
4	2025-08-22	507.2300
4	2025-08-25	504.2600
4	2025-08-26	502.0400
4	2025-08-27	506.7400
4	2025-08-28	509.6400
4	2025-08-29	506.6900
4	2025-09-02	505.1200
4	2025-09-03	505.3500
4	2025-09-04	507.9700
4	2025-09-05	495.0000
4	2025-09-08	498.2000
4	2025-09-09	498.4100
4	2025-09-10	500.3700
4	2025-09-11	501.0100
4	2025-09-12	509.9000
4	2025-09-15	515.3600
4	2025-09-16	509.0400
4	2025-09-17	510.0200
4	2025-09-18	508.4500
4	2025-09-19	517.9300
4	2025-09-22	514.4500
4	2025-09-23	509.2300
4	2025-09-24	510.1500
4	2025-09-25	507.0300
4	2025-09-26	511.4600
4	2025-09-29	514.6000
4	2025-09-30	517.9500
4	2025-10-01	519.7100
4	2025-10-02	515.7400
4	2025-10-03	517.3500
4	2025-10-06	528.5700
4	2025-10-07	523.9800
4	2025-10-08	524.8500
4	2025-10-09	522.4000
4	2025-10-10	510.9600
4	2025-10-13	514.0500
4	2025-10-14	513.5700
4	2025-10-15	513.4300
4	2025-10-16	511.6100
4	2025-10-17	513.5800
4	2025-10-20	516.7900
4	2025-10-21	517.6600
4	2025-10-22	520.5400
4	2025-10-23	520.5600
4	2025-10-24	523.6100
4	2025-10-27	531.5200
4	2025-10-28	542.0700
4	2025-10-29	541.5500
4	2025-10-30	525.7600
4	2025-10-31	517.8100
4	2025-11-03	517.0300
4	2025-11-04	514.3300
4	2025-11-05	507.1600
4	2025-11-06	497.1000
4	2025-11-07	496.8200
4	2025-11-10	506.0000
4	2025-11-11	508.6800
4	2025-11-12	511.1400
4	2025-11-13	503.2900
4	2025-11-14	510.1800
4	2025-11-17	507.4900
4	2025-11-18	493.7900
4	2025-11-19	487.1200
4	2025-11-20	478.4300
4	2025-11-21	472.1200
4	2025-11-24	474.0000
4	2025-11-25	476.9900
4	2025-11-26	485.5000
4	2025-11-28	492.0100
4	2025-12-01	486.7400
4	2025-12-02	490.0000
4	2025-12-03	477.7300
4	2025-12-04	480.8400
4	2025-12-05	483.1600
4	2025-12-08	491.0200
4	2025-12-09	492.0200
4	2025-12-10	478.5600
4	2025-12-11	483.4700
4	2025-12-12	478.5300
4	2025-12-15	474.8200
4	2025-12-16	476.3900
4	2025-12-17	476.1200
4	2025-12-18	483.9800
4	2025-12-19	485.9200
4	2025-12-22	484.9200
4	2025-12-23	486.8500
4	2025-12-24	488.0200
4	2025-12-26	487.7100
4	2025-12-29	487.1000
4	2025-12-30	487.4800
4	2025-12-31	483.6200
4	2026-01-02	472.9400
4	2026-01-05	472.8500
4	2026-01-06	478.5100
4	2026-01-07	483.4700
4	2026-01-08	478.1100
4	2026-01-09	479.2800
4	2026-01-12	477.1800
4	2026-01-13	470.6700
4	2026-01-14	459.3800
4	2026-01-15	456.6600
4	2026-01-16	459.8600
4	2026-01-20	454.5200
4	2026-01-21	444.1100
4	2026-01-22	451.1400
4	2026-01-23	465.9500
4	2026-01-26	470.2800
4	2026-01-27	480.5800
4	2026-01-28	481.6300
4	2026-01-29	433.5000
4	2026-01-30	430.2900
4	2026-02-02	423.3700
4	2026-02-03	411.2100
4	2026-02-04	414.1900
4	2026-02-05	393.6700
4	2026-02-06	401.1400
4	2026-02-09	413.6000
4	2026-02-10	413.2700
4	2026-02-11	404.3700
4	2026-02-12	401.8400
4	2026-02-13	401.3200
4	2026-02-17	396.8600
4	2026-02-18	399.6000
4	2026-02-19	398.4600
4	2026-02-20	397.2300
4	2026-02-23	384.4700
4	2026-02-24	389.0000
4	2026-02-25	400.6000
4	2026-02-26	401.7200
4	2026-02-27	392.7400
4	2026-03-02	398.5500
4	2026-03-03	403.9300
4	2026-03-04	405.2000
4	2026-03-05	410.6800
4	2026-03-06	408.9600
4	2026-03-09	409.4100
4	2026-03-10	405.7600
4	2026-03-11	404.8800
4	2026-03-12	401.8600
4	2026-03-13	395.5500
4	2026-03-16	399.9500
4	2026-03-17	399.4100
4	2026-03-18	391.7900
4	2026-03-19	389.0200
4	2026-03-20	381.8700
4	2026-03-23	383.0000
4	2026-03-24	372.7400
4	2026-03-25	371.0400
4	2026-03-26	365.9700
4	2026-03-27	356.7700
4	2026-03-30	358.9600
4	2026-03-31	370.1700
4	2026-04-01	369.3700
4	2026-04-02	373.4600
4	2026-04-06	372.8800
4	2026-04-07	372.2900
4	2026-04-08	374.3300
4	2026-04-09	373.0700
4	2026-04-10	370.8700
4	2026-04-13	384.3700
4	2026-04-14	393.1100
4	2026-04-15	411.2200
4	2026-04-16	420.2600
4	2026-04-17	422.7900
4	2026-04-20	418.0700
4	2026-04-21	424.1600
4	2026-04-22	432.9200
4	2026-04-23	415.7500
4	2026-04-24	424.6200
4	2026-04-27	424.8200
4	2026-04-28	429.2500
4	2026-04-29	424.4600
4	2026-04-30	407.7800
4	2026-05-01	414.4400
4	2026-05-04	413.6200
4	2026-05-05	411.3800
4	2026-05-06	413.9600
4	2026-05-07	420.7700
4	2026-05-08	415.1200
4	2026-05-11	412.6600
4	2026-05-12	407.7700
4	2026-05-13	405.2100
4	2026-05-14	409.4300
4	2026-05-15	421.9200
4	2026-05-18	423.5400
4	2026-05-19	417.4200
4	2026-05-20	421.0600
4	2026-05-21	419.0900
4	2026-05-22	418.5700
4	2026-05-26	416.0300
4	2026-05-27	412.6700
4	2026-05-28	426.9900
4	2026-05-29	450.2400
4	2026-06-01	460.5200
4	2026-06-02	441.3100
4	2026-06-03	427.3400
4	2026-06-04	428.0500
4	2026-06-05	416.6700
4	2026-06-08	411.7400
4	2026-06-09	403.4100
4	2026-06-10	397.3600
4	2026-06-11	390.3400
4	2026-06-12	390.7400
4	2026-06-15	399.7600
4	2026-06-16	393.8300
4	2026-06-17	378.9100
4	2026-06-18	379.4000
4	2026-06-22	367.3400
4	2026-06-23	373.9400
4	2026-06-24	365.4600
4	2026-06-25	352.8300
4	2026-06-26	372.9700
4	2026-06-29	368.5700
4	2026-06-30	373.0200
4	2026-07-01	384.2800
4	2026-07-02	390.4900
4	2026-07-06	386.7400
4	2026-07-07	388.8400
4	2026-07-08	383.3400
4	2026-07-09	384.3600
4	2026-07-10	385.1000
4	2026-07-13	390.9900
4	2026-07-14	384.9300
4	2026-07-15	395.6300
4	2026-07-16	401.1000
4	2026-07-17	393.8200
4	2026-07-20	402.2900
4	2026-07-21	397.7500
4	2026-07-22	390.3400
4	2026-07-23	381.5800
4	2026-07-24	381.7000
4	2026-07-27	389.1000
4	2026-07-28	393.3500
4	2026-07-29	390.5400
4	2026-07-30	451.1000
4	2026-07-31	464.7200
4	2026-08-03	487.6500
4	2026-08-04	492.8100
4	2026-08-05	487.4600
4	2026-08-06	499.8600
4	2026-08-07	499.9900
4	2026-08-10	506.0600
4	2026-08-11	503.8100
4	2026-08-12	492.4300
4	2026-08-13	496.8800
4	2026-08-14	495.4000
4	2026-08-17	480.3500
4	2026-08-18	481.6300
4	2026-08-19	484.3100
4	2026-08-20	481.1500
4	2026-08-21	483.2400
4	2026-08-24	487.3100
4	2026-08-25	491.7100
4	2026-08-26	496.3700
4	2026-08-27	505.0600
4	2026-08-28	513.5300
4	2026-08-31	507.2900
4	2026-09-01	501.0200
4	2026-09-02	496.8200
4	2026-09-03	510.1200
4	2026-09-04	499.7000
4	2026-09-08	493.9500
4	2026-09-09	491.6500
4	2026-09-10	492.4400
4	2026-09-11	495.6300
4	2026-09-14	505.4100
4	2026-09-15	497.1200
4	2026-09-16	490.3000
4	2026-09-17	497.7500
4	2026-09-18	493.7800
4	2026-09-21	501.6100
4	2026-09-22	498.0000
4	2026-09-23	500.5900
4	2026-09-24	497.9300
4	2026-09-25	516.1700
4	2026-09-28	509.2200
4	2026-09-29	508.9600
4	2026-09-30	512.9000
4	2026-10-01	512.8000
4	2026-10-02	517.5300
4	2026-10-05	525.1800
4	2026-10-06	529.3000
4	2026-10-07	529.7600
4	2026-10-08	522.6100
4	2026-10-09	535.0700
4	2026-10-12	541.1500
4	2026-10-13	543.4500
4	2026-10-14	533.6900
4	2026-10-15	539.4400
4	2026-10-16	529.0500
4	2026-10-19	533.5200
4	2026-10-20	531.8700
4	2026-10-21	532.9500
4	2026-10-22	521.0800
4	2026-10-23	524.5100
4	2026-10-26	532.6000
4	2026-10-27	531.3300
4	2026-10-28	531.0100
4	2026-10-29	530.1400
4	2026-10-30	521.9100
4	2026-11-02	507.1200
4	2026-11-03	520.9900
4	2026-11-04	555.8000
4	2026-11-05	535.9300
4	2026-11-06	530.6100
4	2026-11-09	545.1800
4	2026-11-10	533.1600
4	2026-11-11	521.1300
4	2026-11-12	523.0000
4	2026-11-13	523.8800
4	2026-11-16	517.9900
5	2024-01-02	149.9300
5	2024-01-03	148.4700
5	2024-01-04	144.5700
5	2024-01-05	145.2400
5	2024-01-08	149.1000
5	2024-01-09	151.3700
5	2024-01-10	153.7300
5	2024-01-11	155.1800
5	2024-01-12	154.6200
5	2024-01-16	153.1600
5	2024-01-17	151.7100
5	2024-01-18	153.5000
5	2024-01-19	155.3400
5	2024-01-22	154.7800
5	2024-01-23	156.0200
5	2024-01-24	156.8700
5	2024-01-25	157.7500
5	2024-01-26	159.1200
5	2024-01-29	161.2600
5	2024-01-30	159.0000
5	2024-01-31	155.2000
5	2024-02-01	159.2800
5	2024-02-02	171.8100
5	2024-02-05	170.3100
5	2024-02-06	169.1500
5	2024-02-07	170.5300
5	2024-02-08	169.8400
5	2024-02-09	174.4500
5	2024-02-12	172.3400
5	2024-02-13	168.6400
5	2024-02-14	170.9800
5	2024-02-15	169.8000
5	2024-02-16	169.5100
5	2024-02-20	167.0800
5	2024-02-21	168.5900
5	2024-02-22	174.5800
5	2024-02-23	174.9900
5	2024-02-26	174.7300
5	2024-02-27	173.5400
5	2024-02-28	173.1600
5	2024-02-29	176.7600
5	2024-03-01	178.2200
5	2024-03-04	177.5800
5	2024-03-05	174.1200
5	2024-03-06	173.5100
5	2024-03-07	176.8200
5	2024-03-08	175.3500
5	2024-03-11	171.9600
5	2024-03-12	175.3900
5	2024-03-13	176.5600
5	2024-03-14	178.7500
5	2024-03-15	174.4200
5	2024-03-18	174.4800
5	2024-03-19	175.9000
5	2024-03-20	178.1500
5	2024-03-21	178.1500
5	2024-03-22	178.8700
5	2024-03-25	179.7100
5	2024-03-26	178.3000
5	2024-03-27	179.8300
5	2024-03-28	180.3800
5	2024-04-01	180.9700
5	2024-04-02	180.6900
5	2024-04-03	182.4100
5	2024-04-04	180.0000
5	2024-04-05	185.0700
5	2024-04-08	185.1900
5	2024-04-09	185.6700
5	2024-04-10	185.9500
5	2024-04-11	189.0500
5	2024-04-12	186.1300
5	2024-04-15	183.6200
5	2024-04-16	183.3200
5	2024-04-17	181.2800
5	2024-04-18	179.2200
5	2024-04-19	174.6300
5	2024-04-22	177.2300
5	2024-04-23	179.5400
5	2024-04-24	176.5900
5	2024-04-25	173.6700
5	2024-04-26	179.6200
5	2024-04-29	180.9600
5	2024-04-30	175.0000
5	2024-05-01	179.0000
5	2024-05-02	184.7200
5	2024-05-03	186.2100
5	2024-05-06	188.7000
5	2024-05-07	188.7600
5	2024-05-08	188.0000
5	2024-05-09	189.5000
5	2024-05-10	187.4800
5	2024-05-13	186.5700
5	2024-05-14	187.0700
5	2024-05-15	185.9900
5	2024-05-16	183.6300
5	2024-05-17	184.7000
5	2024-05-20	183.5400
5	2024-05-21	183.1500
5	2024-05-22	183.1300
5	2024-05-23	181.0500
5	2024-05-24	180.7500
5	2024-05-28	182.1500
5	2024-05-29	182.0200
5	2024-05-30	179.3200
5	2024-05-31	176.4400
5	2024-06-03	178.3400
5	2024-06-04	179.3400
5	2024-06-05	181.2800
5	2024-06-06	185.0000
5	2024-06-07	184.3000
5	2024-06-10	187.0600
5	2024-06-11	187.2300
5	2024-06-12	186.8900
5	2024-06-13	183.8300
5	2024-06-14	183.6600
5	2024-06-17	184.0600
5	2024-06-18	182.8100
5	2024-06-20	186.1000
5	2024-06-21	189.0800
5	2024-06-24	185.5700
5	2024-06-25	186.3400
5	2024-06-26	193.6100
5	2024-06-27	197.8500
5	2024-06-28	193.2500
5	2024-07-01	197.2000
5	2024-07-02	200.0000
5	2024-07-03	197.5900
5	2024-07-05	200.0000
5	2024-07-08	199.2900
5	2024-07-09	199.3400
5	2024-07-10	199.7900
5	2024-07-11	195.0500
5	2024-07-12	194.4900
5	2024-07-15	192.7200
5	2024-07-16	193.0200
5	2024-07-17	187.9300
5	2024-07-18	183.7500
5	2024-07-19	183.1300
5	2024-07-22	182.5500
5	2024-07-23	186.4100
5	2024-07-24	180.8300
5	2024-07-25	179.8500
5	2024-07-26	182.5000
5	2024-07-29	183.2000
5	2024-07-30	181.7100
5	2024-07-31	186.9800
5	2024-08-01	184.0700
5	2024-08-02	167.9000
5	2024-08-05	161.0200
5	2024-08-06	161.9300
5	2024-08-07	162.7700
5	2024-08-08	165.8000
5	2024-08-09	166.9400
5	2024-08-12	166.8000
5	2024-08-13	170.2300
5	2024-08-14	170.1000
5	2024-08-15	177.5900
5	2024-08-16	177.0600
5	2024-08-19	178.2200
5	2024-08-20	178.8800
5	2024-08-21	180.1100
5	2024-08-22	176.1300
5	2024-08-23	177.0400
5	2024-08-26	175.5000
5	2024-08-27	173.1200
5	2024-08-28	170.8000
5	2024-08-29	172.1200
5	2024-08-30	178.5000
5	2024-09-03	176.2500
5	2024-09-04	173.3300
5	2024-09-05	177.8900
5	2024-09-06	171.3900
5	2024-09-09	175.4000
5	2024-09-10	179.5500
5	2024-09-11	184.5200
5	2024-09-12	187.0000
5	2024-09-13	186.4900
5	2024-09-16	184.8900
5	2024-09-17	186.8800
5	2024-09-18	186.4300
5	2024-09-19	189.8700
5	2024-09-20	191.6000
5	2024-09-23	193.8800
5	2024-09-24	193.9600
5	2024-09-25	192.5300
5	2024-09-26	191.1600
5	2024-09-27	187.9700
5	2024-09-30	186.3300
5	2024-10-01	185.1300
5	2024-10-02	184.7600
5	2024-10-03	181.9600
5	2024-10-04	186.5100
5	2024-10-07	180.8000
5	2024-10-08	182.7200
5	2024-10-09	185.1700
5	2024-10-10	186.6500
5	2024-10-11	188.8200
5	2024-10-14	187.5400
5	2024-10-15	187.6900
5	2024-10-16	186.8900
5	2024-10-17	187.5300
5	2024-10-18	188.9900
5	2024-10-21	189.0700
5	2024-10-22	189.7000
5	2024-10-23	184.7100
5	2024-10-24	186.3800
5	2024-10-25	187.8300
5	2024-10-28	188.3900
5	2024-10-29	190.8300
5	2024-10-30	192.7300
5	2024-10-31	186.4000
5	2024-11-01	197.9300
5	2024-11-04	195.7800
5	2024-11-05	199.5000
5	2024-11-06	207.0900
5	2024-11-07	210.0500
5	2024-11-08	208.1800
5	2024-11-11	206.8400
5	2024-11-12	208.9100
5	2024-11-13	214.1000
5	2024-11-14	211.4800
5	2024-11-15	202.6100
5	2024-11-18	201.7000
5	2024-11-19	204.6100
5	2024-11-20	202.8800
5	2024-11-21	198.3800
5	2024-11-22	197.1200
5	2024-11-25	201.4500
5	2024-11-26	207.8600
5	2024-11-27	205.7400
5	2024-11-29	207.8900
5	2024-12-02	210.7100
5	2024-12-03	213.4400
5	2024-12-04	218.1600
5	2024-12-05	220.5500
5	2024-12-06	227.0300
5	2024-12-09	226.0900
5	2024-12-10	225.0400
5	2024-12-11	230.2600
5	2024-12-12	228.9700
5	2024-12-13	227.4600
5	2024-12-16	232.9300
5	2024-12-17	231.1500
5	2024-12-18	220.5200
5	2024-12-19	223.2900
5	2024-12-20	224.9200
5	2024-12-23	225.0600
5	2024-12-24	229.0500
5	2024-12-26	227.0500
5	2024-12-27	223.7500
5	2024-12-30	221.3000
5	2024-12-31	219.3900
5	2025-01-02	220.2200
5	2025-01-03	224.1900
5	2025-01-06	227.6100
5	2025-01-07	222.1100
5	2025-01-08	222.1300
5	2025-01-10	218.9400
5	2025-01-13	218.4600
5	2025-01-14	217.7600
5	2025-01-15	223.3500
5	2025-01-16	220.6600
5	2025-01-17	225.9400
5	2025-01-21	230.7100
5	2025-01-22	235.0100
5	2025-01-23	235.4200
5	2025-01-24	234.8500
5	2025-01-27	235.4200
5	2025-01-28	238.1500
5	2025-01-29	237.0700
5	2025-01-30	234.6400
5	2025-01-31	237.6800
5	2025-02-03	237.4200
5	2025-02-04	242.0600
5	2025-02-05	236.1700
5	2025-02-06	238.8300
5	2025-02-07	229.1500
5	2025-02-10	233.1400
5	2025-02-11	232.7600
5	2025-02-12	228.9300
5	2025-02-13	230.3700
5	2025-02-14	228.6800
5	2025-02-18	226.6500
5	2025-02-19	226.6300
5	2025-02-20	222.8800
5	2025-02-21	216.5800
5	2025-02-24	212.7100
5	2025-02-25	212.8000
5	2025-02-26	214.3500
5	2025-02-27	208.7400
5	2025-02-28	212.2800
5	2025-03-03	205.0200
5	2025-03-04	203.8000
5	2025-03-05	208.3600
5	2025-03-06	200.7000
5	2025-03-07	199.2500
5	2025-03-10	194.5400
5	2025-03-11	196.5900
5	2025-03-12	198.8900
5	2025-03-13	193.8900
5	2025-03-14	197.9500
5	2025-03-17	195.7400
5	2025-03-18	192.8200
5	2025-03-19	195.5400
5	2025-03-20	194.9500
5	2025-03-21	196.2100
5	2025-03-24	203.2600
5	2025-03-25	205.7100
5	2025-03-26	201.1300
5	2025-03-27	201.3600
5	2025-03-28	192.7200
5	2025-03-31	190.2600
5	2025-04-01	192.1700
5	2025-04-02	196.0100
5	2025-04-03	178.4100
5	2025-04-04	171.0000
5	2025-04-07	175.2600
5	2025-04-08	170.6600
5	2025-04-09	191.1000
5	2025-04-10	181.2200
5	2025-04-11	184.8700
5	2025-04-14	182.1200
5	2025-04-15	179.5900
5	2025-04-16	174.3300
5	2025-04-17	172.6100
5	2025-04-21	167.3200
5	2025-04-22	173.1800
5	2025-04-23	180.6000
5	2025-04-24	186.5400
5	2025-04-25	188.9900
5	2025-04-28	187.7000
5	2025-04-29	187.3900
5	2025-04-30	184.4200
5	2025-05-01	190.2000
5	2025-05-02	189.9800
5	2025-05-05	186.3500
5	2025-05-06	185.0100
5	2025-05-07	188.7100
5	2025-05-08	192.0800
5	2025-05-09	193.0600
5	2025-05-12	208.6400
5	2025-05-13	211.3700
5	2025-05-14	210.2500
5	2025-05-15	205.1700
5	2025-05-16	205.5900
5	2025-05-19	206.1600
5	2025-05-20	204.0700
5	2025-05-21	201.1200
5	2025-05-22	203.1000
5	2025-05-23	200.9900
5	2025-05-27	206.0200
5	2025-05-28	204.7200
5	2025-05-29	205.7000
5	2025-05-30	205.0100
5	2025-06-02	206.6500
5	2025-06-03	205.7100
5	2025-06-04	207.2300
5	2025-06-05	207.9100
5	2025-06-06	213.5700
5	2025-06-09	216.9800
5	2025-06-10	217.6100
5	2025-06-11	213.2000
5	2025-06-12	213.2400
5	2025-06-13	212.1000
5	2025-06-16	216.1000
5	2025-06-17	214.8200
5	2025-06-18	212.5200
5	2025-06-20	209.6900
5	2025-06-23	208.4700
5	2025-06-24	212.7700
5	2025-06-25	211.9900
5	2025-06-26	217.1200
5	2025-06-27	223.3000
5	2025-06-30	219.3900
5	2025-07-01	220.4600
5	2025-07-02	219.9200
5	2025-07-03	223.4100
5	2025-07-07	223.4700
5	2025-07-08	219.3600
5	2025-07-09	222.5400
5	2025-07-10	222.2600
5	2025-07-11	225.0200
5	2025-07-14	225.6900
5	2025-07-15	226.3500
5	2025-07-16	223.1900
5	2025-07-17	223.8800
5	2025-07-18	226.1300
5	2025-07-21	229.3000
5	2025-07-22	227.4700
5	2025-07-23	228.2900
5	2025-07-24	232.2300
5	2025-07-25	231.4400
5	2025-07-28	232.7900
5	2025-07-29	231.0100
5	2025-07-30	230.1900
5	2025-07-31	234.1100
5	2025-08-01	214.7500
5	2025-08-04	211.6500
5	2025-08-05	213.7500
5	2025-08-06	222.3100
5	2025-08-07	223.1300
5	2025-08-08	222.6900
5	2025-08-11	221.3000
5	2025-08-12	221.4700
5	2025-08-13	224.5600
5	2025-08-14	230.9800
5	2025-08-15	231.0300
5	2025-08-18	231.4900
5	2025-08-19	228.0100
5	2025-08-20	223.8100
5	2025-08-21	221.9500
5	2025-08-22	228.8400
5	2025-08-25	227.9400
5	2025-08-26	228.7100
5	2025-08-27	229.1200
5	2025-08-28	231.6000
5	2025-08-29	229.0000
5	2025-09-02	225.3400
5	2025-09-03	225.9900
5	2025-09-04	235.6800
5	2025-09-05	232.3300
5	2025-09-08	235.8400
5	2025-09-09	238.2400
5	2025-09-10	230.3300
5	2025-09-11	229.9500
5	2025-09-12	228.1500
5	2025-09-15	231.4300
5	2025-09-16	234.0500
5	2025-09-17	231.6200
5	2025-09-18	231.2300
5	2025-09-19	231.4800
5	2025-09-22	227.6300
5	2025-09-23	220.7100
5	2025-09-24	220.2100
5	2025-09-25	218.1500
5	2025-09-26	219.7800
5	2025-09-29	222.1700
5	2025-09-30	219.5700
5	2025-10-01	220.6300
5	2025-10-02	222.4100
5	2025-10-03	219.5100
5	2025-10-06	220.9000
5	2025-10-07	221.7800
5	2025-10-08	225.2200
5	2025-10-09	227.7400
5	2025-10-10	216.3700
5	2025-10-13	220.0700
5	2025-10-14	216.3900
5	2025-10-15	215.5700
5	2025-10-16	214.4700
5	2025-10-17	213.0400
5	2025-10-20	216.4800
5	2025-10-21	222.0300
5	2025-10-22	217.9500
5	2025-10-23	221.0900
5	2025-10-24	224.2100
5	2025-10-27	226.9700
5	2025-10-28	229.2500
5	2025-10-29	230.3000
5	2025-10-30	222.8600
5	2025-10-31	244.2200
5	2025-11-03	254.0000
5	2025-11-04	249.3200
5	2025-11-05	250.2000
5	2025-11-06	243.0400
5	2025-11-07	244.4100
5	2025-11-10	248.4000
5	2025-11-11	249.1000
5	2025-11-12	244.2000
5	2025-11-13	237.5800
5	2025-11-14	234.6900
5	2025-11-17	232.8700
5	2025-11-18	222.5500
5	2025-11-19	222.6900
5	2025-11-20	217.1400
5	2025-11-21	220.6900
5	2025-11-24	226.2800
5	2025-11-25	229.6700
5	2025-11-26	229.1600
5	2025-11-28	233.2200
5	2025-12-01	233.8800
5	2025-12-02	234.4200
5	2025-12-03	232.3800
5	2025-12-04	229.1100
5	2025-12-05	229.5300
5	2025-12-08	226.8900
5	2025-12-09	227.9200
5	2025-12-10	231.7800
5	2025-12-11	230.2800
5	2025-12-12	226.1900
5	2025-12-15	222.5400
5	2025-12-16	222.5600
5	2025-12-17	221.2700
5	2025-12-18	226.7600
5	2025-12-19	227.3500
5	2025-12-22	228.4300
5	2025-12-23	232.1400
5	2025-12-24	232.3800
5	2025-12-26	232.5200
5	2025-12-29	232.0700
5	2025-12-30	232.5300
5	2025-12-31	230.8200
5	2026-01-02	226.5000
5	2026-01-05	233.0600
5	2026-01-06	240.9300
5	2026-01-07	241.5600
5	2026-01-08	246.2900
5	2026-01-09	247.3800
5	2026-01-12	246.4700
5	2026-01-13	242.6000
5	2026-01-14	236.6500
5	2026-01-15	238.1800
5	2026-01-16	239.1200
5	2026-01-20	231.0000
5	2026-01-21	231.3100
5	2026-01-22	234.3400
5	2026-01-23	239.1600
5	2026-01-26	238.4200
5	2026-01-27	244.6800
5	2026-01-28	243.0100
5	2026-01-29	241.7300
5	2026-01-30	239.3000
5	2026-02-02	242.9600
5	2026-02-03	238.6200
5	2026-02-04	232.9900
5	2026-02-05	222.6900
5	2026-02-06	210.3200
5	2026-02-09	208.7200
5	2026-02-10	206.9600
5	2026-02-11	204.0800
5	2026-02-12	199.6000
5	2026-02-13	198.7900
5	2026-02-17	201.1500
5	2026-02-18	204.7900
5	2026-02-19	204.8600
5	2026-02-20	210.1100
5	2026-02-23	205.2700
5	2026-02-24	208.5600
5	2026-02-25	210.6400
5	2026-02-26	207.9200
5	2026-02-27	210.0000
5	2026-03-02	208.3900
5	2026-03-03	208.7300
5	2026-03-04	216.8200
5	2026-03-05	218.9400
5	2026-03-06	213.2100
5	2026-03-09	213.4900
5	2026-03-10	214.3300
5	2026-03-11	212.6500
5	2026-03-12	209.5300
5	2026-03-13	207.6700
5	2026-03-16	211.7400
5	2026-03-17	215.2000
5	2026-03-18	209.8700
5	2026-03-19	208.7600
5	2026-03-20	205.3700
5	2026-03-23	210.1400
5	2026-03-24	207.2400
5	2026-03-25	211.7100
5	2026-03-26	207.5400
5	2026-03-27	199.3400
5	2026-03-30	200.9500
5	2026-03-31	208.2700
5	2026-04-01	210.5700
5	2026-04-02	209.7700
5	2026-04-06	212.7900
5	2026-04-07	213.7700
5	2026-04-08	221.2500
5	2026-04-09	233.6500
5	2026-04-10	238.3800
5	2026-04-13	239.8900
5	2026-04-14	249.0200
5	2026-04-15	248.5000
5	2026-04-16	249.7000
5	2026-04-17	250.5600
5	2026-04-20	248.2800
5	2026-04-21	249.9100
5	2026-04-22	255.3600
5	2026-04-23	255.0800
5	2026-04-24	263.9900
5	2026-04-27	261.1200
5	2026-04-28	259.7000
5	2026-04-29	263.0400
5	2026-04-30	265.0600
5	2026-05-01	268.2600
5	2026-05-04	272.0500
5	2026-05-05	273.5500
5	2026-05-06	274.9900
5	2026-05-07	271.1700
5	2026-05-08	272.6800
5	2026-05-11	268.9900
5	2026-05-12	265.8200
5	2026-05-13	270.1300
5	2026-05-14	267.2200
5	2026-05-15	264.1400
5	2026-05-18	264.8600
5	2026-05-19	259.3400
5	2026-05-20	265.0100
5	2026-05-21	268.4600
5	2026-05-22	266.3200
5	2026-05-26	265.2900
5	2026-05-27	271.8500
5	2026-05-28	274.0000
5	2026-05-29	270.6400
5	2026-06-01	261.2600
5	2026-06-02	256.5200
5	2026-06-03	250.0200
5	2026-06-04	253.7900
5	2026-06-05	246.0300
5	2026-06-08	245.2200
5	2026-06-09	244.1900
5	2026-06-10	238.0000
5	2026-06-11	241.5100
5	2026-06-12	238.5500
5	2026-06-15	246.0200
5	2026-06-16	246.0000
5	2026-06-17	237.5000
5	2026-06-18	244.3900
5	2026-06-22	232.7900
5	2026-06-23	234.1100
5	2026-06-24	234.2700
5	2026-06-25	227.0100
5	2026-06-26	232.6900
5	2026-06-29	240.1400
5	2026-06-30	238.3400
5	2026-07-01	241.7000
5	2026-07-02	242.6700
5	2026-07-06	244.1600
5	2026-07-07	245.9800
5	2026-07-08	243.6200
5	2026-07-09	247.0400
5	2026-07-10	245.3400
5	2026-07-13	247.3100
5	2026-07-14	247.4900
5	2026-07-15	254.9600
5	2026-07-16	249.8900
5	2026-07-17	247.2300
5	2026-07-20	249.9900
5	2026-07-21	247.5500
5	2026-07-22	244.8500
5	2026-07-23	233.6600
5	2026-07-24	232.1100
5	2026-07-27	231.3900
5	2026-07-28	230.8600
5	2026-07-29	226.6500
5	2026-07-30	235.5000
5	2026-07-31	271.5800
5	2026-08-03	284.0200
5	2026-08-04	277.4200
5	2026-08-05	272.6500
5	2026-08-06	272.2600
5	2026-08-07	274.4800
5	2026-08-10	278.0900
5	2026-08-11	272.2700
5	2026-08-12	267.2800
5	2026-08-13	265.1300
5	2026-08-14	262.6500
5	2026-08-17	261.3100
5	2026-08-18	259.4500
5	2026-08-19	265.8400
5	2026-08-20	260.1100
5	2026-08-21	258.6300
5	2026-08-24	262.0700
5	2026-08-25	261.0600
5	2026-08-26	260.2800
5	2026-08-27	256.2600
5	2026-08-28	266.4300
5	2026-08-31	259.7700
5	2026-09-01	254.9200
5	2026-09-02	254.9800
5	2026-09-03	258.9000
5	2026-09-04	258.5100
5	2026-09-08	256.9700
5	2026-09-09	252.4000
5	2026-09-10	251.8900
5	2026-09-11	256.7800
5	2026-09-14	253.5400
5	2026-09-15	248.4200
5	2026-09-16	245.9600
5	2026-09-17	251.1900
5	2026-09-18	253.7100
5	2026-09-21	258.4500
5	2026-09-22	254.9800
5	2026-09-23	249.2700
5	2026-09-24	249.3800
5	2026-09-25	249.6700
5	2026-09-28	246.1500
5	2026-09-29	246.6700
5	2026-09-30	249.1500
5	2026-10-01	248.2300
5	2026-10-02	251.5200
5	2026-10-05	251.4000
5	2026-10-06	256.2900
5	2026-10-07	259.9200
5	2026-10-08	254.0600
5	2026-10-09	262.4300
5	2026-10-12	259.5300
5	2026-10-13	258.5800
5	2026-10-14	254.0800
5	2026-10-15	254.7600
5	2026-10-16	250.0000
5	2026-10-19	262.4500
5	2026-10-20	262.6300
5	2026-10-21	262.3700
5	2026-10-22	250.3800
5	2026-10-23	248.0000
5	2026-10-26	249.0900
5	2026-10-27	253.1000
5	2026-10-28	254.6000
5	2026-10-29	243.7900
5	2026-10-30	240.3500
5	2026-11-02	245.6300
5	2026-11-03	250.6900
5	2026-11-04	266.0300
5	2026-11-05	260.2100
5	2026-11-06	259.3000
5	2026-11-09	266.9300
5	2026-11-10	270.8700
5	2026-11-11	266.1700
5	2026-11-12	267.4400
5	2026-11-13	266.6600
5	2026-11-16	257.7500
6	2024-01-02	138.1700
6	2024-01-03	138.9200
6	2024-01-04	136.3900
6	2024-01-05	135.7300
6	2024-01-08	138.8400
6	2024-01-09	140.9500
6	2024-01-10	142.2800
6	2024-01-11	142.0800
6	2024-01-12	142.6500
6	2024-01-16	142.4900
6	2024-01-17	141.4700
6	2024-01-18	143.4800
6	2024-01-19	146.3800
6	2024-01-22	145.9900
6	2024-01-23	147.0400
6	2024-01-24	148.7000
6	2024-01-25	151.8700
6	2024-01-26	152.1900
6	2024-01-29	153.5100
6	2024-01-30	151.4600
6	2024-01-31	140.1000
6	2024-02-01	141.1600
6	2024-02-02	142.3800
6	2024-02-05	143.6800
6	2024-02-06	144.1000
6	2024-02-07	145.5400
6	2024-02-08	145.9100
6	2024-02-09	149.0000
6	2024-02-12	147.5300
6	2024-02-13	145.1400
6	2024-02-14	145.9400
6	2024-02-15	142.7700
6	2024-02-16	140.5200
6	2024-02-20	141.1200
6	2024-02-21	142.5500
6	2024-02-22	144.0900
6	2024-02-23	143.9600
6	2024-02-26	137.5700
6	2024-02-27	138.8800
6	2024-02-28	136.3800
6	2024-02-29	138.4600
6	2024-03-01	137.1400
6	2024-03-04	133.3500
6	2024-03-05	132.6700
6	2024-03-06	131.4000
6	2024-03-07	134.3800
6	2024-03-08	135.4100
6	2024-03-11	137.6700
6	2024-03-12	138.5000
6	2024-03-13	139.7900
6	2024-03-14	143.1000
6	2024-03-15	141.1800
6	2024-03-18	147.6800
6	2024-03-19	147.0300
6	2024-03-20	148.7400
6	2024-03-21	147.6000
6	2024-03-22	150.7700
6	2024-03-25	150.0700
6	2024-03-26	150.6700
6	2024-03-27	150.8700
6	2024-03-28	150.9300
6	2024-04-01	155.4900
6	2024-04-02	154.5600
6	2024-04-03	154.9200
6	2024-04-04	150.5300
6	2024-04-05	152.5000
6	2024-04-08	154.8500
6	2024-04-09	156.6000
6	2024-04-10	156.1400
6	2024-04-11	159.4100
6	2024-04-12	157.7300
6	2024-04-15	154.8600
6	2024-04-16	154.4000
6	2024-04-17	155.4700
6	2024-04-18	156.0100
6	2024-04-19	154.0900
6	2024-04-22	156.2800
6	2024-04-23	158.2600
6	2024-04-24	159.1300
6	2024-04-25	156.0000
6	2024-04-26	171.9500
6	2024-04-29	166.1500
6	2024-04-30	162.7800
6	2024-05-01	163.8600
6	2024-05-02	166.6200
6	2024-05-03	167.2400
6	2024-05-06	168.1000
6	2024-05-07	171.2500
6	2024-05-08	169.3800
6	2024-05-09	169.9600
6	2024-05-10	168.6500
6	2024-05-13	169.1400
6	2024-05-14	170.3400
6	2024-05-15	172.5100
6	2024-05-16	174.1800
6	2024-05-17	176.0600
6	2024-05-20	176.9200
6	2024-05-21	177.8500
6	2024-05-22	176.3800
6	2024-05-23	173.5500
6	2024-05-24	174.9900
6	2024-05-28	176.4000
6	2024-05-29	175.9000
6	2024-05-30	172.1100
6	2024-05-31	172.5000
6	2024-06-03	173.1700
6	2024-06-04	173.7900
6	2024-06-05	175.4100
6	2024-06-06	176.7300
6	2024-06-07	174.4600
6	2024-06-10	175.0100
6	2024-06-11	176.6200
6	2024-06-12	177.7900
6	2024-06-13	175.1600
6	2024-06-14	176.7900
6	2024-06-17	177.2400
6	2024-06-18	175.0900
6	2024-06-20	176.3000
6	2024-06-21	179.6300
6	2024-06-24	179.2200
6	2024-06-25	184.0300
6	2024-06-26	183.8800
6	2024-06-27	185.4100
6	2024-06-28	182.1500
6	2024-07-01	182.9900
6	2024-07-02	185.2400
6	2024-07-03	185.8200
6	2024-07-05	190.6000
6	2024-07-08	189.0300
6	2024-07-09	188.9800
6	2024-07-10	191.1800
6	2024-07-11	185.5700
6	2024-07-12	185.0700
6	2024-07-15	186.5300
6	2024-07-16	183.9200
6	2024-07-17	181.0200
6	2024-07-18	177.6900
6	2024-07-19	177.6600
6	2024-07-22	181.6700
6	2024-07-23	181.7900
6	2024-07-24	172.6300
6	2024-07-25	167.2800
6	2024-07-26	167.0000
6	2024-07-29	169.5300
6	2024-07-30	170.2900
6	2024-07-31	171.5400
6	2024-08-01	170.7600
6	2024-08-02	166.6600
6	2024-08-05	159.2500
6	2024-08-06	158.2900
6	2024-08-07	158.9400
6	2024-08-08	162.0300
6	2024-08-09	163.6700
6	2024-08-12	162.2900
6	2024-08-13	164.1600
6	2024-08-14	160.3700
6	2024-08-15	161.3000
6	2024-08-16	162.9600
6	2024-08-19	166.6700
6	2024-08-20	167.1800
6	2024-08-21	165.8500
6	2024-08-22	163.8000
6	2024-08-23	165.6200
6	2024-08-26	166.1600
6	2024-08-27	164.6800
6	2024-08-28	162.8500
6	2024-08-29	161.7800
6	2024-08-30	163.3800
6	2024-09-03	157.3600
6	2024-09-04	156.4500
6	2024-09-05	157.2400
6	2024-09-06	150.9200
6	2024-09-09	148.7100
6	2024-09-10	148.6600
6	2024-09-11	151.1600
6	2024-09-12	154.6900
6	2024-09-13	157.4600
6	2024-09-16	158.0600
6	2024-09-17	159.3200
6	2024-09-18	159.8100
6	2024-09-19	162.1400
6	2024-09-20	163.5900
6	2024-09-23	161.8500
6	2024-09-24	162.2900
6	2024-09-25	161.4900
6	2024-09-26	162.7300
6	2024-09-27	163.9500
6	2024-09-30	165.8500
6	2024-10-01	166.9900
6	2024-10-02	165.8600
6	2024-10-03	165.8600
6	2024-10-04	167.0600
6	2024-10-07	162.9800
6	2024-10-08	164.3800
6	2024-10-09	161.8600
6	2024-10-10	162.0800
6	2024-10-11	163.2400
6	2024-10-14	164.9600
6	2024-10-15	165.4600
6	2024-10-16	165.1600
6	2024-10-17	162.9300
6	2024-10-18	163.4200
6	2024-10-21	164.0700
6	2024-10-22	165.1400
6	2024-10-23	162.7800
6	2024-10-24	162.7200
6	2024-10-25	165.2700
6	2024-10-28	166.7200
6	2024-10-29	169.6800
6	2024-10-30	174.4600
6	2024-10-31	171.1100
6	2024-11-01	171.2900
6	2024-11-04	169.2400
6	2024-11-05	169.7400
6	2024-11-06	176.5100
6	2024-11-07	180.7500
6	2024-11-08	178.3500
6	2024-11-11	180.3500
6	2024-11-12	181.6200
6	2024-11-13	178.8800
6	2024-11-14	175.5800
6	2024-11-15	172.4900
6	2024-11-18	175.3000
6	2024-11-19	178.1200
6	2024-11-20	175.9800
6	2024-11-21	167.6300
6	2024-11-22	164.7600
6	2024-11-25	167.6500
6	2024-11-26	169.1200
6	2024-11-27	169.2300
6	2024-11-29	168.9500
6	2024-12-02	171.4900
6	2024-12-03	171.3400
6	2024-12-04	174.3700
6	2024-12-05	172.6400
6	2024-12-06	174.7100
6	2024-12-09	175.3700
6	2024-12-10	185.1700
6	2024-12-11	195.4000
6	2024-12-12	191.9600
6	2024-12-13	189.8200
6	2024-12-16	196.6600
6	2024-12-17	195.4200
6	2024-12-18	188.4000
6	2024-12-19	188.5100
6	2024-12-20	191.4100
6	2024-12-23	194.6300
6	2024-12-24	196.1100
6	2024-12-26	195.6000
6	2024-12-27	192.7600
6	2024-12-30	191.2400
6	2024-12-31	189.3000
6	2025-01-02	189.4300
6	2025-01-03	191.7900
6	2025-01-06	196.8700
6	2025-01-07	195.4900
6	2025-01-08	193.9500
6	2025-01-10	192.0400
6	2025-01-13	191.0100
6	2025-01-14	189.6600
6	2025-01-15	195.5500
6	2025-01-16	192.9100
6	2025-01-17	196.0000
6	2025-01-21	198.0500
6	2025-01-22	198.3700
6	2025-01-23	197.9800
6	2025-01-24	200.2100
6	2025-01-27	191.8100
6	2025-01-28	195.3000
6	2025-01-29	195.4100
6	2025-01-30	200.8700
6	2025-01-31	204.0200
6	2025-02-03	201.2300
6	2025-02-04	206.3800
6	2025-02-05	191.3300
6	2025-02-06	191.6000
6	2025-02-07	185.3400
6	2025-02-10	186.4700
6	2025-02-11	185.3200
6	2025-02-12	183.6100
6	2025-02-13	186.1400
6	2025-02-14	185.2300
6	2025-02-18	183.7700
6	2025-02-19	185.2700
6	2025-02-20	184.5600
6	2025-02-21	179.6600
6	2025-02-24	179.2500
6	2025-02-25	175.4200
6	2025-02-26	172.7300
6	2025-02-27	168.5000
6	2025-02-28	170.2800
6	2025-03-03	167.0100
6	2025-03-04	170.9200
6	2025-03-05	173.0200
6	2025-03-06	172.3500
6	2025-03-07	173.8600
6	2025-03-10	165.8700
6	2025-03-11	164.0400
6	2025-03-12	167.1100
6	2025-03-13	162.7600
6	2025-03-14	165.4900
6	2025-03-17	164.2900
6	2025-03-18	160.6700
6	2025-03-19	163.8900
6	2025-03-20	162.8000
6	2025-03-21	163.9900
6	2025-03-24	167.6800
6	2025-03-25	170.5600
6	2025-03-26	165.0600
6	2025-03-27	162.2400
6	2025-03-28	154.3300
6	2025-03-31	154.6400
6	2025-04-01	157.0700
6	2025-04-02	157.0400
6	2025-04-03	150.7200
6	2025-04-04	145.6000
6	2025-04-07	146.7500
6	2025-04-08	144.7000
6	2025-04-09	158.7100
6	2025-04-10	152.8200
6	2025-04-11	157.1400
6	2025-04-14	159.0700
6	2025-04-15	156.3100
6	2025-04-16	153.3300
6	2025-04-17	151.1600
6	2025-04-21	147.6700
6	2025-04-22	151.4700
6	2025-04-23	155.3500
6	2025-04-24	159.2800
6	2025-04-25	161.9600
6	2025-04-28	160.6100
6	2025-04-29	160.1600
6	2025-04-30	158.8000
6	2025-05-01	161.3000
6	2025-05-02	164.0300
6	2025-05-05	164.2100
6	2025-05-06	163.2300
6	2025-05-07	151.3800
6	2025-05-08	154.2800
6	2025-05-09	152.7500
6	2025-05-12	158.4600
6	2025-05-13	159.5300
6	2025-05-14	165.3700
6	2025-05-15	163.9600
6	2025-05-16	166.1900
6	2025-05-19	166.5400
6	2025-05-20	163.9800
6	2025-05-21	168.5600
6	2025-05-22	170.8700
6	2025-05-23	168.4700
6	2025-05-27	172.9000
6	2025-05-28	172.3600
6	2025-05-29	171.8600
6	2025-05-30	171.7400
6	2025-06-02	169.0300
6	2025-06-03	166.1800
6	2025-06-04	168.0500
6	2025-06-05	168.2100
6	2025-06-06	173.6800
6	2025-06-09	176.0900
6	2025-06-10	178.6000
6	2025-06-11	177.3500
6	2025-06-12	175.7000
6	2025-06-13	174.6700
6	2025-06-16	176.7700
6	2025-06-17	175.9500
6	2025-06-18	173.3200
6	2025-06-20	166.6400
6	2025-06-23	165.1900
6	2025-06-24	166.7700
6	2025-06-25	170.6800
6	2025-06-26	173.5400
6	2025-06-27	178.5300
6	2025-06-30	176.2300
6	2025-07-01	175.8400
6	2025-07-02	178.6400
6	2025-07-03	179.5300
6	2025-07-07	176.7900
6	2025-07-08	174.3600
6	2025-07-09	176.6200
6	2025-07-10	177.6200
6	2025-07-11	180.1900
6	2025-07-14	181.5600
6	2025-07-15	182.0000
6	2025-07-16	182.9700
6	2025-07-17	183.5800
6	2025-07-18	185.0600
6	2025-07-21	190.1000
6	2025-07-22	191.3400
6	2025-07-23	190.2300
6	2025-07-24	192.1700
6	2025-07-25	193.1800
6	2025-07-28	192.5800
6	2025-07-29	195.7500
6	2025-07-30	196.5300
6	2025-07-31	191.9000
6	2025-08-01	189.1300
6	2025-08-04	195.0400
6	2025-08-05	194.6700
6	2025-08-06	196.0900
6	2025-08-07	196.5200
6	2025-08-08	201.4200
6	2025-08-11	201.0000
6	2025-08-12	203.3400
6	2025-08-13	201.9600
6	2025-08-14	202.9400
6	2025-08-15	203.9000
6	2025-08-18	203.5000
6	2025-08-19	201.5700
6	2025-08-20	199.3200
6	2025-08-21	199.7500
6	2025-08-22	206.0900
6	2025-08-25	208.4900
6	2025-08-26	207.1400
6	2025-08-27	207.4800
6	2025-08-28	211.6400
6	2025-08-29	212.9100
6	2025-09-02	211.3500
6	2025-09-03	230.6600
6	2025-09-04	232.3000
6	2025-09-05	235.0000
6	2025-09-08	234.0400
6	2025-09-09	239.6300
6	2025-09-10	239.1700
6	2025-09-11	240.3700
6	2025-09-12	240.8000
6	2025-09-15	251.6100
6	2025-09-16	251.1600
6	2025-09-17	249.5300
6	2025-09-18	252.0300
6	2025-09-19	254.7200
6	2025-09-22	252.5300
6	2025-09-23	251.6600
6	2025-09-24	247.1400
6	2025-09-25	245.7900
6	2025-09-26	246.5400
6	2025-09-29	244.0500
6	2025-09-30	243.1000
6	2025-10-01	244.9000
6	2025-10-02	245.6900
6	2025-10-03	245.3500
6	2025-10-06	250.4300
6	2025-10-07	245.7600
6	2025-10-08	244.6200
6	2025-10-09	241.5300
6	2025-10-10	236.5700
6	2025-10-13	244.1500
6	2025-10-14	245.4500
6	2025-10-15	251.0300
6	2025-10-16	251.4600
6	2025-10-17	253.3000
6	2025-10-20	256.5500
6	2025-10-21	250.4600
6	2025-10-22	251.6900
6	2025-10-23	253.0800
6	2025-10-24	259.9200
6	2025-10-27	269.2700
6	2025-10-28	267.4700
6	2025-10-29	274.5700
6	2025-10-30	281.4800
6	2025-10-31	281.1900
6	2025-11-03	283.7200
6	2025-11-04	277.5400
6	2025-11-05	284.3100
6	2025-11-06	284.7500
6	2025-11-07	278.8300
6	2025-11-10	290.1000
6	2025-11-11	291.3100
6	2025-11-12	286.7100
6	2025-11-13	278.5700
6	2025-11-14	276.4100
6	2025-11-17	285.0200
6	2025-11-18	284.2800
6	2025-11-19	292.8100
6	2025-11-20	289.4500
6	2025-11-21	299.6600
6	2025-11-24	318.5800
6	2025-11-25	323.4400
6	2025-11-26	319.9500
6	2025-11-28	320.1800
6	2025-12-01	314.8900
6	2025-12-02	315.8100
6	2025-12-03	319.6300
6	2025-12-04	317.6200
6	2025-12-05	321.2700
6	2025-12-08	313.7200
6	2025-12-09	317.0800
6	2025-12-10	320.2100
6	2025-12-11	312.4300
6	2025-12-12	309.2900
6	2025-12-15	308.2200
6	2025-12-16	306.5700
6	2025-12-17	296.7200
6	2025-12-18	302.4600
6	2025-12-19	307.1600
6	2025-12-22	309.7800
6	2025-12-23	314.3500
6	2025-12-24	314.0900
6	2025-12-26	313.5100
6	2025-12-29	313.5600
6	2025-12-30	313.8500
6	2025-12-31	313.0000
6	2026-01-02	315.1500
6	2026-01-05	316.5400
6	2026-01-06	314.3400
6	2026-01-07	321.9800
6	2026-01-08	325.4400
6	2026-01-09	328.5700
6	2026-01-12	331.8600
6	2026-01-13	335.9700
6	2026-01-14	335.8400
6	2026-01-15	332.7800
6	2026-01-16	330.0000
6	2026-01-20	322.0000
6	2026-01-21	328.3800
6	2026-01-22	330.5400
6	2026-01-23	327.9300
6	2026-01-26	333.2600
6	2026-01-27	334.5500
6	2026-01-28	336.0100
6	2026-01-29	338.2500
6	2026-01-30	338.0000
6	2026-02-02	343.6900
6	2026-02-03	339.7100
6	2026-02-04	333.0400
6	2026-02-05	331.2500
6	2026-02-06	322.8600
6	2026-02-09	324.3200
6	2026-02-10	318.5800
6	2026-02-11	310.9600
6	2026-02-12	309.0000
6	2026-02-13	305.7200
6	2026-02-17	302.0200
6	2026-02-18	303.3300
6	2026-02-19	302.8500
6	2026-02-20	314.9800
6	2026-02-23	311.4900
6	2026-02-24	310.9000
6	2026-02-25	312.9000
6	2026-02-26	307.3800
6	2026-02-27	311.7600
6	2026-03-02	306.5200
6	2026-03-03	303.5800
6	2026-03-04	303.1300
6	2026-03-05	300.8800
6	2026-03-06	298.5200
6	2026-03-09	306.3600
6	2026-03-10	307.0400
6	2026-03-11	308.7000
6	2026-03-12	303.5500
6	2026-03-13	302.2800
6	2026-03-16	305.5600
6	2026-03-17	310.9200
6	2026-03-18	307.6900
6	2026-03-19	307.1300
6	2026-03-20	301.0000
6	2026-03-23	302.0600
6	2026-03-24	290.4400
6	2026-03-25	290.9300
6	2026-03-26	280.9200
6	2026-03-27	274.3400
6	2026-03-30	273.5000
6	2026-03-31	287.5600
6	2026-04-01	297.3900
6	2026-04-02	295.7700
6	2026-04-06	299.9900
6	2026-04-07	305.4600
6	2026-04-08	317.3200
6	2026-04-09	318.4900
6	2026-04-10	317.2400
6	2026-04-13	321.3100
6	2026-04-14	332.9100
6	2026-04-15	337.1200
6	2026-04-16	336.0200
6	2026-04-17	341.6800
6	2026-04-20	337.4200
6	2026-04-21	332.2900
6	2026-04-22	339.3200
6	2026-04-23	338.8900
6	2026-04-24	344.4000
6	2026-04-27	350.3400
6	2026-04-28	349.7800
6	2026-04-29	349.9400
6	2026-04-30	384.8000
6	2026-05-01	385.6900
6	2026-05-04	383.2500
6	2026-05-05	388.4300
6	2026-05-06	398.0400
6	2026-05-07	397.9900
6	2026-05-08	400.8000
6	2026-05-11	388.6400
6	2026-05-12	387.3500
6	2026-05-13	402.6200
6	2026-05-14	401.0700
6	2026-05-15	396.7800
6	2026-05-18	396.9400
6	2026-05-19	387.6600
6	2026-05-20	388.9100
6	2026-05-21	387.6600
6	2026-05-22	382.9700
6	2026-05-26	388.8800
6	2026-05-27	388.8300
6	2026-05-28	390.1300
6	2026-05-29	380.3400
6	2026-06-01	376.3700
6	2026-06-02	361.8500
6	2026-06-03	358.9900
6	2026-06-04	372.1900
6	2026-06-05	368.5300
6	2026-06-08	363.3100
6	2026-06-09	364.2600
6	2026-06-10	356.3800
6	2026-06-11	357.7700
6	2026-06-12	359.6800
6	2026-06-15	369.3500
6	2026-06-16	373.2500
6	2026-06-17	363.7900
6	2026-06-18	368.0300
6	2026-06-22	349.6800
6	2026-06-23	346.1300
6	2026-06-24	345.2900
6	2026-06-25	343.7100
6	2026-06-26	337.3900
6	2026-06-29	353.6500
6	2026-06-30	357.3700
6	2026-07-01	361.2100
6	2026-07-02	359.9100
6	2026-07-06	366.4600
6	2026-07-07	367.0300
6	2026-07-08	361.9200
6	2026-07-09	358.8900
6	2026-07-10	357.1800
6	2026-07-13	352.5100
6	2026-07-14	359.5100
6	2026-07-15	370.9200
6	2026-07-16	354.4600
6	2026-07-17	346.7700
6	2026-07-20	351.9900
6	2026-07-21	347.1500
6	2026-07-22	342.0900
6	2026-07-23	317.6900
6	2026-07-24	319.7400
6	2026-07-27	326.5600
6	2026-07-28	333.7100
6	2026-07-29	336.7100
6	2026-07-30	333.6600
6	2026-07-31	356.1300
6	2026-08-03	373.5100
6	2026-08-04	377.6500
6	2026-08-05	362.4300
6	2026-08-06	357.7500
6	2026-08-07	354.3000
6	2026-08-10	357.5200
6	2026-08-11	343.8000
6	2026-08-12	343.5400
6	2026-08-13	346.3600
6	2026-08-14	345.9000
6	2026-08-17	344.0000
6	2026-08-18	344.2000
6	2026-08-19	344.7200
6	2026-08-20	340.6700
6	2026-08-21	344.8200
6	2026-08-24	348.0600
6	2026-08-25	346.9600
6	2026-08-26	342.0000
6	2026-08-27	340.6500
6	2026-08-28	346.5900
6	2026-08-31	339.3500
6	2026-09-01	335.0200
6	2026-09-02	337.1200
6	2026-09-03	342.4800
6	2026-09-04	338.4600
6	2026-09-08	338.3600
6	2026-09-09	330.6500
6	2026-09-10	332.6000
6	2026-09-11	338.5000
6	2026-09-14	349.3900
6	2026-09-15	344.9800
6	2026-09-16	342.8700
6	2026-09-17	347.3300
6	2026-09-18	349.5400
6	2026-09-21	354.9700
6	2026-09-22	351.1600
6	2026-09-23	337.8300
6	2026-09-24	342.3600
6	2026-09-25	343.9200
6	2026-09-28	342.7500
6	2026-09-29	340.9200
6	2026-09-30	344.0800
6	2026-10-01	338.2400
6	2026-10-02	343.5000
6	2026-10-05	346.4700
6	2026-10-06	347.6800
6	2026-10-07	350.5000
6	2026-10-08	348.2900
6	2026-10-09	351.6600
6	2026-10-12	352.7200
6	2026-10-13	353.7800
6	2026-10-14	347.6400
6	2026-10-15	349.2200
6	2026-10-16	340.5900
6	2026-10-19	344.1800
6	2026-10-20	340.2800
6	2026-10-21	334.7600
6	2026-10-22	324.2200
6	2026-10-23	320.2100
6	2026-10-26	316.8000
6	2026-10-27	320.5800
6	2026-10-28	324.8900
6	2026-10-29	283.8200
6	2026-10-30	279.8400
6	2026-11-02	278.9900
6	2026-11-03	280.0300
6	2026-11-04	288.9300
6	2026-11-05	282.5700
6	2026-11-06	284.7800
6	2026-11-09	288.1500
6	2026-11-10	287.3800
6	2026-11-11	293.4500
6	2026-11-12	298.7000
6	2026-11-13	295.7700
6	2026-11-16	283.7200
7	2024-01-02	248.4200
7	2024-01-03	238.4500
7	2024-01-04	237.9300
7	2024-01-05	237.4900
7	2024-01-08	240.4500
7	2024-01-09	234.9600
7	2024-01-10	233.9400
7	2024-01-11	227.2200
7	2024-01-12	218.8900
7	2024-01-16	219.9100
7	2024-01-17	215.5500
7	2024-01-18	211.8800
7	2024-01-19	212.1900
7	2024-01-22	208.8000
7	2024-01-23	209.1400
7	2024-01-24	207.8300
7	2024-01-25	182.6300
7	2024-01-26	183.2500
7	2024-01-29	190.9300
7	2024-01-30	191.5900
7	2024-01-31	187.2900
7	2024-02-01	188.8600
7	2024-02-02	187.9100
7	2024-02-05	181.0600
7	2024-02-06	185.1000
7	2024-02-07	187.5800
7	2024-02-08	189.5600
7	2024-02-09	193.5700
7	2024-02-12	188.1300
7	2024-02-13	184.0200
7	2024-02-14	188.7100
7	2024-02-15	200.4500
7	2024-02-16	199.9500
7	2024-02-20	193.7600
7	2024-02-21	194.7700
7	2024-02-22	197.4100
7	2024-02-23	191.9700
7	2024-02-26	199.4000
7	2024-02-27	199.7300
7	2024-02-28	202.0400
7	2024-02-29	201.8800
7	2024-03-01	202.6400
7	2024-03-04	188.1400
7	2024-03-05	180.7400
7	2024-03-06	176.5400
7	2024-03-07	178.6500
7	2024-03-08	175.3400
7	2024-03-11	177.7700
7	2024-03-12	177.5400
7	2024-03-13	169.4800
7	2024-03-14	162.5000
7	2024-03-15	163.5700
7	2024-03-18	173.8000
7	2024-03-19	171.3200
7	2024-03-20	175.6600
7	2024-03-21	172.8200
7	2024-03-22	170.8300
7	2024-03-25	172.6300
7	2024-03-26	177.6700
7	2024-03-27	179.8300
7	2024-03-28	175.7900
7	2024-04-01	175.2200
7	2024-04-02	166.6300
7	2024-04-03	168.3800
7	2024-04-04	171.1100
7	2024-04-05	164.9000
7	2024-04-08	172.9800
7	2024-04-09	176.8800
7	2024-04-10	171.7600
7	2024-04-11	174.6000
7	2024-04-12	171.0500
7	2024-04-15	161.4800
7	2024-04-16	157.1100
7	2024-04-17	155.4500
7	2024-04-18	149.9300
7	2024-04-19	147.0500
7	2024-04-22	142.0500
7	2024-04-23	144.6800
7	2024-04-24	162.1300
7	2024-04-25	170.1800
7	2024-04-26	168.2900
7	2024-04-29	194.0500
7	2024-04-30	183.2800
7	2024-05-01	179.9900
7	2024-05-02	180.0100
7	2024-05-03	181.1900
7	2024-05-06	184.7600
7	2024-05-07	177.8100
7	2024-05-08	174.7200
7	2024-05-09	171.9700
7	2024-05-10	168.4700
7	2024-05-13	171.8900
7	2024-05-14	177.5500
7	2024-05-15	173.9900
7	2024-05-16	174.8400
7	2024-05-17	177.4600
7	2024-05-20	174.9500
7	2024-05-21	186.6000
7	2024-05-22	180.1100
7	2024-05-23	173.7400
7	2024-05-24	179.2400
7	2024-05-28	176.7500
7	2024-05-29	176.1900
7	2024-05-30	178.7900
7	2024-05-31	178.0800
7	2024-06-03	176.2900
7	2024-06-04	174.7700
7	2024-06-05	175.0000
7	2024-06-06	177.9400
7	2024-06-07	177.4800
7	2024-06-10	173.7900
7	2024-06-11	170.6600
7	2024-06-12	177.2900
7	2024-06-13	182.4700
7	2024-06-14	178.0100
7	2024-06-17	187.4400
7	2024-06-18	184.8600
7	2024-06-20	181.5700
7	2024-06-21	183.0100
7	2024-06-24	182.5800
7	2024-06-25	187.3500
7	2024-06-26	196.3700
7	2024-06-27	197.4200
7	2024-06-28	197.8800
7	2024-07-01	209.8600
7	2024-07-02	231.2600
7	2024-07-03	246.3900
7	2024-07-05	251.5200
7	2024-07-08	252.9400
7	2024-07-09	262.3300
7	2024-07-10	263.2600
7	2024-07-11	241.0300
7	2024-07-12	248.2300
7	2024-07-15	252.6400
7	2024-07-16	256.5600
7	2024-07-17	248.5000
7	2024-07-18	249.2300
7	2024-07-19	239.2000
7	2024-07-22	251.5100
7	2024-07-23	246.3800
7	2024-07-24	215.9900
7	2024-07-25	220.2500
7	2024-07-26	219.8000
7	2024-07-29	232.1000
7	2024-07-30	222.6200
7	2024-07-31	232.0700
7	2024-08-01	216.8600
7	2024-08-02	207.6700
7	2024-08-05	198.8800
7	2024-08-06	200.6400
7	2024-08-07	191.7600
7	2024-08-08	198.8400
7	2024-08-09	200.0000
7	2024-08-12	197.4900
7	2024-08-13	207.8300
7	2024-08-14	201.3800
7	2024-08-15	214.1400
7	2024-08-16	216.1200
7	2024-08-19	222.7200
7	2024-08-20	221.1000
7	2024-08-21	223.2700
7	2024-08-22	210.6600
7	2024-08-23	220.3200
7	2024-08-26	213.2100
7	2024-08-27	209.2100
7	2024-08-28	205.7500
7	2024-08-29	206.2800
7	2024-08-30	214.1100
7	2024-09-03	210.6000
7	2024-09-04	219.4100
7	2024-09-05	230.1700
7	2024-09-06	210.7300
7	2024-09-09	216.2700
7	2024-09-10	226.1700
7	2024-09-11	228.1300
7	2024-09-12	229.8100
7	2024-09-13	230.2900
7	2024-09-16	226.7800
7	2024-09-17	227.8700
7	2024-09-18	227.2000
7	2024-09-19	243.9200
7	2024-09-20	238.2500
7	2024-09-23	250.0000
7	2024-09-24	254.2700
7	2024-09-25	257.0200
7	2024-09-26	254.2200
7	2024-09-27	260.4600
7	2024-09-30	261.6300
7	2024-10-01	258.0200
7	2024-10-02	249.0200
7	2024-10-03	240.6600
7	2024-10-04	250.0800
7	2024-10-07	240.8300
7	2024-10-08	244.5000
7	2024-10-09	241.0500
7	2024-10-10	238.7700
7	2024-10-11	217.8000
7	2024-10-14	219.1600
7	2024-10-15	219.5700
7	2024-10-16	221.3300
7	2024-10-17	220.8900
7	2024-10-18	220.7000
7	2024-10-21	218.8500
7	2024-10-22	217.9700
7	2024-10-23	213.6500
7	2024-10-24	260.4800
7	2024-10-25	269.1900
7	2024-10-28	262.5100
7	2024-10-29	259.5200
7	2024-10-30	257.5500
7	2024-10-31	249.8500
7	2024-11-01	248.9800
7	2024-11-04	242.8400
7	2024-11-05	251.4400
7	2024-11-06	288.5300
7	2024-11-07	296.9100
7	2024-11-08	321.2200
7	2024-11-11	350.0000
7	2024-11-12	328.4900
7	2024-11-13	330.2400
7	2024-11-14	311.1800
7	2024-11-15	320.7200
7	2024-11-18	338.7400
7	2024-11-19	346.0000
7	2024-11-20	342.0300
7	2024-11-21	339.6400
7	2024-11-22	352.5600
7	2024-11-25	338.5900
7	2024-11-26	338.2300
7	2024-11-27	332.8900
7	2024-11-29	345.1600
7	2024-12-02	357.0900
7	2024-12-03	351.4200
7	2024-12-04	357.9300
7	2024-12-05	369.4900
7	2024-12-06	389.2200
7	2024-12-09	389.7900
7	2024-12-10	400.9900
7	2024-12-11	424.7700
7	2024-12-12	418.1000
7	2024-12-13	436.2300
7	2024-12-16	463.0200
7	2024-12-17	479.8600
7	2024-12-18	440.1300
7	2024-12-19	436.1700
7	2024-12-20	421.0600
7	2024-12-23	430.6000
7	2024-12-24	462.2800
7	2024-12-26	454.1300
7	2024-12-27	431.6600
7	2024-12-30	417.4100
7	2024-12-31	403.8400
7	2025-01-02	379.2800
7	2025-01-03	410.4400
7	2025-01-06	411.0500
7	2025-01-07	394.3600
7	2025-01-08	394.9400
7	2025-01-10	394.7400
7	2025-01-13	403.3100
7	2025-01-14	396.3600
7	2025-01-15	428.2200
7	2025-01-16	413.8200
7	2025-01-17	426.5000
7	2025-01-21	424.0700
7	2025-01-22	415.1100
7	2025-01-23	412.3800
7	2025-01-24	406.5800
7	2025-01-27	397.1500
7	2025-01-28	398.0900
7	2025-01-29	389.1000
7	2025-01-30	400.2800
7	2025-01-31	404.6000
7	2025-02-03	383.6800
7	2025-02-04	392.2100
7	2025-02-05	378.1700
7	2025-02-06	374.3200
7	2025-02-07	361.6200
7	2025-02-10	350.7300
7	2025-02-11	328.5000
7	2025-02-12	336.5100
7	2025-02-13	355.9400
7	2025-02-14	355.8400
7	2025-02-18	354.1100
7	2025-02-19	360.5600
7	2025-02-20	354.4000
7	2025-02-21	337.8000
7	2025-02-24	330.5300
7	2025-02-25	302.8000
7	2025-02-26	290.8000
7	2025-02-27	281.9500
7	2025-02-28	292.9800
7	2025-03-03	284.6500
7	2025-03-04	272.0400
7	2025-03-05	279.1000
7	2025-03-06	263.4500
7	2025-03-07	262.6700
7	2025-03-10	222.1500
7	2025-03-11	230.5800
7	2025-03-12	248.0900
7	2025-03-13	240.6800
7	2025-03-14	249.9800
7	2025-03-17	238.0100
7	2025-03-18	225.3100
7	2025-03-19	235.8600
7	2025-03-20	236.2600
7	2025-03-21	248.7100
7	2025-03-24	278.3900
7	2025-03-25	288.1400
7	2025-03-26	272.0600
7	2025-03-27	273.1300
7	2025-03-28	263.5500
7	2025-03-31	259.1600
7	2025-04-01	268.4600
7	2025-04-02	282.7600
7	2025-04-03	267.2800
7	2025-04-04	239.4300
7	2025-04-07	233.2900
7	2025-04-08	221.8600
7	2025-04-09	272.2000
7	2025-04-10	252.4000
7	2025-04-11	252.3100
7	2025-04-14	252.3500
7	2025-04-15	254.1100
7	2025-04-16	241.5500
7	2025-04-17	241.3700
7	2025-04-21	227.5000
7	2025-04-22	237.9700
7	2025-04-23	250.7400
7	2025-04-24	259.5100
7	2025-04-25	284.9500
7	2025-04-28	285.8800
7	2025-04-29	292.0300
7	2025-04-30	282.1600
7	2025-05-01	280.5200
7	2025-05-02	287.2100
7	2025-05-05	280.2600
7	2025-05-06	275.3500
7	2025-05-07	276.2200
7	2025-05-08	284.8200
7	2025-05-09	298.2600
7	2025-05-12	318.3800
7	2025-05-13	334.0700
7	2025-05-14	347.6800
7	2025-05-15	342.8200
7	2025-05-16	349.9800
7	2025-05-19	342.0900
7	2025-05-20	343.8200
7	2025-05-21	334.6200
7	2025-05-22	341.0400
7	2025-05-23	339.3400
7	2025-05-27	362.8900
7	2025-05-28	356.9000
7	2025-05-29	358.4300
7	2025-05-30	346.4600
7	2025-06-02	342.6900
7	2025-06-03	344.2700
7	2025-06-04	332.0500
7	2025-06-05	284.7000
7	2025-06-06	295.1400
7	2025-06-09	308.5800
7	2025-06-10	326.0900
7	2025-06-11	326.4300
7	2025-06-12	319.1100
7	2025-06-13	325.3100
7	2025-06-16	329.1300
7	2025-06-17	316.3500
7	2025-06-18	322.0500
7	2025-06-20	322.1600
7	2025-06-23	348.6800
7	2025-06-24	340.4700
7	2025-06-25	327.5500
7	2025-06-26	325.7800
7	2025-06-27	323.6300
7	2025-06-30	317.6600
7	2025-07-01	300.7100
7	2025-07-02	315.6500
7	2025-07-03	315.3500
7	2025-07-07	293.9400
7	2025-07-08	297.8100
7	2025-07-09	295.8800
7	2025-07-10	309.8700
7	2025-07-11	313.5100
7	2025-07-14	316.9000
7	2025-07-15	310.7800
7	2025-07-16	321.6700
7	2025-07-17	319.4100
7	2025-07-18	329.6500
7	2025-07-21	328.4900
7	2025-07-22	332.1100
7	2025-07-23	332.5600
7	2025-07-24	305.3000
7	2025-07-25	316.0600
7	2025-07-28	325.5900
7	2025-07-29	321.2000
7	2025-07-30	319.0400
7	2025-07-31	308.2700
7	2025-08-01	302.6300
7	2025-08-04	309.2600
7	2025-08-05	308.7200
7	2025-08-06	319.9100
7	2025-08-07	322.2700
7	2025-08-08	329.6500
7	2025-08-11	339.0300
7	2025-08-12	340.8400
7	2025-08-13	339.3800
7	2025-08-14	335.5800
7	2025-08-15	330.5600
7	2025-08-18	335.1600
7	2025-08-19	329.3100
7	2025-08-20	323.9000
7	2025-08-21	320.1100
7	2025-08-22	340.0100
7	2025-08-25	346.6000
7	2025-08-26	351.6700
7	2025-08-27	349.6000
7	2025-08-28	345.9800
7	2025-08-29	333.8700
7	2025-09-02	329.3600
7	2025-09-03	334.0900
7	2025-09-04	338.5300
7	2025-09-05	350.8400
7	2025-09-08	346.4000
7	2025-09-09	346.9700
7	2025-09-10	347.7900
7	2025-09-11	368.8100
7	2025-09-12	395.9400
7	2025-09-15	410.0400
7	2025-09-16	421.6200
7	2025-09-17	425.8600
7	2025-09-18	416.8500
7	2025-09-19	426.0700
7	2025-09-22	434.2100
7	2025-09-23	425.8500
7	2025-09-24	442.7900
7	2025-09-25	423.3900
7	2025-09-26	440.4000
7	2025-09-29	443.2100
7	2025-09-30	444.7200
7	2025-10-01	459.4600
7	2025-10-02	436.0000
7	2025-10-03	429.8300
7	2025-10-06	453.2500
7	2025-10-07	433.0900
7	2025-10-08	438.6900
7	2025-10-09	435.5400
7	2025-10-10	413.4900
7	2025-10-13	435.9000
7	2025-10-14	429.2400
7	2025-10-15	435.1500
7	2025-10-16	428.7500
7	2025-10-17	439.3100
7	2025-10-20	447.4300
7	2025-10-21	442.6000
7	2025-10-22	438.9700
7	2025-10-23	448.9800
7	2025-10-24	433.7200
7	2025-10-27	452.4200
7	2025-10-28	460.5500
7	2025-10-29	461.5100
7	2025-10-30	440.1000
7	2025-10-31	456.5600
7	2025-11-03	468.3700
7	2025-11-04	444.2600
7	2025-11-05	462.0700
7	2025-11-06	445.9100
7	2025-11-07	429.5200
7	2025-11-10	445.2300
7	2025-11-11	439.6200
7	2025-11-12	430.6000
7	2025-11-13	401.9900
7	2025-11-14	404.3500
7	2025-11-17	408.9200
7	2025-11-18	401.2500
7	2025-11-19	403.9900
7	2025-11-20	395.2300
7	2025-11-21	391.0900
7	2025-11-24	417.7800
7	2025-11-25	419.4000
7	2025-11-26	426.5800
7	2025-11-28	430.1700
7	2025-12-01	430.1400
7	2025-12-02	429.2400
7	2025-12-03	446.7400
7	2025-12-04	454.5300
7	2025-12-05	455.0000
7	2025-12-08	439.5800
7	2025-12-09	445.1700
7	2025-12-10	451.4500
7	2025-12-11	446.8900
7	2025-12-12	458.9600
7	2025-12-15	475.3100
7	2025-12-16	489.8800
7	2025-12-17	467.2600
7	2025-12-18	483.3700
7	2025-12-19	481.2000
7	2025-12-22	488.7300
7	2025-12-23	485.5600
7	2025-12-24	485.4000
7	2025-12-26	475.1900
7	2025-12-29	459.6400
7	2025-12-30	454.4300
7	2025-12-31	449.7200
7	2026-01-02	438.0700
7	2026-01-05	451.6700
7	2026-01-06	432.9600
7	2026-01-07	431.4100
7	2026-01-08	435.8000
7	2026-01-09	445.0100
7	2026-01-12	448.9600
7	2026-01-13	447.2000
7	2026-01-14	439.2000
7	2026-01-15	438.5700
7	2026-01-16	437.5000
7	2026-01-20	419.2500
7	2026-01-21	431.4400
7	2026-01-22	449.3600
7	2026-01-23	449.0600
7	2026-01-26	435.2000
7	2026-01-27	430.9000
7	2026-01-28	431.4600
7	2026-01-29	416.5600
7	2026-01-30	430.4100
7	2026-02-02	421.8100
7	2026-02-03	421.9600
7	2026-02-04	406.0100
7	2026-02-05	397.2100
7	2026-02-06	411.1100
7	2026-02-09	417.3200
7	2026-02-10	425.2100
7	2026-02-11	428.2700
7	2026-02-12	417.0700
7	2026-02-13	417.4400
7	2026-02-17	410.6300
7	2026-02-18	411.3200
7	2026-02-19	411.7100
7	2026-02-20	411.8200
7	2026-02-23	399.8300
7	2026-02-24	409.3800
7	2026-02-25	417.4000
7	2026-02-26	408.5800
7	2026-02-27	402.5100
7	2026-03-02	403.3200
7	2026-03-03	392.4300
7	2026-03-04	405.9400
7	2026-03-05	405.5500
7	2026-03-06	396.7300
7	2026-03-09	398.6800
7	2026-03-10	399.2400
7	2026-03-11	407.8200
7	2026-03-12	395.0100
7	2026-03-13	391.2000
7	2026-03-16	395.5600
7	2026-03-17	399.2700
7	2026-03-18	392.7800
7	2026-03-19	380.3000
7	2026-03-20	367.9600
7	2026-03-23	380.8500
7	2026-03-24	383.0300
7	2026-03-25	385.9500
7	2026-03-26	372.1100
7	2026-03-27	361.8300
7	2026-03-30	355.2800
7	2026-03-31	371.7500
7	2026-04-01	381.2600
7	2026-04-02	360.5900
7	2026-04-06	352.8200
7	2026-04-07	346.6500
7	2026-04-08	343.2500
7	2026-04-09	345.6200
7	2026-04-10	348.9500
7	2026-04-13	352.4200
7	2026-04-14	364.2000
7	2026-04-15	391.9500
7	2026-04-16	388.9000
7	2026-04-17	400.6200
7	2026-04-20	392.5000
7	2026-04-21	386.4200
7	2026-04-22	387.5100
7	2026-04-23	373.7200
7	2026-04-24	376.3000
7	2026-04-27	378.6700
7	2026-04-28	376.0200
7	2026-04-29	372.8000
7	2026-04-30	381.6300
7	2026-05-01	390.8200
7	2026-05-04	392.5100
7	2026-05-05	389.3700
7	2026-05-06	398.7300
7	2026-05-07	411.7900
7	2026-05-08	428.3500
7	2026-05-11	445.0000
7	2026-05-12	433.4500
7	2026-05-13	445.2700
7	2026-05-14	443.3000
7	2026-05-15	422.2400
7	2026-05-18	409.9900
7	2026-05-19	404.1100
7	2026-05-20	417.2600
7	2026-05-21	417.8500
7	2026-05-22	426.0100
7	2026-05-26	433.5900
7	2026-05-27	440.3600
7	2026-05-28	442.1000
7	2026-05-29	435.7900
7	2026-06-01	415.8800
7	2026-06-02	423.7400
7	2026-06-03	423.7000
7	2026-06-04	418.4500
7	2026-06-05	391.0000
7	2026-06-08	408.9500
7	2026-06-09	396.6800
7	2026-06-10	381.5900
7	2026-06-11	399.1500
7	2026-06-12	406.4300
7	2026-06-15	411.1500
7	2026-06-16	404.6600
7	2026-06-17	396.3800
7	2026-06-18	400.4900
7	2026-06-22	405.0500
7	2026-06-23	381.6100
7	2026-06-24	375.5300
7	2026-06-25	375.1200
7	2026-06-26	379.7100
7	2026-06-29	411.8400
7	2026-06-30	420.6000
7	2026-07-01	425.3000
7	2026-07-02	393.4500
7	2026-07-06	419.7700
7	2026-07-07	402.9000
7	2026-07-08	394.0600
7	2026-07-09	406.5500
7	2026-07-10	407.7600
7	2026-07-13	394.7600
7	2026-07-14	396.1800
7	2026-07-15	394.4600
7	2026-07-16	391.0600
7	2026-07-17	380.8400
7	2026-07-20	369.5700
7	2026-07-21	378.9300
7	2026-07-22	374.0100
7	2026-07-23	319.6900
7	2026-07-24	313.0300
7	2026-07-27	309.2200
7	2026-07-28	307.4400
7	2026-07-29	298.3200
7	2026-07-30	308.8500
7	2026-07-31	311.2100
7	2026-08-03	322.0800
7	2026-08-04	327.3500
7	2026-08-05	321.5500
7	2026-08-06	319.5300
7	2026-08-07	328.5800
7	2026-08-10	330.8800
7	2026-08-11	332.8100
7	2026-08-12	327.5100
7	2026-08-13	339.9600
7	2026-08-14	342.2700
7	2026-08-17	339.3000
7	2026-08-18	336.8700
7	2026-08-19	351.1200
7	2026-08-20	345.1300
7	2026-08-21	362.8600
7	2026-08-24	348.9500
7	2026-08-25	350.2500
7	2026-08-26	345.8200
7	2026-08-27	354.8100
7	2026-08-28	348.7500
7	2026-08-31	367.9500
7	2026-09-01	356.0900
7	2026-09-02	357.0100
7	2026-09-03	376.3700
7	2026-09-04	354.0800
7	2026-09-08	368.1600
7	2026-09-09	367.8100
7	2026-09-10	363.5600
7	2026-09-11	365.4400
7	2026-09-14	358.9700
7	2026-09-15	356.5800
7	2026-09-16	358.0800
7	2026-09-17	366.2000
7	2026-09-18	364.2700
7	2026-09-21	375.3000
7	2026-09-22	378.9000
7	2026-09-23	380.1200
7	2026-09-24	377.9400
7	2026-09-25	372.1100
7	2026-09-28	357.4500
7	2026-09-29	352.8400
7	2026-09-30	354.8100
7	2026-10-01	354.1100
7	2026-10-02	370.5900
7	2026-10-05	378.7300
7	2026-10-06	380.6800
7	2026-10-07	377.8100
7	2026-10-08	375.0000
7	2026-10-09	382.7000
7	2026-10-12	378.0300
7	2026-10-13	375.2300
7	2026-10-14	367.1600
7	2026-10-15	362.4400
7	2026-10-16	354.7200
7	2026-10-19	368.0600
7	2026-10-20	373.7100
7	2026-10-21	386.4700
7	2026-10-22	374.5800
7	2026-10-23	372.2200
7	2026-10-26	391.6200
7	2026-10-27	407.4600
7	2026-10-28	404.2200
7	2026-10-29	403.3000
7	2026-10-30	399.8100
7	2026-11-02	403.8200
7	2026-11-03	398.5000
7	2026-11-04	385.1900
7	2026-11-05	343.6900
7	2026-11-06	358.2200
7	2026-11-09	378.0500
7	2026-11-10	379.7800
7	2026-11-11	390.8400
7	2026-11-12	397.4500
7	2026-11-13	390.2200
7	2026-11-16	379.7400
8	2024-01-02	159.9700
8	2024-01-03	160.9700
8	2024-01-04	160.6300
8	2024-01-05	161.1300
8	2024-01-08	161.5300
8	2024-01-09	161.6300
8	2024-01-10	161.8700
8	2024-01-11	161.1500
8	2024-01-12	162.3900
8	2024-01-16	160.5200
8	2024-01-17	160.4300
8	2024-01-18	161.2100
8	2024-01-19	161.6800
8	2024-01-22	162.4700
8	2024-01-23	159.8100
8	2024-01-24	158.9600
8	2024-01-25	159.5600
8	2024-01-26	159.5000
8	2024-01-29	159.3600
8	2024-01-30	158.7700
8	2024-01-31	158.9000
8	2024-02-01	158.3600
8	2024-02-02	156.6100
8	2024-02-05	155.8000
8	2024-02-06	158.0600
8	2024-02-07	157.9800
8	2024-02-08	156.4000
8	2024-02-09	156.7600
8	2024-02-12	157.8500
8	2024-02-13	156.4700
8	2024-02-14	155.7400
8	2024-02-15	157.9200
8	2024-02-16	156.5500
8	2024-02-20	157.8600
8	2024-02-21	158.6800
8	2024-02-22	160.4500
8	2024-02-23	161.8400
8	2024-02-26	160.7900
8	2024-02-27	160.9800
8	2024-02-28	161.5500
8	2024-02-29	161.3800
8	2024-03-01	162.1200
8	2024-03-04	159.8400
8	2024-03-05	159.9700
8	2024-03-06	159.3400
8	2024-03-07	158.8700
8	2024-03-08	159.5200
8	2024-03-11	161.2300
8	2024-03-12	162.7400
8	2024-03-13	161.1000
8	2024-03-14	159.2100
8	2024-03-15	158.1800
8	2024-03-18	156.7600
8	2024-03-19	156.2100
8	2024-03-20	155.7600
8	2024-03-21	155.7500
8	2024-03-22	155.2300
8	2024-03-25	155.2200
8	2024-03-26	155.7700
8	2024-03-27	157.9600
8	2024-03-28	158.1900
8	2024-04-01	157.7800
8	2024-04-02	157.7300
8	2024-04-03	154.2600
8	2024-04-04	152.5000
8	2024-04-05	152.3900
8	2024-04-08	151.5900
8	2024-04-09	152.2900
8	2024-04-10	150.2000
8	2024-04-11	148.7900
8	2024-04-12	147.5200
8	2024-04-15	147.5900
8	2024-04-16	144.4500
8	2024-04-17	144.7700
8	2024-04-18	145.7400
8	2024-04-19	147.9100
8	2024-04-22	149.1200
8	2024-04-23	149.5600
8	2024-04-24	148.5300
8	2024-04-25	146.8200
8	2024-04-26	146.1400
8	2024-04-29	146.8200
8	2024-04-30	144.5900
8	2024-05-01	151.1800
8	2024-05-02	149.9200
8	2024-05-03	149.2700
8	2024-05-06	148.5800
8	2024-05-07	148.7200
8	2024-05-08	148.9500
8	2024-05-09	149.8500
8	2024-05-10	149.9100
8	2024-05-13	151.2200
8	2024-05-14	151.3800
8	2024-05-15	152.6700
8	2024-05-16	154.2800
8	2024-05-17	154.6400
8	2024-05-20	151.2700
8	2024-05-21	151.2400
8	2024-05-22	153.5000
8	2024-05-23	149.7000
8	2024-05-24	146.9700
8	2024-05-28	144.3800
8	2024-05-29	144.4400
8	2024-05-30	145.2800
8	2024-05-31	146.6700
8	2024-06-03	147.7400
8	2024-06-04	147.8000
8	2024-06-05	145.9700
8	2024-06-06	146.4200
8	2024-06-07	147.0800
8	2024-06-10	147.1300
8	2024-06-11	146.7600
8	2024-06-12	145.4100
8	2024-06-13	145.4500
8	2024-06-14	145.5400
8	2024-06-17	145.9500
8	2024-06-18	145.6500
8	2024-06-20	147.7800
8	2024-06-21	148.7500
8	2024-06-24	149.1200
8	2024-06-25	147.1900
8	2024-06-26	146.8200
8	2024-06-27	145.8000
8	2024-06-28	146.1600
8	2024-07-01	146.4400
8	2024-07-02	146.0300
8	2024-07-03	145.6900
8	2024-07-05	146.4800
8	2024-07-08	145.4800
8	2024-07-09	147.0500
8	2024-07-10	149.4300
8	2024-07-11	149.7000
8	2024-07-12	149.8800
8	2024-07-15	149.2400
8	2024-07-16	151.0100
8	2024-07-17	156.5800
8	2024-07-18	155.4200
8	2024-07-19	154.6900
8	2024-07-22	154.2400
8	2024-07-23	152.3500
8	2024-07-24	156.2800
8	2024-07-25	159.6400
8	2024-07-26	160.6400
8	2024-07-29	158.5600
8	2024-07-30	161.3300
8	2024-07-31	157.8500
8	2024-08-01	160.7600
8	2024-08-02	164.1400
8	2024-08-05	161.2500
8	2024-08-06	158.9700
8	2024-08-07	158.9000
8	2024-08-08	160.2200
8	2024-08-09	160.6200
8	2024-08-12	159.8800
8	2024-08-13	158.3900
8	2024-08-14	158.4800
8	2024-08-15	159.0900
8	2024-08-16	159.3900
8	2024-08-19	159.6300
8	2024-08-20	160.1600
8	2024-08-21	161.4300
8	2024-08-22	162.3500
8	2024-08-23	164.1300
8	2024-08-26	164.6100
8	2024-08-27	162.9500
8	2024-08-28	163.9200
8	2024-08-29	164.2300
8	2024-08-30	165.8600
8	2024-09-03	167.1600
8	2024-09-04	167.3600
8	2024-09-05	164.9900
8	2024-09-06	164.3800
8	2024-09-09	166.6100
8	2024-09-10	167.3800
8	2024-09-11	164.8200
8	2024-09-12	164.6400
8	2024-09-13	165.5200
8	2024-09-16	166.9900
8	2024-09-17	167.0700
8	2024-09-18	166.1500
8	2024-09-19	164.8200
8	2024-09-20	164.1600
8	2024-09-23	163.2200
8	2024-09-24	162.7800
8	2024-09-25	160.6000
8	2024-09-26	161.3900
8	2024-09-27	161.4000
8	2024-09-30	162.0600
8	2024-10-01	161.9900
8	2024-10-02	161.1700
8	2024-10-03	160.5000
8	2024-10-04	160.2900
8	2024-10-07	159.5300
8	2024-10-08	159.6900
8	2024-10-09	160.6500
8	2024-10-10	160.5100
8	2024-10-11	161.4600
8	2024-10-14	161.6000
8	2024-10-15	164.1000
8	2024-10-16	164.2800
8	2024-10-17	164.4700
8	2024-10-18	165.1200
8	2024-10-21	162.8300
8	2024-10-22	163.4500
8	2024-10-23	165.8600
8	2024-10-24	163.6700
8	2024-10-25	160.8800
8	2024-10-28	161.6000
8	2024-10-29	160.0900
8	2024-10-30	160.6100
8	2024-10-31	159.8600
8	2024-11-01	160.1300
8	2024-11-04	158.2400
8	2024-11-05	158.3500
8	2024-11-06	157.8800
8	2024-11-07	156.7300
8	2024-11-08	155.4700
8	2024-11-11	155.0400
8	2024-11-12	152.6400
8	2024-11-13	153.2400
8	2024-11-14	151.8700
8	2024-11-15	154.0000
8	2024-11-18	154.7700
8	2024-11-19	153.0000
8	2024-11-20	153.1100
8	2024-11-21	155.5000
8	2024-11-22	155.1700
8	2024-11-25	155.7800
8	2024-11-26	154.5200
8	2024-11-27	155.4000
8	2024-11-29	155.0100
8	2024-12-02	154.8000
8	2024-12-03	152.3600
8	2024-12-04	150.4700
8	2024-12-05	149.5200
8	2024-12-06	149.3100
8	2024-12-09	149.6000
8	2024-12-10	149.2300
8	2024-12-11	146.6400
8	2024-12-12	146.2400
8	2024-12-13	146.6200
8	2024-12-16	143.8500
8	2024-12-17	146.4100
8	2024-12-18	144.7500
8	2024-12-19	143.5800
8	2024-12-20	144.4700
8	2024-12-23	145.2700
8	2024-12-24	145.8500
8	2024-12-26	145.5800
8	2024-12-27	145.0500
8	2024-12-30	143.3400
8	2024-12-31	144.6200
8	2025-01-02	144.0200
8	2025-01-03	144.1900
8	2025-01-06	143.6600
8	2025-01-07	146.2300
8	2025-01-08	142.2700
8	2025-01-10	142.0600
8	2025-01-13	144.4700
8	2025-01-14	144.7500
8	2025-01-15	144.9700
8	2025-01-16	147.7700
8	2025-01-17	147.0300
8	2025-01-21	148.1500
8	2025-01-22	145.2700
8	2025-01-23	146.6400
8	2025-01-24	146.8200
8	2025-01-27	152.8900
8	2025-01-28	150.3800
8	2025-01-29	151.1500
8	2025-01-30	152.8700
8	2025-01-31	152.1500
8	2025-02-03	151.8700
8	2025-02-04	153.4900
8	2025-02-05	154.6900
8	2025-02-06	153.5100
8	2025-02-07	153.1200
8	2025-02-10	154.2400
8	2025-02-11	156.1300
8	2025-02-12	155.2600
8	2025-02-13	157.2500
8	2025-02-14	156.1500
8	2025-02-18	154.9900
8	2025-02-19	157.8900
8	2025-02-20	159.6800
8	2025-02-21	162.3000
8	2025-02-24	163.7400
8	2025-02-25	166.0900
8	2025-02-26	163.0800
8	2025-02-27	163.7300
8	2025-02-28	165.0200
8	2025-03-03	167.2800
8	2025-03-04	165.4200
8	2025-03-05	165.1200
8	2025-03-06	165.8300
8	2025-03-07	166.6900
8	2025-03-10	167.7000
8	2025-03-11	165.8600
8	2025-03-12	162.8500
8	2025-03-13	162.9900
8	2025-03-14	162.8100
8	2025-03-17	162.8400
8	2025-03-18	164.2500
8	2025-03-19	162.9900
8	2025-03-20	163.0200
8	2025-03-21	163.6300
8	2025-03-24	163.2900
8	2025-03-25	161.0200
8	2025-03-26	161.7200
8	2025-03-27	163.1300
8	2025-03-28	163.7100
8	2025-03-31	165.8400
8	2025-04-01	153.2500
8	2025-04-02	155.3600
8	2025-04-03	159.8200
8	2025-04-04	153.2400
8	2025-04-07	150.6200
8	2025-04-08	150.0000
8	2025-04-09	150.9700
8	2025-04-10	148.6900
8	2025-04-11	151.7300
8	2025-04-14	154.3600
8	2025-04-15	153.6200
8	2025-04-16	153.9100
8	2025-04-17	157.4700
8	2025-04-21	156.9200
8	2025-04-22	157.7500
8	2025-04-23	155.3800
8	2025-04-24	154.9300
8	2025-04-25	154.5800
8	2025-04-28	155.3500
8	2025-04-29	155.9100
8	2025-04-30	156.3100
8	2025-05-01	154.4600
8	2025-05-02	156.1200
8	2025-05-05	155.0000
8	2025-05-06	154.4700
8	2025-05-07	157.3000
8	2025-05-08	155.6600
8	2025-05-09	154.2200
8	2025-05-12	154.1400
8	2025-05-13	148.4400
8	2025-05-14	146.3600
8	2025-05-15	149.6100
8	2025-05-16	151.3300
8	2025-05-19	152.4900
8	2025-05-20	153.6600
8	2025-05-21	153.1800
8	2025-05-22	152.6100
8	2025-05-23	152.9400
8	2025-05-27	153.2500
8	2025-05-28	152.4300
8	2025-05-29	153.5800
8	2025-05-30	155.2100
8	2025-06-02	155.4000
8	2025-06-03	154.4200
8	2025-06-04	153.2200
8	2025-06-05	153.6600
8	2025-06-06	155.0300
8	2025-06-09	155.2300
8	2025-06-10	156.4500
8	2025-06-11	155.2600
8	2025-06-12	156.6600
8	2025-06-13	157.1000
8	2025-06-16	155.2200
8	2025-06-17	152.3800
8	2025-06-18	150.7300
8	2025-06-20	149.7900
8	2025-06-23	151.3200
8	2025-06-24	152.1900
8	2025-06-25	152.2800
8	2025-06-26	152.0100
8	2025-06-27	152.4100
8	2025-06-30	152.7500
8	2025-07-01	155.9200
8	2025-07-02	155.5600
8	2025-07-03	156.0100
8	2025-07-07	155.2700
8	2025-07-08	155.7900
8	2025-07-09	156.2800
8	2025-07-10	157.6900
8	2025-07-11	156.9000
8	2025-07-14	156.8200
8	2025-07-15	155.1700
8	2025-07-16	164.7800
8	2025-07-17	162.9800
8	2025-07-18	163.7000
8	2025-07-21	164.3600
8	2025-07-22	167.9300
8	2025-07-23	169.1000
8	2025-07-24	169.5600
8	2025-07-25	168.3000
8	2025-07-28	166.2200
8	2025-07-29	168.1100
8	2025-07-30	167.2600
8	2025-07-31	164.7400
8	2025-08-01	167.3300
8	2025-08-04	171.0400
8	2025-08-05	170.7400
8	2025-08-06	170.5900
8	2025-08-07	171.5300
8	2025-08-08	173.3300
8	2025-08-11	173.8200
8	2025-08-12	172.7800
8	2025-08-13	174.4200
8	2025-08-14	174.7200
8	2025-08-15	176.6400
8	2025-08-18	176.2500
8	2025-08-19	177.8000
8	2025-08-20	178.8400
8	2025-08-21	178.9300
8	2025-08-22	179.2900
8	2025-08-25	178.4100
8	2025-08-26	176.4900
8	2025-08-27	176.7900
8	2025-08-28	175.4500
8	2025-08-29	177.1700
8	2025-09-02	178.0600
8	2025-09-03	178.0000
8	2025-09-04	178.7600
8	2025-09-05	178.4300
8	2025-09-08	178.1300
8	2025-09-09	176.9600
8	2025-09-10	175.7900
8	2025-09-11	178.5000
8	2025-09-12	178.0600
8	2025-09-15	177.4000
8	2025-09-16	176.4600
8	2025-09-17	177.2000
8	2025-09-18	174.1600
8	2025-09-19	176.1900
8	2025-09-22	174.2100
8	2025-09-23	176.5800
8	2025-09-24	176.6900
8	2025-09-25	177.7300
8	2025-09-26	179.7100
8	2025-09-29	181.6200
8	2025-09-30	185.4200
8	2025-10-01	186.0500
8	2025-10-02	185.9800
8	2025-10-03	188.6400
8	2025-10-06	188.1600
8	2025-10-07	188.8900
8	2025-10-08	189.6900
8	2025-10-09	191.0800
8	2025-10-10	190.7200
8	2025-10-13	190.9000
8	2025-10-14	190.8500
8	2025-10-15	191.1700
8	2025-10-16	192.1200
8	2025-10-17	193.2200
8	2025-10-20	193.7200
8	2025-10-21	191.8800
8	2025-10-22	192.9400
8	2025-10-23	192.4700
8	2025-10-24	190.4000
8	2025-10-27	190.3000
8	2025-10-28	186.9300
8	2025-10-29	186.6000
8	2025-10-30	189.0500
8	2025-10-31	188.8700
8	2025-11-03	186.2600
8	2025-11-04	186.8600
8	2025-11-05	186.0000
8	2025-11-06	186.9700
8	2025-11-07	186.5700
8	2025-11-10	188.4100
8	2025-11-11	193.8300
8	2025-11-12	194.3900
8	2025-11-13	195.2500
8	2025-11-14	195.9300
8	2025-11-17	199.5800
8	2025-11-18	200.0000
8	2025-11-19	202.5100
8	2025-11-20	203.0700
8	2025-11-21	203.9000
8	2025-11-24	206.0500
8	2025-11-25	206.6700
8	2025-11-26	207.5600
8	2025-11-28	206.9200
8	2025-12-01	205.3400
8	2025-12-02	205.4200
8	2025-12-03	205.3300
8	2025-12-04	202.4800
8	2025-12-05	201.9300
8	2025-12-08	201.6200
8	2025-12-09	199.9600
8	2025-12-10	206.5400
8	2025-12-11	210.0100
8	2025-12-12	211.5800
8	2025-12-15	214.1700
8	2025-12-16	209.3000
8	2025-12-17	210.3300
8	2025-12-18	208.3100
8	2025-12-19	206.3700
8	2025-12-22	207.3200
8	2025-12-23	205.7800
8	2025-12-24	207.7800
8	2025-12-26	207.6300
8	2025-12-29	207.5600
8	2025-12-30	206.9100
8	2025-12-31	206.9500
8	2026-01-02	207.3500
8	2026-01-05	204.3100
8	2026-01-06	204.7900
8	2026-01-07	207.4900
8	2026-01-08	205.7500
8	2026-01-09	204.3900
8	2026-01-12	209.7200
8	2026-01-13	213.6500
8	2026-01-14	218.5500
8	2026-01-15	219.5700
8	2026-01-16	218.6600
8	2026-01-20	218.2100
8	2026-01-21	218.0100
8	2026-01-22	218.4900
8	2026-01-23	220.1400
8	2026-01-26	221.4900
8	2026-01-27	224.4400
8	2026-01-28	227.7200
8	2026-01-29	227.2900
8	2026-01-30	227.2500
8	2026-02-02	230.7500
8	2026-02-03	233.1000
8	2026-02-04	234.4700
8	2026-02-05	237.7900
8	2026-02-06	239.9900
8	2026-02-09	238.6400
8	2026-02-10	238.3500
8	2026-02-11	240.8600
8	2026-02-12	244.5500
8	2026-02-13	243.4500
8	2026-02-17	243.3300
8	2026-02-18	244.9900
8	2026-02-19	246.9100
8	2026-02-20	242.4900
8	2026-02-23	245.8400
8	2026-02-24	246.2800
8	2026-02-25	245.1700
8	2026-02-26	243.4700
8	2026-02-27	248.4300
8	2026-03-02	248.5600
8	2026-03-03	246.7500
8	2026-03-04	245.3000
8	2026-03-05	239.6300
8	2026-03-06	240.4000
8	2026-03-09	242.5900
8	2026-03-10	243.7100
8	2026-03-11	242.9900
8	2026-03-12	242.0400
8	2026-03-13	241.5200
8	2026-03-16	243.1900
8	2026-03-17	238.1100
8	2026-03-18	237.2800
8	2026-03-19	237.6000
8	2026-03-20	235.3700
8	2026-03-23	235.4200
8	2026-03-24	235.2700
8	2026-03-25	239.9300
8	2026-03-26	239.2400
8	2026-03-27	240.4500
8	2026-03-30	242.4900
8	2026-03-31	244.4400
8	2026-04-01	244.1200
8	2026-04-02	243.0400
8	2026-04-06	240.9700
8	2026-04-07	238.4100
8	2026-04-08	241.3000
8	2026-04-09	241.3100
8	2026-04-10	238.4600
8	2026-04-13	237.9600
8	2026-04-14	240.1000
8	2026-04-15	238.6700
8	2026-04-16	234.5400
8	2026-04-17	234.1800
8	2026-04-20	230.6900
8	2026-04-21	226.1600
8	2026-04-22	226.1000
8	2026-04-23	230.6500
8	2026-04-24	227.5000
8	2026-04-27	225.3400
8	2026-04-28	227.7900
8	2026-04-29	227.3500
8	2026-04-30	229.8500
8	2026-05-01	227.1900
8	2026-05-04	224.2000
8	2026-05-05	225.5500
8	2026-05-06	224.6200
8	2026-05-07	222.5100
8	2026-05-08	221.3200
8	2026-05-11	221.4300
8	2026-05-12	224.2600
8	2026-05-13	230.4200
8	2026-05-14	230.8000
8	2026-05-15	226.7100
8	2026-05-18	228.9200
8	2026-05-19	230.0000
8	2026-05-20	229.3200
8	2026-05-21	231.7300
8	2026-05-22	234.3400
8	2026-05-26	230.1800
8	2026-05-27	231.2900
8	2026-05-28	230.8000
8	2026-05-29	225.3300
8	2026-06-01	223.5100
8	2026-06-02	222.8900
8	2026-06-03	223.2400
8	2026-06-04	228.1700
8	2026-06-05	232.7700
8	2026-06-08	232.1600
8	2026-06-09	237.0000
8	2026-06-10	238.4900
8	2026-06-11	238.3300
8	2026-06-12	240.8700
8	2026-06-15	235.6600
8	2026-06-16	235.1800
8	2026-06-17	234.2000
8	2026-06-18	228.3900
8	2026-06-22	231.2900
8	2026-06-23	239.0800
8	2026-06-24	241.0000
8	2026-06-25	244.8800
8	2026-06-26	254.6600
8	2026-06-29	258.5100
8	2026-06-30	253.9700
8	2026-07-01	253.9800
8	2026-07-02	263.0400
8	2026-07-06	259.3300
8	2026-07-07	267.2400
8	2026-07-08	263.4000
8	2026-07-09	259.1000
8	2026-07-10	256.9800
8	2026-07-13	257.7700
8	2026-07-14	253.8500
8	2026-07-15	247.0200
8	2026-07-16	249.9700
8	2026-07-17	253.0400
8	2026-07-20	248.8200
8	2026-07-21	250.6100
8	2026-07-22	255.6300
8	2026-07-23	259.2700
8	2026-07-24	263.4000
8	2026-07-27	265.9500
8	2026-07-28	266.7300
8	2026-07-29	265.5300
8	2026-07-30	255.8200
8	2026-07-31	256.3500
8	2026-08-03	254.4100
8	2026-08-04	254.9300
8	2026-08-05	257.5900
8	2026-08-06	256.9800
8	2026-08-07	259.2400
8	2026-08-10	261.8100
8	2026-08-11	259.8000
8	2026-08-12	260.8600
8	2026-08-13	262.0800
8	2026-08-14	260.3500
8	2026-08-17	262.3700
8	2026-08-18	271.1100
8	2026-08-19	273.4100
8	2026-08-20	267.3700
8	2026-08-21	270.2400
8	2026-08-24	273.0400
8	2026-08-25	273.1400
8	2026-08-26	270.0000
8	2026-08-27	265.7700
8	2026-08-28	268.0400
8	2026-08-31	265.8500
8	2026-09-01	271.1900
8	2026-09-02	275.2100
8	2026-09-03	278.4300
8	2026-09-04	275.2300
8	2026-09-08	269.1200
8	2026-09-09	267.0800
8	2026-09-10	266.3500
8	2026-09-11	265.5800
8	2026-09-14	266.3200
8	2026-09-15	267.2000
8	2026-09-16	267.2800
8	2026-09-17	270.2200
8	2026-09-18	269.9900
8	2026-09-21	269.4700
8	2026-09-22	269.1900
8	2026-09-23	269.1700
8	2026-09-24	270.6800
8	2026-09-25	271.2200
8	2026-09-28	271.9500
8	2026-09-29	267.5700
8	2026-09-30	264.7400
8	2026-10-01	258.6600
8	2026-10-02	256.0300
8	2026-10-05	252.9300
8	2026-10-06	254.7800
8	2026-10-07	258.4500
8	2026-10-08	256.4800
8	2026-10-09	261.4400
8	2026-10-12	263.7300
8	2026-10-13	248.6100
8	2026-10-14	253.9100
8	2026-10-15	253.2800
8	2026-10-16	255.5600
8	2026-10-19	253.7900
8	2026-10-20	259.3600
8	2026-10-21	257.7800
8	2026-10-22	267.6100
8	2026-10-23	263.8100
8	2026-10-26	266.3000
8	2026-10-27	268.7300
8	2026-10-28	271.0400
8	2026-10-29	275.2000
8	2026-10-30	273.2000
8	2026-11-02	270.5600
8	2026-11-03	266.1700
8	2026-11-04	276.3200
8	2026-11-05	272.3200
8	2026-11-06	276.2200
8	2026-11-09	282.1100
8	2026-11-10	280.7800
8	2026-11-11	280.4100
8	2026-11-12	283.5200
8	2026-11-13	285.7500
8	2026-11-16	282.5500
9	2024-01-02	472.6500
9	2024-01-03	468.7900
9	2024-01-04	467.2800
9	2024-01-05	467.9200
9	2024-01-08	474.6000
9	2024-01-09	473.8800
9	2024-01-10	476.5600
9	2024-01-11	476.3500
9	2024-01-12	476.6800
9	2024-01-16	474.9300
9	2024-01-17	472.2900
9	2024-01-18	476.4900
9	2024-01-19	482.4300
9	2024-01-22	483.4500
9	2024-01-23	484.8600
9	2024-01-24	485.3900
9	2024-01-25	488.0300
9	2024-01-26	487.4100
9	2024-01-29	491.2700
9	2024-01-30	490.8900
9	2024-01-31	482.8800
9	2024-02-01	489.2000
9	2024-02-02	494.3500
9	2024-02-05	492.5500
9	2024-02-06	493.9800
9	2024-02-07	498.1000
9	2024-02-08	498.3200
9	2024-02-09	501.2000
9	2024-02-12	500.9800
9	2024-02-13	494.0800
9	2024-02-14	498.5700
9	2024-02-15	502.0100
9	2024-02-16	499.5100
9	2024-02-20	496.7600
9	2024-02-21	497.2100
9	2024-02-22	507.5000
9	2024-02-23	507.8500
9	2024-02-26	505.9900
9	2024-02-27	506.9300
9	2024-02-28	506.2600
9	2024-02-29	508.0800
9	2024-03-01	512.8500
9	2024-03-04	512.3000
9	2024-03-05	507.1800
9	2024-03-06	509.7500
9	2024-03-07	514.8100
9	2024-03-08	511.7200
9	2024-03-11	511.2800
9	2024-03-12	516.7800
9	2024-03-13	515.9700
9	2024-03-14	514.9500
9	2024-03-15	509.8300
9	2024-03-18	512.8600
9	2024-03-19	515.7100
9	2024-03-20	520.4800
9	2024-03-21	522.2000
9	2024-03-22	521.2100
9	2024-03-25	519.7700
9	2024-03-26	518.8100
9	2024-03-27	523.1700
9	2024-03-28	523.0700
9	2024-04-01	522.1600
9	2024-04-02	518.8400
9	2024-04-03	519.4100
9	2024-04-04	513.0700
9	2024-04-05	518.4300
9	2024-04-08	518.7200
9	2024-04-09	519.3200
9	2024-04-10	514.1200
9	2024-04-11	518.0000
9	2024-04-12	510.8500
9	2024-04-15	504.4500
9	2024-04-16	503.5300
9	2024-04-17	500.5500
9	2024-04-18	499.5200
9	2024-04-19	495.1600
9	2024-04-22	499.7200
9	2024-04-23	505.6500
9	2024-04-24	505.4100
9	2024-04-25	503.4900
9	2024-04-26	508.2600
9	2024-04-29	510.0600
9	2024-04-30	501.9800
9	2024-05-01	500.3500
9	2024-05-02	505.0300
9	2024-05-03	511.2900
9	2024-05-06	516.5700
9	2024-05-07	517.1400
9	2024-05-08	517.1900
9	2024-05-09	520.1700
9	2024-05-10	520.8400
9	2024-05-13	520.9100
9	2024-05-14	523.3000
9	2024-05-15	529.7800
9	2024-05-16	528.6900
9	2024-05-17	529.4500
9	2024-05-20	530.0600
9	2024-05-21	531.3600
9	2024-05-22	529.8300
9	2024-05-23	525.9600
9	2024-05-24	529.4400
9	2024-05-28	529.8100
9	2024-05-29	526.1000
9	2024-05-30	522.6100
9	2024-05-31	527.3700
9	2024-06-03	527.8000
9	2024-06-04	528.3900
9	2024-06-05	534.6700
9	2024-06-06	534.6600
9	2024-06-07	534.0100
9	2024-06-10	535.6600
9	2024-06-11	536.9500
9	2024-06-12	541.3600
9	2024-06-13	542.4500
9	2024-06-14	542.7800
9	2024-06-17	547.1000
9	2024-06-18	548.4900
9	2024-06-20	547.0000
9	2024-06-21	544.5100
9	2024-06-24	542.7400
9	2024-06-25	544.8300
9	2024-06-26	545.5100
9	2024-06-27	546.3700
9	2024-06-28	544.2200
9	2024-07-01	545.3400
9	2024-07-02	549.0100
9	2024-07-03	551.4600
9	2024-07-05	554.6400
9	2024-07-08	555.2800
9	2024-07-09	555.8200
9	2024-07-10	561.3200
9	2024-07-11	556.4800
9	2024-07-12	559.9900
9	2024-07-15	561.5300
9	2024-07-16	564.8600
9	2024-07-17	556.9400
9	2024-07-18	552.6600
9	2024-07-19	548.9900
9	2024-07-22	554.6500
9	2024-07-23	553.7800
9	2024-07-24	541.2300
9	2024-07-25	538.4100
9	2024-07-26	544.4400
9	2024-07-29	544.7600
9	2024-07-30	542.0000
9	2024-07-31	550.8100
9	2024-08-01	543.0100
9	2024-08-02	532.9000
9	2024-08-05	517.3800
9	2024-08-06	522.1500
9	2024-08-07	518.6600
9	2024-08-08	530.6500
9	2024-08-09	532.9900
9	2024-08-12	533.2700
9	2024-08-13	542.0400
9	2024-08-14	543.7500
9	2024-08-15	553.0700
9	2024-08-16	554.3100
9	2024-08-19	559.6100
9	2024-08-20	558.7000
9	2024-08-21	560.6200
9	2024-08-22	556.2200
9	2024-08-23	562.1300
9	2024-08-26	560.7900
9	2024-08-27	561.5600
9	2024-08-28	558.3000
9	2024-08-29	558.3500
9	2024-08-30	563.6800
9	2024-09-03	552.0800
9	2024-09-04	550.9500
9	2024-09-05	549.6100
9	2024-09-06	540.3600
9	2024-09-09	546.4100
9	2024-09-10	548.7900
9	2024-09-11	554.4200
9	2024-09-12	559.0900
9	2024-09-13	562.0100
9	2024-09-16	562.8400
9	2024-09-17	563.0700
9	2024-09-18	561.4000
9	2024-09-19	570.9800
9	2024-09-20	568.2500
9	2024-09-23	569.6700
9	2024-09-24	571.3000
9	2024-09-25	570.0400
9	2024-09-26	572.3000
9	2024-09-27	571.4700
9	2024-09-30	573.7600
9	2024-10-01	568.6200
9	2024-10-02	568.8600
9	2024-10-03	567.8200
9	2024-10-04	572.9800
9	2024-10-07	567.8000
9	2024-10-08	573.1700
9	2024-10-09	577.1400
9	2024-10-10	576.1300
9	2024-10-11	579.5800
9	2024-10-14	584.3200
9	2024-10-15	579.7800
9	2024-10-16	582.3000
9	2024-10-17	582.3500
9	2024-10-18	584.5900
9	2024-10-21	583.6300
9	2024-10-22	583.3200
9	2024-10-23	577.9900
9	2024-10-24	579.2400
9	2024-10-25	579.0400
9	2024-10-28	580.8300
9	2024-10-29	581.7700
9	2024-10-30	580.0100
9	2024-10-31	568.6400
9	2024-11-01	571.0400
9	2024-11-04	569.8100
9	2024-11-05	576.7000
9	2024-11-06	591.0400
9	2024-11-07	595.6100
9	2024-11-08	598.1900
9	2024-11-11	598.7600
9	2024-11-12	596.9000
9	2024-11-13	597.1900
9	2024-11-14	593.3500
9	2024-11-15	585.7500
9	2024-11-18	588.1500
9	2024-11-19	590.3000
9	2024-11-20	590.5000
9	2024-11-21	593.6700
9	2024-11-22	595.5100
9	2024-11-25	597.5300
9	2024-11-26	600.6500
9	2024-11-27	598.8300
9	2024-11-29	602.5500
9	2024-12-02	603.6300
9	2024-12-03	603.9100
9	2024-12-04	607.6600
9	2024-12-05	606.6600
9	2024-12-06	607.8100
9	2024-12-09	604.6800
9	2024-12-10	602.8000
9	2024-12-11	607.4600
9	2024-12-12	604.3300
9	2024-12-13	604.2100
9	2024-12-16	606.7900
9	2024-12-17	604.2900
9	2024-12-18	586.2800
9	2024-12-19	586.1000
9	2024-12-20	591.1500
9	2024-12-23	594.6900
9	2024-12-24	601.3000
9	2024-12-26	601.3400
9	2024-12-27	595.0100
9	2024-12-30	588.2200
9	2024-12-31	586.0800
9	2025-01-02	584.6400
9	2025-01-03	591.9500
9	2025-01-06	595.3600
9	2025-01-07	588.6300
9	2025-01-08	589.4900
9	2025-01-10	580.4900
9	2025-01-13	581.3900
9	2025-01-14	582.1900
9	2025-01-15	592.7800
9	2025-01-16	591.6400
9	2025-01-17	597.5800
9	2025-01-21	603.0500
9	2025-01-22	606.4400
9	2025-01-23	609.7500
9	2025-01-24	607.9700
9	2025-01-27	599.3700
9	2025-01-28	604.5200
9	2025-01-29	601.8100
9	2025-01-30	605.0400
9	2025-01-31	601.8200
9	2025-02-03	597.7700
9	2025-02-04	601.7800
9	2025-02-05	604.2200
9	2025-02-06	606.3200
9	2025-02-07	600.7700
9	2025-02-10	604.8500
9	2025-02-11	605.3100
9	2025-02-12	603.3600
9	2025-02-13	609.7300
9	2025-02-14	609.7000
9	2025-02-18	611.4900
9	2025-02-19	612.9300
9	2025-02-20	610.3800
9	2025-02-21	599.9400
9	2025-02-24	597.2100
9	2025-02-25	594.2400
9	2025-02-26	594.5400
9	2025-02-27	585.0500
9	2025-02-28	594.1800
9	2025-03-03	583.7700
9	2025-03-04	576.8600
9	2025-03-05	583.0600
9	2025-03-06	572.7100
9	2025-03-07	575.9200
9	2025-03-10	560.5800
9	2025-03-11	555.9200
9	2025-03-12	558.8700
9	2025-03-13	551.4200
9	2025-03-14	562.8100
9	2025-03-17	567.1500
9	2025-03-18	561.0200
9	2025-03-19	567.1300
9	2025-03-20	565.4900
9	2025-03-21	563.9800
9	2025-03-24	574.0800
9	2025-03-25	575.4600
9	2025-03-26	568.5900
9	2025-03-27	567.0800
9	2025-03-28	555.6600
9	2025-03-31	559.3900
9	2025-04-01	560.9700
9	2025-04-02	564.5200
9	2025-04-03	536.7000
9	2025-04-04	505.2800
9	2025-04-07	504.3800
9	2025-04-08	496.4800
9	2025-04-09	548.6200
9	2025-04-10	524.5800
9	2025-04-11	533.9400
9	2025-04-14	539.1200
9	2025-04-15	537.6100
9	2025-04-16	525.6600
9	2025-04-17	526.4100
9	2025-04-21	513.8800
9	2025-04-22	527.2500
9	2025-04-23	535.4200
9	2025-04-24	546.6900
9	2025-04-25	550.6400
9	2025-04-28	550.8500
9	2025-04-29	554.3200
9	2025-04-30	554.5400
9	2025-05-01	558.4700
9	2025-05-02	566.7600
9	2025-05-05	563.5100
9	2025-05-06	558.8000
9	2025-05-07	561.1500
9	2025-05-08	565.0600
9	2025-05-09	564.3400
9	2025-05-12	582.9900
9	2025-05-13	586.8400
9	2025-05-14	587.5900
9	2025-05-15	590.4600
9	2025-05-16	594.2000
9	2025-05-19	594.8500
9	2025-05-20	592.8500
9	2025-05-21	582.8600
9	2025-05-22	583.0900
9	2025-05-23	579.1100
9	2025-05-27	591.1500
9	2025-05-28	587.7300
9	2025-05-29	590.0500
9	2025-05-30	589.3900
9	2025-06-02	592.7100
9	2025-06-03	596.0900
9	2025-06-04	595.9300
9	2025-06-05	593.0500
9	2025-06-06	599.1400
9	2025-06-09	599.6800
9	2025-06-10	603.0800
9	2025-06-11	601.3600
9	2025-06-12	603.7500
9	2025-06-13	597.0000
9	2025-06-16	602.6800
9	2025-06-17	597.5300
9	2025-06-18	597.4400
9	2025-06-20	594.2800
9	2025-06-23	600.1500
9	2025-06-24	606.7800
9	2025-06-25	607.1200
9	2025-06-26	611.8700
9	2025-06-27	614.9100
9	2025-06-30	617.8500
9	2025-07-01	617.6500
9	2025-07-02	620.4500
9	2025-07-03	625.3400
9	2025-07-07	620.6800
9	2025-07-08	620.3400
9	2025-07-09	624.0600
9	2025-07-10	625.8200
9	2025-07-11	623.6200
9	2025-07-14	624.8100
9	2025-07-15	622.1400
9	2025-07-16	624.2200
9	2025-07-17	628.0400
9	2025-07-18	627.5800
9	2025-07-21	628.7700
9	2025-07-22	628.8600
9	2025-07-23	634.2100
9	2025-07-24	634.4200
9	2025-07-25	637.1000
9	2025-07-28	636.9400
9	2025-07-29	635.2600
9	2025-07-30	634.4600
9	2025-07-31	632.0800
9	2025-08-01	621.7200
9	2025-08-04	631.1700
9	2025-08-05	627.9700
9	2025-08-06	632.7800
9	2025-08-07	632.2500
9	2025-08-08	637.1800
9	2025-08-11	635.9200
9	2025-08-12	642.6900
9	2025-08-13	644.8900
9	2025-08-14	644.9500
9	2025-08-15	643.4400
9	2025-08-18	643.3000
9	2025-08-19	639.8100
9	2025-08-20	638.1100
9	2025-08-21	635.5500
9	2025-08-22	645.3100
9	2025-08-25	642.4700
9	2025-08-26	645.1600
9	2025-08-27	646.6300
9	2025-08-28	648.9200
9	2025-08-29	645.0500
9	2025-09-02	640.2700
9	2025-09-03	643.7400
9	2025-09-04	649.1200
9	2025-09-05	647.2400
9	2025-09-08	648.8300
9	2025-09-09	650.3300
9	2025-09-10	652.2100
9	2025-09-11	657.6300
9	2025-09-12	657.4100
9	2025-09-15	660.9100
9	2025-09-16	660.0000
9	2025-09-17	659.1800
9	2025-09-18	662.2600
9	2025-09-19	663.7000
9	2025-09-22	666.8400
9	2025-09-23	663.2100
9	2025-09-24	661.1000
9	2025-09-25	658.0500
9	2025-09-26	661.8200
9	2025-09-29	663.6800
9	2025-09-30	666.1800
9	2025-10-01	668.4500
9	2025-10-02	669.2200
9	2025-10-03	669.2100
9	2025-10-06	671.6100
9	2025-10-07	669.1200
9	2025-10-08	673.1100
9	2025-10-09	671.1600
9	2025-10-10	653.0200
9	2025-10-13	663.0400
9	2025-10-14	662.2300
9	2025-10-15	665.1700
9	2025-10-16	660.6400
9	2025-10-17	664.3900
9	2025-10-20	671.3000
9	2025-10-21	671.2900
9	2025-10-22	667.8000
9	2025-10-23	671.7600
9	2025-10-24	677.2500
9	2025-10-27	685.2400
9	2025-10-28	687.0600
9	2025-10-29	687.3900
9	2025-10-30	679.8300
9	2025-10-31	682.0600
9	2025-11-03	683.3400
9	2025-11-04	675.2400
9	2025-11-05	677.5800
9	2025-11-06	670.3100
9	2025-11-07	670.9700
9	2025-11-10	681.4400
9	2025-11-11	683.0000
9	2025-11-12	683.3800
9	2025-11-13	672.0400
9	2025-11-14	671.9300
9	2025-11-17	665.6700
9	2025-11-18	660.0800
9	2025-11-19	662.6300
9	2025-11-20	652.5300
9	2025-11-21	659.0300
9	2025-11-24	668.7300
9	2025-11-25	675.0200
9	2025-11-26	679.6800
9	2025-11-28	683.3900
9	2025-12-01	680.2700
9	2025-12-02	681.5300
9	2025-12-03	683.8900
9	2025-12-04	684.3900
9	2025-12-05	685.6900
9	2025-12-08	683.6300
9	2025-12-09	683.0400
9	2025-12-10	687.5700
9	2025-12-11	689.1700
9	2025-12-12	681.7600
9	2025-12-15	680.7300
9	2025-12-16	678.8700
9	2025-12-17	671.4000
9	2025-12-18	676.4700
9	2025-12-19	680.5900
9	2025-12-22	684.8300
9	2025-12-23	687.9600
9	2025-12-24	690.3800
9	2025-12-26	690.3100
9	2025-12-29	687.8500
9	2025-12-30	687.0100
9	2025-12-31	681.9200
9	2026-01-02	683.1700
9	2026-01-05	687.7200
9	2026-01-06	691.8100
9	2026-01-07	689.5800
9	2026-01-08	689.5100
9	2026-01-09	694.0700
9	2026-01-12	695.1600
9	2026-01-13	693.7700
9	2026-01-14	690.3600
9	2026-01-15	692.2400
9	2026-01-16	691.6600
9	2026-01-20	677.5800
9	2026-01-21	685.4000
9	2026-01-22	688.9800
9	2026-01-23	689.2300
9	2026-01-26	692.7300
9	2026-01-27	695.4900
9	2026-01-28	695.4200
9	2026-01-29	694.0400
9	2026-01-30	691.9700
9	2026-02-02	695.4100
9	2026-02-03	689.5300
9	2026-02-04	686.1900
9	2026-02-05	677.6200
9	2026-02-06	690.6200
9	2026-02-09	693.9500
9	2026-02-10	692.1200
9	2026-02-11	691.9600
9	2026-02-12	681.2700
9	2026-02-13	681.7500
9	2026-02-17	682.8500
9	2026-02-18	686.2900
9	2026-02-19	684.4800
9	2026-02-20	689.4300
9	2026-02-23	682.3900
9	2026-02-24	687.3500
9	2026-02-25	693.1500
9	2026-02-26	689.3000
9	2026-02-27	685.9900
9	2026-03-02	686.3800
9	2026-03-03	680.3300
9	2026-03-04	685.1300
9	2026-03-05	681.3100
9	2026-03-06	672.3800
9	2026-03-09	678.2700
9	2026-03-10	677.1800
9	2026-03-11	676.3300
9	2026-03-12	666.0600
9	2026-03-13	662.2900
9	2026-03-16	669.0300
9	2026-03-17	670.7900
9	2026-03-18	661.4300
9	2026-03-19	659.8000
9	2026-03-20	648.5700
9	2026-03-23	655.3800
9	2026-03-24	653.1800
9	2026-03-25	656.8200
9	2026-03-26	645.0900
9	2026-03-27	634.0900
9	2026-03-30	631.9700
9	2026-03-31	650.3400
9	2026-04-01	655.2400
9	2026-04-02	655.8300
9	2026-04-06	658.9300
9	2026-04-07	659.2200
9	2026-04-08	676.0100
9	2026-04-09	679.9100
9	2026-04-10	679.4600
9	2026-04-13	686.1000
9	2026-04-14	694.4600
9	2026-04-15	699.9400
9	2026-04-16	701.6600
9	2026-04-17	710.1400
9	2026-04-20	708.7200
9	2026-04-21	704.0800
9	2026-04-22	711.2100
9	2026-04-23	708.4500
9	2026-04-24	713.9400
9	2026-04-27	715.1700
9	2026-04-28	711.6900
9	2026-04-29	711.5800
9	2026-04-30	718.6600
9	2026-05-01	720.6500
9	2026-05-04	718.0100
9	2026-05-05	723.7700
9	2026-05-06	733.8300
9	2026-05-07	731.5800
9	2026-05-08	737.6200
9	2026-05-11	739.3000
9	2026-05-12	738.1800
9	2026-05-13	742.3100
9	2026-05-14	748.1700
9	2026-05-15	739.1700
9	2026-05-18	738.6500
9	2026-05-19	733.7300
9	2026-05-20	741.2500
9	2026-05-21	742.7200
9	2026-05-22	745.6400
9	2026-05-26	750.5900
9	2026-05-27	750.4600
9	2026-05-28	754.6000
9	2026-05-29	756.4800
9	2026-06-01	758.5400
9	2026-06-02	759.5700
9	2026-06-03	754.2400
9	2026-06-04	757.0900
9	2026-06-05	737.5500
9	2026-06-08	739.2200
9	2026-06-09	737.0500
9	2026-06-10	725.4300
9	2026-06-11	737.7600
9	2026-06-12	741.7500
9	2026-06-15	754.8300
9	2026-06-16	750.3300
9	2026-06-17	740.9600
9	2026-06-18	746.7400
9	2026-06-22	744.3900
9	2026-06-23	733.5800
9	2026-06-24	733.2400
9	2026-06-25	734.3000
9	2026-06-26	728.9900
9	2026-06-29	741.0000
9	2026-06-30	746.7700
9	2026-07-01	745.7600
9	2026-07-02	744.7800
9	2026-07-06	751.2800
9	2026-07-07	747.7100
9	2026-07-08	745.4000
9	2026-07-09	751.7100
9	2026-07-10	754.9500
9	2026-07-13	749.1700
9	2026-07-14	751.8300
9	2026-07-15	754.8100
9	2026-07-16	750.7200
9	2026-07-17	743.2900
9	2026-07-20	742.0900
9	2026-07-21	748.2800
9	2026-07-22	747.4100
9	2026-07-23	738.1800
9	2026-07-24	738.9300
9	2026-07-27	739.0900
9	2026-07-28	740.8600
9	2026-07-29	729.4600
9	2026-07-30	741.6900
9	2026-07-31	747.0300
9	2026-08-03	757.6700
9	2026-08-04	771.3300
9	2026-08-05	769.7900
9	2026-08-06	768.5600
9	2026-08-07	773.2600
9	2026-08-10	773.0300
9	2026-08-11	770.5600
9	2026-08-12	772.4900
9	2026-08-13	777.8800
9	2026-08-14	776.3400
9	2026-08-17	772.6700
9	2026-08-18	767.4500
9	2026-08-19	769.0600
9	2026-08-20	762.6000
9	2026-08-21	765.7200
9	2026-08-24	763.4700
9	2026-08-25	765.9100
9	2026-08-26	766.0800
9	2026-08-27	771.1000
9	2026-08-28	769.3500
9	2026-08-31	767.0500
9	2026-09-01	761.7800
9	2026-09-02	765.1600
9	2026-09-03	773.1700
9	2026-09-04	770.1900
9	2026-09-08	765.9600
9	2026-09-09	762.4000
9	2026-09-10	757.8300
9	2026-09-11	764.2900
9	2026-09-14	760.8800
9	2026-09-15	757.3900
9	2026-09-16	754.0500
9	2026-09-17	762.6000
9	2026-09-18	761.6900
9	2026-09-21	773.5000
9	2026-09-22	773.3800
9	2026-09-23	767.8100
9	2026-09-24	767.1800
9	2026-09-25	771.3500
9	2026-09-28	765.6100
9	2026-09-29	764.2000
9	2026-09-30	762.6300
9	2026-10-01	763.9900
9	2026-10-02	769.6400
9	2026-10-05	774.8300
9	2026-10-06	779.0900
9	2026-10-07	777.2200
9	2026-10-08	773.9300
9	2026-10-09	778.5700
9	2026-10-12	778.1000
9	2026-10-13	778.0100
9	2026-10-14	769.6000
9	2026-10-15	771.7900
9	2026-10-16	763.2500
9	2026-10-19	766.4800
9	2026-10-20	769.0500
9	2026-10-21	773.0900
9	2026-10-22	763.9600
9	2026-10-23	759.9700
9	2026-10-26	765.3700
9	2026-10-27	769.6600
9	2026-10-28	772.3100
9	2026-10-29	769.3600
9	2026-10-30	755.7200
9	2026-11-02	752.1000
9	2026-11-03	754.3500
9	2026-11-04	766.8100
9	2026-11-05	733.0000
9	2026-11-06	735.2900
9	2026-11-09	752.6900
9	2026-11-10	749.9200
9	2026-11-11	759.8100
9	2026-11-12	757.1200
9	2026-11-13	754.3700
9	2026-11-16	739.9500
10	2024-01-02	402.5900
10	2024-01-03	398.3300
10	2024-01-04	396.2800
10	2024-01-05	396.7500
10	2024-01-08	404.9500
10	2024-01-09	405.7500
10	2024-01-10	408.5000
10	2024-01-11	409.3500
10	2024-01-12	409.5600
10	2024-01-16	409.5200
10	2024-01-17	407.2100
10	2024-01-18	412.9900
10	2024-01-19	421.1800
10	2024-01-22	421.7300
10	2024-01-23	423.4800
10	2024-01-24	425.8300
10	2024-01-25	426.3500
10	2024-01-26	423.8100
10	2024-01-29	428.1500
10	2024-01-30	425.3000
10	2024-01-31	416.9700
10	2024-02-01	421.8800
10	2024-02-02	429.0100
10	2024-02-05	428.4500
10	2024-02-06	427.5900
10	2024-02-07	431.9900
10	2024-02-08	432.7900
10	2024-02-09	437.0500
10	2024-02-12	435.3400
10	2024-02-13	428.5500
10	2024-02-14	433.2200
10	2024-02-15	434.5100
10	2024-02-16	430.5700
10	2024-02-20	427.3200
10	2024-02-21	425.6100
10	2024-02-22	438.0700
10	2024-02-23	436.7800
10	2024-02-26	436.5500
10	2024-02-27	437.6000
10	2024-02-28	435.2700
10	2024-02-29	439.0000
10	2024-03-01	445.6100
10	2024-03-04	444.0200
10	2024-03-05	436.0500
10	2024-03-06	438.7900
10	2024-03-07	445.4500
10	2024-03-08	439.0200
10	2024-03-11	437.3900
10	2024-03-12	443.6600
10	2024-03-13	440.2500
10	2024-03-14	439.1400
10	2024-03-15	433.9200
10	2024-03-18	437.4800
10	2024-03-19	438.5700
10	2024-03-20	443.7700
10	2024-03-21	445.8700
10	2024-03-22	446.3800
10	2024-03-25	444.7600
10	2024-03-26	443.3200
10	2024-03-27	444.8300
10	2024-03-28	444.0100
10	2024-04-01	444.9500
10	2024-04-02	441.1100
10	2024-04-03	442.1000
10	2024-04-04	435.3400
10	2024-04-05	440.4700
10	2024-04-08	440.6000
10	2024-04-09	442.2300
10	2024-04-10	438.3700
10	2024-04-11	445.3700
10	2024-04-12	438.2700
10	2024-04-15	431.0600
10	2024-04-16	431.1000
10	2024-04-17	425.8400
10	2024-04-18	423.4100
10	2024-04-19	414.6500
10	2024-04-22	418.8200
10	2024-04-23	425.0700
10	2024-04-24	426.5100
10	2024-04-25	424.4500
10	2024-04-26	431.0000
10	2024-04-29	432.7500
10	2024-04-30	424.5900
10	2024-05-01	421.5200
10	2024-05-02	426.9000
10	2024-05-03	435.4800
10	2024-05-06	440.2500
10	2024-05-07	440.3200
10	2024-05-08	440.0600
10	2024-05-09	441.0200
10	2024-05-10	442.0600
10	2024-05-13	443.0800
10	2024-05-14	445.9300
10	2024-05-15	452.9000
10	2024-05-16	451.9800
10	2024-05-17	451.7600
10	2024-05-20	454.9100
10	2024-05-21	455.8000
10	2024-05-22	455.7100
10	2024-05-23	453.6600
10	2024-05-24	457.9500
10	2024-05-28	459.6800
10	2024-05-29	456.4400
10	2024-05-30	451.5500
10	2024-05-31	450.7100
10	2024-06-03	453.1300
10	2024-06-04	454.3700
10	2024-06-05	463.5300
10	2024-06-06	463.3700
10	2024-06-07	462.9600
10	2024-06-10	464.8300
10	2024-06-11	468.0200
10	2024-06-12	474.1500
10	2024-06-13	476.7200
10	2024-06-14	479.1900
10	2024-06-17	485.0600
10	2024-06-18	485.2100
10	2024-06-20	481.4700
10	2024-06-21	480.1800
10	2024-06-24	473.9600
10	2024-06-25	479.3800
10	2024-06-26	480.3700
10	2024-06-27	481.6100
10	2024-06-28	479.1100
10	2024-07-01	481.9200
10	2024-07-02	486.9800
10	2024-07-03	491.0400
10	2024-07-05	496.1600
10	2024-07-08	497.3400
10	2024-07-09	497.7700
10	2024-07-10	502.9600
10	2024-07-11	491.9300
10	2024-07-12	494.8200
10	2024-07-15	496.1500
10	2024-07-16	496.3400
10	2024-07-17	481.7700
10	2024-07-18	479.4900
10	2024-07-19	475.2400
10	2024-07-22	482.3200
10	2024-07-23	480.6200
10	2024-07-24	463.3800
10	2024-07-25	458.2700
10	2024-07-26	462.9700
10	2024-07-29	463.9000
10	2024-07-30	457.5300
10	2024-07-31	471.0700
10	2024-08-01	459.6600
10	2024-08-02	448.7500
10	2024-08-05	435.3700
10	2024-08-06	439.5300
10	2024-08-07	434.7700
10	2024-08-08	448.0700
10	2024-08-09	450.4100
10	2024-08-12	451.3800
10	2024-08-13	462.5800
10	2024-08-14	462.7300
10	2024-08-15	474.4200
10	2024-08-16	475.0300
10	2024-08-19	481.2700
10	2024-08-20	480.2600
10	2024-08-21	482.5000
10	2024-08-22	474.8500
10	2024-08-23	480.0000
10	2024-08-26	475.3400
10	2024-08-27	476.7600
10	2024-08-28	471.3500
10	2024-08-29	470.6600
10	2024-08-30	476.2700
10	2024-09-03	461.8100
10	2024-09-04	460.6100
10	2024-09-05	461.0400
10	2024-09-06	448.6900
10	2024-09-09	454.4600
10	2024-09-10	458.6600
10	2024-09-11	468.6200
10	2024-09-12	473.2200
10	2024-09-13	475.3400
10	2024-09-16	473.2400
10	2024-09-17	473.4900
10	2024-09-18	471.4400
10	2024-09-19	483.3600
10	2024-09-20	482.4400
10	2024-09-23	483.0400
10	2024-09-24	485.3700
10	2024-09-25	485.8200
10	2024-09-26	489.4700
10	2024-09-27	486.7500
10	2024-09-30	488.0700
10	2024-10-01	481.2700
10	2024-10-02	481.9500
10	2024-10-03	481.5900
10	2024-10-04	487.3200
10	2024-10-07	482.1000
10	2024-10-08	489.3000
10	2024-10-09	493.1500
10	2024-10-10	492.5900
10	2024-10-11	493.3600
10	2024-10-14	497.5000
10	2024-10-15	490.8500
10	2024-10-16	490.9100
10	2024-10-17	491.2500
10	2024-10-18	494.4700
10	2024-10-21	495.4200
10	2024-10-22	495.9600
10	2024-10-23	488.3600
10	2024-10-24	492.3200
10	2024-10-25	495.3200
10	2024-10-28	495.4000
10	2024-10-29	500.1600
10	2024-10-30	496.3800
10	2024-10-31	483.8500
10	2024-11-01	487.4300
10	2024-11-04	486.0100
10	2024-11-05	492.2100
10	2024-11-06	505.5800
10	2024-11-07	513.5400
10	2024-11-08	514.1400
10	2024-11-11	513.8400
10	2024-11-12	512.9100
10	2024-11-13	512.2500
10	2024-11-14	508.6900
10	2024-11-15	496.5700
10	2024-11-18	500.0200
10	2024-11-19	503.4600
10	2024-11-20	503.1700
10	2024-11-21	504.9800
10	2024-11-22	505.7900
10	2024-11-25	506.5900
10	2024-11-26	509.3100
10	2024-11-27	505.3000
10	2024-11-29	509.7400
10	2024-12-02	515.2900
10	2024-12-03	516.8700
10	2024-12-04	523.2600
10	2024-12-05	521.8100
10	2024-12-06	526.4800
10	2024-12-09	522.3800
10	2024-12-10	520.6000
10	2024-12-11	529.9200
10	2024-12-12	526.5000
10	2024-12-13	530.5300
10	2024-12-16	538.1700
10	2024-12-17	535.8000
10	2024-12-18	516.4700
10	2024-12-19	514.1700
10	2024-12-20	518.6600
10	2024-12-23	522.8700
10	2024-12-24	529.9600
10	2024-12-26	529.6000
10	2024-12-27	522.5600
10	2024-12-30	515.6100
10	2024-12-31	511.2300
10	2025-01-02	510.2300
10	2025-01-03	518.5800
10	2025-01-06	524.5400
10	2025-01-07	515.1800
10	2025-01-08	515.2700
10	2025-01-10	507.1900
10	2025-01-13	505.5600
10	2025-01-14	505.0800
10	2025-01-15	516.7000
10	2025-01-16	513.0800
10	2025-01-17	521.7400
10	2025-01-21	524.8000
10	2025-01-22	531.5100
10	2025-01-23	532.6400
10	2025-01-24	529.6300
10	2025-01-27	514.2100
10	2025-01-28	521.8100
10	2025-01-29	520.8300
10	2025-01-30	523.0500
10	2025-01-31	522.2900
10	2025-02-03	518.1100
10	2025-02-04	524.4700
10	2025-02-05	526.8500
10	2025-02-06	529.6000
10	2025-02-07	522.9200
10	2025-02-10	529.2500
10	2025-02-11	527.9900
10	2025-02-12	528.3000
10	2025-02-13	535.9000
10	2025-02-14	538.1500
10	2025-02-18	539.3700
10	2025-02-19	539.5200
10	2025-02-20	537.2300
10	2025-02-21	526.0800
10	2025-02-24	519.8700
10	2025-02-25	513.3200
10	2025-02-26	514.5600
10	2025-02-27	500.2700
10	2025-02-28	508.1700
10	2025-03-03	497.0500
10	2025-03-04	495.5500
10	2025-03-05	502.0100
10	2025-03-06	488.2000
10	2025-03-07	491.7900
10	2025-03-10	472.7300
10	2025-03-11	471.6000
10	2025-03-12	476.9200
10	2025-03-13	468.3400
10	2025-03-14	479.6600
10	2025-03-17	482.7700
10	2025-03-18	474.5400
10	2025-03-19	480.8900
10	2025-03-20	479.2600
10	2025-03-21	480.8400
10	2025-03-24	490.6600
10	2025-03-25	493.4600
10	2025-03-26	484.3800
10	2025-03-27	481.6200
10	2025-03-28	468.9400
10	2025-03-31	468.9200
10	2025-04-01	472.7000
10	2025-04-02	476.1500
10	2025-04-03	450.6600
10	2025-04-04	422.6700
10	2025-04-07	423.6900
10	2025-04-08	416.0600
10	2025-04-09	466.0000
10	2025-04-10	446.1800
10	2025-04-11	454.4000
10	2025-04-14	457.4800
10	2025-04-15	457.9900
10	2025-04-16	444.1800
10	2025-04-17	444.1000
10	2025-04-21	433.1100
10	2025-04-22	444.4800
10	2025-04-23	454.5600
10	2025-04-24	467.3500
10	2025-04-25	472.5600
10	2025-04-28	472.4100
10	2025-04-29	475.5300
10	2025-04-30	475.4700
10	2025-05-01	481.6800
10	2025-05-02	488.8300
10	2025-05-05	485.9300
10	2025-05-06	481.4100
10	2025-05-07	483.3000
10	2025-05-08	488.2900
10	2025-05-09	487.9700
10	2025-05-12	507.8500
10	2025-05-13	515.5900
10	2025-05-14	518.6800
10	2025-05-15	519.2500
10	2025-05-16	521.5100
10	2025-05-19	522.0100
10	2025-05-20	520.2700
10	2025-05-21	513.0400
10	2025-05-22	514.0000
10	2025-05-23	509.2400
10	2025-05-27	521.2200
10	2025-05-28	518.9100
10	2025-05-29	519.9300
10	2025-05-30	519.1100
10	2025-06-02	523.2100
10	2025-06-03	527.3000
10	2025-06-04	528.7700
10	2025-06-05	524.7900
10	2025-06-06	529.9200
10	2025-06-09	530.7000
10	2025-06-10	534.2100
10	2025-06-11	532.4100
10	2025-06-12	533.6600
10	2025-06-13	526.9600
10	2025-06-16	534.2900
10	2025-06-17	529.0800
10	2025-06-18	528.9900
10	2025-06-20	526.8300
10	2025-06-23	531.6500
10	2025-06-24	539.7800
10	2025-06-25	541.1600
10	2025-06-26	546.2200
10	2025-06-27	548.0900
10	2025-06-30	551.6400
10	2025-07-01	546.9900
10	2025-07-02	550.8000
10	2025-07-03	556.2200
10	2025-07-07	552.0300
10	2025-07-08	552.3400
10	2025-07-09	556.2500
10	2025-07-10	555.4500
10	2025-07-11	554.2000
10	2025-07-14	556.2100
10	2025-07-15	556.7200
10	2025-07-16	557.2900
10	2025-07-17	561.8000
10	2025-07-18	561.2600
10	2025-07-21	564.1700
10	2025-07-22	561.2500
10	2025-07-23	563.8100
10	2025-07-24	565.0100
10	2025-07-25	566.3700
10	2025-07-28	568.1400
10	2025-07-29	567.2600
10	2025-07-30	568.0200
10	2025-07-31	565.0100
10	2025-08-01	553.8800
10	2025-08-04	564.1000
10	2025-08-05	560.2700
10	2025-08-06	567.3200
10	2025-08-07	569.2400
10	2025-08-08	574.5500
10	2025-08-11	572.8500
10	2025-08-12	580.0500
10	2025-08-13	580.3400
10	2025-08-14	579.8900
10	2025-08-15	577.3400
10	2025-08-18	577.1100
10	2025-08-19	569.2800
10	2025-08-20	565.9000
10	2025-08-21	563.2800
10	2025-08-22	571.9700
10	2025-08-25	570.3200
10	2025-08-26	572.6100
10	2025-08-27	573.4900
10	2025-08-28	577.0800
10	2025-08-29	570.4000
10	2025-09-02	565.6200
10	2025-09-03	570.0700
10	2025-09-04	575.2300
10	2025-09-05	576.0600
10	2025-09-08	578.8700
10	2025-09-09	580.5100
10	2025-09-10	580.7000
10	2025-09-11	584.0800
10	2025-09-12	586.6600
10	2025-09-15	591.6800
10	2025-09-16	591.1800
10	2025-09-17	590.0000
10	2025-09-18	595.3200
10	2025-09-19	599.3500
10	2025-09-22	602.2000
10	2025-09-23	598.2000
10	2025-09-24	596.1000
10	2025-09-25	593.5300
10	2025-09-26	595.9700
10	2025-09-29	598.7300
10	2025-09-30	600.3700
10	2025-10-01	603.2500
10	2025-10-02	605.7300
10	2025-10-03	603.1800
10	2025-10-06	607.7100
10	2025-10-07	604.5100
10	2025-10-08	611.4400
10	2025-10-09	610.7000
10	2025-10-10	589.5000
10	2025-10-13	602.0100
10	2025-10-14	598.0000
10	2025-10-15	602.2200
10	2025-10-16	599.9900
10	2025-10-17	603.9300
10	2025-10-20	611.5400
10	2025-10-21	611.3800
10	2025-10-22	605.4900
10	2025-10-23	610.5800
10	2025-10-24	617.1000
10	2025-10-27	628.0900
10	2025-10-28	632.9200
10	2025-10-29	635.7700
10	2025-10-30	626.0500
10	2025-10-31	629.0700
10	2025-11-03	632.0800
10	2025-11-04	619.2500
10	2025-11-05	623.2800
10	2025-11-06	611.6700
10	2025-11-07	609.7400
10	2025-11-10	623.2300
10	2025-11-11	621.5700
10	2025-11-12	621.0800
10	2025-11-13	608.4000
10	2025-11-14	608.8600
10	2025-11-17	603.6600
10	2025-11-18	596.3100
10	2025-11-19	599.8700
10	2025-11-20	585.6700
10	2025-11-21	590.0700
10	2025-11-24	605.1600
10	2025-11-25	608.8900
10	2025-11-26	614.2700
10	2025-11-28	619.2500
10	2025-12-01	617.1700
10	2025-12-02	622.0000
10	2025-12-03	623.5200
10	2025-12-04	622.9400
10	2025-12-05	625.4800
10	2025-12-08	624.2800
10	2025-12-09	625.0500
10	2025-12-10	627.6100
10	2025-12-11	625.5800
10	2025-12-12	613.6200
10	2025-12-15	610.5400
10	2025-12-16	611.7500
10	2025-12-17	600.4100
10	2025-12-18	609.1100
10	2025-12-19	617.0500
10	2025-12-22	619.2100
10	2025-12-23	622.1100
10	2025-12-24	623.9300
10	2025-12-26	623.8900
10	2025-12-29	620.8700
10	2025-12-30	619.4300
10	2025-12-31	614.3100
10	2026-01-02	613.1200
10	2026-01-05	617.9900
10	2026-01-06	623.4200
10	2026-01-07	624.0200
10	2026-01-08	620.4700
10	2026-01-09	626.6500
10	2026-01-12	627.1700
10	2026-01-13	626.2400
10	2026-01-14	619.5500
10	2026-01-15	621.7800
10	2026-01-16	621.2600
10	2026-01-20	608.0600
10	2026-01-21	616.2800
10	2026-01-22	620.7600
10	2026-01-23	622.7200
10	2026-01-26	625.4600
10	2026-01-27	631.1300
10	2026-01-28	633.2200
10	2026-01-29	629.4300
10	2026-01-30	621.8700
10	2026-02-02	626.1400
10	2026-02-03	616.5200
10	2026-02-04	605.7500
10	2026-02-05	597.0300
10	2026-02-06	609.6500
10	2026-02-09	614.3200
10	2026-02-10	611.4700
10	2026-02-11	613.1100
10	2026-02-12	600.6400
10	2026-02-13	601.9200
10	2026-02-17	601.3000
10	2026-02-18	605.7900
10	2026-02-19	603.4700
10	2026-02-20	608.8100
10	2026-02-23	601.4100
10	2026-02-24	607.8700
10	2026-02-25	616.6800
10	2026-02-26	609.2400
10	2026-02-27	607.2900
10	2026-03-02	608.0900
10	2026-03-03	601.5800
10	2026-03-04	610.7500
10	2026-03-05	608.9100
10	2026-03-06	599.7500
10	2026-03-09	607.7600
10	2026-03-10	607.7700
10	2026-03-11	607.6900
10	2026-03-12	597.2600
10	2026-03-13	593.7200
10	2026-03-16	600.3800
10	2026-03-17	603.3100
10	2026-03-18	594.9000
10	2026-03-19	593.0200
10	2026-03-20	582.0600
10	2026-03-23	588.0000
10	2026-03-24	583.9800
10	2026-03-25	587.8200
10	2026-03-26	573.7900
10	2026-03-27	562.5800
10	2026-03-30	558.2800
10	2026-03-31	577.1800
10	2026-04-01	584.3100
10	2026-04-02	584.9800
10	2026-04-06	588.5000
10	2026-04-07	588.5900
10	2026-04-08	606.0900
10	2026-04-09	610.1900
10	2026-04-10	611.0700
10	2026-04-13	617.3900
10	2026-04-14	628.6000
10	2026-04-15	637.4000
10	2026-04-16	640.4700
10	2026-04-17	648.8500
10	2026-04-20	646.7900
10	2026-04-21	644.3300
10	2026-04-22	655.1100
10	2026-04-23	651.4200
10	2026-04-24	663.8800
10	2026-04-27	664.2300
10	2026-04-28	657.5500
10	2026-04-29	661.5700
10	2026-04-30	667.7400
10	2026-05-01	674.1500
10	2026-05-04	672.8800
10	2026-05-05	681.6100
10	2026-05-06	695.7700
10	2026-05-07	694.9400
10	2026-05-08	711.2300
10	2026-05-11	713.2900
10	2026-05-12	707.2400
10	2026-05-13	714.7100
10	2026-05-14	719.7900
10	2026-05-15	708.9300
10	2026-05-18	705.8800
10	2026-05-19	701.5300
10	2026-05-20	713.1500
10	2026-05-21	714.5100
10	2026-05-22	717.5400
10	2026-05-26	730.2800
10	2026-05-27	729.4500
10	2026-05-28	735.6000
10	2026-05-29	738.3100
10	2026-06-01	742.7400
10	2026-06-02	746.1600
10	2026-06-03	744.2100
10	2026-06-04	740.6100
10	2026-06-05	705.0600
10	2026-06-08	716.0700
10	2026-06-09	707.8300
10	2026-06-10	693.6900
10	2026-06-11	717.1200
10	2026-06-12	721.3400
10	2026-06-15	744.0000
10	2026-06-16	729.8600
10	2026-06-17	722.5100
10	2026-06-18	740.6200
10	2026-06-22	737.9500
10	2026-06-23	713.6500
10	2026-06-24	710.6200
10	2026-06-25	716.3800
10	2026-06-26	706.5200
10	2026-06-29	724.0800
10	2026-06-30	736.4000
10	2026-07-01	725.1700
10	2026-07-02	712.6000
10	2026-07-06	722.8200
10	2026-07-07	709.4300
10	2026-07-08	711.4400
10	2026-07-09	723.2800
10	2026-07-10	725.5100
10	2026-07-13	711.7400
10	2026-07-14	719.6900
10	2026-07-15	717.7400
10	2026-07-16	705.9400
10	2026-07-17	695.3300
10	2026-07-20	696.0600
10	2026-07-21	708.9700
10	2026-07-22	705.3500
10	2026-07-23	691.9600
10	2026-07-24	684.2300
10	2026-07-27	682.1200
10	2026-07-28	675.4900
10	2026-07-29	661.7300
10	2026-07-30	683.5500
10	2026-07-31	687.9900
10	2026-08-03	700.0700
10	2026-08-04	723.8500
10	2026-08-05	717.3000
10	2026-08-06	714.6500
10	2026-08-07	723.0300
10	2026-08-10	720.8700
10	2026-08-11	718.4500
10	2026-08-12	723.7000
10	2026-08-13	732.0700
10	2026-08-14	731.0700
10	2026-08-17	729.8700
10	2026-08-18	717.5100
10	2026-08-19	716.0800
10	2026-08-20	710.9300
10	2026-08-21	713.4400
10	2026-08-24	706.3200
10	2026-08-25	710.7200
10	2026-08-26	711.3700
10	2026-08-27	721.1100
10	2026-08-28	716.4300
10	2026-08-31	716.7600
10	2026-09-01	707.6400
10	2026-09-02	709.2400
10	2026-09-03	717.6700
10	2026-09-04	718.9600
10	2026-09-08	718.3600
10	2026-09-09	716.3100
10	2026-09-10	708.6900
10	2026-09-11	714.8800
10	2026-09-14	709.1800
10	2026-09-15	704.5400
10	2026-09-16	704.7200
10	2026-09-17	716.9200
10	2026-09-18	721.4500
10	2026-09-21	741.4700
10	2026-09-22	747.4600
10	2026-09-23	741.2100
10	2026-09-24	741.1000
10	2026-09-25	744.5000
10	2026-09-28	736.5300
10	2026-09-29	737.9300
10	2026-09-30	739.7700
10	2026-10-01	742.0300
10	2026-10-02	749.5800
10	2026-10-05	756.2000
10	2026-10-06	759.6600
10	2026-10-07	757.7300
10	2026-10-08	747.5800
10	2026-10-09	751.2700
10	2026-10-12	746.0400
10	2026-10-13	743.5700
10	2026-10-14	728.9500
10	2026-10-15	728.0000
10	2026-10-16	709.8000
10	2026-10-19	718.3600
10	2026-10-20	717.6300
10	2026-10-21	725.2000
10	2026-10-22	704.4700
10	2026-10-23	704.4000
10	2026-10-26	712.2000
10	2026-10-27	721.2500
10	2026-10-28	725.6100
10	2026-10-29	715.3400
10	2026-10-30	690.4900
10	2026-11-02	681.0900
10	2026-11-03	685.2800
10	2026-11-04	691.9500
10	2026-11-05	647.0500
10	2026-11-06	656.1000
10	2026-11-09	679.3500
10	2026-11-10	674.7600
10	2026-11-11	690.3800
10	2026-11-12	688.1700
10	2026-11-13	679.8900
10	2026-11-16	661.7500
\.


--
-- Data for Name: rendimiento; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.rendimiento (id_rendimiento, id_cuenta, id_activo, fecha, tipo_rendimiento, monto) FROM stdin;
1	40	4	2024-02-14	DIVIDENDO	26.25
2	16	8	2024-02-16	DIVIDENDO	123.76
3	15	9	2024-03-15	DIVIDENDO	89.32
4	15	10	2024-03-18	DIVIDENDO	37.82
5	69	10	2024-03-18	DIVIDENDO	3.44
6	70	10	2024-03-18	DIVIDENDO	6.30
7	29	2	2024-03-28	DIVIDENDO	465.68
8	51	2	2024-03-28	DIVIDENDO	213.82
9	15	1	2024-04-04	DIVIDENDO	2152.80
10	51	1	2024-04-04	DIVIDENDO	1003.20
11	19	3	2024-05-10	DIVIDENDO	7.25
12	66	3	2024-05-10	DIVIDENDO	22.50
13	5	4	2024-05-15	DIVIDENDO	15.00
14	22	4	2024-05-15	DIVIDENDO	4.50
15	40	4	2024-05-15	DIVIDENDO	33.75
16	49	4	2024-05-15	DIVIDENDO	3.00
17	16	8	2024-05-20	DIVIDENDO	63.24
18	19	8	2024-05-20	DIVIDENDO	44.64
19	29	8	2024-05-20	DIVIDENDO	133.92
20	59	8	2024-05-20	DIVIDENDO	163.68
21	19	6	2024-06-10	DIVIDENDO	6.40
22	59	6	2024-06-10	DIVIDENDO	23.20
23	6	9	2024-06-21	DIVIDENDO	253.30
24	15	9	2024-06-21	DIVIDENDO	98.50
25	26	9	2024-06-21	DIVIDENDO	31.66
26	8	10	2024-06-24	DIVIDENDO	15.24
27	15	10	2024-06-24	DIVIDENDO	50.29
28	42	10	2024-06-24	DIVIDENDO	13.72
29	59	10	2024-06-24	DIVIDENDO	33.53
30	69	10	2024-06-24	DIVIDENDO	3.81
31	70	10	2024-06-24	DIVIDENDO	8.38
32	15	1	2024-06-25	DIVIDENDO	2152.80
33	20	1	2024-06-25	DIVIDENDO	576.80
34	51	1	2024-06-25	DIVIDENDO	1003.20
35	8	2	2024-06-27	DIVIDENDO	240.16
36	29	2	2024-06-27	DIVIDENDO	901.04
37	40	2	2024-06-27	DIVIDENDO	122.71
38	6	12	2024-07-01	INTERES	3290.71
39	16	12	2024-07-01	INTERES	1417.54
40	49	12	2024-07-01	INTERES	286.88
41	51	12	2024-07-01	INTERES	1029.40
42	70	12	2024-07-01	INTERES	675.02
43	5	3	2024-08-12	DIVIDENDO	2.25
44	19	3	2024-08-12	DIVIDENDO	7.25
45	26	3	2024-08-12	DIVIDENDO	1.75
46	27	3	2024-08-12	DIVIDENDO	6.50
47	40	3	2024-08-12	DIVIDENDO	5.00
48	51	3	2024-08-12	DIVIDENDO	6.50
49	66	3	2024-08-12	DIVIDENDO	22.50
50	75	3	2024-08-12	DIVIDENDO	9.50
51	5	4	2024-08-15	DIVIDENDO	18.00
52	9	4	2024-08-15	DIVIDENDO	8.25
53	22	4	2024-08-15	DIVIDENDO	3.00
54	26	4	2024-08-15	DIVIDENDO	2.25
55	30	4	2024-08-15	DIVIDENDO	95.25
56	40	4	2024-08-15	DIVIDENDO	40.50
57	49	4	2024-08-15	DIVIDENDO	3.00
58	70	4	2024-08-15	DIVIDENDO	7.50
59	6	8	2024-08-27	DIVIDENDO	322.40
60	8	8	2024-08-27	DIVIDENDO	14.88
61	9	8	2024-08-27	DIVIDENDO	43.40
62	16	8	2024-08-27	DIVIDENDO	63.24
63	19	8	2024-08-27	DIVIDENDO	64.48
64	29	8	2024-08-27	DIVIDENDO	164.92
65	53	8	2024-08-27	DIVIDENDO	49.60
66	55	8	2024-08-27	DIVIDENDO	131.44
67	59	8	2024-08-27	DIVIDENDO	163.68
68	77	8	2024-08-27	DIVIDENDO	64.48
69	19	6	2024-09-09	DIVIDENDO	6.40
70	50	6	2024-09-09	DIVIDENDO	4.00
71	59	6	2024-09-09	DIVIDENDO	23.20
72	6	9	2024-09-20	DIVIDENDO	251.42
73	15	9	2024-09-20	DIVIDENDO	97.78
74	26	9	2024-09-20	DIVIDENDO	31.43
75	32	9	2024-09-20	DIVIDENDO	19.21
76	44	9	2024-09-20	DIVIDENDO	33.17
77	49	9	2024-09-20	DIVIDENDO	3.49
78	3	10	2024-09-23	DIVIDENDO	4.74
79	5	10	2024-09-23	DIVIDENDO	2.71
80	8	10	2024-09-23	DIVIDENDO	13.54
81	10	10	2024-09-23	DIVIDENDO	2.71
82	13	10	2024-09-23	DIVIDENDO	19.63
83	15	10	2024-09-23	DIVIDENDO	50.10
84	42	10	2024-09-23	DIVIDENDO	8.80
85	59	10	2024-09-23	DIVIDENDO	33.17
86	69	10	2024-09-23	DIVIDENDO	5.42
87	70	10	2024-09-23	DIVIDENDO	10.83
88	8	2	2024-09-27	DIVIDENDO	206.67
89	23	2	2024-09-27	DIVIDENDO	87.15
90	29	2	2024-09-27	DIVIDENDO	121.18
91	40	2	2024-09-27	DIVIDENDO	253.98
92	65	2	2024-09-27	DIVIDENDO	1449.18
93	3	13	2024-10-09	INTERES	280.50
94	9	13	2024-10-09	INTERES	221.45
95	15	11	2024-11-04	INTERES	3282.74
96	27	11	2024-11-04	INTERES	91.19
97	40	11	2024-11-04	INTERES	794.63
98	66	11	2024-11-04	INTERES	117.24
99	68	11	2024-11-04	INTERES	273.56
100	69	11	2024-11-04	INTERES	377.78
101	70	11	2024-11-04	INTERES	195.40
102	5	3	2024-11-08	DIVIDENDO	2.25
103	19	3	2024-11-08	DIVIDENDO	7.25
104	26	3	2024-11-08	DIVIDENDO	4.00
105	27	3	2024-11-08	DIVIDENDO	6.50
106	40	3	2024-11-08	DIVIDENDO	13.50
107	51	3	2024-11-08	DIVIDENDO	6.50
108	55	3	2024-11-08	DIVIDENDO	2.25
109	66	3	2024-11-08	DIVIDENDO	22.50
110	75	3	2024-11-08	DIVIDENDO	9.50
111	5	4	2024-11-21	DIVIDENDO	19.92
112	9	4	2024-11-21	DIVIDENDO	12.45
113	16	4	2024-11-21	DIVIDENDO	5.81
114	22	4	2024-11-21	DIVIDENDO	3.32
115	26	4	2024-11-21	DIVIDENDO	6.64
116	32	4	2024-11-21	DIVIDENDO	18.26
117	40	4	2024-11-21	DIVIDENDO	44.82
118	49	4	2024-11-21	DIVIDENDO	3.32
119	66	4	2024-11-21	DIVIDENDO	6.64
120	70	4	2024-11-21	DIVIDENDO	8.30
121	6	8	2024-11-26	DIVIDENDO	322.40
122	8	8	2024-11-26	DIVIDENDO	14.88
123	9	8	2024-11-26	DIVIDENDO	43.40
124	10	8	2024-11-26	DIVIDENDO	2.48
125	16	8	2024-11-26	DIVIDENDO	63.24
126	19	8	2024-11-26	DIVIDENDO	64.48
127	26	8	2024-11-26	DIVIDENDO	16.12
128	29	8	2024-11-26	DIVIDENDO	164.92
129	53	8	2024-11-26	DIVIDENDO	49.60
130	55	8	2024-11-26	DIVIDENDO	131.44
131	59	8	2024-11-26	DIVIDENDO	163.68
132	75	8	2024-11-26	DIVIDENDO	13.64
133	77	8	2024-11-26	DIVIDENDO	64.48
134	19	6	2024-12-09	DIVIDENDO	4.40
135	20	6	2024-12-09	DIVIDENDO	3.00
136	21	6	2024-12-09	DIVIDENDO	5.20
137	24	6	2024-12-09	DIVIDENDO	2.80
138	42	6	2024-12-09	DIVIDENDO	2.60
139	50	6	2024-12-09	DIVIDENDO	2.60
140	59	6	2024-12-09	DIVIDENDO	23.20
141	3	9	2024-12-20	DIVIDENDO	5.90
142	6	9	2024-12-20	DIVIDENDO	182.84
143	15	9	2024-12-20	DIVIDENDO	110.10
144	26	9	2024-12-20	DIVIDENDO	35.39
145	32	9	2024-12-20	DIVIDENDO	21.63
146	40	9	2024-12-20	DIVIDENDO	19.66
147	44	9	2024-12-20	DIVIDENDO	37.35
148	49	9	2024-12-20	DIVIDENDO	3.93
149	54	9	2024-12-20	DIVIDENDO	80.61
150	57	9	2024-12-20	DIVIDENDO	11.80
151	3	10	2024-12-23	DIVIDENDO	5.85
152	5	10	2024-12-23	DIVIDENDO	3.34
153	8	10	2024-12-23	DIVIDENDO	17.54
154	10	10	2024-12-23	DIVIDENDO	3.34
155	13	10	2024-12-23	DIVIDENDO	27.56
156	15	10	2024-12-23	DIVIDENDO	61.79
157	20	10	2024-12-23	DIVIDENDO	8.35
158	42	10	2024-12-23	DIVIDENDO	14.20
159	46	10	2024-12-23	DIVIDENDO	10.02
160	59	10	2024-12-23	DIVIDENDO	27.56
161	60	10	2024-12-23	DIVIDENDO	8.35
162	61	10	2024-12-23	DIVIDENDO	38.41
163	68	10	2024-12-23	DIVIDENDO	3.34
164	69	10	2024-12-23	DIVIDENDO	5.01
165	70	10	2024-12-23	DIVIDENDO	13.36
166	8	2	2024-12-30	DIVIDENDO	219.47
167	10	2	2024-12-30	DIVIDENDO	9.61
168	23	2	2024-12-30	DIVIDENDO	66.48
169	29	2	2024-12-30	DIVIDENDO	173.82
170	40	2	2024-12-30	DIVIDENDO	245.11
171	60	2	2024-12-30	DIVIDENDO	128.96
172	65	2	2024-12-30	DIVIDENDO	1398.55
173	66	2	2024-12-30	DIVIDENDO	51.26
174	68	2	2024-12-30	DIVIDENDO	55.27
175	70	2	2024-12-30	DIVIDENDO	13.62
176	5	3	2025-02-10	DIVIDENDO	1.75
177	19	3	2025-02-10	DIVIDENDO	7.25
178	26	3	2025-02-10	DIVIDENDO	6.50
179	27	3	2025-02-10	DIVIDENDO	6.50
180	40	3	2025-02-10	DIVIDENDO	17.00
181	52	3	2025-02-10	DIVIDENDO	3.25
182	55	3	2025-02-10	DIVIDENDO	2.00
183	61	3	2025-02-10	DIVIDENDO	25.25
184	66	3	2025-02-10	DIVIDENDO	22.50
185	68	3	2025-02-10	DIVIDENDO	1.25
186	71	3	2025-02-10	DIVIDENDO	2.50
187	75	3	2025-02-10	DIVIDENDO	11.25
188	79	3	2025-02-10	DIVIDENDO	7.75
189	80	3	2025-02-10	DIVIDENDO	31.75
190	6	8	2025-02-18	DIVIDENDO	322.40
191	8	8	2025-02-18	DIVIDENDO	14.88
192	9	8	2025-02-18	DIVIDENDO	43.40
193	10	8	2025-02-18	DIVIDENDO	2.48
194	13	8	2025-02-18	DIVIDENDO	19.84
195	16	8	2025-02-18	DIVIDENDO	89.28
196	19	8	2025-02-18	DIVIDENDO	64.48
197	24	8	2025-02-18	DIVIDENDO	18.60
198	26	8	2025-02-18	DIVIDENDO	16.12
199	29	8	2025-02-18	DIVIDENDO	182.28
200	53	8	2025-02-18	DIVIDENDO	49.60
201	55	8	2025-02-18	DIVIDENDO	131.44
202	59	8	2025-02-18	DIVIDENDO	163.68
203	75	8	2025-02-18	DIVIDENDO	13.64
204	77	8	2025-02-18	DIVIDENDO	71.92
205	5	4	2025-02-20	DIVIDENDO	19.92
206	9	4	2025-02-20	DIVIDENDO	12.45
207	16	4	2025-02-20	DIVIDENDO	4.98
208	22	4	2025-02-20	DIVIDENDO	3.32
209	26	4	2025-02-20	DIVIDENDO	6.64
210	32	4	2025-02-20	DIVIDENDO	9.96
211	40	4	2025-02-20	DIVIDENDO	44.82
212	49	4	2025-02-20	DIVIDENDO	3.32
213	52	4	2025-02-20	DIVIDENDO	5.81
214	61	4	2025-02-20	DIVIDENDO	46.48
215	66	4	2025-02-20	DIVIDENDO	6.64
216	70	4	2025-02-20	DIVIDENDO	8.30
217	19	6	2025-03-10	DIVIDENDO	4.40
218	20	6	2025-03-10	DIVIDENDO	3.00
219	21	6	2025-03-10	DIVIDENDO	5.20
220	24	6	2025-03-10	DIVIDENDO	2.80
221	30	6	2025-03-10	DIVIDENDO	5.00
222	42	6	2025-03-10	DIVIDENDO	2.60
223	50	6	2025-03-10	DIVIDENDO	2.60
224	57	6	2025-03-10	DIVIDENDO	19.00
225	59	6	2025-03-10	DIVIDENDO	23.20
226	65	6	2025-03-10	DIVIDENDO	3.00
227	77	6	2025-03-10	DIVIDENDO	2.20
228	3	9	2025-03-21	DIVIDENDO	5.09
229	6	9	2025-03-21	DIVIDENDO	157.73
230	15	9	2025-03-21	DIVIDENDO	94.98
231	26	9	2025-03-21	DIVIDENDO	30.53
232	32	9	2025-03-21	DIVIDENDO	18.66
233	40	9	2025-03-21	DIVIDENDO	16.96
234	44	9	2025-03-21	DIVIDENDO	15.26
235	49	9	2025-03-21	DIVIDENDO	5.09
236	54	9	2025-03-21	DIVIDENDO	69.54
237	57	9	2025-03-21	DIVIDENDO	115.33
238	62	9	2025-03-21	DIVIDENDO	74.62
239	3	10	2025-03-24	DIVIDENDO	5.01
240	5	10	2025-03-24	DIVIDENDO	2.86
241	7	10	2025-03-24	DIVIDENDO	114.56
242	8	10	2025-03-24	DIVIDENDO	15.75
243	10	10	2025-03-24	DIVIDENDO	2.86
244	13	10	2025-03-24	DIVIDENDO	23.63
245	15	10	2025-03-24	DIVIDENDO	52.98
246	20	10	2025-03-24	DIVIDENDO	9.31
247	42	10	2025-03-24	DIVIDENDO	16.47
248	46	10	2025-03-24	DIVIDENDO	8.59
249	59	10	2025-03-24	DIVIDENDO	13.60
250	60	10	2025-03-24	DIVIDENDO	7.16
251	61	10	2025-03-24	DIVIDENDO	32.94
252	68	10	2025-03-24	DIVIDENDO	2.86
253	70	10	2025-03-24	DIVIDENDO	11.46
254	8	2	2025-03-31	DIVIDENDO	2061.58
255	10	2	2025-03-31	DIVIDENDO	90.29
256	16	2	2025-03-31	DIVIDENDO	624.49
257	23	2	2025-03-31	DIVIDENDO	624.49
258	29	2	2025-03-31	DIVIDENDO	2505.49
259	40	2	2025-03-31	DIVIDENDO	2302.34
260	60	2	2025-03-31	DIVIDENDO	1391.94
261	65	2	2025-03-31	DIVIDENDO	13136.90
262	66	2	2025-03-31	DIVIDENDO	759.92
263	68	2	2025-03-31	DIVIDENDO	519.16
264	70	2	2025-03-31	DIVIDENDO	127.91
265	4	1	2025-04-03	DIVIDENDO	11.18
266	9	1	2025-04-03	DIVIDENDO	235.22
267	15	1	2025-04-03	DIVIDENDO	1565.89
268	20	1	2025-04-03	DIVIDENDO	241.06
269	26	1	2025-04-03	DIVIDENDO	166.21
270	29	1	2025-04-03	DIVIDENDO	142.40
271	44	1	2025-04-03	DIVIDENDO	325.13
272	48	1	2025-04-03	DIVIDENDO	129.76
273	49	1	2025-04-03	DIVIDENDO	78.25
274	50	1	2025-04-03	DIVIDENDO	273.13
275	51	1	2025-04-03	DIVIDENDO	609.44
276	55	1	2025-04-03	DIVIDENDO	112.75
277	57	1	2025-04-03	DIVIDENDO	1927.48
278	65	1	2025-04-03	DIVIDENDO	3199.34
279	71	1	2025-04-03	DIVIDENDO	831.55
280	4	1	2025-04-28	DIVIDENDO	11.64
281	8	2	2025-04-28	DIVIDENDO	95.28
282	9	1	2025-04-28	DIVIDENDO	244.90
283	10	2	2025-04-28	DIVIDENDO	6.89
284	15	1	2025-04-28	DIVIDENDO	1630.33
285	16	2	2025-04-28	DIVIDENDO	47.64
286	20	1	2025-04-28	DIVIDENDO	250.98
287	21	2	2025-04-28	DIVIDENDO	106.76
288	23	2	2025-04-28	DIVIDENDO	47.64
289	26	1	2025-04-28	DIVIDENDO	173.05
290	29	2	2025-04-28	DIVIDENDO	191.14
291	29	1	2025-04-28	DIVIDENDO	148.26
292	34	1	2025-04-28	DIVIDENDO	82.98
293	40	2	2025-04-28	DIVIDENDO	175.64
294	44	1	2025-04-28	DIVIDENDO	338.51
295	48	1	2025-04-28	DIVIDENDO	135.10
296	49	1	2025-04-28	DIVIDENDO	81.47
297	50	1	2025-04-28	DIVIDENDO	284.37
298	51	1	2025-04-28	DIVIDENDO	634.52
299	55	1	2025-04-28	DIVIDENDO	117.39
300	57	1	2025-04-28	DIVIDENDO	2006.80
301	60	2	2025-04-28	DIVIDENDO	106.19
302	65	2	2025-04-28	DIVIDENDO	1128.48
303	65	1	2025-04-28	DIVIDENDO	3331.00
304	66	2	2025-04-28	DIVIDENDO	57.97
305	68	2	2025-04-28	DIVIDENDO	39.61
306	70	2	2025-04-28	DIVIDENDO	9.76
307	71	1	2025-04-28	DIVIDENDO	865.77
308	5	3	2025-05-12	DIVIDENDO	7.54
309	19	3	2025-05-12	DIVIDENDO	3.64
310	26	3	2025-05-12	DIVIDENDO	11.18
311	27	3	2025-05-12	DIVIDENDO	6.76
312	36	3	2025-05-12	DIVIDENDO	6.24
313	40	3	2025-05-12	DIVIDENDO	17.68
314	41	3	2025-05-12	DIVIDENDO	1.30
315	52	3	2025-05-12	DIVIDENDO	3.38
316	55	3	2025-05-12	DIVIDENDO	13.52
317	60	3	2025-05-12	DIVIDENDO	1.04
318	61	3	2025-05-12	DIVIDENDO	26.26
319	66	3	2025-05-12	DIVIDENDO	24.96
320	68	3	2025-05-12	DIVIDENDO	1.30
321	71	3	2025-05-12	DIVIDENDO	2.60
322	75	3	2025-05-12	DIVIDENDO	16.64
323	77	3	2025-05-12	DIVIDENDO	2.08
324	78	3	2025-05-12	DIVIDENDO	3.12
325	79	3	2025-05-12	DIVIDENDO	8.06
326	80	3	2025-05-12	DIVIDENDO	33.02
327	5	4	2025-05-15	DIVIDENDO	19.92
328	9	4	2025-05-15	DIVIDENDO	24.07
329	16	4	2025-05-15	DIVIDENDO	4.98
330	22	4	2025-05-15	DIVIDENDO	2.49
331	25	4	2025-05-15	DIVIDENDO	8.30
332	26	4	2025-05-15	DIVIDENDO	9.13
333	30	4	2025-05-15	DIVIDENDO	18.26
334	32	4	2025-05-15	DIVIDENDO	9.96
335	37	4	2025-05-15	DIVIDENDO	11.62
336	40	4	2025-05-15	DIVIDENDO	44.82
337	49	4	2025-05-15	DIVIDENDO	3.32
338	52	4	2025-05-15	DIVIDENDO	5.81
339	61	4	2025-05-15	DIVIDENDO	46.48
340	66	4	2025-05-15	DIVIDENDO	16.60
341	67	4	2025-05-15	DIVIDENDO	25.73
342	68	4	2025-05-15	DIVIDENDO	1.66
343	70	4	2025-05-15	DIVIDENDO	8.30
344	6	8	2025-05-27	DIVIDENDO	338.00
345	7	8	2025-05-27	DIVIDENDO	356.20
346	8	8	2025-05-27	DIVIDENDO	19.50
347	9	8	2025-05-27	DIVIDENDO	45.50
348	10	8	2025-05-27	DIVIDENDO	13.00
349	13	8	2025-05-27	DIVIDENDO	11.70
350	16	8	2025-05-27	DIVIDENDO	93.60
351	17	8	2025-05-27	DIVIDENDO	28.60
352	18	8	2025-05-27	DIVIDENDO	569.40
353	19	8	2025-05-27	DIVIDENDO	67.60
354	24	8	2025-05-27	DIVIDENDO	19.50
355	26	8	2025-05-27	DIVIDENDO	16.90
356	29	8	2025-05-27	DIVIDENDO	115.70
357	36	8	2025-05-27	DIVIDENDO	42.90
358	37	8	2025-05-27	DIVIDENDO	46.80
359	51	8	2025-05-27	DIVIDENDO	31.20
360	53	8	2025-05-27	DIVIDENDO	52.00
361	55	8	2025-05-27	DIVIDENDO	137.80
362	59	8	2025-05-27	DIVIDENDO	171.60
363	75	8	2025-05-27	DIVIDENDO	48.10
364	76	8	2025-05-27	DIVIDENDO	9.10
365	77	8	2025-05-27	DIVIDENDO	110.50
366	19	6	2025-06-09	DIVIDENDO	4.62
367	20	6	2025-06-09	DIVIDENDO	5.88
368	21	6	2025-06-09	DIVIDENDO	5.46
369	24	6	2025-06-09	DIVIDENDO	2.94
370	30	6	2025-06-09	DIVIDENDO	5.25
371	31	6	2025-06-09	DIVIDENDO	4.62
372	34	6	2025-06-09	DIVIDENDO	1.68
373	41	6	2025-06-09	DIVIDENDO	1.26
374	42	6	2025-06-09	DIVIDENDO	2.73
375	45	6	2025-06-09	DIVIDENDO	107.10
376	59	6	2025-06-09	DIVIDENDO	24.36
377	65	6	2025-06-09	DIVIDENDO	3.15
378	71	6	2025-06-09	DIVIDENDO	5.88
379	77	6	2025-06-09	DIVIDENDO	5.88
380	3	9	2025-06-20	DIVIDENDO	5.28
381	6	9	2025-06-20	DIVIDENDO	82.77
382	11	9	2025-06-20	DIVIDENDO	1.76
383	15	9	2025-06-20	DIVIDENDO	98.62
384	26	9	2025-06-20	DIVIDENDO	31.70
385	32	9	2025-06-20	DIVIDENDO	14.09
386	40	9	2025-06-20	DIVIDENDO	17.61
387	44	9	2025-06-20	DIVIDENDO	22.89
388	49	9	2025-06-20	DIVIDENDO	5.28
389	54	9	2025-06-20	DIVIDENDO	72.20
390	56	9	2025-06-20	DIVIDENDO	36.98
391	57	9	2025-06-20	DIVIDENDO	119.75
392	62	9	2025-06-20	DIVIDENDO	95.09
393	67	9	2025-06-20	DIVIDENDO	8.81
394	72	9	2025-06-20	DIVIDENDO	7.04
395	2	10	2025-06-23	DIVIDENDO	4.14
396	3	10	2025-06-23	DIVIDENDO	7.68
397	5	10	2025-06-23	DIVIDENDO	5.32
398	7	10	2025-06-23	DIVIDENDO	101.65
399	8	10	2025-06-23	DIVIDENDO	13.00
400	10	10	2025-06-23	DIVIDENDO	2.96
401	13	10	2025-06-23	DIVIDENDO	19.50
402	15	10	2025-06-23	DIVIDENDO	33.69
403	20	10	2025-06-23	DIVIDENDO	7.68
404	27	10	2025-06-23	DIVIDENDO	1.77
405	37	10	2025-06-23	DIVIDENDO	1.18
406	42	10	2025-06-23	DIVIDENDO	7.68
407	44	10	2025-06-23	DIVIDENDO	2.96
408	46	10	2025-06-23	DIVIDENDO	2.96
409	59	10	2025-06-23	DIVIDENDO	11.23
410	60	10	2025-06-23	DIVIDENDO	5.91
411	61	10	2025-06-23	DIVIDENDO	27.19
412	68	10	2025-06-23	DIVIDENDO	2.96
413	69	10	2025-06-23	DIVIDENDO	4.73
414	70	10	2025-06-23	DIVIDENDO	4.73
415	6	12	2025-06-30	INTERES	3354.08
416	7	12	2025-06-30	INTERES	1737.24
417	10	12	2025-06-30	INTERES	705.22
418	16	12	2025-06-30	INTERES	1444.83
419	27	12	2025-06-30	INTERES	258.01
420	40	12	2025-06-30	INTERES	292.41
421	44	12	2025-06-30	INTERES	103.20
422	46	12	2025-06-30	INTERES	1272.83
423	49	12	2025-06-30	INTERES	292.41
424	51	12	2025-06-30	INTERES	1049.23
425	52	12	2025-06-30	INTERES	223.61
426	56	12	2025-06-30	INTERES	1754.44
427	67	12	2025-06-30	INTERES	1444.83
428	70	12	2025-06-30	INTERES	688.02
429	5	3	2025-08-11	DIVIDENDO	11.18
430	19	3	2025-08-11	DIVIDENDO	3.64
431	23	3	2025-08-11	DIVIDENDO	0.78
432	26	3	2025-08-11	DIVIDENDO	11.18
433	27	3	2025-08-11	DIVIDENDO	8.84
434	36	3	2025-08-11	DIVIDENDO	6.24
435	40	3	2025-08-11	DIVIDENDO	17.68
436	41	3	2025-08-11	DIVIDENDO	1.30
437	52	3	2025-08-11	DIVIDENDO	1.56
438	54	3	2025-08-11	DIVIDENDO	6.24
439	55	3	2025-08-11	DIVIDENDO	18.20
440	60	3	2025-08-11	DIVIDENDO	4.94
441	61	3	2025-08-11	DIVIDENDO	17.16
442	66	3	2025-08-11	DIVIDENDO	24.96
443	68	3	2025-08-11	DIVIDENDO	2.08
444	71	3	2025-08-11	DIVIDENDO	2.60
445	72	3	2025-08-11	DIVIDENDO	3.12
446	75	3	2025-08-11	DIVIDENDO	9.62
447	77	3	2025-08-11	DIVIDENDO	2.08
448	78	3	2025-08-11	DIVIDENDO	3.90
449	79	3	2025-08-11	DIVIDENDO	2.86
450	80	3	2025-08-11	DIVIDENDO	33.02
451	5	4	2025-08-21	DIVIDENDO	19.92
452	9	4	2025-08-21	DIVIDENDO	24.07
453	11	4	2025-08-21	DIVIDENDO	3.32
454	16	4	2025-08-21	DIVIDENDO	4.98
455	22	4	2025-08-21	DIVIDENDO	2.49
456	25	4	2025-08-21	DIVIDENDO	8.30
457	26	4	2025-08-21	DIVIDENDO	9.13
458	28	4	2025-08-21	DIVIDENDO	24.07
459	30	4	2025-08-21	DIVIDENDO	64.74
460	32	4	2025-08-21	DIVIDENDO	9.96
461	37	4	2025-08-21	DIVIDENDO	11.62
462	40	4	2025-08-21	DIVIDENDO	44.82
463	43	4	2025-08-21	DIVIDENDO	7.47
464	45	4	2025-08-21	DIVIDENDO	158.53
465	49	4	2025-08-21	DIVIDENDO	3.32
466	52	4	2025-08-21	DIVIDENDO	5.81
467	61	4	2025-08-21	DIVIDENDO	51.46
468	64	4	2025-08-21	DIVIDENDO	6.64
469	66	4	2025-08-21	DIVIDENDO	7.47
470	67	4	2025-08-21	DIVIDENDO	25.73
471	68	4	2025-08-21	DIVIDENDO	3.32
472	70	4	2025-08-21	DIVIDENDO	8.30
473	80	4	2025-08-21	DIVIDENDO	4.98
474	2	8	2025-08-26	DIVIDENDO	33.80
475	6	8	2025-08-26	DIVIDENDO	475.80
476	7	8	2025-08-26	DIVIDENDO	382.20
477	8	8	2025-08-26	DIVIDENDO	19.50
478	9	8	2025-08-26	DIVIDENDO	45.50
479	10	8	2025-08-26	DIVIDENDO	13.00
480	13	8	2025-08-26	DIVIDENDO	11.70
481	16	8	2025-08-26	DIVIDENDO	93.60
482	17	8	2025-08-26	DIVIDENDO	28.60
483	18	8	2025-08-26	DIVIDENDO	676.00
484	19	8	2025-08-26	DIVIDENDO	67.60
485	24	8	2025-08-26	DIVIDENDO	9.10
486	26	8	2025-08-26	DIVIDENDO	16.90
487	29	8	2025-08-26	DIVIDENDO	115.70
488	33	8	2025-08-26	DIVIDENDO	62.40
489	36	8	2025-08-26	DIVIDENDO	42.90
490	37	8	2025-08-26	DIVIDENDO	58.50
491	38	8	2025-08-26	DIVIDENDO	161.20
492	53	8	2025-08-26	DIVIDENDO	52.00
493	55	8	2025-08-26	DIVIDENDO	137.80
494	59	8	2025-08-26	DIVIDENDO	171.60
495	75	8	2025-08-26	DIVIDENDO	48.10
496	76	8	2025-08-26	DIVIDENDO	9.10
497	77	8	2025-08-26	DIVIDENDO	110.50
498	19	6	2025-09-08	DIVIDENDO	2.73
499	20	6	2025-09-08	DIVIDENDO	9.45
500	21	6	2025-09-08	DIVIDENDO	5.46
501	23	6	2025-09-08	DIVIDENDO	0.84
502	24	6	2025-09-08	DIVIDENDO	2.94
503	30	6	2025-09-08	DIVIDENDO	5.25
504	31	6	2025-09-08	DIVIDENDO	4.62
505	34	6	2025-09-08	DIVIDENDO	1.68
506	41	6	2025-09-08	DIVIDENDO	1.26
507	42	6	2025-09-08	DIVIDENDO	5.67
508	45	6	2025-09-08	DIVIDENDO	56.91
509	59	6	2025-09-08	DIVIDENDO	24.36
510	65	6	2025-09-08	DIVIDENDO	3.15
511	71	6	2025-09-08	DIVIDENDO	9.87
512	77	6	2025-09-08	DIVIDENDO	5.88
513	1	9	2025-09-19	DIVIDENDO	36.62
514	3	9	2025-09-19	DIVIDENDO	3.66
515	6	9	2025-09-19	DIVIDENDO	38.45
516	15	9	2025-09-19	DIVIDENDO	102.54
517	21	9	2025-09-19	DIVIDENDO	18.31
518	26	9	2025-09-19	DIVIDENDO	32.96
519	32	9	2025-09-19	DIVIDENDO	10.99
520	40	9	2025-09-19	DIVIDENDO	18.31
521	44	9	2025-09-19	DIVIDENDO	23.80
522	49	9	2025-09-19	DIVIDENDO	5.49
523	54	9	2025-09-19	DIVIDENDO	75.07
524	56	9	2025-09-19	DIVIDENDO	38.45
525	57	9	2025-09-19	DIVIDENDO	124.51
526	62	9	2025-09-19	DIVIDENDO	98.87
527	63	9	2025-09-19	DIVIDENDO	14.65
528	64	9	2025-09-19	DIVIDENDO	3.66
529	67	9	2025-09-19	DIVIDENDO	9.16
530	69	9	2025-09-19	DIVIDENDO	7.32
531	72	9	2025-09-19	DIVIDENDO	5.49
532	2	10	2025-09-22	DIVIDENDO	4.86
533	3	10	2025-09-22	DIVIDENDO	9.02
534	5	10	2025-09-22	DIVIDENDO	6.25
535	7	10	2025-09-22	DIVIDENDO	119.37
536	8	10	2025-09-22	DIVIDENDO	15.27
537	10	10	2025-09-22	DIVIDENDO	4.16
538	13	10	2025-09-22	DIVIDENDO	22.90
539	15	10	2025-09-22	DIVIDENDO	39.56
540	20	10	2025-09-22	DIVIDENDO	17.35
541	27	10	2025-09-22	DIVIDENDO	2.08
542	33	10	2025-09-22	DIVIDENDO	18.04
543	37	10	2025-09-22	DIVIDENDO	1.39
544	42	10	2025-09-22	DIVIDENDO	9.02
545	44	10	2025-09-22	DIVIDENDO	3.47
546	46	10	2025-09-22	DIVIDENDO	5.55
547	59	10	2025-09-22	DIVIDENDO	13.19
548	60	10	2025-09-22	DIVIDENDO	12.49
549	61	10	2025-09-22	DIVIDENDO	31.92
550	67	10	2025-09-22	DIVIDENDO	2.08
551	68	10	2025-09-22	DIVIDENDO	3.47
552	69	10	2025-09-22	DIVIDENDO	3.47
553	70	10	2025-09-22	DIVIDENDO	5.55
554	3	13	2025-10-09	INTERES	306.07
555	4	13	2025-10-09	INTERES	209.42
556	5	13	2025-10-09	INTERES	241.64
557	9	13	2025-10-09	INTERES	451.05
558	16	13	2025-10-09	INTERES	225.53
559	26	13	2025-10-09	INTERES	80.55
560	38	13	2025-10-09	INTERES	499.38
561	46	13	2025-10-09	INTERES	273.85
562	54	13	2025-10-09	INTERES	161.09
563	55	13	2025-10-09	INTERES	306.07
564	61	13	2025-10-09	INTERES	1014.87
565	67	13	2025-10-09	INTERES	483.27
566	68	13	2025-10-09	INTERES	112.76
567	73	13	2025-10-09	INTERES	1594.80
568	9	11	2025-11-03	INTERES	1325.74
569	10	11	2025-11-03	INTERES	119.17
570	13	11	2025-11-03	INTERES	208.54
571	15	11	2025-11-03	INTERES	3753.77
572	25	11	2025-11-03	INTERES	119.17
573	27	11	2025-11-03	INTERES	104.27
574	40	11	2025-11-03	INTERES	908.65
575	42	11	2025-11-03	INTERES	297.92
576	45	11	2025-11-03	INTERES	253.23
577	48	11	2025-11-03	INTERES	104.27
578	57	11	2025-11-03	INTERES	89.38
579	66	11	2025-11-03	INTERES	134.06
580	68	11	2025-11-03	INTERES	312.81
581	69	11	2025-11-03	INTERES	431.98
582	70	11	2025-11-03	INTERES	223.44
583	78	11	2025-11-03	INTERES	1742.82
584	5	3	2025-11-10	DIVIDENDO	11.18
585	19	3	2025-11-10	DIVIDENDO	5.20
586	23	3	2025-11-10	DIVIDENDO	0.78
587	26	3	2025-11-10	DIVIDENDO	14.04
588	27	3	2025-11-10	DIVIDENDO	10.40
589	36	3	2025-11-10	DIVIDENDO	6.24
590	40	3	2025-11-10	DIVIDENDO	17.68
591	41	3	2025-11-10	DIVIDENDO	1.30
592	52	3	2025-11-10	DIVIDENDO	2.60
593	54	3	2025-11-10	DIVIDENDO	6.24
594	55	3	2025-11-10	DIVIDENDO	25.48
595	60	3	2025-11-10	DIVIDENDO	4.94
596	61	3	2025-11-10	DIVIDENDO	17.16
597	66	3	2025-11-10	DIVIDENDO	27.56
598	68	3	2025-11-10	DIVIDENDO	2.08
599	71	3	2025-11-10	DIVIDENDO	2.60
600	72	3	2025-11-10	DIVIDENDO	3.12
601	77	3	2025-11-10	DIVIDENDO	8.32
602	78	3	2025-11-10	DIVIDENDO	3.90
603	79	3	2025-11-10	DIVIDENDO	7.54
604	80	3	2025-11-10	DIVIDENDO	33.02
605	1	4	2025-11-20	DIVIDENDO	19.11
606	5	4	2025-11-20	DIVIDENDO	21.84
607	9	4	2025-11-20	DIVIDENDO	26.39
608	11	4	2025-11-20	DIVIDENDO	3.64
609	16	4	2025-11-20	DIVIDENDO	12.74
610	22	4	2025-11-20	DIVIDENDO	2.73
611	25	4	2025-11-20	DIVIDENDO	9.10
612	26	4	2025-11-20	DIVIDENDO	14.56
613	28	4	2025-11-20	DIVIDENDO	26.39
614	30	4	2025-11-20	DIVIDENDO	70.98
615	31	4	2025-11-20	DIVIDENDO	2.73
616	32	4	2025-11-20	DIVIDENDO	13.65
617	37	4	2025-11-20	DIVIDENDO	12.74
618	40	4	2025-11-20	DIVIDENDO	49.14
619	43	4	2025-11-20	DIVIDENDO	8.19
620	45	4	2025-11-20	DIVIDENDO	219.31
621	49	4	2025-11-20	DIVIDENDO	3.64
622	52	4	2025-11-20	DIVIDENDO	6.37
623	56	4	2025-11-20	DIVIDENDO	5.46
624	64	4	2025-11-20	DIVIDENDO	7.28
625	66	4	2025-11-20	DIVIDENDO	8.19
626	67	4	2025-11-20	DIVIDENDO	28.21
627	68	4	2025-11-20	DIVIDENDO	3.64
628	70	4	2025-11-20	DIVIDENDO	9.10
629	80	4	2025-11-20	DIVIDENDO	5.46
630	2	8	2025-11-25	DIVIDENDO	50.70
631	6	8	2025-11-25	DIVIDENDO	475.80
632	7	8	2025-11-25	DIVIDENDO	382.20
633	8	8	2025-11-25	DIVIDENDO	19.50
634	9	8	2025-11-25	DIVIDENDO	66.30
635	10	8	2025-11-25	DIVIDENDO	13.00
636	13	8	2025-11-25	DIVIDENDO	11.70
637	16	8	2025-11-25	DIVIDENDO	124.80
638	17	8	2025-11-25	DIVIDENDO	28.60
639	18	8	2025-11-25	DIVIDENDO	497.90
640	19	8	2025-11-25	DIVIDENDO	67.60
641	24	8	2025-11-25	DIVIDENDO	7.80
642	26	8	2025-11-25	DIVIDENDO	36.40
643	29	8	2025-11-25	DIVIDENDO	115.70
644	33	8	2025-11-25	DIVIDENDO	62.40
645	36	8	2025-11-25	DIVIDENDO	46.80
646	37	8	2025-11-25	DIVIDENDO	58.50
647	38	8	2025-11-25	DIVIDENDO	161.20
648	53	8	2025-11-25	DIVIDENDO	67.60
649	55	8	2025-11-25	DIVIDENDO	183.30
650	56	8	2025-11-25	DIVIDENDO	46.80
651	62	8	2025-11-25	DIVIDENDO	23.40
652	73	8	2025-11-25	DIVIDENDO	27.30
653	75	8	2025-11-25	DIVIDENDO	48.10
654	76	8	2025-11-25	DIVIDENDO	9.10
655	77	8	2025-11-25	DIVIDENDO	110.50
656	19	6	2025-12-08	DIVIDENDO	2.73
657	20	6	2025-12-08	DIVIDENDO	9.45
658	21	6	2025-12-08	DIVIDENDO	5.46
659	23	6	2025-12-08	DIVIDENDO	0.84
660	24	6	2025-12-08	DIVIDENDO	2.94
661	30	6	2025-12-08	DIVIDENDO	12.81
662	31	6	2025-12-08	DIVIDENDO	4.62
663	34	6	2025-12-08	DIVIDENDO	1.68
664	41	6	2025-12-08	DIVIDENDO	0.63
665	45	6	2025-12-08	DIVIDENDO	56.91
666	58	6	2025-12-08	DIVIDENDO	15.33
667	59	6	2025-12-08	DIVIDENDO	24.36
668	65	6	2025-12-08	DIVIDENDO	3.15
669	71	6	2025-12-08	DIVIDENDO	9.87
670	77	6	2025-12-08	DIVIDENDO	8.40
671	1	9	2025-12-19	DIVIDENDO	39.86
672	3	9	2025-12-19	DIVIDENDO	3.99
673	6	9	2025-12-19	DIVIDENDO	41.85
674	15	9	2025-12-19	DIVIDENDO	111.61
675	21	9	2025-12-19	DIVIDENDO	19.93
676	26	9	2025-12-19	DIVIDENDO	21.92
677	32	9	2025-12-19	DIVIDENDO	11.96
678	40	9	2025-12-19	DIVIDENDO	19.93
679	44	9	2025-12-19	DIVIDENDO	25.91
680	49	9	2025-12-19	DIVIDENDO	7.97
681	54	9	2025-12-19	DIVIDENDO	39.86
682	56	9	2025-12-19	DIVIDENDO	41.85
683	57	9	2025-12-19	DIVIDENDO	135.52
684	62	9	2025-12-19	DIVIDENDO	115.59
685	63	9	2025-12-19	DIVIDENDO	9.97
686	64	9	2025-12-19	DIVIDENDO	3.99
687	67	9	2025-12-19	DIVIDENDO	9.97
688	69	9	2025-12-19	DIVIDENDO	7.97
689	72	9	2025-12-19	DIVIDENDO	5.98
690	2	10	2025-12-22	DIVIDENDO	5.56
691	3	10	2025-12-22	DIVIDENDO	10.32
692	5	10	2025-12-22	DIVIDENDO	7.15
693	7	10	2025-12-22	DIVIDENDO	95.28
694	8	10	2025-12-22	DIVIDENDO	17.47
695	10	10	2025-12-22	DIVIDENDO	4.76
696	13	10	2025-12-22	DIVIDENDO	26.20
697	15	10	2025-12-22	DIVIDENDO	67.49
698	20	10	2025-12-22	DIVIDENDO	19.85
699	27	10	2025-12-22	DIVIDENDO	2.38
700	33	10	2025-12-22	DIVIDENDO	20.64
701	37	10	2025-12-22	DIVIDENDO	1.59
702	42	10	2025-12-22	DIVIDENDO	10.32
703	44	10	2025-12-22	DIVIDENDO	3.97
704	46	10	2025-12-22	DIVIDENDO	6.35
705	59	10	2025-12-22	DIVIDENDO	15.09
706	60	10	2025-12-22	DIVIDENDO	14.29
707	61	10	2025-12-22	DIVIDENDO	36.52
708	67	10	2025-12-22	DIVIDENDO	2.38
709	68	10	2025-12-22	DIVIDENDO	3.97
710	69	10	2025-12-22	DIVIDENDO	3.97
711	70	10	2025-12-22	DIVIDENDO	6.35
712	1	3	2026-02-09	DIVIDENDO	1.56
713	5	3	2026-02-09	DIVIDENDO	4.68
714	14	3	2026-02-09	DIVIDENDO	2.08
715	19	3	2026-02-09	DIVIDENDO	5.20
716	23	3	2026-02-09	DIVIDENDO	0.52
717	26	3	2026-02-09	DIVIDENDO	14.04
718	27	3	2026-02-09	DIVIDENDO	10.40
719	36	3	2026-02-09	DIVIDENDO	6.24
720	40	3	2026-02-09	DIVIDENDO	14.04
721	41	3	2026-02-09	DIVIDENDO	1.30
722	52	3	2026-02-09	DIVIDENDO	3.38
723	54	3	2026-02-09	DIVIDENDO	6.24
724	55	3	2026-02-09	DIVIDENDO	25.48
725	60	3	2026-02-09	DIVIDENDO	3.38
726	61	3	2026-02-09	DIVIDENDO	17.16
727	66	3	2026-02-09	DIVIDENDO	27.56
728	68	3	2026-02-09	DIVIDENDO	2.34
729	71	3	2026-02-09	DIVIDENDO	2.60
730	72	3	2026-02-09	DIVIDENDO	3.12
731	77	3	2026-02-09	DIVIDENDO	8.32
732	78	3	2026-02-09	DIVIDENDO	5.20
733	79	3	2026-02-09	DIVIDENDO	8.58
734	80	3	2026-02-09	DIVIDENDO	33.02
735	1	4	2026-02-19	DIVIDENDO	19.11
736	5	4	2026-02-19	DIVIDENDO	21.84
737	9	4	2026-02-19	DIVIDENDO	31.85
738	11	4	2026-02-19	DIVIDENDO	2.73
739	16	4	2026-02-19	DIVIDENDO	12.74
740	22	4	2026-02-19	DIVIDENDO	3.64
741	25	4	2026-02-19	DIVIDENDO	9.10
742	26	4	2026-02-19	DIVIDENDO	14.56
743	28	4	2026-02-19	DIVIDENDO	30.03
744	30	4	2026-02-19	DIVIDENDO	88.27
745	31	4	2026-02-19	DIVIDENDO	2.73
746	32	4	2026-02-19	DIVIDENDO	13.65
747	33	4	2026-02-19	DIVIDENDO	3.64
748	37	4	2026-02-19	DIVIDENDO	12.74
749	40	4	2026-02-19	DIVIDENDO	49.14
750	43	4	2026-02-19	DIVIDENDO	8.19
751	45	4	2026-02-19	DIVIDENDO	219.31
752	49	4	2026-02-19	DIVIDENDO	3.64
753	52	4	2026-02-19	DIVIDENDO	6.37
754	56	4	2026-02-19	DIVIDENDO	5.46
755	64	4	2026-02-19	DIVIDENDO	7.28
756	66	4	2026-02-19	DIVIDENDO	8.19
757	67	4	2026-02-19	DIVIDENDO	28.21
758	68	4	2026-02-19	DIVIDENDO	3.64
759	70	4	2026-02-19	DIVIDENDO	9.10
760	80	4	2026-02-19	DIVIDENDO	5.46
761	2	8	2026-02-24	DIVIDENDO	50.70
762	6	8	2026-02-24	DIVIDENDO	475.80
763	7	8	2026-02-24	DIVIDENDO	440.70
764	8	8	2026-02-24	DIVIDENDO	9.10
765	9	8	2026-02-24	DIVIDENDO	66.30
766	10	8	2026-02-24	DIVIDENDO	13.00
767	13	8	2026-02-24	DIVIDENDO	11.70
768	16	8	2026-02-24	DIVIDENDO	166.40
769	17	8	2026-02-24	DIVIDENDO	28.60
770	18	8	2026-02-24	DIVIDENDO	497.90
771	24	8	2026-02-24	DIVIDENDO	7.80
772	26	8	2026-02-24	DIVIDENDO	36.40
773	29	8	2026-02-24	DIVIDENDO	115.70
774	33	8	2026-02-24	DIVIDENDO	62.40
775	36	8	2026-02-24	DIVIDENDO	46.80
776	37	8	2026-02-24	DIVIDENDO	58.50
777	38	8	2026-02-24	DIVIDENDO	161.20
778	51	8	2026-02-24	DIVIDENDO	11.70
779	53	8	2026-02-24	DIVIDENDO	67.60
780	55	8	2026-02-24	DIVIDENDO	183.30
781	56	8	2026-02-24	DIVIDENDO	46.80
782	58	8	2026-02-24	DIVIDENDO	15.60
783	59	8	2026-02-24	DIVIDENDO	36.40
784	62	8	2026-02-24	DIVIDENDO	18.20
785	68	8	2026-02-24	DIVIDENDO	1.30
786	73	8	2026-02-24	DIVIDENDO	27.30
787	75	8	2026-02-24	DIVIDENDO	35.10
788	76	8	2026-02-24	DIVIDENDO	19.50
789	77	8	2026-02-24	DIVIDENDO	126.10
790	19	6	2026-03-09	DIVIDENDO	2.73
791	20	6	2026-03-09	DIVIDENDO	9.45
792	21	6	2026-03-09	DIVIDENDO	5.46
793	23	6	2026-03-09	DIVIDENDO	0.84
794	24	6	2026-03-09	DIVIDENDO	3.57
795	30	6	2026-03-09	DIVIDENDO	14.49
796	31	6	2026-03-09	DIVIDENDO	4.62
797	34	6	2026-03-09	DIVIDENDO	1.89
798	41	6	2026-03-09	DIVIDENDO	0.63
799	45	6	2026-03-09	DIVIDENDO	80.85
800	47	6	2026-03-09	DIVIDENDO	1.68
801	58	6	2026-03-09	DIVIDENDO	15.33
802	59	6	2026-03-09	DIVIDENDO	28.14
803	64	6	2026-03-09	DIVIDENDO	0.42
804	65	6	2026-03-09	DIVIDENDO	3.15
805	69	6	2026-03-09	DIVIDENDO	3.15
806	71	6	2026-03-09	DIVIDENDO	9.87
807	77	6	2026-03-09	DIVIDENDO	8.40
808	1	9	2026-03-20	DIVIDENDO	35.94
809	3	9	2026-03-20	DIVIDENDO	7.19
810	6	9	2026-03-20	DIVIDENDO	37.74
811	15	9	2026-03-20	DIVIDENDO	115.01
812	21	9	2026-03-20	DIVIDENDO	39.53
813	26	9	2026-03-20	DIVIDENDO	19.77
814	32	9	2026-03-20	DIVIDENDO	17.97
815	40	9	2026-03-20	DIVIDENDO	17.97
816	44	9	2026-03-20	DIVIDENDO	23.36
817	49	9	2026-03-20	DIVIDENDO	7.19
818	54	9	2026-03-20	DIVIDENDO	35.94
819	56	9	2026-03-20	DIVIDENDO	37.74
820	57	9	2026-03-20	DIVIDENDO	75.47
821	62	9	2026-03-20	DIVIDENDO	104.23
822	63	9	2026-03-20	DIVIDENDO	8.99
823	64	9	2026-03-20	DIVIDENDO	3.59
824	69	9	2026-03-20	DIVIDENDO	7.19
825	72	9	2026-03-20	DIVIDENDO	5.39
826	2	10	2026-03-23	DIVIDENDO	9.53
827	3	10	2026-03-23	DIVIDENDO	11.00
828	5	10	2026-03-23	DIVIDENDO	6.60
829	7	10	2026-03-23	DIVIDENDO	87.96
830	8	10	2026-03-23	DIVIDENDO	16.13
831	10	10	2026-03-23	DIVIDENDO	4.40
832	13	10	2026-03-23	DIVIDENDO	13.19
833	15	10	2026-03-23	DIVIDENDO	62.31
834	17	10	2026-03-23	DIVIDENDO	69.64
835	20	10	2026-03-23	DIVIDENDO	11.73
836	27	10	2026-03-23	DIVIDENDO	1.47
837	33	10	2026-03-23	DIVIDENDO	23.46
838	37	10	2026-03-23	DIVIDENDO	1.47
839	42	10	2026-03-23	DIVIDENDO	11.73
840	44	10	2026-03-23	DIVIDENDO	3.67
841	46	10	2026-03-23	DIVIDENDO	4.40
842	59	10	2026-03-23	DIVIDENDO	13.93
843	60	10	2026-03-23	DIVIDENDO	13.19
844	61	10	2026-03-23	DIVIDENDO	33.72
845	67	10	2026-03-23	DIVIDENDO	2.20
846	68	10	2026-03-23	DIVIDENDO	3.67
847	69	10	2026-03-23	DIVIDENDO	3.67
848	70	10	2026-03-23	DIVIDENDO	5.86
849	8	2	2026-03-31	DIVIDENDO	216.80
850	10	2	2026-03-31	DIVIDENDO	10.96
851	12	2	2026-03-31	DIVIDENDO	97.44
852	14	2	2026-03-31	DIVIDENDO	271.61
853	16	2	2026-03-31	DIVIDENDO	345.91
854	19	2	2026-03-31	DIVIDENDO	70.64
855	21	2	2026-03-31	DIVIDENDO	226.55
856	23	2	2026-03-31	DIVIDENDO	101.09
857	24	2	2026-03-31	DIVIDENDO	24.36
858	29	2	2026-03-31	DIVIDENDO	621.18
859	40	2	2026-03-31	DIVIDENDO	181.48
860	41	2	2026-03-31	DIVIDENDO	15.83
861	44	2	2026-03-31	DIVIDENDO	57.25
862	51	2	2026-03-31	DIVIDENDO	38.98
863	52	2	2026-03-31	DIVIDENDO	21.92
864	60	2	2026-03-31	DIVIDENDO	118.15
865	65	2	2026-03-31	DIVIDENDO	2902.49
866	66	2	2026-03-31	DIVIDENDO	123.02
867	68	2	2026-03-31	DIVIDENDO	107.18
868	70	2	2026-03-31	DIVIDENDO	20.71
869	73	2	2026-03-31	DIVIDENDO	92.57
870	74	2	2026-03-31	DIVIDENDO	53.59
871	78	2	2026-03-31	DIVIDENDO	102.31
872	3	1	2026-04-29	DIVIDENDO	120.30
873	4	1	2026-04-29	DIVIDENDO	26.44
874	6	1	2026-04-29	DIVIDENDO	1072.80
875	9	1	2026-04-29	DIVIDENDO	687.44
876	15	1	2026-04-29	DIVIDENDO	2129.74
877	20	1	2026-04-29	DIVIDENDO	94.52
878	25	1	2026-04-29	DIVIDENDO	117.66
879	26	1	2026-04-29	DIVIDENDO	226.06
880	28	1	2026-04-29	DIVIDENDO	1042.40
881	29	1	2026-04-29	DIVIDENDO	130.22
882	34	1	2026-04-29	DIVIDENDO	140.79
883	38	1	2026-04-29	DIVIDENDO	556.56
884	42	1	2026-04-29	DIVIDENDO	456.75
885	44	1	2026-04-29	DIVIDENDO	546.65
886	48	1	2026-04-29	DIVIDENDO	187.06
887	49	1	2026-04-29	DIVIDENDO	42.97
888	50	1	2026-04-29	DIVIDENDO	452.79
889	51	1	2026-04-29	DIVIDENDO	939.28
890	55	1	2026-04-29	DIVIDENDO	1308.78
891	57	1	2026-04-29	DIVIDENDO	3266.66
892	61	1	2026-04-29	DIVIDENDO	243.25
893	62	1	2026-04-29	DIVIDENDO	482.53
894	64	1	2026-04-29	DIVIDENDO	98.49
895	65	1	2026-04-29	DIVIDENDO	2236.82
896	71	1	2026-04-29	DIVIDENDO	1396.69
897	74	1	2026-04-29	DIVIDENDO	389.33
898	79	1	2026-04-29	DIVIDENDO	64.78
899	1	3	2026-05-11	DIVIDENDO	1.08
900	5	3	2026-05-11	DIVIDENDO	12.42
901	14	3	2026-05-11	DIVIDENDO	4.05
902	19	3	2026-05-11	DIVIDENDO	5.40
903	23	3	2026-05-11	DIVIDENDO	0.27
904	26	3	2026-05-11	DIVIDENDO	21.06
905	27	3	2026-05-11	DIVIDENDO	10.80
906	36	3	2026-05-11	DIVIDENDO	6.48
907	39	3	2026-05-11	DIVIDENDO	48.06
908	40	3	2026-05-11	DIVIDENDO	14.58
909	41	3	2026-05-11	DIVIDENDO	1.35
910	52	3	2026-05-11	DIVIDENDO	3.51
911	54	3	2026-05-11	DIVIDENDO	14.04
912	55	3	2026-05-11	DIVIDENDO	38.34
913	60	3	2026-05-11	DIVIDENDO	3.51
914	61	3	2026-05-11	DIVIDENDO	8.37
915	62	3	2026-05-11	DIVIDENDO	10.26
916	66	3	2026-05-11	DIVIDENDO	15.12
917	68	3	2026-05-11	DIVIDENDO	2.43
918	69	3	2026-05-11	DIVIDENDO	0.54
919	71	3	2026-05-11	DIVIDENDO	2.70
920	72	3	2026-05-11	DIVIDENDO	4.32
921	77	3	2026-05-11	DIVIDENDO	4.59
922	78	3	2026-05-11	DIVIDENDO	6.48
923	79	3	2026-05-11	DIVIDENDO	4.05
924	80	3	2026-05-11	DIVIDENDO	34.29
925	1	4	2026-05-21	DIVIDENDO	27.30
926	5	4	2026-05-21	DIVIDENDO	30.94
927	9	4	2026-05-21	DIVIDENDO	38.22
928	11	4	2026-05-21	DIVIDENDO	2.73
929	16	4	2026-05-21	DIVIDENDO	12.74
930	21	4	2026-05-21	DIVIDENDO	19.11
931	25	4	2026-05-21	DIVIDENDO	9.10
932	26	4	2026-05-21	DIVIDENDO	29.12
933	28	4	2026-05-21	DIVIDENDO	30.03
934	30	4	2026-05-21	DIVIDENDO	88.27
935	31	4	2026-05-21	DIVIDENDO	2.73
936	32	4	2026-05-21	DIVIDENDO	13.65
937	33	4	2026-05-21	DIVIDENDO	3.64
938	37	4	2026-05-21	DIVIDENDO	12.74
939	40	4	2026-05-21	DIVIDENDO	49.14
940	43	4	2026-05-21	DIVIDENDO	8.19
941	45	4	2026-05-21	DIVIDENDO	219.31
942	49	4	2026-05-21	DIVIDENDO	5.46
943	52	4	2026-05-21	DIVIDENDO	6.37
944	56	4	2026-05-21	DIVIDENDO	2.73
945	64	4	2026-05-21	DIVIDENDO	7.28
946	66	4	2026-05-21	DIVIDENDO	8.19
947	67	4	2026-05-21	DIVIDENDO	28.21
948	68	4	2026-05-21	DIVIDENDO	3.64
949	70	4	2026-05-21	DIVIDENDO	9.10
950	80	4	2026-05-21	DIVIDENDO	3.64
951	2	8	2026-05-26	DIVIDENDO	52.26
952	6	8	2026-05-26	DIVIDENDO	490.44
953	7	8	2026-05-26	DIVIDENDO	454.26
954	8	8	2026-05-26	DIVIDENDO	9.38
955	9	8	2026-05-26	DIVIDENDO	68.34
956	10	8	2026-05-26	DIVIDENDO	13.40
957	13	8	2026-05-26	DIVIDENDO	12.06
958	16	8	2026-05-26	DIVIDENDO	129.98
959	17	8	2026-05-26	DIVIDENDO	29.48
960	18	8	2026-05-26	DIVIDENDO	612.38
961	19	8	2026-05-26	DIVIDENDO	28.14
962	24	8	2026-05-26	DIVIDENDO	10.72
963	26	8	2026-05-26	DIVIDENDO	37.52
964	29	8	2026-05-26	DIVIDENDO	119.26
965	33	8	2026-05-26	DIVIDENDO	49.58
966	36	8	2026-05-26	DIVIDENDO	48.24
967	37	8	2026-05-26	DIVIDENDO	60.30
968	38	8	2026-05-26	DIVIDENDO	166.16
969	39	8	2026-05-26	DIVIDENDO	266.66
970	51	8	2026-05-26	DIVIDENDO	12.06
971	53	8	2026-05-26	DIVIDENDO	69.68
972	55	8	2026-05-26	DIVIDENDO	188.94
973	56	8	2026-05-26	DIVIDENDO	48.24
974	58	8	2026-05-26	DIVIDENDO	16.08
975	59	8	2026-05-26	DIVIDENDO	56.28
976	62	8	2026-05-26	DIVIDENDO	18.76
977	68	8	2026-05-26	DIVIDENDO	1.34
978	73	8	2026-05-26	DIVIDENDO	28.14
979	75	8	2026-05-26	DIVIDENDO	36.18
980	76	8	2026-05-26	DIVIDENDO	20.10
981	77	8	2026-05-26	DIVIDENDO	129.98
982	19	6	2026-06-08	DIVIDENDO	2.86
983	20	6	2026-06-08	DIVIDENDO	12.10
984	21	6	2026-06-08	DIVIDENDO	5.72
985	23	6	2026-06-08	DIVIDENDO	0.88
986	24	6	2026-06-08	DIVIDENDO	3.74
987	30	6	2026-06-08	DIVIDENDO	23.10
988	31	6	2026-06-08	DIVIDENDO	2.42
989	34	6	2026-06-08	DIVIDENDO	1.98
990	41	6	2026-06-08	DIVIDENDO	0.66
991	42	6	2026-06-08	DIVIDENDO	11.88
992	45	6	2026-06-08	DIVIDENDO	84.70
993	47	6	2026-06-08	DIVIDENDO	1.76
994	58	6	2026-06-08	DIVIDENDO	7.70
995	59	6	2026-06-08	DIVIDENDO	29.48
996	64	6	2026-06-08	DIVIDENDO	0.22
997	65	6	2026-06-08	DIVIDENDO	18.48
998	69	6	2026-06-08	DIVIDENDO	3.30
999	71	6	2026-06-08	DIVIDENDO	10.34
1000	77	6	2026-06-08	DIVIDENDO	8.80
1001	1	9	2026-06-18	DIVIDENDO	38.08
1002	3	9	2026-06-18	DIVIDENDO	7.62
1003	6	9	2026-06-18	DIVIDENDO	39.98
1004	7	9	2026-06-18	DIVIDENDO	24.75
1005	15	9	2026-06-18	DIVIDENDO	121.86
1006	21	9	2026-06-18	DIVIDENDO	41.89
1007	26	9	2026-06-18	DIVIDENDO	38.08
1008	32	9	2026-06-18	DIVIDENDO	13.33
1009	40	9	2026-06-18	DIVIDENDO	19.04
1010	44	9	2026-06-18	DIVIDENDO	24.75
1011	49	9	2026-06-18	DIVIDENDO	7.62
1012	54	9	2026-06-18	DIVIDENDO	38.08
1013	56	9	2026-06-18	DIVIDENDO	39.98
1014	57	9	2026-06-18	DIVIDENDO	76.16
1015	62	9	2026-06-18	DIVIDENDO	110.43
1016	63	9	2026-06-18	DIVIDENDO	7.62
1017	64	9	2026-06-18	DIVIDENDO	3.81
1018	69	9	2026-06-18	DIVIDENDO	7.62
1019	72	9	2026-06-18	DIVIDENDO	5.71
1020	2	10	2026-06-22	DIVIDENDO	10.57
1021	3	10	2026-06-22	DIVIDENDO	12.20
1022	5	10	2026-06-22	DIVIDENDO	7.32
1023	7	10	2026-06-22	DIVIDENDO	108.94
1024	8	10	2026-06-22	DIVIDENDO	21.14
1025	10	10	2026-06-22	DIVIDENDO	4.88
1026	13	10	2026-06-22	DIVIDENDO	14.63
1027	14	10	2026-06-22	DIVIDENDO	2.44
1028	15	10	2026-06-22	DIVIDENDO	69.11
1029	17	10	2026-06-22	DIVIDENDO	77.24
1030	18	10	2026-06-22	DIVIDENDO	9.76
1031	20	10	2026-06-22	DIVIDENDO	13.82
1032	27	10	2026-06-22	DIVIDENDO	1.63
1033	33	10	2026-06-22	DIVIDENDO	27.64
1034	37	10	2026-06-22	DIVIDENDO	1.63
1035	42	10	2026-06-22	DIVIDENDO	13.01
1036	44	10	2026-06-22	DIVIDENDO	4.07
1037	46	10	2026-06-22	DIVIDENDO	4.88
1038	51	10	2026-06-22	DIVIDENDO	2.44
1039	59	10	2026-06-22	DIVIDENDO	28.46
1040	60	10	2026-06-22	DIVIDENDO	14.63
1041	61	10	2026-06-22	DIVIDENDO	37.40
1042	67	10	2026-06-22	DIVIDENDO	2.44
1043	68	10	2026-06-22	DIVIDENDO	4.07
1044	69	10	2026-06-22	DIVIDENDO	4.07
1045	70	10	2026-06-22	DIVIDENDO	6.50
1046	72	10	2026-06-22	DIVIDENDO	0.81
1047	8	2	2026-06-30	DIVIDENDO	232.11
1048	10	2	2026-06-30	DIVIDENDO	11.74
1049	12	2	2026-06-30	DIVIDENDO	104.32
1050	14	2	2026-06-30	DIVIDENDO	333.82
1051	16	2	2026-06-30	DIVIDENDO	370.34
1052	19	2	2026-06-30	DIVIDENDO	75.63
1053	21	2	2026-06-30	DIVIDENDO	242.54
1054	23	2	2026-06-30	DIVIDENDO	108.23
1055	24	2	2026-06-30	DIVIDENDO	31.30
1056	29	2	2026-06-30	DIVIDENDO	665.04
1057	40	2	2026-06-30	DIVIDENDO	194.30
1058	41	2	2026-06-30	DIVIDENDO	16.95
1059	44	2	2026-06-30	DIVIDENDO	61.29
1060	46	2	2026-06-30	DIVIDENDO	53.46
1061	51	2	2026-06-30	DIVIDENDO	41.73
1062	52	2	2026-06-30	DIVIDENDO	23.47
1063	60	2	2026-06-30	DIVIDENDO	126.49
1064	65	2	2026-06-30	DIVIDENDO	3107.43
1065	66	2	2026-06-30	DIVIDENDO	131.70
1066	68	2	2026-06-30	DIVIDENDO	114.75
1067	70	2	2026-06-30	DIVIDENDO	22.17
1068	73	2	2026-06-30	DIVIDENDO	108.23
1069	74	2	2026-06-30	DIVIDENDO	57.38
1070	78	2	2026-06-30	DIVIDENDO	109.54
1071	1	12	2026-06-30	INTERES	304.91
1072	5	12	2026-06-30	INTERES	182.95
1073	6	12	2026-06-30	INTERES	3963.89
1074	7	12	2026-06-30	INTERES	2053.09
1075	10	12	2026-06-30	INTERES	833.43
1076	15	12	2026-06-30	INTERES	1544.90
1077	16	12	2026-06-30	INTERES	2032.76
1078	27	12	2026-06-30	INTERES	304.91
1079	36	12	2026-06-30	INTERES	121.97
1080	40	12	2026-06-30	INTERES	345.57
1081	44	12	2026-06-30	INTERES	121.97
1082	46	12	2026-06-30	INTERES	1504.24
1083	49	12	2026-06-30	INTERES	345.57
1084	51	12	2026-06-30	INTERES	1239.99
1085	52	12	2026-06-30	INTERES	264.26
1086	56	12	2026-06-30	INTERES	2073.42
1087	61	12	2026-06-30	INTERES	142.29
1088	66	12	2026-06-30	INTERES	406.55
1089	67	12	2026-06-30	INTERES	1707.52
1090	69	12	2026-06-30	INTERES	142.29
1091	70	12	2026-06-30	INTERES	813.10
1092	75	12	2026-06-30	INTERES	345.57
1093	78	12	2026-06-30	INTERES	426.88
1094	1	3	2026-08-10	DIVIDENDO	1.08
1095	3	3	2026-08-10	DIVIDENDO	1.62
1096	5	3	2026-08-10	DIVIDENDO	12.42
1097	13	3	2026-08-10	DIVIDENDO	2.16
1098	14	3	2026-08-10	DIVIDENDO	4.05
1099	19	3	2026-08-10	DIVIDENDO	9.72
1100	23	3	2026-08-10	DIVIDENDO	5.13
1101	26	3	2026-08-10	DIVIDENDO	21.06
1102	27	3	2026-08-10	DIVIDENDO	10.80
1103	36	3	2026-08-10	DIVIDENDO	6.48
1104	39	3	2026-08-10	DIVIDENDO	48.06
1105	40	3	2026-08-10	DIVIDENDO	14.58
1106	41	3	2026-08-10	DIVIDENDO	1.35
1107	52	3	2026-08-10	DIVIDENDO	3.51
1108	54	3	2026-08-10	DIVIDENDO	14.04
1109	55	3	2026-08-10	DIVIDENDO	38.34
1110	60	3	2026-08-10	DIVIDENDO	3.51
1111	61	3	2026-08-10	DIVIDENDO	8.37
1112	62	3	2026-08-10	DIVIDENDO	10.26
1113	66	3	2026-08-10	DIVIDENDO	15.12
1114	68	3	2026-08-10	DIVIDENDO	2.43
1115	69	3	2026-08-10	DIVIDENDO	0.54
1116	71	3	2026-08-10	DIVIDENDO	2.16
1117	72	3	2026-08-10	DIVIDENDO	3.51
1118	75	3	2026-08-10	DIVIDENDO	1.62
1119	77	3	2026-08-10	DIVIDENDO	4.59
1120	78	3	2026-08-10	DIVIDENDO	4.32
1121	79	3	2026-08-10	DIVIDENDO	7.83
1122	80	3	2026-08-10	DIVIDENDO	40.50
1123	1	4	2026-08-20	DIVIDENDO	27.30
1124	5	4	2026-08-20	DIVIDENDO	32.76
1125	9	4	2026-08-20	DIVIDENDO	38.22
1126	11	4	2026-08-20	DIVIDENDO	1.82
1127	16	4	2026-08-20	DIVIDENDO	12.74
1128	21	4	2026-08-20	DIVIDENDO	19.11
1129	25	4	2026-08-20	DIVIDENDO	9.10
1130	26	4	2026-08-20	DIVIDENDO	29.12
1131	28	4	2026-08-20	DIVIDENDO	30.03
1132	30	4	2026-08-20	DIVIDENDO	88.27
1133	31	4	2026-08-20	DIVIDENDO	2.73
1134	32	4	2026-08-20	DIVIDENDO	13.65
1135	33	4	2026-08-20	DIVIDENDO	7.28
1136	37	4	2026-08-20	DIVIDENDO	12.74
1137	40	4	2026-08-20	DIVIDENDO	49.14
1138	43	4	2026-08-20	DIVIDENDO	8.19
1139	45	4	2026-08-20	DIVIDENDO	219.31
1140	49	4	2026-08-20	DIVIDENDO	7.28
1141	52	4	2026-08-20	DIVIDENDO	6.37
1142	56	4	2026-08-20	DIVIDENDO	27.30
1143	64	4	2026-08-20	DIVIDENDO	7.28
1144	67	4	2026-08-20	DIVIDENDO	28.21
1145	68	4	2026-08-20	DIVIDENDO	3.64
1146	70	4	2026-08-20	DIVIDENDO	9.10
1147	80	4	2026-08-20	DIVIDENDO	16.38
1148	2	8	2026-08-25	DIVIDENDO	52.26
1149	6	8	2026-08-25	DIVIDENDO	490.44
1150	7	8	2026-08-25	DIVIDENDO	454.26
1151	8	8	2026-08-25	DIVIDENDO	49.58
1152	9	8	2026-08-25	DIVIDENDO	68.34
1153	10	8	2026-08-25	DIVIDENDO	13.40
1154	13	8	2026-08-25	DIVIDENDO	41.54
1155	16	8	2026-08-25	DIVIDENDO	129.98
1156	17	8	2026-08-25	DIVIDENDO	29.48
1157	18	8	2026-08-25	DIVIDENDO	612.38
1158	19	8	2026-08-25	DIVIDENDO	28.14
1159	24	8	2026-08-25	DIVIDENDO	10.72
1160	26	8	2026-08-25	DIVIDENDO	44.22
1161	29	8	2026-08-25	DIVIDENDO	119.26
1162	33	8	2026-08-25	DIVIDENDO	49.58
1163	36	8	2026-08-25	DIVIDENDO	48.24
1164	37	8	2026-08-25	DIVIDENDO	60.30
1165	38	8	2026-08-25	DIVIDENDO	166.16
1166	39	8	2026-08-25	DIVIDENDO	266.66
1167	51	8	2026-08-25	DIVIDENDO	12.06
1168	53	8	2026-08-25	DIVIDENDO	93.80
1169	55	8	2026-08-25	DIVIDENDO	188.94
1170	56	8	2026-08-25	DIVIDENDO	37.52
1171	59	8	2026-08-25	DIVIDENDO	72.36
1172	62	8	2026-08-25	DIVIDENDO	18.76
1173	68	8	2026-08-25	DIVIDENDO	1.34
1174	73	8	2026-08-25	DIVIDENDO	30.82
1175	75	8	2026-08-25	DIVIDENDO	36.18
1176	76	8	2026-08-25	DIVIDENDO	21.44
1177	77	8	2026-08-25	DIVIDENDO	80.40
1178	19	6	2026-09-04	DIVIDENDO	2.86
1179	20	6	2026-09-04	DIVIDENDO	12.10
1180	21	6	2026-09-04	DIVIDENDO	12.54
1181	23	6	2026-09-04	DIVIDENDO	0.44
1182	24	6	2026-09-04	DIVIDENDO	2.42
1183	30	6	2026-09-04	DIVIDENDO	23.10
1184	31	6	2026-09-04	DIVIDENDO	2.42
1185	34	6	2026-09-04	DIVIDENDO	1.98
1186	41	6	2026-09-04	DIVIDENDO	0.66
1187	42	6	2026-09-04	DIVIDENDO	11.88
1188	45	6	2026-09-04	DIVIDENDO	89.10
1189	46	6	2026-09-04	DIVIDENDO	1.76
1190	47	6	2026-09-04	DIVIDENDO	2.64
1191	50	6	2026-09-04	DIVIDENDO	1.32
1192	57	6	2026-09-04	DIVIDENDO	5.72
1193	58	6	2026-09-04	DIVIDENDO	3.52
1194	59	6	2026-09-04	DIVIDENDO	33.22
1195	64	6	2026-09-04	DIVIDENDO	0.22
1196	65	6	2026-09-04	DIVIDENDO	18.48
1197	69	6	2026-09-04	DIVIDENDO	4.62
1198	71	6	2026-09-04	DIVIDENDO	12.98
1199	77	6	2026-09-04	DIVIDENDO	9.46
1200	8	2	2026-09-08	DIVIDENDO	290.50
1201	10	2	2026-09-08	DIVIDENDO	14.69
1202	12	2	2026-09-08	DIVIDENDO	226.85
1203	14	2	2026-09-08	DIVIDENDO	417.79
1204	16	2	2026-09-08	DIVIDENDO	1144.03
1205	19	2	2026-09-08	DIVIDENDO	94.66
1206	21	2	2026-09-08	DIVIDENDO	303.55
1207	23	2	2026-09-08	DIVIDENDO	135.46
1208	24	2	2026-09-08	DIVIDENDO	39.17
1209	29	2	2026-09-08	DIVIDENDO	832.32
1210	40	2	2026-09-08	DIVIDENDO	243.17
1211	41	2	2026-09-08	DIVIDENDO	21.22
1212	44	2	2026-09-08	DIVIDENDO	76.70
1213	46	2	2026-09-08	DIVIDENDO	66.91
1214	51	2	2026-09-08	DIVIDENDO	52.22
1215	52	2	2026-09-08	DIVIDENDO	29.38
1216	60	2	2026-09-08	DIVIDENDO	158.30
1217	65	2	2026-09-08	DIVIDENDO	3889.06
1218	66	2	2026-09-08	DIVIDENDO	164.83
1219	68	2	2026-09-08	DIVIDENDO	143.62
1220	70	2	2026-09-08	DIVIDENDO	27.74
1221	73	2	2026-09-08	DIVIDENDO	135.46
1222	74	2	2026-09-08	DIVIDENDO	71.81
1223	78	2	2026-09-08	DIVIDENDO	137.09
1224	1	9	2026-09-18	DIVIDENDO	37.78
1225	3	9	2026-09-18	DIVIDENDO	11.33
1226	6	9	2026-09-18	DIVIDENDO	39.67
1227	7	9	2026-09-18	DIVIDENDO	24.56
1228	15	9	2026-09-18	DIVIDENDO	137.90
1229	21	9	2026-09-18	DIVIDENDO	41.56
1230	22	9	2026-09-18	DIVIDENDO	1.89
1231	26	9	2026-09-18	DIVIDENDO	37.78
1232	32	9	2026-09-18	DIVIDENDO	13.22
1233	40	9	2026-09-18	DIVIDENDO	18.89
1234	44	9	2026-09-18	DIVIDENDO	24.56
1235	49	9	2026-09-18	DIVIDENDO	9.45
1236	54	9	2026-09-18	DIVIDENDO	37.78
1237	56	9	2026-09-18	DIVIDENDO	39.67
1238	57	9	2026-09-18	DIVIDENDO	75.56
1239	62	9	2026-09-18	DIVIDENDO	109.56
1240	63	9	2026-09-18	DIVIDENDO	3.78
1241	64	9	2026-09-18	DIVIDENDO	3.78
1242	69	9	2026-09-18	DIVIDENDO	7.56
1243	72	9	2026-09-18	DIVIDENDO	5.67
1244	80	9	2026-09-18	DIVIDENDO	17.00
1245	2	10	2026-09-21	DIVIDENDO	12.02
1246	3	10	2026-09-21	DIVIDENDO	11.27
1247	5	10	2026-09-21	DIVIDENDO	8.26
1248	7	10	2026-09-21	DIVIDENDO	100.63
1249	8	10	2026-09-21	DIVIDENDO	19.53
1250	10	10	2026-09-21	DIVIDENDO	4.51
1251	12	10	2026-09-21	DIVIDENDO	1.50
1252	13	10	2026-09-21	DIVIDENDO	13.52
1253	14	10	2026-09-21	DIVIDENDO	2.25
1254	15	10	2026-09-21	DIVIDENDO	63.84
1255	17	10	2026-09-21	DIVIDENDO	71.35
1256	18	10	2026-09-21	DIVIDENDO	9.01
1257	20	10	2026-09-21	DIVIDENDO	12.77
1258	27	10	2026-09-21	DIVIDENDO	1.50
1259	33	10	2026-09-21	DIVIDENDO	26.29
1260	37	10	2026-09-21	DIVIDENDO	1.50
1261	42	10	2026-09-21	DIVIDENDO	12.02
1262	44	10	2026-09-21	DIVIDENDO	3.76
1263	46	10	2026-09-21	DIVIDENDO	4.51
1264	51	10	2026-09-21	DIVIDENDO	2.25
1265	59	10	2026-09-21	DIVIDENDO	26.29
1266	60	10	2026-09-21	DIVIDENDO	14.27
1267	61	10	2026-09-21	DIVIDENDO	34.55
1268	67	10	2026-09-21	DIVIDENDO	2.25
1269	68	10	2026-09-21	DIVIDENDO	3.76
1270	69	10	2026-09-21	DIVIDENDO	8.26
1271	70	10	2026-09-21	DIVIDENDO	6.01
1272	72	10	2026-09-21	DIVIDENDO	0.75
1273	8	2	2026-09-30	DIVIDENDO	257.03
1274	10	2	2026-09-30	DIVIDENDO	13.00
1275	12	2	2026-09-30	DIVIDENDO	200.72
1276	14	2	2026-09-30	DIVIDENDO	369.66
1277	16	2	2026-09-30	DIVIDENDO	1012.24
1278	19	2	2026-09-30	DIVIDENDO	83.75
1279	21	2	2026-09-30	DIVIDENDO	268.58
1280	23	2	2026-09-30	DIVIDENDO	119.85
1281	24	2	2026-09-30	DIVIDENDO	34.66
1282	29	2	2026-09-30	DIVIDENDO	736.44
1283	40	2	2026-09-30	DIVIDENDO	215.16
1284	41	2	2026-09-30	DIVIDENDO	18.77
1285	44	2	2026-09-30	DIVIDENDO	67.87
1286	46	2	2026-09-30	DIVIDENDO	59.20
1287	51	2	2026-09-30	DIVIDENDO	46.21
1288	52	2	2026-09-30	DIVIDENDO	25.99
1289	60	2	2026-09-30	DIVIDENDO	140.07
1290	65	2	2026-09-30	DIVIDENDO	3441.05
1291	66	2	2026-09-30	DIVIDENDO	145.84
1292	68	2	2026-09-30	DIVIDENDO	127.07
1293	70	2	2026-09-30	DIVIDENDO	73.64
1294	73	2	2026-09-30	DIVIDENDO	119.85
1295	74	2	2026-09-30	DIVIDENDO	63.54
1296	78	2	2026-09-30	DIVIDENDO	121.30
1297	3	13	2026-10-09	INTERES	368.93
1298	4	13	2026-10-09	INTERES	252.43
1299	5	13	2026-10-09	INTERES	291.26
1300	8	13	2026-10-09	INTERES	601.94
1301	9	13	2026-10-09	INTERES	543.69
1302	12	13	2026-10-09	INTERES	77.67
1303	16	13	2026-10-09	INTERES	271.84
1304	17	13	2026-10-09	INTERES	1825.24
1305	26	13	2026-10-09	INTERES	97.09
1306	38	13	2026-10-09	INTERES	601.94
1307	42	13	2026-10-09	INTERES	1223.30
1308	46	13	2026-10-09	INTERES	893.20
1309	54	13	2026-10-09	INTERES	194.17
1310	55	13	2026-10-09	INTERES	368.93
1311	56	13	2026-10-09	INTERES	524.27
1312	61	13	2026-10-09	INTERES	1223.30
1313	67	13	2026-10-09	INTERES	582.52
1314	68	13	2026-10-09	INTERES	135.92
1315	73	13	2026-10-09	INTERES	1922.33
1316	78	13	2026-10-09	INTERES	563.11
1317	3	11	2026-11-03	INTERES	162.58
1318	7	11	2026-11-03	INTERES	379.36
1319	9	11	2026-11-03	INTERES	2240.03
1320	10	11	2026-11-03	INTERES	144.52
1321	13	11	2026-11-03	INTERES	469.68
1322	15	11	2026-11-03	INTERES	4552.32
1323	25	11	2026-11-03	INTERES	144.52
1324	27	11	2026-11-03	INTERES	126.45
1325	39	11	2026-11-03	INTERES	1120.02
1326	40	11	2026-11-03	INTERES	1101.95
1327	42	11	2026-11-03	INTERES	776.79
1328	45	11	2026-11-03	INTERES	307.10
1329	48	11	2026-11-03	INTERES	126.45
1330	55	11	2026-11-03	INTERES	758.72
1331	57	11	2026-11-03	INTERES	108.39
1332	66	11	2026-11-03	INTERES	162.58
1333	68	11	2026-11-03	INTERES	379.36
1334	69	11	2026-11-03	INTERES	523.88
1335	70	11	2026-11-03	INTERES	270.97
1336	74	11	2026-11-03	INTERES	180.65
1337	75	11	2026-11-03	INTERES	289.04
1338	78	11	2026-11-03	INTERES	2781.98
1339	79	11	2026-11-03	INTERES	126.45
1340	1	3	2026-11-12	DIVIDENDO	2.70
1341	3	3	2026-11-12	DIVIDENDO	1.35
1342	5	3	2026-11-12	DIVIDENDO	12.42
1343	13	3	2026-11-12	DIVIDENDO	5.13
1344	14	3	2026-11-12	DIVIDENDO	4.05
1345	19	3	2026-11-12	DIVIDENDO	9.72
1346	26	3	2026-11-12	DIVIDENDO	21.06
1347	27	3	2026-11-12	DIVIDENDO	10.80
1348	36	3	2026-11-12	DIVIDENDO	6.48
1349	39	3	2026-11-12	DIVIDENDO	48.06
1350	40	3	2026-11-12	DIVIDENDO	14.58
1351	41	3	2026-11-12	DIVIDENDO	1.35
1352	52	3	2026-11-12	DIVIDENDO	3.51
1353	54	3	2026-11-12	DIVIDENDO	14.04
1354	55	3	2026-11-12	DIVIDENDO	38.34
1355	60	3	2026-11-12	DIVIDENDO	3.51
1356	61	3	2026-11-12	DIVIDENDO	4.05
1357	62	3	2026-11-12	DIVIDENDO	10.26
1358	66	3	2026-11-12	DIVIDENDO	15.12
1359	68	3	2026-11-12	DIVIDENDO	2.43
1360	69	3	2026-11-12	DIVIDENDO	0.54
1361	71	3	2026-11-12	DIVIDENDO	2.16
1362	72	3	2026-11-12	DIVIDENDO	3.51
1363	75	3	2026-11-12	DIVIDENDO	1.62
1364	77	3	2026-11-12	DIVIDENDO	4.59
1365	78	3	2026-11-12	DIVIDENDO	4.59
1366	79	3	2026-11-12	DIVIDENDO	7.83
1367	80	3	2026-11-12	DIVIDENDO	40.50
\.


--
-- Data for Name: tes; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.tes (id_activo, id_tipo_activo, serie, tasa_cupon, fecha_emision, fecha_vencimiento) FROM stdin;
11	4	TFIT08031127	0.0575	2019-11-03	2027-11-03
12	4	TFIT16300632	0.0700	2016-06-30	2032-06-30
13	4	TFIT16091036	0.0625	2020-10-09	2036-10-09
\.


--
-- Data for Name: tipo_activo; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.tipo_activo (id_tipo_activo, nombre_tipo, clase_activo) FROM stdin;
1	ACCION	RENTA_VARIABLE
2	FONDO	RENTA_VARIABLE
3	CDT	RENTA_FIJA
4	TES	RENTA_FIJA
\.


--
-- Data for Name: transaccion; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.transaccion (id_transaccion, id_cuenta, id_activo, tipo_transaccion, fecha_hora, cantidad, precio_unitario, tasa_comision, tasa_pactada) FROM stdin;
1	16	8	COMPRA	2024-01-29 11:30:00	104.000000	159.3600	0.0050	\N
2	16	12	COMPRA	2024-01-29 11:33:00	84.000000	254.7602	0.0050	0.1040
3	16	83	COMPRA	2024-01-29 11:36:00	1.000000	32319.9700	0.0050	0.1034
4	40	4	COMPRA	2024-01-30 10:15:00	35.000000	408.5900	0.0050	\N
5	40	11	COMPRA	2024-01-30 10:18:00	61.000000	255.1717	0.0050	0.1148
6	40	165	COMPRA	2024-01-30 10:21:00	1.000000	23625.4900	0.0050	0.0994
7	70	10	COMPRA	2024-02-07 09:45:00	11.000000	431.9900	0.0050	\N
8	70	7	COMPRA	2024-02-07 09:48:00	27.000000	187.5800	0.0050	\N
9	70	12	COMPRA	2024-02-07 09:51:00	34.000000	253.1280	0.0050	0.1033
10	70	296	COMPRA	2024-02-07 09:54:00	1.000000	12918.0000	0.0050	0.1059
11	51	1	COMPRA	2024-02-12 11:32:00	627.000000	11.9000	0.0050	\N
12	51	1	COMPRA	2024-02-12 11:35:00	627.000000	11.9000	0.0050	\N
13	51	2	COMPRA	2024-02-12 11:38:00	236.000000	31.5300	0.0050	\N
14	51	12	COMPRA	2024-02-12 11:41:00	61.000000	254.7070	0.0050	0.1019
15	51	212	COMPRA	2024-02-12 11:44:00	1.000000	20191.1400	0.0050	0.0994
16	69	10	COMPRA	2024-02-22 09:38:00	6.000000	438.0700	0.0050	\N
17	69	11	COMPRA	2024-02-22 09:41:00	29.000000	254.4361	0.0050	0.0927
18	69	289	COMPRA	2024-02-22 09:44:00	1.000000	11239.4800	0.0050	0.1074
19	66	3	COMPRA	2024-02-27 13:17:00	45.000000	182.6300	0.0050	\N
20	66	3	COMPRA	2024-02-27 13:20:00	45.000000	182.6300	0.0050	\N
21	66	274	COMPRA	2024-02-27 13:23:00	1.000000	43505.6000	0.0050	0.0894
22	15	1	COMPRA	2024-03-14 11:20:00	2691.000000	10.7700	0.0050	\N
23	15	10	COMPRA	2024-03-14 11:23:00	66.000000	439.1400	0.0050	\N
24	15	9	COMPRA	2024-03-14 11:26:00	56.000000	514.9500	0.0050	\N
25	15	11	COMPRA	2024-03-14 11:29:00	252.000000	255.8841	0.0050	0.0938
26	15	75	COMPRA	2024-03-14 11:32:00	1.000000	83555.7700	0.0050	0.1110
27	29	8	COMPRA	2024-03-18 13:01:00	108.000000	156.7600	0.0050	\N
28	29	2	COMPRA	2024-03-18 13:04:00	514.000000	33.1600	0.0050	\N
29	29	139	COMPRA	2024-03-18 13:07:00	1.000000	8163.8200	0.0050	0.0993
30	40	4	COMPRA	2024-04-10 10:18:00	5.000000	423.2600	0.0050	\N
31	40	2	COMPRA	2024-04-10 10:21:00	70.000000	35.8100	0.0050	\N
32	40	4	COMPRA	2024-04-10 10:24:00	5.000000	423.2600	0.0050	\N
33	40	166	COMPRA	2024-04-10 10:27:00	1.000000	6944.5100	0.0050	0.0998
34	5	4	COMPRA	2024-04-15 10:10:00	10.000000	413.6400	0.0050	\N
35	5	4	COMPRA	2024-04-15 10:13:00	10.000000	413.6400	0.0050	\N
36	5	28	COMPRA	2024-04-15 10:16:00	1.000000	17400.5100	0.0050	0.0955
37	69	10	VENTA	2024-04-17 09:38:00	1.000000	425.8400	0.0050	\N
38	49	4	COMPRA	2024-04-19 11:18:00	4.000000	399.1200	0.0050	\N
39	49	5	COMPRA	2024-04-19 11:21:00	11.000000	174.6300	0.0050	\N
40	49	12	COMPRA	2024-04-19 11:24:00	17.000000	255.2173	0.0050	0.1032
41	49	203	COMPRA	2024-04-19 11:27:00	1.000000	6550.5600	0.0050	0.1057
42	22	4	COMPRA	2024-04-22 12:09:00	6.000000	400.9600	0.0050	\N
43	22	118	COMPRA	2024-04-22 12:12:00	1.000000	38294.7100	0.0050	0.1154
44	51	2	VENTA	2024-04-25 11:32:00	236.000000	31.3900	0.0050	\N
45	59	8	COMPRA	2024-04-29 12:28:00	132.000000	146.8200	0.0050	\N
46	59	10	COMPRA	2024-04-29 12:31:00	44.000000	432.7500	0.0050	\N
47	59	6	COMPRA	2024-04-29 12:34:00	116.000000	166.1500	0.0050	\N
48	59	249	COMPRA	2024-04-29 12:37:00	1.000000	16220.9500	0.0050	0.0944
49	26	9	COMPRA	2024-05-01 12:37:00	18.000000	500.3500	0.0050	\N
50	26	129	COMPRA	2024-05-01 12:40:00	1.000000	12052.6700	0.0050	0.1047
51	19	6	COMPRA	2024-05-06 11:51:00	32.000000	168.1000	0.0050	\N
52	19	3	COMPRA	2024-05-06 11:54:00	29.000000	181.7100	0.0050	\N
53	19	8	COMPRA	2024-05-06 11:57:00	36.000000	148.5800	0.0050	\N
54	16	8	VENTA	2024-05-09 11:27:00	53.000000	149.8500	0.0050	\N
55	8	10	COMPRA	2024-05-16 10:31:00	10.000000	451.9800	0.0050	\N
56	8	2	COMPRA	2024-05-16 10:34:00	137.000000	35.9000	0.0050	\N
57	8	10	COMPRA	2024-05-16 10:37:00	10.000000	451.9800	0.0050	\N
58	8	40	COMPRA	2024-05-16 10:40:00	1.000000	28224.2600	0.0050	0.1029
59	70	4	COMPRA	2024-05-17 09:45:00	5.000000	420.2100	0.0050	\N
60	70	12	COMPRA	2024-05-17 09:48:00	6.000000	261.1662	0.0050	0.1176
61	70	297	COMPRA	2024-05-17 09:51:00	1.000000	2698.1500	0.0050	0.0967
62	20	1	COMPRA	2024-05-20 11:58:00	721.000000	12.3000	0.0050	\N
63	20	101	COMPRA	2024-05-20 12:01:00	1.000000	42643.3300	0.0050	0.1010
64	75	3	COMPRA	2024-05-22 10:20:00	38.000000	190.9000	0.0050	\N
65	75	318	COMPRA	2024-05-22 10:23:00	1.000000	98335.9900	0.0050	0.1252
66	29	8	COMPRA	2024-05-23 13:01:00	25.000000	149.7000	0.0050	\N
67	29	140	COMPRA	2024-05-23 13:04:00	1.000000	1808.9800	0.0050	0.0917
68	40	3	COMPRA	2024-05-30 10:18:00	20.000000	191.2900	0.0050	\N
69	40	4	COMPRA	2024-05-30 10:21:00	9.000000	414.6700	0.0050	\N
70	40	167	COMPRA	2024-05-30 10:24:00	1.000000	10590.5600	0.0050	0.0899
71	42	10	COMPRA	2024-05-30 10:29:00	18.000000	451.5500	0.0050	\N
72	42	174	COMPRA	2024-05-30 10:32:00	1.000000	42441.4600	0.0050	0.0978
73	6	9	COMPRA	2024-06-03 10:17:00	72.000000	527.8000	0.0050	\N
74	6	8	COMPRA	2024-06-03 10:20:00	260.000000	147.7400	0.0050	\N
75	6	9	COMPRA	2024-06-03 10:23:00	72.000000	527.8000	0.0050	\N
76	6	12	COMPRA	2024-06-03 10:26:00	195.000000	259.0056	0.0050	0.0979
77	6	34	COMPRA	2024-06-03 10:29:00	1.000000	70659.2800	0.0050	0.0991
78	27	3	COMPRA	2024-06-12 12:44:00	13.000000	213.0700	0.0050	\N
79	27	3	COMPRA	2024-06-12 12:47:00	13.000000	213.0700	0.0050	\N
80	27	134	COMPRA	2024-06-12 12:50:00	1.000000	30930.0100	0.0050	0.1130
81	69	10	COMPRA	2024-06-25 09:38:00	3.000000	479.3800	0.0050	\N
82	69	290	COMPRA	2024-06-25 09:41:00	1.000000	4578.9800	0.0050	0.0971
83	19	8	COMPRA	2024-06-25 11:51:00	16.000000	147.1900	0.0050	\N
84	30	5	COMPRA	2024-06-25 13:05:00	307.000000	186.3400	0.0050	\N
85	30	5	COMPRA	2024-06-25 13:08:00	307.000000	186.3400	0.0050	\N
86	30	4	COMPRA	2024-06-25 13:11:00	127.000000	450.9500	0.0050	\N
87	30	142	COMPRA	2024-06-25 13:14:00	1.000000	48970.0800	0.0050	0.0958
88	5	3	COMPRA	2024-07-01 10:10:00	9.000000	216.7500	0.0050	\N
89	5	4	COMPRA	2024-07-01 10:13:00	4.000000	456.7300	0.0050	\N
90	5	10	COMPRA	2024-07-01 10:16:00	4.000000	481.9200	0.0050	\N
91	5	29	COMPRA	2024-07-01 10:19:00	1.000000	1021.4500	0.0050	0.0900
92	49	1	COMPRA	2024-07-08 11:21:00	21.000000	11.2300	0.0050	\N
93	22	4	VENTA	2024-07-08 12:09:00	2.000000	466.2400	0.0050	\N
94	29	2	VENTA	2024-07-09 12:58:00	253.000000	33.5900	0.0050	\N
95	9	8	COMPRA	2024-07-10 10:38:00	35.000000	149.4300	0.0050	\N
96	9	4	COMPRA	2024-07-10 10:41:00	11.000000	466.2500	0.0050	\N
97	9	47	COMPRA	2024-07-10 10:44:00	1.000000	57955.7500	0.0050	0.1206
98	44	9	COMPRA	2024-07-12 10:43:00	19.000000	559.9900	0.0050	\N
99	44	1	COMPRA	2024-07-12 10:46:00	952.000000	11.1900	0.0050	\N
100	44	12	COMPRA	2024-07-12 10:49:00	6.000000	251.9609	0.0050	0.1151
101	44	184	COMPRA	2024-07-12 10:52:00	1.000000	2610.9200	0.0050	0.1049
102	8	2	COMPRA	2024-07-18 10:34:00	56.000000	33.2100	0.0050	\N
103	8	2	COMPRA	2024-07-18 10:37:00	56.000000	33.2100	0.0050	\N
104	8	8	COMPRA	2024-07-18 10:40:00	12.000000	155.4200	0.0050	\N
105	8	41	COMPRA	2024-07-18 10:43:00	1.000000	3248.5100	0.0050	0.1239
106	4	7	COMPRA	2024-07-23 10:03:00	6.000000	246.3800	0.0050	\N
107	4	7	COMPRA	2024-07-23 10:06:00	6.000000	246.3800	0.0050	\N
108	4	24	COMPRA	2024-07-23 10:09:00	1.000000	10131.3000	0.0050	0.0956
109	26	4	COMPRA	2024-07-24 12:40:00	3.000000	428.9000	0.0050	\N
110	26	3	COMPRA	2024-07-24 12:43:00	7.000000	218.5400	0.0050	\N
111	26	1	COMPRA	2024-07-24 12:46:00	152.000000	10.6000	0.0050	\N
112	51	3	COMPRA	2024-07-26 11:35:00	13.000000	217.9600	0.0050	\N
113	51	3	COMPRA	2024-07-26 11:38:00	13.000000	217.9600	0.0050	\N
114	51	213	COMPRA	2024-07-26 11:41:00	1.000000	7870.2200	0.0050	0.1173
115	40	165	VENTA	2024-07-29 10:15:00	1.000000	24166.0882	0.0050	\N
116	10	10	COMPRA	2024-07-30 10:45:00	4.000000	457.5300	0.0050	\N
117	10	12	COMPRA	2024-07-30 10:48:00	41.000000	246.3109	0.0050	0.1064
118	10	56	COMPRA	2024-07-30 10:51:00	1.000000	15473.1000	0.0050	0.1118
119	55	8	COMPRA	2024-07-30 12:00:00	106.000000	161.3300	0.0050	\N
120	55	228	COMPRA	2024-07-30 12:03:00	1.000000	42965.0700	0.0050	0.0903
121	20	1	VENTA	2024-07-31 11:55:00	225.000000	10.7200	0.0050	\N
122	70	296	VENTA	2024-08-05 09:45:00	1.000000	13047.6600	0.0050	\N
123	50	6	COMPRA	2024-08-05 11:25:00	20.000000	159.2500	0.0050	\N
124	50	210	COMPRA	2024-08-05 11:28:00	1.000000	4158.8600	0.0050	0.1019
125	21	5	COMPRA	2024-08-05 12:02:00	229.000000	161.0200	0.0050	\N
126	21	110	COMPRA	2024-08-05 12:05:00	1.000000	41750.8200	0.0050	0.0918
127	70	10	COMPRA	2024-08-07 09:45:00	5.000000	434.7700	0.0050	\N
128	70	4	COMPRA	2024-08-07 09:48:00	5.000000	398.4300	0.0050	\N
129	70	11	COMPRA	2024-08-07 09:51:00	15.000000	241.7637	0.0050	0.1045
130	70	298	COMPRA	2024-08-07 09:54:00	1.000000	5638.6000	0.0050	0.1217
131	3	10	COMPRA	2024-08-07 09:56:00	7.000000	434.7700	0.0050	\N
132	3	7	COMPRA	2024-08-07 09:59:00	17.000000	191.7600	0.0050	\N
133	3	13	COMPRA	2024-08-07 10:02:00	19.000000	241.7637	0.0050	0.1074
134	3	19	COMPRA	2024-08-07 10:05:00	1.000000	7098.1400	0.0050	0.1023
135	53	8	COMPRA	2024-08-13 11:49:00	40.000000	158.3900	0.0050	\N
136	53	7	COMPRA	2024-08-13 11:52:00	30.000000	207.8300	0.0050	\N
137	53	5	COMPRA	2024-08-13 11:55:00	37.000000	170.2300	0.0050	\N
138	53	221	COMPRA	2024-08-13 11:58:00	1.000000	3676.1600	0.0050	0.0906
139	77	7	COMPRA	2024-08-20 10:34:00	37.000000	221.1000	0.0050	\N
140	77	8	COMPRA	2024-08-20 10:37:00	52.000000	160.1600	0.0050	\N
141	77	324	COMPRA	2024-08-20 10:40:00	1.000000	111859.4800	0.0050	0.1003
142	29	2	VENTA	2024-08-22 12:58:00	115.000000	32.7100	0.0050	\N
143	16	4	COMPRA	2024-08-26 11:30:00	7.000000	413.4900	0.0050	\N
144	16	84	COMPRA	2024-08-26 11:33:00	1.000000	9908.1800	0.0050	0.0981
145	23	2	COMPRA	2024-08-26 12:19:00	105.000000	33.4100	0.0050	\N
146	23	122	COMPRA	2024-08-26 12:22:00	1.000000	13183.1800	0.0050	0.0966
147	40	2	COMPRA	2024-08-27 10:15:00	236.000000	33.2100	0.0050	\N
148	40	3	COMPRA	2024-08-27 10:18:00	34.000000	228.0300	0.0050	\N
149	40	168	COMPRA	2024-08-27 10:21:00	1.000000	21524.0200	0.0050	0.0948
150	13	10	COMPRA	2024-08-27 11:06:00	29.000000	476.7600	0.0050	\N
151	13	67	COMPRA	2024-08-27 11:09:00	1.000000	47019.9500	0.0050	0.0905
152	57	1	COMPRA	2024-08-29 12:14:00	3966.000000	9.9700	0.0050	\N
153	57	241	COMPRA	2024-08-29 12:17:00	1.000000	19671.0100	0.0050	0.1166
154	30	4	VENTA	2024-08-30 13:05:00	127.000000	417.1400	0.0050	\N
155	32	4	COMPRA	2024-08-30 13:22:00	14.000000	417.1400	0.0050	\N
156	32	9	COMPRA	2024-08-30 13:25:00	11.000000	563.6800	0.0050	\N
157	32	151	COMPRA	2024-08-30 13:28:00	1.000000	3363.5300	0.0050	0.0913
158	42	10	VENTA	2024-09-06 10:29:00	5.000000	448.6900	0.0050	\N
159	49	9	COMPRA	2024-09-06 11:18:00	1.000000	540.3600	0.0050	\N
160	49	9	COMPRA	2024-09-06 11:21:00	1.000000	540.3600	0.0050	\N
161	15	10	COMPRA	2024-09-06 11:23:00	8.000000	448.6900	0.0050	\N
162	49	204	COMPRA	2024-09-06 11:24:00	1.000000	1563.5800	0.0050	0.1218
163	15	76	COMPRA	2024-09-06 11:26:00	1.000000	10983.6700	0.0050	0.1177
164	15	75	VENTA	2024-09-10 11:20:00	1.000000	81488.1984	0.0050	\N
165	55	1	COMPRA	2024-09-13 12:03:00	232.000000	9.1600	0.0050	\N
166	55	3	COMPRA	2024-09-13 12:06:00	9.000000	222.5000	0.0050	\N
167	55	229	COMPRA	2024-09-13 12:09:00	1.000000	5324.1600	0.0050	0.1136
168	26	8	COMPRA	2024-09-13 12:40:00	13.000000	165.5200	0.0050	\N
169	26	3	COMPRA	2024-09-13 12:43:00	9.000000	222.5000	0.0050	\N
170	26	4	COMPRA	2024-09-13 12:46:00	5.000000	430.5900	0.0050	\N
171	26	130	COMPRA	2024-09-13 12:49:00	1.000000	2888.7000	0.0050	0.1187
172	71	7	COMPRA	2024-09-18 09:52:00	68.000000	227.2000	0.0050	\N
173	71	1	COMPRA	2024-09-18 09:55:00	1711.000000	9.1600	0.0050	\N
174	71	7	COMPRA	2024-09-18 09:58:00	68.000000	227.2000	0.0050	\N
175	71	301	COMPRA	2024-09-18 10:01:00	1.000000	51282.6700	0.0050	0.1012
176	59	10	COMPRA	2024-09-19 12:31:00	5.000000	483.3600	0.0050	\N
177	59	5	COMPRA	2024-09-19 12:34:00	14.000000	189.8700	0.0050	\N
178	50	6	VENTA	2024-09-23 11:25:00	7.000000	161.8500	0.0050	\N
179	27	10	COMPRA	2024-09-23 12:47:00	1.000000	483.0400	0.0050	\N
180	27	11	COMPRA	2024-09-23 12:50:00	7.000000	240.5645	0.0050	0.1081
181	27	135	COMPRA	2024-09-23 12:53:00	1.000000	2864.0600	0.0050	0.1179
182	9	1	COMPRA	2024-09-26 10:38:00	197.000000	8.7600	0.0050	\N
183	9	7	COMPRA	2024-09-26 10:41:00	6.000000	254.2200	0.0050	\N
184	9	4	COMPRA	2024-09-26 10:44:00	4.000000	431.3100	0.0050	\N
185	9	13	COMPRA	2024-09-26 10:47:00	15.000000	238.5075	0.0050	0.1108
186	9	48	COMPRA	2024-09-26 10:50:00	1.000000	4995.9500	0.0050	0.0986
187	65	2	COMPRA	2024-09-26 13:10:00	1746.000000	33.0200	0.0050	\N
188	65	1	COMPRA	2024-09-26 13:13:00	6583.000000	8.7600	0.0050	\N
189	65	271	COMPRA	2024-09-26 13:16:00	1.000000	15014.8800	0.0050	0.0988
190	68	10	COMPRA	2024-10-04 13:31:00	4.000000	487.3200	0.0050	\N
191	68	2	COMPRA	2024-10-04 13:34:00	69.000000	31.3700	0.0050	\N
192	68	11	COMPRA	2024-10-04 13:37:00	21.000000	238.2240	0.0050	0.1135
193	68	283	COMPRA	2024-10-04 13:40:00	1.000000	7690.0200	0.0050	0.1178
194	20	10	COMPRA	2024-10-07 11:58:00	5.000000	482.1000	0.0050	\N
195	20	6	COMPRA	2024-10-07 12:01:00	15.000000	162.9800	0.0050	\N
196	20	10	COMPRA	2024-10-07 12:04:00	5.000000	482.1000	0.0050	\N
197	20	102	COMPRA	2024-10-07 12:07:00	1.000000	6005.9900	0.0050	0.1134
198	4	1	COMPRA	2024-10-10 10:06:00	23.000000	8.8100	0.0050	\N
199	77	7	VENTA	2024-10-10 10:34:00	13.000000	238.7700	0.0050	\N
200	3	9	COMPRA	2024-10-11 09:59:00	3.000000	579.5800	0.0050	\N
201	3	20	COMPRA	2024-10-11 10:02:00	1.000000	3447.6200	0.0050	0.1118
202	6	9	VENTA	2024-10-11 10:17:00	51.000000	579.5800	0.0050	\N
203	66	4	COMPRA	2024-10-11 13:20:00	4.000000	416.3200	0.0050	\N
204	66	2	COMPRA	2024-10-11 13:23:00	64.000000	32.3500	0.0050	\N
205	66	4	COMPRA	2024-10-11 13:26:00	4.000000	416.3200	0.0050	\N
206	66	11	COMPRA	2024-10-11 13:29:00	9.000000	237.1129	0.0050	0.0924
207	66	275	COMPRA	2024-10-11 13:32:00	1.000000	3234.5600	0.0050	0.1197
208	70	2	COMPRA	2024-10-21 09:45:00	17.000000	33.3000	0.0050	\N
209	76	7	COMPRA	2024-10-21 10:27:00	12.000000	218.8500	0.0050	\N
210	76	5	COMPRA	2024-10-21 10:30:00	14.000000	189.0700	0.0050	\N
211	19	6	VENTA	2024-10-21 11:48:00	10.000000	164.0700	0.0050	\N
212	21	6	COMPRA	2024-10-25 12:05:00	13.000000	165.2700	0.0050	\N
213	21	6	COMPRA	2024-10-25 12:08:00	13.000000	165.2700	0.0050	\N
214	22	5	COMPRA	2024-10-25 12:09:00	4.000000	187.8300	0.0050	\N
215	21	111	COMPRA	2024-10-25 12:11:00	1.000000	2566.0500	0.0050	0.1232
216	22	119	COMPRA	2024-10-25 12:12:00	1.000000	7028.2000	0.0050	0.0904
217	32	4	COMPRA	2024-10-28 13:22:00	8.000000	426.5900	0.0050	\N
218	10	2	COMPRA	2024-10-29 10:48:00	12.000000	31.1700	0.0050	\N
219	10	8	COMPRA	2024-10-29 10:51:00	2.000000	160.0900	0.0050	\N
220	10	57	COMPRA	2024-10-29 10:54:00	1.000000	2232.2500	0.0050	0.0958
221	53	5	VENTA	2024-10-31 11:46:00	18.000000	186.4000	0.0050	\N
222	69	10	VENTA	2024-11-04 09:38:00	2.000000	486.0100	0.0050	\N
223	75	3	COMPRA	2024-11-11 10:20:00	7.000000	224.2300	0.0050	\N
224	75	8	COMPRA	2024-11-11 10:23:00	11.000000	155.0400	0.0050	\N
225	75	319	COMPRA	2024-11-11 10:26:00	1.000000	11788.7400	0.0050	0.0961
226	8	40	VENTA	2024-11-12 10:31:00	1.000000	26068.6623	0.0050	\N
227	57	9	COMPRA	2024-11-12 12:17:00	6.000000	596.9000	0.0050	\N
228	57	242	COMPRA	2024-11-12 12:20:00	1.000000	1864.1900	0.0050	0.1228
229	8	10	COMPRA	2024-11-14 10:34:00	1.000000	508.6900	0.0050	\N
230	8	2	COMPRA	2024-11-14 10:37:00	25.000000	31.4800	0.0050	\N
231	8	42	COMPRA	2024-11-14 10:40:00	1.000000	2328.4100	0.0050	0.0954
232	71	3	COMPRA	2024-11-18 09:55:00	10.000000	228.0200	0.0050	\N
233	71	302	COMPRA	2024-11-18 09:58:00	1.000000	7777.8400	0.0050	0.1154
234	75	318	VENTA	2024-11-18 10:20:00	1.000000	89258.1061	0.0050	\N
235	50	1	COMPRA	2024-11-19 11:25:00	281.000000	8.0500	0.0050	\N
236	50	1	COMPRA	2024-11-19 11:28:00	281.000000	8.0500	0.0050	\N
237	54	9	COMPRA	2024-11-22 11:53:00	41.000000	595.5100	0.0050	\N
238	54	5	COMPRA	2024-11-22 11:56:00	125.000000	197.1200	0.0050	\N
239	54	224	COMPRA	2024-11-22 11:59:00	1.000000	20440.2300	0.0050	0.1168
240	27	10	VENTA	2024-11-22 12:44:00	1.000000	505.7900	0.0050	\N
241	61	3	COMPRA	2024-11-25 12:42:00	101.000000	232.8700	0.0050	\N
242	61	10	COMPRA	2024-11-25 12:45:00	46.000000	506.5900	0.0050	\N
243	61	4	COMPRA	2024-11-25 12:48:00	56.000000	418.7900	0.0050	\N
244	61	13	COMPRA	2024-11-25 12:51:00	63.000000	226.3171	0.0050	0.0989
245	61	260	COMPRA	2024-11-25 12:54:00	1.000000	4390.6700	0.0050	0.1071
246	42	6	COMPRA	2024-11-26 10:32:00	13.000000	169.1200	0.0050	\N
247	42	10	COMPRA	2024-11-26 10:35:00	4.000000	509.3100	0.0050	\N
248	42	11	COMPRA	2024-11-26 10:38:00	20.000000	228.2068	0.0050	0.0923
249	42	175	COMPRA	2024-11-26 10:41:00	1.000000	7096.8000	0.0050	0.1030
250	55	3	VENTA	2024-11-26 12:00:00	1.000000	235.0600	0.0050	\N
251	24	6	COMPRA	2024-11-26 12:26:00	14.000000	169.1200	0.0050	\N
252	59	10	VENTA	2024-11-26 12:28:00	16.000000	509.3100	0.0050	\N
253	24	8	COMPRA	2024-11-26 12:29:00	15.000000	154.5200	0.0050	\N
254	24	125	COMPRA	2024-11-26 12:32:00	1.000000	2059.2300	0.0050	0.0942
255	29	2	COMPRA	2024-12-02 13:01:00	71.000000	32.6500	0.0050	\N
256	29	1	COMPRA	2024-12-02 13:04:00	293.000000	7.9300	0.0050	\N
257	16	4	VENTA	2024-12-03 11:27:00	1.000000	431.2000	0.0050	\N
258	40	9	COMPRA	2024-12-04 10:18:00	5.000000	607.6600	0.0050	\N
259	40	9	COMPRA	2024-12-04 10:21:00	5.000000	607.6600	0.0050	\N
260	40	3	COMPRA	2024-12-04 10:24:00	14.000000	243.0100	0.0050	\N
261	40	12	COMPRA	2024-12-04 10:27:00	17.000000	225.0463	0.0050	0.0966
262	40	169	COMPRA	2024-12-04 10:30:00	1.000000	5890.6900	0.0050	0.0983
263	17	5	COMPRA	2024-12-06 11:34:00	204.000000	227.0300	0.0050	\N
264	17	90	COMPRA	2024-12-06 11:37:00	1.000000	48405.8900	0.0050	0.1191
265	23	2	VENTA	2024-12-10 12:16:00	22.000000	32.8800	0.0050	\N
266	60	2	COMPRA	2024-12-10 12:35:00	161.000000	32.8800	0.0050	\N
267	60	10	COMPRA	2024-12-10 12:38:00	10.000000	520.6000	0.0050	\N
268	60	255	COMPRA	2024-12-10 12:41:00	1.000000	61835.8100	0.0050	0.1106
269	15	1	VENTA	2024-12-13 11:20:00	591.000000	8.2200	0.0050	\N
270	46	10	COMPRA	2024-12-16 10:57:00	6.000000	538.1700	0.0050	\N
271	46	10	COMPRA	2024-12-16 11:00:00	6.000000	538.1700	0.0050	\N
272	46	7	COMPRA	2024-12-16 11:03:00	7.000000	463.0200	0.0050	\N
273	46	12	COMPRA	2024-12-16 11:06:00	74.000000	230.3447	0.0050	0.1171
274	46	191	COMPRA	2024-12-16 11:09:00	1.000000	25745.1300	0.0050	0.0927
275	49	1	COMPRA	2024-12-16 11:21:00	32.000000	7.9500	0.0050	\N
276	49	5	COMPRA	2024-12-16 11:24:00	1.000000	232.9300	0.0050	\N
277	77	7	COMPRA	2024-12-18 10:37:00	2.000000	440.1300	0.0050	\N
278	77	8	COMPRA	2024-12-18 10:40:00	6.000000	144.7500	0.0050	\N
279	77	325	COMPRA	2024-12-18 10:43:00	1.000000	6353.3800	0.0050	0.1165
280	13	10	COMPRA	2024-12-18 11:06:00	4.000000	516.4700	0.0050	\N
281	13	8	COMPRA	2024-12-18 11:09:00	16.000000	144.7500	0.0050	\N
282	13	11	COMPRA	2024-12-18 11:12:00	14.000000	230.1326	0.0050	0.0949
283	13	68	COMPRA	2024-12-18 11:15:00	1.000000	4858.4400	0.0050	0.1070
284	30	5	COMPRA	2024-12-19 13:08:00	21.000000	223.2900	0.0050	\N
285	30	5	COMPRA	2024-12-19 13:11:00	21.000000	223.2900	0.0050	\N
286	30	6	COMPRA	2024-12-19 13:14:00	25.000000	188.5100	0.0050	\N
287	30	143	COMPRA	2024-12-19 13:17:00	1.000000	6239.3700	0.0050	0.0955
288	52	3	COMPRA	2024-12-20 11:39:00	13.000000	254.4900	0.0050	\N
289	52	4	COMPRA	2024-12-20 11:42:00	7.000000	436.6000	0.0050	\N
290	52	12	COMPRA	2024-12-20 11:45:00	13.000000	227.5572	0.0050	0.0935
291	52	218	COMPRA	2024-12-20 11:48:00	1.000000	3572.8900	0.0050	0.1074
292	26	3	COMPRA	2024-12-24 12:40:00	5.000000	258.2000	0.0050	\N
293	26	3	COMPRA	2024-12-24 12:43:00	5.000000	258.2000	0.0050	\N
294	26	1	COMPRA	2024-12-24 12:46:00	190.000000	7.5500	0.0050	\N
295	68	3	COMPRA	2024-12-27 13:34:00	5.000000	255.5900	0.0050	\N
296	68	13	COMPRA	2024-12-27 13:37:00	7.000000	228.5265	0.0050	0.1083
297	68	284	COMPRA	2024-12-27 13:40:00	1.000000	2688.3600	0.0050	0.1150
298	65	6	COMPRA	2025-01-06 13:10:00	15.000000	196.8700	0.0050	\N
299	32	4	VENTA	2025-01-06 13:19:00	10.000000	427.8500	0.0050	\N
300	5	28	VENTA	2025-01-10 10:10:00	1.000000	16649.7245	0.0050	\N
301	44	1	VENTA	2025-01-10 10:43:00	283.000000	8.4900	0.0050	\N
302	57	6	COMPRA	2025-01-10 12:14:00	95.000000	192.0400	0.0050	\N
303	57	9	COMPRA	2025-01-10 12:17:00	31.000000	580.4900	0.0050	\N
304	57	9	COMPRA	2025-01-10 12:20:00	31.000000	580.4900	0.0050	\N
305	57	243	COMPRA	2025-01-10 12:23:00	1.000000	3811.5100	0.0050	0.1001
306	8	41	VENTA	2025-01-14 10:31:00	1.000000	3186.8570	0.0050	\N
307	49	203	VENTA	2025-01-14 11:18:00	1.000000	6383.1752	0.0050	\N
308	48	5	COMPRA	2025-01-16 11:11:00	9.000000	220.6600	0.0050	\N
309	48	1	COMPRA	2025-01-16 11:14:00	250.000000	8.6300	0.0050	\N
310	48	198	COMPRA	2025-01-16 11:17:00	1.000000	24398.0400	0.0050	0.0975
311	59	10	VENTA	2025-01-16 12:28:00	14.000000	513.0800	0.0050	\N
312	16	83	VENTA	2025-01-23 11:27:00	1.000000	32677.2258	0.0050	\N
313	10	56	VENTA	2025-01-27 10:45:00	1.000000	15802.9239	0.0050	\N
314	5	3	VENTA	2025-01-28 10:10:00	2.000000	238.2600	0.0050	\N
315	17	5	COMPRA	2025-01-29 11:34:00	60.000000	237.0700	0.0050	\N
316	17	91	COMPRA	2025-01-29 11:37:00	1.000000	14897.3000	0.0050	0.1208
317	4	25	COMPRA	2025-01-30 10:06:00	1.000000	1795.8900	0.0050	0.1194
318	80	3	COMPRA	2025-01-31 10:55:00	127.000000	236.0000	0.0050	\N
319	80	7	COMPRA	2025-01-31 10:58:00	74.000000	404.6000	0.0050	\N
320	80	7	COMPRA	2025-01-31 11:01:00	74.000000	404.6000	0.0050	\N
321	80	342	COMPRA	2025-01-31 11:04:00	1.000000	22903.5300	0.0050	0.1188
322	51	3	VENTA	2025-01-31 11:32:00	26.000000	236.0000	0.0050	\N
323	71	7	VENTA	2025-02-04 09:52:00	47.000000	392.2100	0.0050	\N
324	79	3	COMPRA	2025-02-04 10:48:00	31.000000	232.8000	0.0050	\N
325	79	339	COMPRA	2025-02-04 10:51:00	1.000000	8264.7800	0.0050	0.0916
326	29	2	COMPRA	2025-02-05 13:01:00	58.000000	39.1400	0.0050	\N
327	29	8	COMPRA	2025-02-05 13:04:00	14.000000	154.6900	0.0050	\N
328	29	2	COMPRA	2025-02-05 13:07:00	58.000000	39.1400	0.0050	\N
329	51	212	VENTA	2025-02-06 11:32:00	1.000000	20822.3348	0.0050	\N
330	49	9	COMPRA	2025-02-07 11:21:00	1.000000	600.7700	0.0050	\N
331	49	5	COMPRA	2025-02-07 11:24:00	3.000000	229.1500	0.0050	\N
332	49	205	COMPRA	2025-02-07 11:27:00	1.000000	1921.1200	0.0050	0.1006
333	62	9	COMPRA	2025-02-07 12:49:00	44.000000	600.7700	0.0050	\N
334	62	262	COMPRA	2025-02-07 12:52:00	1.000000	35962.3200	0.0050	0.1242
335	46	7	VENTA	2025-02-12 10:57:00	7.000000	336.5100	0.0050	\N
336	16	2	COMPRA	2025-02-12 11:30:00	83.000000	39.9900	0.0050	\N
337	16	8	COMPRA	2025-02-12 11:33:00	21.000000	155.2600	0.0050	\N
338	16	85	COMPRA	2025-02-12 11:36:00	1.000000	10785.5200	0.0050	0.1084
339	19	3	VENTA	2025-02-12 11:48:00	15.000000	236.8700	0.0050	\N
340	60	2	COMPRA	2025-02-12 12:35:00	24.000000	39.9900	0.0050	\N
341	60	3	COMPRA	2025-02-12 12:38:00	4.000000	236.8700	0.0050	\N
342	60	256	COMPRA	2025-02-12 12:41:00	1.000000	5787.3000	0.0050	0.1188
343	15	1	COMPRA	2025-02-13 11:23:00	561.000000	10.2200	0.0050	\N
344	15	5	COMPRA	2025-02-13 11:26:00	24.000000	230.3700	0.0050	\N
345	15	1	COMPRA	2025-02-13 11:29:00	561.000000	10.2200	0.0050	\N
346	15	77	COMPRA	2025-02-13 11:32:00	1.000000	32029.1300	0.0050	0.1130
347	66	3	COMPRA	2025-02-13 13:20:00	6.000000	241.5300	0.0050	\N
348	66	2	COMPRA	2025-02-13 13:23:00	37.000000	40.3200	0.0050	\N
349	66	276	COMPRA	2025-02-13 13:26:00	1.000000	3420.0900	0.0050	0.0899
350	76	7	COMPRA	2025-02-14 10:27:00	4.000000	355.8400	0.0050	\N
351	69	289	VENTA	2025-02-18 09:38:00	1.000000	11912.7313	0.0050	\N
352	42	10	COMPRA	2025-02-18 10:32:00	2.000000	539.3700	0.0050	\N
353	8	10	COMPRA	2025-02-18 10:34:00	1.000000	539.3700	0.0050	\N
354	42	10	COMPRA	2025-02-18 10:35:00	2.000000	539.3700	0.0050	\N
355	8	8	COMPRA	2025-02-18 10:37:00	3.000000	154.9900	0.0050	\N
356	42	10	COMPRA	2025-02-18 10:38:00	2.000000	539.3700	0.0050	\N
357	8	43	COMPRA	2025-02-18 10:40:00	1.000000	1823.3100	0.0050	0.1004
358	42	176	COMPRA	2025-02-18 10:41:00	1.000000	2913.1700	0.0050	0.1072
359	29	140	VENTA	2025-02-18 12:58:00	1.000000	1802.6786	0.0050	\N
360	70	7	VENTA	2025-02-19 09:45:00	13.000000	360.5600	0.0050	\N
361	7	8	COMPRA	2025-02-19 10:24:00	274.000000	157.8900	0.0050	\N
362	7	10	COMPRA	2025-02-19 10:27:00	80.000000	539.5200	0.0050	\N
363	7	10	COMPRA	2025-02-19 10:30:00	80.000000	539.5200	0.0050	\N
364	7	12	COMPRA	2025-02-19 10:33:00	101.000000	243.2273	0.0050	0.1007
365	7	36	COMPRA	2025-02-19 10:36:00	1.000000	7138.9800	0.0050	0.1184
366	26	3	COMPRA	2025-02-21 12:37:00	10.000000	245.5500	0.0050	\N
367	26	131	COMPRA	2025-02-21 12:40:00	1.000000	1727.8700	0.0050	0.1124
368	40	168	VENTA	2025-02-24 10:15:00	1.000000	22232.9241	0.0050	\N
369	77	3	COMPRA	2025-02-27 10:37:00	8.000000	237.3000	0.0050	\N
370	77	8	COMPRA	2025-02-27 10:40:00	11.000000	163.7300	0.0050	\N
371	77	6	COMPRA	2025-02-27 10:43:00	11.000000	168.5000	0.0050	\N
372	77	326	COMPRA	2025-02-27 10:46:00	1.000000	12751.0700	0.0050	0.0931
373	6	34	VENTA	2025-02-28 10:17:00	1.000000	71008.0343	0.0050	\N
374	69	10	VENTA	2025-03-04 09:38:00	6.000000	495.5500	0.0050	\N
375	49	204	VENTA	2025-03-05 11:18:00	1.000000	1666.0716	0.0050	\N
376	20	10	COMPRA	2025-03-07 11:55:00	3.000000	491.7900	0.0050	\N
377	20	103	COMPRA	2025-03-07 11:58:00	1.000000	4286.6600	0.0050	0.0956
378	59	5	VENTA	2025-03-11 12:28:00	6.000000	196.5900	0.0050	\N
379	55	229	VENTA	2025-03-12 12:00:00	1.000000	5727.6880	0.0050	\N
380	17	8	COMPRA	2025-03-13 11:37:00	22.000000	162.9900	0.0050	\N
381	17	92	COMPRA	2025-03-13 11:40:00	1.000000	3882.1900	0.0050	0.1187
382	41	6	COMPRA	2025-03-17 10:25:00	6.000000	164.2900	0.0050	\N
383	41	5	COMPRA	2025-03-17 10:28:00	5.000000	195.7400	0.0050	\N
384	41	3	COMPRA	2025-03-17 10:31:00	5.000000	214.0000	0.0050	\N
385	41	170	COMPRA	2025-03-17 10:34:00	1.000000	17473.6700	0.0050	0.0944
386	13	8	VENTA	2025-03-17 11:06:00	7.000000	162.8400	0.0050	\N
387	55	3	COMPRA	2025-03-18 12:03:00	22.000000	212.6900	0.0050	\N
388	55	3	COMPRA	2025-03-18 12:06:00	22.000000	212.6900	0.0050	\N
389	55	13	COMPRA	2025-03-18 12:09:00	19.000000	245.2964	0.0050	0.0932
390	55	230	COMPRA	2025-03-18 12:12:00	1.000000	7037.4000	0.0050	0.0961
391	44	9	VENTA	2025-03-19 10:43:00	10.000000	567.1300	0.0050	\N
392	48	1	COMPRA	2025-03-21 11:11:00	17.000000	10.1600	0.0050	\N
393	48	199	COMPRA	2025-03-21 11:14:00	1.000000	1992.9600	0.0050	0.1026
394	50	6	VENTA	2025-03-24 11:25:00	13.000000	167.6800	0.0050	\N
395	57	6	VENTA	2025-03-24 12:14:00	95.000000	167.6800	0.0050	\N
396	37	4	COMPRA	2025-03-26 09:54:00	14.000000	389.9700	0.0050	\N
397	37	8	COMPRA	2025-03-26 09:57:00	36.000000	161.7200	0.0050	\N
398	37	158	COMPRA	2025-03-26 10:00:00	1.000000	18702.2300	0.0050	0.1042
399	54	7	COMPRA	2025-03-26 11:56:00	29.000000	272.0600	0.0050	\N
400	54	13	COMPRA	2025-03-26 11:59:00	10.000000	243.4784	0.0050	0.1162
401	54	225	COMPRA	2025-03-26 12:02:00	1.000000	3950.5900	0.0050	0.1256
402	67	7	COMPRA	2025-03-27 13:24:00	44.000000	273.1300	0.0050	\N
403	67	4	COMPRA	2025-03-27 13:27:00	31.000000	390.5800	0.0050	\N
404	67	12	COMPRA	2025-03-27 13:30:00	84.000000	242.0475	0.0050	0.1003
405	67	280	COMPRA	2025-03-27 13:33:00	1.000000	30528.7400	0.0050	0.0931
406	68	4	COMPRA	2025-03-27 13:34:00	1.000000	390.5800	0.0050	\N
407	68	10	COMPRA	2025-03-27 13:37:00	1.000000	481.6200	0.0050	\N
408	68	4	COMPRA	2025-03-27 13:40:00	1.000000	390.5800	0.0050	\N
409	68	285	COMPRA	2025-03-27 13:43:00	1.000000	1803.7600	0.0050	0.0972
410	66	4	COMPRA	2025-03-31 13:20:00	6.000000	375.3900	0.0050	\N
411	66	4	COMPRA	2025-03-31 13:23:00	6.000000	375.3900	0.0050	\N
412	66	277	COMPRA	2025-03-31 13:26:00	1.000000	4899.7300	0.0050	0.1163
413	9	4	COMPRA	2025-04-01 10:41:00	7.000000	382.1900	0.0050	\N
414	9	4	COMPRA	2025-04-01 10:44:00	7.000000	382.1900	0.0050	\N
415	9	1	COMPRA	2025-04-01 10:47:00	287.000000	10.6100	0.0050	\N
416	9	49	COMPRA	2025-04-01 10:50:00	1.000000	12359.9900	0.0050	0.1109
417	49	1	COMPRA	2025-04-02 11:18:00	108.000000	10.6300	0.0050	\N
418	49	206	COMPRA	2025-04-02 11:21:00	1.000000	3155.7700	0.0050	0.1148
419	42	10	VENTA	2025-04-03 10:29:00	10.000000	450.6600	0.0050	\N
420	18	8	COMPRA	2025-04-04 11:41:00	438.000000	153.2400	0.0050	\N
421	18	5	COMPRA	2025-04-04 11:44:00	393.000000	171.0000	0.0050	\N
422	18	96	COMPRA	2025-04-04 11:47:00	1.000000	25539.6900	0.0050	0.1236
423	9	47	VENTA	2025-04-07 10:38:00	1.000000	59331.6381	0.0050	\N
424	22	4	VENTA	2025-04-09 12:09:00	1.000000	390.4900	0.0050	\N
425	66	275	VENTA	2025-04-09 13:17:00	1.000000	3287.0771	0.0050	\N
426	6	9	VENTA	2025-04-10 10:17:00	46.000000	524.5800	0.0050	\N
427	34	6	COMPRA	2025-04-10 13:33:00	8.000000	152.8200	0.0050	\N
428	34	1	COMPRA	2025-04-10 13:36:00	164.000000	8.2300	0.0050	\N
429	34	5	COMPRA	2025-04-10 13:39:00	7.000000	181.2200	0.0050	\N
430	34	153	COMPRA	2025-04-10 13:42:00	1.000000	6159.3400	0.0050	0.1270
431	30	4	COMPRA	2025-04-11 13:08:00	22.000000	388.4500	0.0050	\N
432	30	144	COMPRA	2025-04-11 13:11:00	1.000000	11019.2400	0.0050	0.1139
433	51	8	COMPRA	2025-04-15 11:35:00	24.000000	153.6200	0.0050	\N
434	51	214	COMPRA	2025-04-15 11:38:00	1.000000	9799.3000	0.0050	0.0924
435	21	5	COMPRA	2025-04-16 12:02:00	42.000000	174.3300	0.0050	\N
436	21	2	COMPRA	2025-04-16 12:05:00	186.000000	39.6500	0.0050	\N
437	21	112	COMPRA	2025-04-16 12:08:00	1.000000	8357.8400	0.0050	0.1066
438	65	2	COMPRA	2025-04-16 13:10:00	220.000000	39.6500	0.0050	\N
439	65	272	COMPRA	2025-04-16 13:13:00	1.000000	2280.9600	0.0050	0.1208
440	8	2	VENTA	2025-04-17 10:31:00	108.000000	39.5300	0.0050	\N
441	22	118	VENTA	2025-04-17 12:09:00	1.000000	38991.5913	0.0050	\N
442	77	6	COMPRA	2025-04-22 10:37:00	17.000000	151.4700	0.0050	\N
443	77	8	COMPRA	2025-04-22 10:40:00	16.000000	157.7500	0.0050	\N
444	77	327	COMPRA	2025-04-22 10:43:00	1.000000	17370.7500	0.0050	0.0989
445	5	3	COMPRA	2025-04-23 10:10:00	11.000000	204.6000	0.0050	\N
446	5	3	COMPRA	2025-04-23 10:13:00	11.000000	204.6000	0.0050	\N
447	5	10	COMPRA	2025-04-23 10:16:00	5.000000	454.5600	0.0050	\N
448	5	13	COMPRA	2025-04-23 10:19:00	15.000000	233.4692	0.0050	0.1134
449	5	30	COMPRA	2025-04-23 10:22:00	1.000000	5483.5700	0.0050	0.1072
450	32	9	VENTA	2025-04-23 13:19:00	3.000000	535.4200	0.0050	\N
451	15	10	VENTA	2025-04-24 11:20:00	17.000000	467.3500	0.0050	\N
452	59	249	VENTA	2025-04-24 12:28:00	1.000000	16194.6097	0.0050	\N
453	75	8	COMPRA	2025-04-28 10:20:00	26.000000	155.3500	0.0050	\N
454	75	3	COMPRA	2025-04-28 10:23:00	19.000000	210.1400	0.0050	\N
455	75	320	COMPRA	2025-04-28 10:26:00	1.000000	55544.6200	0.0050	0.1238
456	10	57	VENTA	2025-04-28 10:45:00	1.000000	2392.1546	0.0050	\N
457	10	8	COMPRA	2025-04-28 10:51:00	4.000000	155.3500	0.0050	\N
458	10	8	COMPRA	2025-04-28 10:54:00	4.000000	155.3500	0.0050	\N
459	10	10	COMPRA	2025-04-28 10:57:00	1.000000	472.4100	0.0050	\N
460	10	58	COMPRA	2025-04-28 11:00:00	1.000000	4151.4600	0.0050	0.1120
461	55	228	VENTA	2025-04-28 12:00:00	1.000000	43861.0233	0.0050	\N
462	26	129	VENTA	2025-04-28 12:37:00	1.000000	12228.3914	0.0050	\N
463	36	8	COMPRA	2025-04-30 09:47:00	33.000000	156.3100	0.0050	\N
464	36	3	COMPRA	2025-04-30 09:50:00	24.000000	212.5000	0.0050	\N
465	36	7	COMPRA	2025-04-30 09:53:00	18.000000	282.1600	0.0050	\N
466	36	155	COMPRA	2025-04-30 09:56:00	1.000000	57671.1300	0.0050	0.1050
467	46	10	VENTA	2025-05-01 10:57:00	7.000000	481.6800	0.0050	\N
468	25	4	COMPRA	2025-05-01 12:30:00	10.000000	425.4000	0.0050	\N
469	25	1	COMPRA	2025-05-01 12:33:00	558.000000	8.0600	0.0050	\N
470	25	11	COMPRA	2025-05-01 12:36:00	8.000000	236.8405	0.0050	0.1049
471	25	126	COMPRA	2025-05-01 12:39:00	1.000000	3170.0400	0.0050	0.0944
472	76	5	COMPRA	2025-05-02 10:30:00	6.000000	189.9800	0.0050	\N
473	76	8	COMPRA	2025-05-02 10:33:00	7.000000	156.1200	0.0050	\N
474	26	3	COMPRA	2025-05-02 12:40:00	7.000000	205.3500	0.0050	\N
475	26	4	COMPRA	2025-05-02 12:43:00	3.000000	435.2800	0.0050	\N
476	3	19	VENTA	2025-05-05 09:56:00	1.000000	7435.1340	0.0050	\N
477	78	3	COMPRA	2025-05-06 10:41:00	12.000000	198.5100	0.0050	\N
478	78	11	COMPRA	2025-05-06 10:44:00	117.000000	233.4474	0.0050	0.1096
479	78	333	COMPRA	2025-05-06 10:47:00	1.000000	41293.3000	0.0050	0.1046
480	20	1	COMPRA	2025-05-08 11:58:00	250.000000	8.0900	0.0050	\N
481	20	6	COMPRA	2025-05-08 12:01:00	13.000000	154.2800	0.0050	\N
482	20	104	COMPRA	2025-05-08 12:04:00	1.000000	4874.0200	0.0050	0.1078
483	75	319	VENTA	2025-05-12 10:20:00	1.000000	12647.1369	0.0050	\N
484	55	1	COMPRA	2025-05-12 12:03:00	468.000000	8.2900	0.0050	\N
485	55	3	COMPRA	2025-05-12 12:06:00	18.000000	210.7900	0.0050	\N
486	55	231	COMPRA	2025-05-12 12:09:00	1.000000	9715.2800	0.0050	0.1278
487	8	42	VENTA	2025-05-13 10:31:00	1.000000	2585.2996	0.0050	\N
488	9	7	COMPRA	2025-05-14 10:38:00	11.000000	347.6800	0.0050	\N
489	9	11	COMPRA	2025-05-14 10:41:00	72.000000	237.8331	0.0050	0.0927
490	9	50	COMPRA	2025-05-14 10:44:00	1.000000	25916.6700	0.0050	0.0934
491	20	101	VENTA	2025-05-15 11:55:00	1.000000	42842.4109	0.0050	\N
492	3	10	COMPRA	2025-05-16 09:59:00	3.000000	521.5100	0.0050	\N
493	3	1	COMPRA	2025-05-16 10:02:00	182.000000	8.6000	0.0050	\N
494	3	10	COMPRA	2025-05-16 10:05:00	3.000000	521.5100	0.0050	\N
495	3	21	COMPRA	2025-05-16 10:08:00	1.000000	2723.2700	0.0050	0.1228
496	71	6	COMPRA	2025-05-21 09:55:00	28.000000	168.5600	0.0050	\N
497	71	303	COMPRA	2025-05-21 09:58:00	1.000000	15664.2000	0.0050	0.1024
498	48	5	COMPRA	2025-05-21 11:14:00	2.000000	201.1200	0.0050	\N
499	48	11	COMPRA	2025-05-21 11:17:00	7.000000	239.6495	0.0050	0.0997
500	48	200	COMPRA	2025-05-21 11:20:00	1.000000	2834.2600	0.0050	0.0935
501	28	1	COMPRA	2025-05-22 12:51:00	1577.000000	8.4700	0.0050	\N
502	62	9	COMPRA	2025-05-22 12:52:00	10.000000	583.0900	0.0050	\N
503	28	4	COMPRA	2025-05-22 12:54:00	29.000000	454.8600	0.0050	\N
504	62	1	COMPRA	2025-05-22 12:55:00	730.000000	8.4700	0.0050	\N
505	28	138	COMPRA	2025-05-22 12:57:00	1.000000	6988.9800	0.0050	0.0889
506	29	8	VENTA	2025-05-22 12:58:00	58.000000	152.6100	0.0050	\N
507	62	263	COMPRA	2025-05-22 12:58:00	1.000000	8362.5700	0.0050	0.1254
508	4	1	VENTA	2025-05-23 10:03:00	7.000000	8.6100	0.0050	\N
509	79	3	VENTA	2025-05-23 10:48:00	7.000000	195.2700	0.0050	\N
510	38	8	COMPRA	2025-05-27 10:01:00	124.000000	153.2500	0.0050	\N
511	38	13	COMPRA	2025-05-27 10:04:00	31.000000	240.0724	0.0050	0.1149
512	38	160	COMPRA	2025-05-27 10:07:00	1.000000	11165.8300	0.0050	0.1080
513	40	167	VENTA	2025-05-27 10:15:00	1.000000	10703.1619	0.0050	\N
514	42	174	VENTA	2025-05-27 10:29:00	1.000000	43199.3380	0.0050	\N
515	45	6	COMPRA	2025-05-27 10:53:00	510.000000	172.9000	0.0050	\N
516	45	4	COMPRA	2025-05-27 10:56:00	191.000000	460.6900	0.0050	\N
517	45	186	COMPRA	2025-05-27 10:59:00	1.000000	36465.3600	0.0050	0.1197
518	13	67	VENTA	2025-05-27 11:06:00	1.000000	48429.1039	0.0050	\N
519	17	5	COMPRA	2025-05-27 11:37:00	46.000000	206.0200	0.0050	\N
520	17	5	COMPRA	2025-05-27 11:40:00	46.000000	206.0200	0.0050	\N
521	17	93	COMPRA	2025-05-27 11:43:00	1.000000	9916.9700	0.0050	0.1158
522	32	151	VENTA	2025-05-27 13:19:00	1.000000	3559.4074	0.0050	\N
523	80	7	VENTA	2025-05-28 10:55:00	85.000000	356.9000	0.0050	\N
524	54	3	COMPRA	2025-05-29 11:53:00	24.000000	199.9500	0.0050	\N
525	54	5	COMPRA	2025-05-29 11:56:00	24.000000	205.7000	0.0050	\N
526	54	226	COMPRA	2025-05-29 11:59:00	1.000000	4136.6000	0.0050	0.1151
527	24	8	VENTA	2025-05-29 12:23:00	8.000000	153.5800	0.0050	\N
528	37	10	COMPRA	2025-06-03 09:54:00	2.000000	527.3000	0.0050	\N
529	37	8	COMPRA	2025-06-03 09:57:00	9.000000	154.4200	0.0050	\N
530	37	5	COMPRA	2025-06-03 10:00:00	6.000000	205.7100	0.0050	\N
531	37	159	COMPRA	2025-06-03 10:03:00	1.000000	1171.5800	0.0050	0.1255
532	72	9	COMPRA	2025-06-04 10:02:00	4.000000	595.9300	0.0050	\N
533	72	3	COMPRA	2025-06-04 10:05:00	12.000000	202.8200	0.0050	\N
534	72	308	COMPRA	2025-06-04 10:08:00	1.000000	13741.9500	0.0050	0.1261
535	61	3	VENTA	2025-06-04 12:42:00	50.000000	202.8200	0.0050	\N
536	11	9	COMPRA	2025-06-05 10:52:00	1.000000	593.0500	0.0050	\N
537	11	4	COMPRA	2025-06-05 10:55:00	2.000000	467.6800	0.0050	\N
538	11	4	COMPRA	2025-06-05 10:58:00	2.000000	467.6800	0.0050	\N
539	11	60	COMPRA	2025-06-05 11:01:00	1.000000	12617.2400	0.0050	0.1217
540	16	2	COMPRA	2025-06-05 11:30:00	62.000000	43.5700	0.0050	\N
541	16	13	COMPRA	2025-06-05 11:33:00	14.000000	243.4363	0.0050	0.0993
542	16	86	COMPRA	2025-06-05 11:36:00	1.000000	5272.6800	0.0050	0.1040
543	57	1	COMPRA	2025-06-05 12:17:00	976.000000	8.6900	0.0050	\N
544	57	11	COMPRA	2025-06-05 12:20:00	6.000000	243.4363	0.0050	0.1108
545	57	244	COMPRA	2025-06-05 12:23:00	1.000000	2532.4900	0.0050	0.0958
546	27	3	COMPRA	2025-06-05 12:47:00	8.000000	200.6300	0.0050	\N
547	27	10	COMPRA	2025-06-05 12:50:00	3.000000	524.7900	0.0050	\N
548	27	12	COMPRA	2025-06-05 12:53:00	15.000000	243.4363	0.0050	0.1141
549	27	136	COMPRA	2025-06-05 12:56:00	1.000000	5510.6100	0.0050	0.1169
550	31	6	COMPRA	2025-06-06 13:12:00	22.000000	173.6800	0.0050	\N
551	31	149	COMPRA	2025-06-06 13:15:00	1.000000	17126.5500	0.0050	0.0910
552	2	8	COMPRA	2025-06-09 09:52:00	26.000000	155.2300	0.0050	\N
553	2	10	COMPRA	2025-06-09 09:55:00	7.000000	530.7000	0.0050	\N
554	67	9	COMPRA	2025-06-09 13:27:00	5.000000	599.6800	0.0050	\N
555	67	13	COMPRA	2025-06-09 13:30:00	24.000000	241.6206	0.0050	0.1108
556	67	281	COMPRA	2025-06-09 13:33:00	1.000000	8901.3300	0.0050	0.1004
557	7	8	COMPRA	2025-06-10 10:27:00	20.000000	156.4500	0.0050	\N
558	7	10	COMPRA	2025-06-10 10:30:00	6.000000	534.2100	0.0050	\N
559	7	10	COMPRA	2025-06-10 10:33:00	6.000000	534.2100	0.0050	\N
560	7	37	COMPRA	2025-06-10 10:36:00	1.000000	2832.5300	0.0050	0.0979
561	42	1	COMPRA	2025-06-12 10:32:00	276.000000	9.3300	0.0050	\N
562	42	6	COMPRA	2025-06-12 10:35:00	14.000000	175.7000	0.0050	\N
563	42	177	COMPRA	2025-06-12 10:38:00	1.000000	13123.9000	0.0050	0.1162
564	44	10	COMPRA	2025-06-16 10:46:00	5.000000	534.2900	0.0050	\N
565	44	9	COMPRA	2025-06-16 10:49:00	4.000000	602.6800	0.0050	\N
566	59	5	COMPRA	2025-06-16 12:31:00	11.000000	216.1000	0.0050	\N
567	59	5	COMPRA	2025-06-16 12:34:00	11.000000	216.1000	0.0050	\N
568	59	5	COMPRA	2025-06-16 12:37:00	11.000000	216.1000	0.0050	\N
569	59	250	COMPRA	2025-06-16 12:40:00	1.000000	2716.2300	0.0050	0.1098
570	75	3	VENTA	2025-06-17 10:20:00	27.000000	195.6400	0.0050	\N
571	56	9	COMPRA	2025-06-17 12:07:00	21.000000	597.5300	0.0050	\N
572	56	12	COMPRA	2025-06-17 12:10:00	102.000000	244.1144	0.0050	0.0952
573	56	236	COMPRA	2025-06-17 12:13:00	1.000000	37688.8900	0.0050	0.1277
574	30	143	VENTA	2025-06-17 13:05:00	1.000000	6944.9135	0.0050	\N
575	70	10	VENTA	2025-06-18 09:45:00	8.000000	528.9900	0.0050	\N
576	69	9	COMPRA	2025-06-20 09:38:00	4.000000	594.2800	0.0050	\N
577	69	10	COMPRA	2025-06-20 09:41:00	4.000000	526.8300	0.0050	\N
578	69	10	COMPRA	2025-06-20 09:44:00	4.000000	526.8300	0.0050	\N
579	69	291	COMPRA	2025-06-20 09:47:00	1.000000	7703.4700	0.0050	0.1058
580	6	1	COMPRA	2025-06-20 10:17:00	1623.000000	9.8400	0.0050	\N
581	6	8	COMPRA	2025-06-20 10:20:00	106.000000	149.7900	0.0050	\N
582	6	35	COMPRA	2025-06-20 10:23:00	1.000000	52736.9700	0.0050	0.1230
583	27	135	VENTA	2025-06-20 12:44:00	1.000000	3171.6649	0.0050	\N
584	30	142	VENTA	2025-06-20 13:05:00	1.000000	53963.1308	0.0050	\N
585	9	48	VENTA	2025-06-23 10:38:00	1.000000	5503.7611	0.0050	\N
586	43	4	COMPRA	2025-06-24 10:36:00	9.000000	490.1100	0.0050	\N
587	43	5	COMPRA	2025-06-24 10:39:00	22.000000	212.7700	0.0050	\N
588	43	183	COMPRA	2025-06-24 10:42:00	1.000000	4710.2200	0.0050	0.1240
589	33	8	COMPRA	2025-06-24 13:26:00	48.000000	152.1900	0.0050	\N
590	33	10	COMPRA	2025-06-24 13:29:00	13.000000	539.7800	0.0050	\N
591	33	10	COMPRA	2025-06-24 13:32:00	13.000000	539.7800	0.0050	\N
592	33	152	COMPRA	2025-06-24 13:35:00	1.000000	6005.0300	0.0050	0.1066
593	20	10	COMPRA	2025-06-26 11:58:00	3.000000	546.2200	0.0050	\N
594	20	10	COMPRA	2025-06-26 12:01:00	3.000000	546.2200	0.0050	\N
595	20	1	COMPRA	2025-06-26 12:04:00	235.000000	9.2400	0.0050	\N
596	20	105	COMPRA	2025-06-26 12:07:00	1.000000	10435.8800	0.0050	0.1069
597	52	3	VENTA	2025-06-30 11:39:00	7.000000	205.1700	0.0050	\N
598	32	9	VENTA	2025-06-30 13:19:00	4.000000	617.8500	0.0050	\N
599	51	8	VENTA	2025-07-02 11:32:00	24.000000	155.5600	0.0050	\N
600	18	8	COMPRA	2025-07-02 11:44:00	41.000000	155.5600	0.0050	\N
601	18	8	COMPRA	2025-07-02 11:47:00	41.000000	155.5600	0.0050	\N
602	18	97	COMPRA	2025-07-02 11:50:00	1.000000	2422.0900	0.0050	0.0998
603	5	3	COMPRA	2025-07-03 10:13:00	14.000000	213.5500	0.0050	\N
604	5	12	COMPRA	2025-07-03 10:16:00	9.000000	249.5969	0.0050	0.0943
605	5	31	COMPRA	2025-07-03 10:19:00	1.000000	3466.1200	0.0050	0.1142
606	19	6	VENTA	2025-07-03 11:48:00	9.000000	179.5300	0.0050	\N
607	64	7	COMPRA	2025-07-03 13:03:00	6.000000	315.3500	0.0050	\N
608	64	4	COMPRA	2025-07-03 13:06:00	4.000000	498.8400	0.0050	\N
609	64	4	COMPRA	2025-07-03 13:09:00	4.000000	498.8400	0.0050	\N
610	64	269	COMPRA	2025-07-03 13:12:00	1.000000	5301.3200	0.0050	0.1253
611	77	7	COMPRA	2025-07-07 10:37:00	7.000000	293.9400	0.0050	\N
612	77	7	COMPRA	2025-07-07 10:40:00	7.000000	293.9400	0.0050	\N
613	44	184	VENTA	2025-07-07 10:43:00	1.000000	2876.8794	0.0050	\N
614	77	328	COMPRA	2025-07-07 10:43:00	1.000000	15638.4200	0.0050	0.1095
615	12	5	COMPRA	2025-07-07 11:02:00	16.000000	223.4700	0.0050	\N
616	12	5	COMPRA	2025-07-07 11:05:00	16.000000	223.4700	0.0050	\N
617	12	2	COMPRA	2025-07-07 11:08:00	80.000000	44.9300	0.0050	\N
618	12	64	COMPRA	2025-07-07 11:11:00	1.000000	11930.0200	0.0050	0.1247
619	15	5	COMPRA	2025-07-07 11:23:00	22.000000	223.4700	0.0050	\N
620	15	78	COMPRA	2025-07-07 11:26:00	1.000000	28463.9700	0.0050	0.1107
621	68	2	COMPRA	2025-07-07 13:34:00	14.000000	44.9300	0.0050	\N
622	68	3	COMPRA	2025-07-07 13:37:00	3.000000	209.9500	0.0050	\N
623	68	286	COMPRA	2025-07-07 13:40:00	1.000000	1952.8000	0.0050	0.1059
624	1	9	COMPRA	2025-07-09 09:42:00	20.000000	624.0600	0.0050	\N
625	1	12	COMPRA	2025-07-09 09:45:00	15.000000	246.6620	0.0050	0.1081
626	1	14	COMPRA	2025-07-09 09:48:00	1.000000	5821.1500	0.0050	0.1279
627	79	3	VENTA	2025-07-09 10:48:00	13.000000	211.1400	0.0050	\N
628	41	171	COMPRA	2025-07-10 10:25:00	1.000000	2633.4900	0.0050	0.1264
629	50	5	COMPRA	2025-07-10 11:25:00	5.000000	222.2600	0.0050	\N
630	60	10	COMPRA	2025-07-14 12:38:00	5.000000	556.2100	0.0050	\N
631	60	3	COMPRA	2025-07-14 12:41:00	15.000000	208.6200	0.0050	\N
632	60	257	COMPRA	2025-07-14 12:44:00	1.000000	19281.5200	0.0050	0.1207
633	71	6	COMPRA	2025-07-17 09:55:00	19.000000	183.5800	0.0050	\N
634	71	1	COMPRA	2025-07-17 09:58:00	402.000000	8.8800	0.0050	\N
635	71	304	COMPRA	2025-07-17 10:01:00	1.000000	5852.7100	0.0050	0.0886
636	74	1	COMPRA	2025-07-17 10:13:00	1375.000000	8.8800	0.0050	\N
637	74	315	COMPRA	2025-07-17 10:16:00	1.000000	29997.8900	0.0050	0.1004
638	46	10	COMPRA	2025-07-17 11:00:00	3.000000	561.8000	0.0050	\N
639	46	192	COMPRA	2025-07-17 11:03:00	1.000000	12106.0000	0.0050	0.1255
640	4	24	VENTA	2025-07-18 10:03:00	1.000000	11057.1898	0.0050	\N
641	66	4	VENTA	2025-07-21 13:17:00	11.000000	510.0600	0.0050	\N
642	78	2	COMPRA	2025-07-22 10:44:00	17.000000	44.6800	0.0050	\N
643	78	3	COMPRA	2025-07-22 10:47:00	3.000000	214.4000	0.0050	\N
644	78	2	COMPRA	2025-07-22 10:50:00	17.000000	44.6800	0.0050	\N
645	78	334	COMPRA	2025-07-22 10:53:00	1.000000	10693.7000	0.0050	0.1203
646	22	119	VENTA	2025-07-22 12:09:00	1.000000	8024.2800	0.0050	\N
647	17	91	VENTA	2025-07-28 11:34:00	1.000000	16175.1895	0.0050	\N
648	28	5	COMPRA	2025-07-28 12:51:00	14.000000	232.7900	0.0050	\N
649	61	4	COMPRA	2025-07-29 12:42:00	6.000000	512.5700	0.0050	\N
650	61	1	COMPRA	2025-07-29 12:45:00	368.000000	8.7800	0.0050	\N
651	61	3	COMPRA	2025-07-29 12:48:00	15.000000	211.2700	0.0050	\N
652	80	342	VENTA	2025-07-30 10:55:00	1.000000	24295.8865	0.0050	\N
653	65	2	COMPRA	2025-07-30 13:13:00	115.000000	43.7100	0.0050	\N
654	65	1	COMPRA	2025-07-30 13:16:00	594.000000	8.5000	0.0050	\N
655	14	5	COMPRA	2025-07-31 11:13:00	41.000000	234.1100	0.0050	\N
656	14	2	COMPRA	2025-07-31 11:16:00	223.000000	43.4200	0.0050	\N
657	14	71	COMPRA	2025-07-31 11:19:00	1.000000	52940.1200	0.0050	0.0919
658	49	5	COMPRA	2025-07-31 11:21:00	2.000000	234.1100	0.0050	\N
659	76	5	VENTA	2025-08-04 10:27:00	8.000000	211.6500	0.0050	\N
660	21	9	COMPRA	2025-08-05 12:02:00	5.000000	627.9700	0.0050	\N
661	21	9	COMPRA	2025-08-05 12:05:00	5.000000	627.9700	0.0050	\N
662	21	113	COMPRA	2025-08-05 12:08:00	1.000000	1876.4100	0.0050	0.1111
663	23	6	COMPRA	2025-08-06 12:19:00	4.000000	196.0900	0.0050	\N
664	23	3	COMPRA	2025-08-06 12:22:00	3.000000	213.2500	0.0050	\N
665	23	123	COMPRA	2025-08-06 12:25:00	1.000000	1570.9300	0.0050	0.1147
666	36	5	COMPRA	2025-08-07 09:47:00	3.000000	223.1300	0.0050	\N
667	36	12	COMPRA	2025-08-07 09:50:00	6.000000	246.9532	0.0050	0.0993
668	36	156	COMPRA	2025-08-07 09:53:00	1.000000	2329.1300	0.0050	0.1127
669	80	4	COMPRA	2025-08-11 10:58:00	6.000000	521.7700	0.0050	\N
670	80	343	COMPRA	2025-08-11 11:01:00	1.000000	1921.8600	0.0050	0.0968
671	16	85	VENTA	2025-08-11 11:27:00	1.000000	11681.8933	0.0050	\N
672	60	256	VENTA	2025-08-11 12:35:00	1.000000	6297.2123	0.0050	\N
673	63	9	COMPRA	2025-08-12 12:56:00	8.000000	642.6900	0.0050	\N
674	63	267	COMPRA	2025-08-12 12:59:00	1.000000	25161.0800	0.0050	0.0959
675	9	7	COMPRA	2025-08-14 10:41:00	5.000000	335.5800	0.0050	\N
676	9	11	COMPRA	2025-08-14 10:44:00	17.000000	248.7166	0.0050	0.1148
677	9	51	COMPRA	2025-08-14 10:47:00	1.000000	6587.0200	0.0050	0.0928
678	11	9	VENTA	2025-08-14 10:52:00	1.000000	644.9500	0.0050	\N
679	30	4	COMPRA	2025-08-14 13:05:00	56.000000	522.4800	0.0050	\N
680	30	145	COMPRA	2025-08-14 13:08:00	1.000000	37641.4500	0.0050	0.0995
681	71	302	VENTA	2025-08-15 09:52:00	1.000000	9277.7210	0.0050	\N
682	77	324	VENTA	2025-08-15 10:34:00	1.000000	122094.8898	0.0050	\N
683	7	36	VENTA	2025-08-18 10:24:00	1.000000	7716.9479	0.0050	\N
684	42	176	VENTA	2025-08-18 10:29:00	1.000000	3125.2572	0.0050	\N
685	8	43	VENTA	2025-08-18 10:31:00	1.000000	1950.1186	0.0050	\N
686	68	4	COMPRA	2025-08-18 13:31:00	1.000000	517.1000	0.0050	\N
687	68	4	COMPRA	2025-08-18 13:34:00	1.000000	517.1000	0.0050	\N
688	68	287	COMPRA	2025-08-18 13:37:00	1.000000	2040.4700	0.0050	0.0971
689	66	274	VENTA	2025-08-20 13:17:00	1.000000	48484.0159	0.0050	\N
690	45	6	VENTA	2025-08-21 10:50:00	239.000000	199.7500	0.0050	\N
691	17	5	VENTA	2025-08-21 11:34:00	356.000000	221.9500	0.0050	\N
692	20	10	COMPRA	2025-08-21 11:58:00	6.000000	563.2800	0.0050	\N
693	20	1	COMPRA	2025-08-21 12:01:00	399.000000	8.9000	0.0050	\N
694	20	6	COMPRA	2025-08-21 12:04:00	17.000000	199.7500	0.0050	\N
695	20	106	COMPRA	2025-08-21 12:07:00	1.000000	8531.6400	0.0050	0.0975
696	23	122	VENTA	2025-08-21 12:16:00	1.000000	14456.3944	0.0050	\N
697	10	10	COMPRA	2025-08-25 10:48:00	1.000000	570.3200	0.0050	\N
698	10	11	COMPRA	2025-08-25 10:51:00	8.000000	249.4574	0.0050	0.1144
699	10	59	COMPRA	2025-08-25 10:54:00	1.000000	3115.1900	0.0050	0.1205
700	22	5	VENTA	2025-08-25 12:09:00	1.000000	227.9400	0.0050	\N
701	57	241	VENTA	2025-08-25 12:14:00	1.000000	22241.3666	0.0050	\N
702	60	10	COMPRA	2025-08-25 12:38:00	3.000000	570.3200	0.0050	\N
703	60	258	COMPRA	2025-08-25 12:41:00	1.000000	12774.4900	0.0050	0.1255
704	6	9	VENTA	2025-08-26 10:17:00	26.000000	645.1600	0.0050	\N
705	79	3	COMPRA	2025-08-26 10:51:00	9.000000	229.3100	0.0050	\N
706	79	3	COMPRA	2025-08-26 10:54:00	9.000000	229.3100	0.0050	\N
707	59	8	VENTA	2025-08-26 12:28:00	132.000000	176.4900	0.0050	\N
708	42	1	COMPRA	2025-08-27 10:32:00	246.000000	9.2300	0.0050	\N
709	42	178	COMPRA	2025-08-27 10:35:00	1.000000	11561.6800	0.0050	0.0928
710	26	8	COMPRA	2025-08-27 12:40:00	15.000000	176.7900	0.0050	\N
711	26	3	COMPRA	2025-08-27 12:43:00	11.000000	230.4900	0.0050	\N
712	26	4	COMPRA	2025-08-27 12:46:00	5.000000	506.7400	0.0050	\N
713	26	13	COMPRA	2025-08-27 12:49:00	5.000000	247.2487	0.0050	0.1167
714	26	132	COMPRA	2025-08-27 12:52:00	1.000000	2151.9600	0.0050	0.1238
715	52	3	COMPRA	2025-08-28 11:42:00	4.000000	232.5600	0.0050	\N
716	52	2	COMPRA	2025-08-28 11:45:00	18.000000	49.8000	0.0050	\N
717	52	219	COMPRA	2025-08-28 11:48:00	1.000000	2204.7800	0.0050	0.1137
718	29	2	COMPRA	2025-08-28 13:01:00	59.000000	49.8000	0.0050	\N
719	29	2	COMPRA	2025-08-28 13:04:00	59.000000	49.8000	0.0050	\N
720	29	2	COMPRA	2025-08-28 13:07:00	59.000000	49.8000	0.0050	\N
721	25	1	VENTA	2025-08-29 12:30:00	558.000000	9.4000	0.0050	\N
722	38	1	COMPRA	2025-09-02 10:04:00	421.000000	9.3800	0.0050	\N
723	38	1	COMPRA	2025-09-02 10:07:00	421.000000	9.3800	0.0050	\N
724	38	161	COMPRA	2025-09-02 10:10:00	1.000000	1921.6900	0.0050	0.1211
725	15	76	VENTA	2025-09-02 11:20:00	1.000000	12727.7852	0.0050	\N
726	31	4	COMPRA	2025-09-03 13:12:00	3.000000	505.3500	0.0050	\N
727	31	150	COMPRA	2025-09-03 13:15:00	1.000000	4079.3200	0.0050	0.0983
728	72	9	VENTA	2025-09-05 09:59:00	1.000000	647.2400	0.0050	\N
729	55	8	COMPRA	2025-09-05 12:03:00	15.000000	178.4300	0.0050	\N
730	55	1	COMPRA	2025-09-05 12:06:00	305.000000	9.0800	0.0050	\N
731	55	232	COMPRA	2025-09-05 12:09:00	1.000000	3471.5800	0.0050	0.1230
732	56	4	COMPRA	2025-09-05 12:10:00	6.000000	495.0000	0.0050	\N
733	56	237	COMPRA	2025-09-05 12:13:00	1.000000	7600.3200	0.0050	0.1120
734	27	3	COMPRA	2025-09-05 12:47:00	6.000000	239.6900	0.0050	\N
735	27	137	COMPRA	2025-09-05 12:50:00	1.000000	7881.9900	0.0050	0.0906
736	67	7	COMPRA	2025-09-05 13:27:00	5.000000	350.8400	0.0050	\N
737	67	10	COMPRA	2025-09-05 13:30:00	3.000000	576.0600	0.0050	\N
738	67	13	COMPRA	2025-09-05 13:33:00	6.000000	250.5581	0.0050	0.1027
739	67	282	COMPRA	2025-09-05 13:36:00	1.000000	2286.5800	0.0050	0.1085
740	26	130	VENTA	2025-09-08 12:37:00	1.000000	3451.2073	0.0050	\N
741	3	9	VENTA	2025-09-09 09:56:00	1.000000	650.3300	0.0050	\N
742	29	139	VENTA	2025-09-09 12:58:00	1.000000	9246.8701	0.0050	\N
743	2	8	COMPRA	2025-09-10 09:49:00	13.000000	175.7900	0.0050	\N
744	41	6	VENTA	2025-09-10 10:22:00	3.000000	239.1700	0.0050	\N
745	69	10	VENTA	2025-09-11 09:38:00	3.000000	584.0800	0.0050	\N
746	44	1	COMPRA	2025-09-11 10:46:00	158.000000	9.2500	0.0050	\N
747	4	7	COMPRA	2025-09-15 10:03:00	3.000000	410.0400	0.0050	\N
748	4	13	COMPRA	2025-09-15 10:06:00	13.000000	256.0007	0.0050	0.0997
749	4	26	COMPRA	2025-09-15 10:09:00	1.000000	5080.9300	0.0050	0.0957
750	48	1	COMPRA	2025-09-15 11:14:00	16.000000	9.2300	0.0050	\N
751	48	201	COMPRA	2025-09-15 11:17:00	1.000000	1736.2400	0.0050	0.0958
752	61	4	COMPRA	2025-09-15 12:45:00	5.000000	515.3600	0.0050	\N
753	61	12	COMPRA	2025-09-15 12:48:00	7.000000	256.0007	0.0050	0.1141
754	61	261	COMPRA	2025-09-15 12:51:00	1.000000	2705.3600	0.0050	0.0911
755	32	9	COMPRA	2025-09-15 13:22:00	2.000000	660.9100	0.0050	\N
756	32	5	COMPRA	2025-09-15 13:25:00	6.000000	231.4300	0.0050	\N
757	32	4	COMPRA	2025-09-15 13:28:00	3.000000	515.3600	0.0050	\N
758	71	7	VENTA	2025-09-16 09:52:00	49.000000	421.6200	0.0050	\N
759	16	2	COMPRA	2025-09-16 11:30:00	85.000000	51.7200	0.0050	\N
760	16	4	COMPRA	2025-09-16 11:33:00	8.000000	509.0400	0.0050	\N
761	16	8	COMPRA	2025-09-16 11:36:00	24.000000	176.4600	0.0050	\N
762	16	87	COMPRA	2025-09-16 11:39:00	1.000000	14257.4900	0.0050	0.0889
763	64	9	COMPRA	2025-09-16 13:06:00	2.000000	660.0000	0.0050	\N
764	64	1	COMPRA	2025-09-16 13:09:00	149.000000	9.3800	0.0050	\N
765	64	270	COMPRA	2025-09-16 13:12:00	1.000000	1110.5500	0.0050	0.1050
766	48	199	VENTA	2025-09-17 11:11:00	1.000000	2256.0468	0.0050	\N
767	21	5	COMPRA	2025-09-19 12:05:00	37.000000	231.4800	0.0050	\N
768	21	114	COMPRA	2025-09-19 12:08:00	1.000000	9792.6600	0.0050	0.1064
769	24	8	VENTA	2025-09-19 12:23:00	1.000000	176.1900	0.0050	\N
770	62	9	COMPRA	2025-09-22 12:52:00	4.000000	666.8400	0.0050	\N
771	62	8	COMPRA	2025-09-22 12:55:00	18.000000	174.2100	0.0050	\N
772	62	264	COMPRA	2025-09-22 12:58:00	1.000000	2168.3800	0.0050	0.0950
773	54	9	VENTA	2025-09-23 11:53:00	15.000000	663.2100	0.0050	\N
774	67	280	VENTA	2025-09-23 13:24:00	1.000000	34211.2596	0.0050	\N
775	19	3	COMPRA	2025-09-24 11:51:00	6.000000	252.3100	0.0050	\N
776	19	2	COMPRA	2025-09-24 11:54:00	29.000000	52.4600	0.0050	\N
777	19	2	COMPRA	2025-09-24 11:57:00	29.000000	52.4600	0.0050	\N
778	9	8	COMPRA	2025-09-26 10:41:00	8.000000	179.7100	0.0050	\N
779	9	8	COMPRA	2025-09-26 10:44:00	8.000000	179.7100	0.0050	\N
780	9	13	COMPRA	2025-09-26 10:47:00	13.000000	256.4846	0.0050	0.1083
781	9	52	COMPRA	2025-09-26 10:50:00	1.000000	5063.7300	0.0050	0.1226
782	53	5	COMPRA	2025-09-26 11:46:00	5.000000	219.7800	0.0050	\N
783	53	8	COMPRA	2025-09-26 11:49:00	6.000000	179.7100	0.0050	\N
784	1	4	COMPRA	2025-09-29 09:42:00	7.000000	514.6000	0.0050	\N
785	1	4	COMPRA	2025-09-29 09:45:00	7.000000	514.6000	0.0050	\N
786	1	4	COMPRA	2025-09-29 09:48:00	7.000000	514.6000	0.0050	\N
787	1	15	COMPRA	2025-09-29 09:51:00	1.000000	2931.0800	0.0050	0.1063
788	14	5	COMPRA	2025-10-01 11:16:00	8.000000	220.6300	0.0050	\N
789	14	72	COMPRA	2025-10-01 11:19:00	1.000000	5201.7800	0.0050	0.1006
790	74	1	VENTA	2025-10-02 10:13:00	786.000000	9.0700	0.0050	\N
791	50	5	VENTA	2025-10-03 11:25:00	2.000000	219.5100	0.0050	\N
792	73	2	COMPRA	2025-10-06 10:06:00	76.000000	52.1600	0.0050	\N
793	73	8	COMPRA	2025-10-06 10:09:00	21.000000	188.1600	0.0050	\N
794	73	13	COMPRA	2025-10-06 10:12:00	99.000000	258.1191	0.0050	0.1012
795	73	312	COMPRA	2025-10-06 10:15:00	1.000000	38567.4700	0.0050	0.1196
796	7	10	VENTA	2025-10-06 10:24:00	52.000000	607.7100	0.0050	\N
797	18	8	VENTA	2025-10-06 11:41:00	137.000000	188.1600	0.0050	\N
798	8	2	COMPRA	2025-10-07 10:34:00	12.000000	51.9900	0.0050	\N
799	8	44	COMPRA	2025-10-07 10:37:00	1.000000	1868.7400	0.0050	0.1162
800	34	153	VENTA	2025-10-07 13:33:00	1.000000	7488.8820	0.0050	\N
801	46	7	COMPRA	2025-10-08 11:00:00	4.000000	438.6900	0.0050	\N
802	46	13	COMPRA	2025-10-08 11:03:00	17.000000	258.5623	0.0050	0.1148
803	46	193	COMPRA	2025-10-08 11:06:00	1.000000	6922.6700	0.0050	0.1278
804	15	10	COMPRA	2025-10-08 11:23:00	14.000000	611.4400	0.0050	\N
805	15	10	COMPRA	2025-10-08 11:26:00	14.000000	611.4400	0.0050	\N
806	15	12	COMPRA	2025-10-08 11:29:00	76.000000	258.5623	0.0050	0.0999
807	15	79	COMPRA	2025-10-08 11:32:00	1.000000	29751.9300	0.0050	0.1083
808	76	5	COMPRA	2025-10-09 10:30:00	4.000000	227.7400	0.0050	\N
809	60	2	VENTA	2025-10-09 12:35:00	88.000000	54.4600	0.0050	\N
810	78	2	COMPRA	2025-10-10 10:44:00	25.000000	52.5400	0.0050	\N
811	78	2	COMPRA	2025-10-10 10:47:00	25.000000	52.5400	0.0050	\N
812	78	13	COMPRA	2025-10-10 10:50:00	29.000000	256.7401	0.0050	0.0991
813	78	335	COMPRA	2025-10-10 10:53:00	1.000000	11238.6200	0.0050	0.1224
814	58	6	COMPRA	2025-10-10 12:21:00	73.000000	236.5700	0.0050	\N
815	58	247	COMPRA	2025-10-10 12:24:00	1.000000	20992.4500	0.0050	0.0892
816	21	112	VENTA	2025-10-13 12:02:00	1.000000	9721.4145	0.0050	\N
817	42	6	VENTA	2025-10-14 10:29:00	27.000000	245.4500	0.0050	\N
818	49	5	COMPRA	2025-10-14 11:21:00	5.000000	216.3900	0.0050	\N
819	49	9	COMPRA	2025-10-14 11:24:00	1.000000	662.2300	0.0050	\N
820	49	207	COMPRA	2025-10-14 11:27:00	1.000000	3054.2400	0.0050	0.1179
821	66	3	COMPRA	2025-10-14 13:20:00	10.000000	247.7700	0.0050	\N
822	66	12	COMPRA	2025-10-14 13:23:00	20.000000	255.5427	0.0050	0.0975
823	66	278	COMPRA	2025-10-14 13:26:00	1.000000	7747.2800	0.0050	0.0880
824	34	5	VENTA	2025-10-15 13:33:00	7.000000	215.5700	0.0050	\N
825	75	3	VENTA	2025-10-16 10:20:00	37.000000	247.4500	0.0050	\N
826	5	30	VENTA	2025-10-20 10:10:00	1.000000	6485.3478	0.0050	\N
827	21	111	VENTA	2025-10-20 12:02:00	1.000000	3258.2321	0.0050	\N
828	55	3	COMPRA	2025-10-22 12:03:00	14.000000	258.4500	0.0050	\N
829	55	8	COMPRA	2025-10-22 12:06:00	20.000000	192.9400	0.0050	\N
830	55	3	COMPRA	2025-10-22 12:09:00	14.000000	258.4500	0.0050	\N
831	55	233	COMPRA	2025-10-22 12:12:00	1.000000	9682.1900	0.0050	0.1278
832	30	6	COMPRA	2025-10-22 13:05:00	36.000000	251.6900	0.0050	\N
833	30	5	COMPRA	2025-10-22 13:08:00	42.000000	217.9500	0.0050	\N
834	30	146	COMPRA	2025-10-22 13:11:00	1.000000	11852.1900	0.0050	0.1166
835	77	6	COMPRA	2025-10-24 10:37:00	12.000000	259.9200	0.0050	\N
836	77	3	COMPRA	2025-10-24 10:40:00	12.000000	262.8200	0.0050	\N
837	77	3	COMPRA	2025-10-24 10:43:00	12.000000	262.8200	0.0050	\N
838	77	329	COMPRA	2025-10-24 10:46:00	1.000000	21772.6800	0.0050	0.1224
839	4	25	VENTA	2025-10-27 10:03:00	1.000000	2122.6402	0.0050	\N
840	45	4	COMPRA	2025-10-30 10:50:00	50.000000	525.7600	0.0050	\N
841	45	11	COMPRA	2025-10-30 10:53:00	17.000000	257.3810	0.0050	0.1120
842	45	187	COMPRA	2025-10-30 10:56:00	1.000000	6617.3700	0.0050	0.1223
843	4	7	COMPRA	2025-10-31 10:06:00	1.000000	456.5600	0.0050	\N
844	4	27	COMPRA	2025-10-31 10:09:00	1.000000	3208.0400	0.0050	0.0991
845	79	339	VENTA	2025-11-03 10:48:00	1.000000	9591.7485	0.0050	\N
846	24	2	COMPRA	2025-11-03 12:26:00	7.000000	57.9500	0.0050	\N
847	11	61	COMPRA	2025-11-05 10:52:00	1.000000	1902.5900	0.0050	0.1234
848	25	1	COMPRA	2025-11-05 12:33:00	277.000000	9.4600	0.0050	\N
849	25	127	COMPRA	2025-11-05 12:36:00	1.000000	1539.7900	0.0050	0.1101
850	71	7	VENTA	2025-11-06 09:52:00	14.000000	445.9100	0.0050	\N
851	44	2	COMPRA	2025-11-06 10:43:00	96.000000	60.2700	0.0050	\N
852	44	185	COMPRA	2025-11-06 10:46:00	1.000000	2380.6000	0.0050	0.1178
853	57	242	VENTA	2025-11-07 12:14:00	1.000000	2386.0165	0.0050	\N
854	53	8	COMPRA	2025-11-10 11:49:00	6.000000	188.4100	0.0050	\N
855	53	7	COMPRA	2025-11-10 11:52:00	2.000000	445.2300	0.0050	\N
856	66	276	VENTA	2025-11-10 13:17:00	1.000000	4017.1296	0.0050	\N
857	36	7	COMPRA	2025-11-11 09:50:00	1.000000	439.6200	0.0050	\N
858	36	7	COMPRA	2025-11-11 09:53:00	1.000000	439.6200	0.0050	\N
859	36	8	COMPRA	2025-11-11 09:56:00	3.000000	193.8300	0.0050	\N
860	36	157	COMPRA	2025-11-11 09:59:00	1.000000	3804.4000	0.0050	0.1203
861	40	3	VENTA	2025-11-11 10:15:00	14.000000	275.2500	0.0050	\N
862	41	172	COMPRA	2025-11-11 10:22:00	1.000000	1930.9500	0.0050	0.0939
863	52	3	COMPRA	2025-11-11 11:42:00	3.000000	275.2500	0.0050	\N
864	52	220	COMPRA	2025-11-11 11:45:00	1.000000	2455.8300	0.0050	0.0949
865	80	7	COMPRA	2025-11-14 10:55:00	37.000000	404.3500	0.0050	\N
866	80	344	COMPRA	2025-11-14 10:58:00	1.000000	16284.9400	0.0050	0.1220
867	14	5	COMPRA	2025-11-18 11:16:00	9.000000	222.5500	0.0050	\N
868	14	3	COMPRA	2025-11-18 11:19:00	8.000000	267.4400	0.0050	\N
869	14	73	COMPRA	2025-11-18 11:22:00	1.000000	12051.2000	0.0050	0.1052
870	26	9	VENTA	2025-11-18 12:37:00	7.000000	660.0800	0.0050	\N
871	61	4	VENTA	2025-11-18 12:42:00	67.000000	493.7900	0.0050	\N
872	62	263	VENTA	2025-11-18 12:49:00	1.000000	9817.1225	0.0050	\N
873	23	3	VENTA	2025-11-19 12:16:00	1.000000	268.5600	0.0050	\N
874	63	9	VENTA	2025-11-19 12:56:00	3.000000	662.6300	0.0050	\N
875	65	1	VENTA	2025-11-19 13:10:00	3793.000000	10.4400	0.0050	\N
876	32	5	VENTA	2025-11-19 13:19:00	2.000000	222.6900	0.0050	\N
877	56	8	COMPRA	2025-11-20 12:10:00	18.000000	203.0700	0.0050	\N
878	56	8	COMPRA	2025-11-20 12:13:00	18.000000	203.0700	0.0050	\N
879	56	13	COMPRA	2025-11-20 12:16:00	27.000000	269.0537	0.0050	0.1069
880	56	238	COMPRA	2025-11-20 12:19:00	1.000000	11130.7200	0.0050	0.0933
881	61	260	VENTA	2025-11-20 12:42:00	1.000000	5770.7739	0.0050	\N
882	42	175	VENTA	2025-11-21 10:29:00	1.000000	9156.0295	0.0050	\N
883	24	125	VENTA	2025-11-21 12:23:00	1.000000	2635.8356	0.0050	\N
884	5	3	VENTA	2025-11-25 10:10:00	25.000000	276.9700	0.0050	\N
885	75	8	VENTA	2025-12-01 10:20:00	10.000000	205.3400	0.0050	\N
886	17	90	VENTA	2025-12-01 11:34:00	1.000000	63660.1729	0.0050	\N
887	78	5	COMPRA	2025-12-02 10:44:00	6.000000	234.4200	0.0050	\N
888	78	5	COMPRA	2025-12-02 10:47:00	6.000000	234.4200	0.0050	\N
889	78	3	COMPRA	2025-12-02 10:50:00	5.000000	286.1900	0.0050	\N
890	78	11	COMPRA	2025-12-02 10:53:00	31.000000	264.2406	0.0050	0.1140
891	78	336	COMPRA	2025-12-02 10:56:00	1.000000	12421.1700	0.0050	0.1174
892	31	7	COMPRA	2025-12-03 13:12:00	1.000000	446.7400	0.0050	\N
893	31	5	COMPRA	2025-12-03 13:15:00	2.000000	232.3800	0.0050	\N
894	27	134	VENTA	2025-12-04 12:44:00	1.000000	37963.8217	0.0050	\N
895	29	141	COMPRA	2025-12-04 13:01:00	1.000000	8457.0000	0.0050	0.1067
896	51	2	COMPRA	2025-12-05 11:35:00	32.000000	62.4100	0.0050	\N
897	51	8	COMPRA	2025-12-05 11:38:00	9.000000	201.9300	0.0050	\N
898	51	215	COMPRA	2025-12-05 11:41:00	1.000000	10466.7700	0.0050	0.1061
899	50	5	VENTA	2025-12-08 11:25:00	1.000000	226.8900	0.0050	\N
900	17	92	VENTA	2025-12-08 11:34:00	1.000000	4526.4817	0.0050	\N
901	59	6	COMPRA	2025-12-08 12:31:00	18.000000	313.7200	0.0050	\N
902	59	8	COMPRA	2025-12-08 12:34:00	28.000000	201.6200	0.0050	\N
903	59	251	COMPRA	2025-12-08 12:37:00	1.000000	6347.1400	0.0050	0.1267
904	42	177	VENTA	2025-12-09 10:29:00	1.000000	15159.4388	0.0050	\N
905	20	1	VENTA	2025-12-09 11:55:00	1380.000000	10.0000	0.0050	\N
906	46	191	VENTA	2025-12-11 10:57:00	1.000000	31648.0648	0.0050	\N
907	41	170	VENTA	2025-12-12 10:22:00	1.000000	20109.0927	0.0050	\N
908	10	2	VENTA	2025-12-12 10:45:00	3.000000	63.9000	0.0050	\N
909	52	218	VENTA	2025-12-15 11:39:00	1.000000	4583.0647	0.0050	\N
910	56	236	VENTA	2025-12-15 12:07:00	1.000000	43240.2817	0.0050	\N
911	30	6	COMPRA	2025-12-15 13:08:00	29.000000	308.2200	0.0050	\N
912	30	4	COMPRA	2025-12-15 13:11:00	19.000000	474.8200	0.0050	\N
913	30	147	COMPRA	2025-12-15 13:14:00	1.000000	11814.4000	0.0050	0.1207
914	69	290	VENTA	2025-12-17 09:38:00	1.000000	5603.0588	0.0050	\N
915	74	7	COMPRA	2025-12-17 10:16:00	5.000000	467.2600	0.0050	\N
916	74	5	COMPRA	2025-12-17 10:19:00	12.000000	221.2700	0.0050	\N
917	74	2	COMPRA	2025-12-17 10:22:00	44.000000	61.8300	0.0050	\N
918	74	11	COMPRA	2025-12-17 10:25:00	10.000000	259.9361	0.0050	0.1106
919	74	316	COMPRA	2025-12-17 10:28:00	1.000000	4038.0300	0.0050	0.0962
920	22	5	COMPRA	2025-12-17 12:12:00	4.000000	221.2700	0.0050	\N
921	22	4	COMPRA	2025-12-17 12:15:00	1.000000	476.1200	0.0050	\N
922	22	120	COMPRA	2025-12-17 12:18:00	1.000000	7468.3400	0.0050	0.1106
923	29	1	VENTA	2025-12-17 12:58:00	96.000000	9.3500	0.0050	\N
924	68	2	COMPRA	2025-12-17 13:31:00	5.000000	61.8300	0.0050	\N
925	68	3	COMPRA	2025-12-17 13:34:00	1.000000	271.8400	0.0050	\N
926	68	8	COMPRA	2025-12-17 13:37:00	1.000000	210.3300	0.0050	\N
927	54	9	VENTA	2025-12-18 11:53:00	6.000000	676.4700	0.0050	\N
928	45	6	COMPRA	2025-12-19 10:53:00	57.000000	307.1600	0.0050	\N
929	45	6	COMPRA	2025-12-19 10:56:00	57.000000	307.1600	0.0050	\N
930	45	5	COMPRA	2025-12-19 10:59:00	77.000000	227.3500	0.0050	\N
931	45	188	COMPRA	2025-12-19 11:02:00	1.000000	7306.5700	0.0050	0.1225
932	17	10	COMPRA	2025-12-22 11:34:00	95.000000	619.2100	0.0050	\N
933	17	13	COMPRA	2025-12-22 11:37:00	94.000000	261.9220	0.0050	0.1180
934	17	94	COMPRA	2025-12-22 11:40:00	1.000000	37151.7000	0.0050	0.0936
935	57	9	VENTA	2025-12-22 12:14:00	26.000000	684.8300	0.0050	\N
936	33	152	VENTA	2025-12-22 13:26:00	1.000000	6746.0227	0.0050	\N
937	34	6	COMPRA	2025-12-22 13:36:00	1.000000	309.7800	0.0050	\N
938	34	5	COMPRA	2025-12-22 13:39:00	1.000000	228.4300	0.0050	\N
939	34	1	COMPRA	2025-12-22 13:42:00	38.000000	9.3000	0.0050	\N
940	34	154	COMPRA	2025-12-22 13:45:00	1.000000	1904.4900	0.0050	0.0941
941	5	29	VENTA	2025-12-23 10:10:00	1.000000	1269.0971	0.0050	\N
942	33	10	COMPRA	2025-12-24 13:29:00	3.000000	623.9300	0.0050	\N
943	33	10	COMPRA	2025-12-24 13:32:00	3.000000	623.9300	0.0050	\N
944	33	4	COMPRA	2025-12-24 13:35:00	4.000000	488.0200	0.0050	\N
945	67	9	VENTA	2025-12-26 13:24:00	5.000000	690.3100	0.0050	\N
946	77	8	COMPRA	2025-12-29 10:37:00	12.000000	207.5600	0.0050	\N
947	9	49	VENTA	2025-12-29 10:38:00	1.000000	15070.3400	0.0050	\N
948	77	330	COMPRA	2025-12-29 10:40:00	1.000000	17400.2000	0.0050	0.1069
949	18	97	VENTA	2025-12-29 11:41:00	1.000000	2764.9801	0.0050	\N
950	3	10	COMPRA	2025-12-30 09:59:00	2.000000	619.4300	0.0050	\N
951	3	9	COMPRA	2025-12-30 10:02:00	2.000000	687.0100	0.0050	\N
952	3	22	COMPRA	2025-12-30 10:05:00	1.000000	3007.9400	0.0050	0.0898
953	16	8	COMPRA	2025-12-30 11:30:00	16.000000	206.9100	0.0050	\N
954	16	2	COMPRA	2025-12-30 11:33:00	54.000000	63.9900	0.0050	\N
955	16	8	COMPRA	2025-12-30 11:36:00	16.000000	206.9100	0.0050	\N
956	16	12	COMPRA	2025-12-30 11:39:00	16.000000	269.7621	0.0050	0.1018
957	16	88	COMPRA	2025-12-30 11:42:00	1.000000	6817.5700	0.0050	0.1077
958	64	269	VENTA	2025-12-30 13:03:00	1.000000	6073.0767	0.0050	\N
959	64	6	COMPRA	2025-12-31 13:06:00	1.000000	313.0000	0.0050	\N
960	64	6	COMPRA	2025-12-31 13:09:00	1.000000	313.0000	0.0050	\N
961	4	1	COMPRA	2026-01-02 10:06:00	12.000000	10.2200	0.0050	\N
962	4	1	COMPRA	2026-01-02 10:09:00	12.000000	10.2200	0.0050	\N
963	9	1	COMPRA	2026-01-02 10:41:00	278.000000	10.2200	0.0050	\N
964	9	4	COMPRA	2026-01-02 10:44:00	6.000000	472.9400	0.0050	\N
965	9	1	COMPRA	2026-01-02 10:47:00	278.000000	10.2200	0.0050	\N
966	9	53	COMPRA	2026-01-02 10:50:00	1.000000	15543.7300	0.0050	0.1158
967	68	288	COMPRA	2026-01-02 13:34:00	1.000000	2626.6800	0.0050	0.1257
968	57	243	VENTA	2026-01-05 12:14:00	1.000000	4773.5073	0.0050	\N
969	27	10	VENTA	2026-01-05 12:44:00	1.000000	617.9900	0.0050	\N
970	1	3	COMPRA	2026-01-08 09:42:00	6.000000	259.0400	0.0050	\N
971	2	10	COMPRA	2026-01-09 09:52:00	3.000000	626.6500	0.0050	\N
972	2	10	COMPRA	2026-01-09 09:55:00	3.000000	626.6500	0.0050	\N
973	46	10	VENTA	2026-01-09 10:57:00	2.000000	626.6500	0.0050	\N
974	58	8	COMPRA	2026-01-09 12:24:00	12.000000	204.3900	0.0050	\N
975	58	248	COMPRA	2026-01-09 12:27:00	1.000000	1595.4900	0.0050	0.1205
976	47	6	COMPRA	2026-01-12 11:07:00	8.000000	331.8600	0.0050	\N
977	47	196	COMPRA	2026-01-12 11:10:00	1.000000	39656.9200	0.0050	0.1067
978	48	198	VENTA	2026-01-12 11:11:00	1.000000	30894.1371	0.0050	\N
979	60	257	VENTA	2026-01-12 12:35:00	1.000000	21969.8520	0.0050	\N
980	65	272	VENTA	2026-01-12 13:10:00	1.000000	2890.8776	0.0050	\N
981	11	4	VENTA	2026-01-13 10:52:00	1.000000	470.6700	0.0050	\N
982	62	8	VENTA	2026-01-13 12:49:00	4.000000	213.6500	0.0050	\N
983	71	7	VENTA	2026-01-14 09:52:00	14.000000	439.2000	0.0050	\N
984	15	9	COMPRA	2026-01-14 11:23:00	8.000000	690.3600	0.0050	\N
985	15	80	COMPRA	2026-01-14 11:26:00	1.000000	33475.7100	0.0050	0.1220
986	72	309	COMPRA	2026-01-16 09:59:00	1.000000	1749.2900	0.0050	0.1019
987	70	7	VENTA	2026-01-20 09:45:00	14.000000	419.2500	0.0050	\N
988	74	317	COMPRA	2026-01-20 10:16:00	1.000000	9173.4000	0.0050	0.0987
989	78	334	VENTA	2026-01-20 10:41:00	1.000000	12307.0102	0.0050	\N
990	28	4	COMPRA	2026-01-20 12:51:00	4.000000	454.5200	0.0050	\N
991	7	8	COMPRA	2026-01-21 10:27:00	45.000000	218.0100	0.0050	\N
992	7	38	COMPRA	2026-01-21 10:30:00	1.000000	14014.2800	0.0050	0.1064
993	79	3	COMPRA	2026-01-22 10:51:00	4.000000	248.3500	0.0050	\N
994	79	1	COMPRA	2026-01-22 10:54:00	98.000000	12.2000	0.0050	\N
995	75	320	VENTA	2026-01-23 10:20:00	1.000000	70716.1846	0.0050	\N
996	42	10	COMPRA	2026-01-23 10:32:00	3.000000	622.7200	0.0050	\N
997	42	1	COMPRA	2026-01-23 10:35:00	169.000000	12.5000	0.0050	\N
998	42	179	COMPRA	2026-01-23 10:38:00	1.000000	5399.9300	0.0050	0.1111
999	10	58	VENTA	2026-01-23 10:45:00	1.000000	5244.2888	0.0050	\N
1000	51	1	COMPRA	2026-01-23 11:35:00	167.000000	12.5000	0.0050	\N
1001	51	216	COMPRA	2026-01-23 11:38:00	1.000000	10935.1900	0.0050	0.0899
1002	20	10	VENTA	2026-01-23 11:55:00	9.000000	622.7200	0.0050	\N
1003	19	8	VENTA	2026-01-26 11:48:00	52.000000	221.4900	0.0050	\N
1004	53	222	COMPRA	2026-01-26 11:49:00	1.000000	4259.9400	0.0050	0.1279
1005	21	110	VENTA	2026-01-27 12:02:00	1.000000	53161.7090	0.0050	\N
1006	44	2	VENTA	2026-01-29 10:43:00	49.000000	84.5300	0.0050	\N
1007	8	8	VENTA	2026-01-30 10:31:00	8.000000	227.2500	0.0050	\N
1008	18	5	COMPRA	2026-02-03 11:44:00	23.000000	238.6200	0.0050	\N
1009	18	5	COMPRA	2026-02-03 11:47:00	23.000000	238.6200	0.0050	\N
1010	18	98	COMPRA	2026-02-03 11:50:00	1.000000	2088.0600	0.0050	0.1232
1011	60	3	VENTA	2026-02-03 12:35:00	6.000000	269.4800	0.0050	\N
1012	76	8	COMPRA	2026-02-04 10:30:00	4.000000	234.4700	0.0050	\N
1013	76	8	COMPRA	2026-02-04 10:33:00	4.000000	234.4700	0.0050	\N
1014	76	7	COMPRA	2026-02-04 10:36:00	2.000000	406.0100	0.0050	\N
1015	53	221	VENTA	2026-02-04 11:46:00	1.000000	4688.6181	0.0050	\N
1016	49	1	VENTA	2026-02-06 11:18:00	96.000000	12.2300	0.0050	\N
1017	32	9	COMPRA	2026-02-09 13:22:00	4.000000	693.9500	0.0050	\N
1018	79	340	COMPRA	2026-02-10 10:51:00	1.000000	5052.7700	0.0050	0.0893
1019	66	3	COMPRA	2026-02-13 13:20:00	13.000000	255.7800	0.0050	\N
1020	66	279	COMPRA	2026-02-13 13:23:00	1.000000	8792.2700	0.0050	0.1133
1021	2	18	COMPRA	2026-02-17 09:52:00	1.000000	2487.5600	0.0050	0.0971
1022	48	200	VENTA	2026-02-17 11:11:00	1.000000	3458.9300	0.0050	\N
1023	55	3	COMPRA	2026-02-17 12:00:00	44.000000	263.8800	0.0050	\N
1024	55	1	COMPRA	2026-02-17 12:03:00	975.000000	11.9500	0.0050	\N
1025	55	11	COMPRA	2026-02-17 12:06:00	42.000000	273.7558	0.0050	0.1022
1026	55	234	COMPRA	2026-02-17 12:09:00	1.000000	17491.3100	0.0050	0.1241
1027	13	10	VENTA	2026-02-18 11:06:00	15.000000	605.7900	0.0050	\N
1028	53	7	VENTA	2026-02-18 11:46:00	17.000000	411.3200	0.0050	\N
1029	38	160	VENTA	2026-02-23 10:01:00	1.000000	13592.8942	0.0050	\N
1030	9	7	VENTA	2026-02-25 10:38:00	5.000000	417.4000	0.0050	\N
1031	69	6	COMPRA	2026-02-26 09:41:00	5.000000	307.3800	0.0050	\N
1032	69	6	COMPRA	2026-02-26 09:44:00	5.000000	307.3800	0.0050	\N
1033	69	6	COMPRA	2026-02-26 09:47:00	5.000000	307.3800	0.0050	\N
1034	69	12	COMPRA	2026-02-26 09:50:00	7.000000	270.0010	0.0050	0.1002
1035	69	292	COMPRA	2026-02-26 09:53:00	1.000000	3195.7300	0.0050	0.0888
1036	22	5	VENTA	2026-02-27 12:09:00	7.000000	210.0000	0.0050	\N
1037	30	6	VENTA	2026-03-02 13:05:00	21.000000	306.5200	0.0050	\N
1038	25	1	VENTA	2026-03-03 12:30:00	99.000000	11.6900	0.0050	\N
1039	54	3	COMPRA	2026-03-04 11:53:00	28.000000	262.5200	0.0050	\N
1040	54	227	COMPRA	2026-03-04 11:56:00	1.000000	6290.3200	0.0050	0.1021
1041	55	232	VENTA	2026-03-04 12:00:00	1.000000	3863.2225	0.0050	\N
1042	24	2	COMPRA	2026-03-04 12:26:00	13.000000	67.0200	0.0050	\N
1043	24	6	COMPRA	2026-03-04 12:29:00	3.000000	303.1300	0.0050	\N
1044	27	137	VENTA	2026-03-04 12:44:00	1.000000	8645.4653	0.0050	\N
1045	28	5	VENTA	2026-03-04 12:51:00	6.000000	216.8200	0.0050	\N
1046	34	1	COMPRA	2026-03-05 13:36:00	11.000000	12.6100	0.0050	\N
1047	7	37	VENTA	2026-03-09 10:24:00	1.000000	3309.4152	0.0050	\N
1048	65	6	COMPRA	2026-03-10 13:10:00	69.000000	307.0400	0.0050	\N
1049	65	2	COMPRA	2026-03-10 13:13:00	302.000000	70.2100	0.0050	\N
1050	65	273	COMPRA	2026-03-10 13:16:00	1.000000	5524.3300	0.0050	0.0996
1051	61	3	VENTA	2026-03-11 12:42:00	35.000000	260.8100	0.0050	\N
1052	71	301	VENTA	2026-03-12 09:52:00	1.000000	67987.8471	0.0050	\N
1053	40	2	VENTA	2026-03-13 10:15:00	157.000000	65.8300	0.0050	\N
1054	1	4	COMPRA	2026-03-16 09:45:00	9.000000	399.9500	0.0050	\N
1055	1	16	COMPRA	2026-03-16 09:48:00	1.000000	2742.6700	0.0050	0.0940
1056	4	26	VENTA	2026-03-16 10:03:00	1.000000	5633.4722	0.0050	\N
1057	39	8	COMPRA	2026-03-16 10:08:00	185.000000	243.1900	0.0050	\N
1058	39	3	COMPRA	2026-03-16 10:11:00	178.000000	252.8200	0.0050	\N
1059	39	11	COMPRA	2026-03-16 10:14:00	62.000000	271.3314	0.0050	0.1068
1060	39	163	COMPRA	2026-03-16 10:17:00	1.000000	25591.8800	0.0050	0.0972
1061	12	5	VENTA	2026-03-16 10:59:00	13.000000	211.7400	0.0050	\N
1062	41	2	COMPRA	2026-03-17 10:22:00	13.000000	67.9000	0.0050	\N
1063	41	173	COMPRA	2026-03-17 10:25:00	1.000000	14706.3700	0.0050	0.0887
1064	42	6	COMPRA	2026-03-17 10:29:00	27.000000	310.9200	0.0050	\N
1065	42	6	COMPRA	2026-03-17 10:32:00	27.000000	310.9200	0.0050	\N
1066	42	13	COMPRA	2026-03-17 10:35:00	63.000000	270.8632	0.0050	0.1023
1067	42	180	COMPRA	2026-03-17 10:38:00	1.000000	25877.4900	0.0050	0.0961
1068	79	3	VENTA	2026-03-17 10:48:00	18.000000	254.2300	0.0050	\N
1069	21	4	COMPRA	2026-03-18 12:05:00	21.000000	391.7900	0.0050	\N
1070	21	9	COMPRA	2026-03-18 12:08:00	12.000000	661.4300	0.0050	\N
1071	21	115	COMPRA	2026-03-18 12:11:00	1.000000	9347.4000	0.0050	0.1036
1072	62	3	COMPRA	2026-03-18 12:49:00	38.000000	249.9400	0.0050	\N
1073	62	265	COMPRA	2026-03-18 12:52:00	1.000000	13080.9100	0.0050	0.0909
1074	80	4	VENTA	2026-03-20 10:55:00	2.000000	381.8700	0.0050	\N
1075	14	5	VENTA	2026-03-20 11:13:00	29.000000	205.3700	0.0050	\N
1076	58	6	VENTA	2026-03-20 12:21:00	38.000000	301.0000	0.0050	\N
1077	78	5	COMPRA	2026-03-23 10:44:00	5.000000	210.1400	0.0050	\N
1078	78	3	COMPRA	2026-03-23 10:47:00	4.000000	251.4900	0.0050	\N
1079	78	12	COMPRA	2026-03-23 10:50:00	21.000000	269.9150	0.0050	0.1076
1080	78	337	COMPRA	2026-03-23 10:53:00	1.000000	8792.6000	0.0050	0.0957
1081	54	225	VENTA	2026-03-23 11:53:00	1.000000	4921.6269	0.0050	\N
1082	57	9	VENTA	2026-03-23 12:14:00	10.000000	655.3800	0.0050	\N
1083	26	9	COMPRA	2026-03-24 12:37:00	9.000000	653.1800	0.0050	\N
1084	26	3	COMPRA	2026-03-24 12:40:00	24.000000	251.6400	0.0050	\N
1085	26	4	COMPRA	2026-03-24 12:43:00	16.000000	372.7400	0.0050	\N
1086	26	133	COMPRA	2026-03-24 12:46:00	1.000000	5120.5300	0.0050	0.1025
1087	72	10	COMPRA	2026-03-25 10:02:00	1.000000	587.8200	0.0050	\N
1088	72	3	COMPRA	2026-03-25 10:05:00	2.000000	252.6200	0.0050	\N
1089	72	3	COMPRA	2026-03-25 10:08:00	2.000000	252.6200	0.0050	\N
1090	72	310	COMPRA	2026-03-25 10:11:00	1.000000	4178.6100	0.0050	0.1063
1091	23	3	VENTA	2026-03-26 12:16:00	1.000000	252.8900	0.0050	\N
1092	5	4	COMPRA	2026-03-27 10:10:00	10.000000	356.7700	0.0050	\N
1093	5	3	COMPRA	2026-03-27 10:13:00	14.000000	248.8000	0.0050	\N
1094	5	3	COMPRA	2026-03-27 10:16:00	14.000000	248.8000	0.0050	\N
1095	5	32	COMPRA	2026-03-27 10:19:00	1.000000	5736.4800	0.0050	0.1110
1096	20	6	COMPRA	2026-03-27 11:58:00	7.000000	274.3400	0.0050	\N
1097	20	1	COMPRA	2026-03-27 12:01:00	143.000000	15.0100	0.0050	\N
1098	20	107	COMPRA	2026-03-27 12:04:00	1.000000	5174.1700	0.0050	0.1048
1099	1	15	VENTA	2026-03-30 09:42:00	1.000000	3281.6845	0.0050	\N
1100	5	31	VENTA	2026-03-30 10:10:00	1.000000	4100.2429	0.0050	\N
1101	59	10	COMPRA	2026-03-30 12:31:00	6.000000	558.2800	0.0050	\N
1102	59	8	COMPRA	2026-03-30 12:34:00	14.000000	242.4900	0.0050	\N
1103	59	10	COMPRA	2026-03-30 12:37:00	6.000000	558.2800	0.0050	\N
1104	59	252	COMPRA	2026-03-30 12:40:00	1.000000	1984.2800	0.0050	0.0972
1105	68	283	VENTA	2026-03-30 13:31:00	1.000000	10374.3203	0.0050	\N
1106	40	166	VENTA	2026-03-31 10:15:00	1.000000	8591.3155	0.0050	\N
1107	20	102	VENTA	2026-03-31 11:55:00	1.000000	8006.7926	0.0050	\N
1108	33	8	VENTA	2026-03-31 13:26:00	11.000000	244.4400	0.0050	\N
1109	31	6	VENTA	2026-04-01 13:12:00	7.000000	297.3900	0.0050	\N
1110	3	20	VENTA	2026-04-06 09:56:00	1.000000	4627.0627	0.0050	\N
1111	41	171	VENTA	2026-04-06 10:22:00	1.000000	3149.9270	0.0050	\N
1112	16	8	VENTA	2026-04-07 11:27:00	31.000000	238.4100	0.0050	\N
1113	64	6	VENTA	2026-04-08 13:03:00	1.000000	317.3200	0.0050	\N
1114	51	214	VENTA	2026-04-10 11:32:00	1.000000	12579.6783	0.0050	\N
1115	71	304	VENTA	2026-04-13 09:52:00	1.000000	6919.1072	0.0050	\N
1116	56	4	VENTA	2026-04-13 12:07:00	3.000000	384.3700	0.0050	\N
1117	77	3	VENTA	2026-04-14 10:34:00	15.000000	258.8300	0.0050	\N
1118	63	9	VENTA	2026-04-16 12:56:00	1.000000	701.6600	0.0050	\N
1119	50	7	COMPRA	2026-04-17 11:28:00	4.000000	400.6200	0.0050	\N
1120	50	1	COMPRA	2026-04-17 11:31:00	123.000000	13.5500	0.0050	\N
1121	53	5	VENTA	2026-04-20 11:46:00	5.000000	248.2800	0.0050	\N
1122	24	8	COMPRA	2026-04-20 12:26:00	1.000000	230.6900	0.0050	\N
1123	24	2	COMPRA	2026-04-20 12:29:00	4.000000	74.7400	0.0050	\N
1124	24	8	COMPRA	2026-04-20 12:32:00	1.000000	230.6900	0.0050	\N
1125	70	7	COMPRA	2026-04-22 09:45:00	10.000000	387.5100	0.0050	\N
1126	70	299	COMPRA	2026-04-22 09:48:00	1.000000	8085.3400	0.0050	0.0926
1127	77	329	VENTA	2026-04-22 10:34:00	1.000000	25063.9664	0.0050	\N
1128	9	4	COMPRA	2026-04-27 10:38:00	7.000000	424.8200	0.0050	\N
1129	9	11	COMPRA	2026-04-27 10:41:00	25.000000	281.5973	0.0050	0.0953
1130	9	54	COMPRA	2026-04-27 10:44:00	1.000000	10672.7800	0.0050	0.1042
1131	25	126	VENTA	2026-04-27 12:30:00	1.000000	4119.8049	0.0050	\N
1132	4	27	VENTA	2026-04-29 10:03:00	1.000000	3579.9681	0.0050	\N
1133	12	5	VENTA	2026-04-30 10:59:00	5.000000	265.0600	0.0050	\N
1134	49	4	COMPRA	2026-04-30 11:21:00	2.000000	407.7800	0.0050	\N
1135	49	5	COMPRA	2026-04-30 11:24:00	3.000000	265.0600	0.0050	\N
1136	49	1	COMPRA	2026-04-30 11:27:00	59.000000	14.1600	0.0050	\N
1137	49	208	COMPRA	2026-04-30 11:30:00	1.000000	2319.5800	0.0050	0.1125
1138	78	333	VENTA	2026-05-01 10:41:00	1.000000	53641.3281	0.0050	\N
1139	3	1	VENTA	2026-05-04 09:56:00	182.000000	14.0300	0.0050	\N
1140	18	8	COMPRA	2026-05-04 11:44:00	37.000000	224.2000	0.0050	\N
1141	18	10	COMPRA	2026-05-04 11:47:00	12.000000	672.8800	0.0050	\N
1142	18	8	COMPRA	2026-05-04 11:50:00	37.000000	224.2000	0.0050	\N
1143	18	99	COMPRA	2026-05-04 11:53:00	1.000000	3176.4300	0.0050	0.0909
1144	20	104	VENTA	2026-05-04 11:55:00	1.000000	6383.9446	0.0050	\N
1145	69	3	COMPRA	2026-05-05 09:41:00	2.000000	284.1800	0.0050	\N
1146	69	293	COMPRA	2026-05-05 09:44:00	1.000000	1912.5000	0.0050	0.0973
1147	44	185	VENTA	2026-05-05 10:43:00	1.000000	2604.4617	0.0050	\N
1148	1	3	VENTA	2026-05-06 09:42:00	2.000000	287.5100	0.0050	\N
1149	14	2	COMPRA	2026-05-06 11:16:00	33.000000	66.8400	0.0050	\N
1150	14	10	COMPRA	2026-05-06 11:19:00	3.000000	695.7700	0.0050	\N
1151	15	1	VENTA	2026-05-06 11:20:00	878.000000	13.3600	0.0050	\N
1152	14	3	COMPRA	2026-05-06 11:22:00	7.000000	287.5100	0.0050	\N
1153	14	74	COMPRA	2026-05-06 11:25:00	1.000000	12341.4800	0.0050	0.0927
1154	70	297	VENTA	2026-05-07 09:45:00	1.000000	3344.0257	0.0050	\N
1155	39	8	COMPRA	2026-05-07 10:11:00	14.000000	222.5100	0.0050	\N
1156	39	164	COMPRA	2026-05-07 10:14:00	1.000000	3057.9100	0.0050	0.1074
1157	55	231	VENTA	2026-05-07 12:00:00	1.000000	12511.2848	0.0050	\N
1158	66	3	VENTA	2026-05-07 13:17:00	63.000000	287.4400	0.0050	\N
1159	80	343	VENTA	2026-05-08 10:55:00	1.000000	2226.3672	0.0050	\N
1160	3	21	VENTA	2026-05-11 09:56:00	1.000000	3419.1058	0.0050	\N
1161	75	5	COMPRA	2026-05-11 10:23:00	6.000000	268.9900	0.0050	\N
1162	75	3	COMPRA	2026-05-11 10:26:00	6.000000	292.6800	0.0050	\N
1163	75	12	COMPRA	2026-05-11 10:29:00	17.000000	266.8730	0.0050	0.1140
1164	75	321	COMPRA	2026-05-11 10:32:00	1.000000	7041.9500	0.0050	0.1189
1165	9	50	VENTA	2026-05-11 10:38:00	1.000000	31758.4684	0.0050	\N
1166	23	3	COMPRA	2026-05-11 12:16:00	6.000000	292.6800	0.0050	\N
1167	23	3	COMPRA	2026-05-11 12:19:00	6.000000	292.6800	0.0050	\N
1168	23	3	COMPRA	2026-05-11 12:22:00	6.000000	292.6800	0.0050	\N
1169	23	124	COMPRA	2026-05-11 12:25:00	1.000000	7551.3500	0.0050	0.1149
1170	30	145	VENTA	2026-05-11 13:05:00	1.000000	43325.0863	0.0050	\N
1171	32	9	VENTA	2026-05-11 13:19:00	3.000000	739.3000	0.0050	\N
1172	71	3	VENTA	2026-05-12 09:52:00	2.000000	294.8000	0.0050	\N
1173	22	4	VENTA	2026-05-13 12:09:00	4.000000	405.2100	0.0050	\N
1174	33	10	COMPRA	2026-05-13 13:29:00	1.000000	714.7100	0.0050	\N
1175	33	10	COMPRA	2026-05-13 13:32:00	1.000000	714.7100	0.0050	\N
1176	7	9	COMPRA	2026-05-14 10:24:00	13.000000	748.1700	0.0050	\N
1177	7	10	COMPRA	2026-05-14 10:27:00	14.000000	719.7900	0.0050	\N
1178	7	11	COMPRA	2026-05-14 10:30:00	21.000000	263.5109	0.0050	0.1081
1179	7	39	COMPRA	2026-05-14 10:33:00	1.000000	8660.8300	0.0050	0.1182
1180	57	9	COMPRA	2026-05-15 12:17:00	8.000000	739.1700	0.0050	\N
1181	57	245	COMPRA	2026-05-15 12:20:00	1.000000	2982.8300	0.0050	0.1021
1182	28	138	VENTA	2026-05-18 12:51:00	1.000000	8347.5789	0.0050	\N
1183	42	1	COMPRA	2026-05-21 10:32:00	177.000000	13.8600	0.0050	\N
1184	42	11	COMPRA	2026-05-21 10:35:00	9.000000	268.0613	0.0050	0.0922
1185	42	181	COMPRA	2026-05-21 10:38:00	1.000000	3749.2900	0.0050	0.0941
1186	51	10	COMPRA	2026-05-21 11:35:00	3.000000	714.5100	0.0050	\N
1187	51	217	COMPRA	2026-05-21 11:38:00	1.000000	6772.3900	0.0050	0.0952
1188	10	59	VENTA	2026-05-22 10:45:00	1.000000	3670.0910	0.0050	\N
1189	45	186	VENTA	2026-05-22 10:50:00	1.000000	45878.0354	0.0050	\N
1190	17	93	VENTA	2026-05-22 11:34:00	1.000000	12433.9393	0.0050	\N
1191	19	8	COMPRA	2026-05-22 11:48:00	21.000000	234.3400	0.0050	\N
1192	19	3	COMPRA	2026-05-22 11:51:00	16.000000	308.8200	0.0050	\N
1193	19	100	COMPRA	2026-05-22 11:54:00	1.000000	4036.9500	0.0050	0.1219
1194	30	5	COMPRA	2026-05-22 13:08:00	26.000000	266.3200	0.0050	\N
1195	30	6	COMPRA	2026-05-22 13:11:00	18.000000	382.9700	0.0050	\N
1196	30	6	COMPRA	2026-05-22 13:14:00	18.000000	382.9700	0.0050	\N
1197	30	148	COMPRA	2026-05-22 13:17:00	1.000000	9061.3000	0.0050	0.1023
1198	54	226	VENTA	2026-05-26 11:53:00	1.000000	5182.8272	0.0050	\N
1199	56	239	COMPRA	2026-05-26 12:10:00	1.000000	24200.8300	0.0050	0.1169
1200	58	8	VENTA	2026-05-26 12:21:00	12.000000	230.1800	0.0050	\N
1201	26	132	VENTA	2026-05-26 12:37:00	1.000000	2587.4865	0.0050	\N
1202	8	8	COMPRA	2026-05-27 10:31:00	15.000000	231.2900	0.0050	\N
1203	8	8	COMPRA	2026-05-27 10:34:00	15.000000	231.2900	0.0050	\N
1204	8	10	COMPRA	2026-05-27 10:37:00	4.000000	729.4500	0.0050	\N
1205	8	13	COMPRA	2026-05-27 10:40:00	31.000000	274.3883	0.0050	0.0938
1206	8	45	COMPRA	2026-05-27 10:43:00	1.000000	12829.5900	0.0050	0.0959
1207	72	3	VENTA	2026-05-28 09:59:00	3.000000	312.5100	0.0050	\N
1208	40	169	VENTA	2026-05-28 10:15:00	1.000000	8280.2721	0.0050	\N
1209	72	308	VENTA	2026-06-01 09:59:00	1.000000	17375.7848	0.0050	\N
1210	11	60	VENTA	2026-06-01 10:52:00	1.000000	15781.3075	0.0050	\N
1211	16	86	VENTA	2026-06-01 11:27:00	1.000000	6492.2765	0.0050	\N
1212	27	136	VENTA	2026-06-01 12:44:00	1.000000	6863.4327	0.0050	\N
1213	31	150	VENTA	2026-06-01 13:12:00	1.000000	4775.0295	0.0050	\N
1214	56	237	VENTA	2026-06-02 12:07:00	1.000000	9216.1394	0.0050	\N
1215	31	6	VENTA	2026-06-02 13:12:00	4.000000	361.8500	0.0050	\N
1216	67	282	VENTA	2026-06-02 13:24:00	1.000000	2766.2460	0.0050	\N
1217	20	10	COMPRA	2026-06-04 11:58:00	1.000000	740.6100	0.0050	\N
1218	20	1	COMPRA	2026-06-04 12:01:00	71.000000	15.6400	0.0050	\N
1219	20	6	COMPRA	2026-06-04 12:04:00	3.000000	372.1900	0.0050	\N
1220	20	108	COMPRA	2026-06-04 12:07:00	1.000000	2684.8300	0.0050	0.0990
1221	67	281	VENTA	2026-06-04 13:24:00	1.000000	11331.5041	0.0050	\N
1222	72	311	COMPRA	2026-06-08 10:02:00	1.000000	4612.0100	0.0050	0.1056
1223	77	8	COMPRA	2026-06-09 10:37:00	5.000000	237.0000	0.0050	\N
1224	77	6	COMPRA	2026-06-09 10:40:00	3.000000	364.2600	0.0050	\N
1225	77	7	COMPRA	2026-06-09 10:43:00	3.000000	396.6800	0.0050	\N
1226	77	331	COMPRA	2026-06-09 10:46:00	1.000000	8931.8900	0.0050	0.1079
1227	65	1	COMPRA	2026-06-09 13:10:00	355.000000	15.8800	0.0050	\N
1228	37	5	VENTA	2026-06-11 09:54:00	3.000000	241.5100	0.0050	\N
1229	59	250	VENTA	2026-06-11 12:28:00	1.000000	3499.8111	0.0050	\N
1230	48	201	VENTA	2026-06-12 11:11:00	1.000000	2065.4470	0.0050	\N
1231	59	10	COMPRA	2026-06-12 12:31:00	4.000000	721.3400	0.0050	\N
1232	59	8	COMPRA	2026-06-12 12:34:00	12.000000	240.8700	0.0050	\N
1233	59	253	COMPRA	2026-06-12 12:37:00	1.000000	3378.5100	0.0050	0.1205
1234	69	291	VENTA	2026-06-15 09:38:00	1.000000	9976.7286	0.0050	\N
1235	6	35	VENTA	2026-06-15 10:17:00	1.000000	69347.0967	0.0050	\N
1236	56	4	COMPRA	2026-06-15 12:10:00	9.000000	399.7600	0.0050	\N
1237	56	4	COMPRA	2026-06-15 12:13:00	9.000000	399.7600	0.0050	\N
1238	56	4	COMPRA	2026-06-15 12:16:00	9.000000	399.7600	0.0050	\N
1239	56	240	COMPRA	2026-06-15 12:19:00	1.000000	9061.5300	0.0050	0.1126
1240	64	270	VENTA	2026-06-15 13:03:00	1.000000	1340.7983	0.0050	\N
1241	34	5	VENTA	2026-06-15 13:33:00	1.000000	246.0200	0.0050	\N
1242	69	294	COMPRA	2026-06-16 09:41:00	1.000000	6776.2700	0.0050	0.1198
1243	46	2	COMPRA	2026-06-16 10:57:00	41.000000	79.2500	0.0050	\N
1244	46	6	COMPRA	2026-06-16 11:00:00	8.000000	373.2500	0.0050	\N
1245	46	13	COMPRA	2026-06-16 11:03:00	29.000000	287.7102	0.0050	0.1155
1246	46	194	COMPRA	2026-06-16 11:06:00	1.000000	12606.1300	0.0050	0.1191
1247	79	3	COMPRA	2026-06-17 10:51:00	7.000000	295.9500	0.0050	\N
1248	79	3	COMPRA	2026-06-17 10:54:00	7.000000	295.9500	0.0050	\N
1249	45	5	COMPRA	2026-06-18 10:53:00	30.000000	244.3900	0.0050	\N
1250	45	6	COMPRA	2026-06-18 10:56:00	20.000000	368.0300	0.0050	\N
1251	45	189	COMPRA	2026-06-18 10:59:00	1.000000	3122.5800	0.0050	0.0961
1252	53	8	COMPRA	2026-06-18 11:49:00	8.000000	228.3900	0.0050	\N
1253	13	3	COMPRA	2026-06-22 11:09:00	8.000000	297.0100	0.0050	\N
1254	13	8	COMPRA	2026-06-22 11:12:00	11.000000	231.2900	0.0050	\N
1255	13	8	COMPRA	2026-06-22 11:15:00	11.000000	231.2900	0.0050	\N
1256	13	11	COMPRA	2026-06-22 11:18:00	12.000000	289.0566	0.0050	0.1110
1257	13	69	COMPRA	2026-06-22 11:21:00	1.000000	5235.2200	0.0050	0.1038
1258	62	264	VENTA	2026-06-22 12:49:00	1.000000	2608.2930	0.0050	\N
1259	34	154	VENTA	2026-06-22 13:33:00	1.000000	2197.1037	0.0050	\N
1260	38	162	COMPRA	2026-06-23 10:04:00	1.000000	10857.3000	0.0050	0.0974
1261	73	2	COMPRA	2026-06-23 10:06:00	7.000000	80.9700	0.0050	\N
1262	73	8	COMPRA	2026-06-23 10:09:00	2.000000	239.0800	0.0050	\N
1263	73	313	COMPRA	2026-06-23 10:12:00	1.000000	4942.7800	0.0050	0.1215
1264	78	3	VENTA	2026-06-29 10:41:00	8.000000	281.7400	0.0050	\N
1265	12	2	COMPRA	2026-06-30 11:02:00	21.000000	79.4300	0.0050	\N
1266	12	1	COMPRA	2026-06-30 11:05:00	117.000000	14.2400	0.0050	\N
1267	12	65	COMPRA	2026-06-30 11:08:00	1.000000	2847.8800	0.0050	0.1127
1268	76	8	COMPRA	2026-07-01 10:27:00	1.000000	253.9800	0.0050	\N
1269	77	328	VENTA	2026-07-02 10:34:00	1.000000	20233.1583	0.0050	\N
1270	25	1	COMPRA	2026-07-02 12:33:00	205.000000	14.7000	0.0050	\N
1271	25	128	COMPRA	2026-07-02 12:36:00	1.000000	1775.0800	0.0050	0.0900
1272	1	14	VENTA	2026-07-06 09:42:00	1.000000	7968.4582	0.0050	\N
1273	11	62	COMPRA	2026-07-06 10:55:00	1.000000	1588.7000	0.0050	0.1038
1274	46	193	VENTA	2026-07-06 10:57:00	1.000000	8775.2431	0.0050	\N
1275	43	7	COMPRA	2026-07-07 10:39:00	3.000000	402.9000	0.0050	\N
1276	48	202	COMPRA	2026-07-07 11:14:00	1.000000	5396.0600	0.0050	0.1142
1277	55	1	COMPRA	2026-07-07 12:03:00	219.000000	14.6900	0.0050	\N
1278	55	1	COMPRA	2026-07-07 12:06:00	219.000000	14.6900	0.0050	\N
1279	55	235	COMPRA	2026-07-07 12:09:00	1.000000	4037.0200	0.0050	0.1028
1280	26	8	COMPRA	2026-07-07 12:40:00	5.000000	267.2400	0.0050	\N
1281	75	5	COMPRA	2026-07-08 10:23:00	7.000000	243.6200	0.0050	\N
1282	75	11	COMPRA	2026-07-08 10:26:00	16.000000	299.8051	0.0050	0.1013
1283	75	322	COMPRA	2026-07-08 10:29:00	1.000000	7613.6000	0.0050	0.1073
1284	21	6	COMPRA	2026-07-08 12:02:00	31.000000	361.9200	0.0050	\N
1285	21	116	COMPRA	2026-07-08 12:05:00	1.000000	12831.8700	0.0050	0.0964
1286	60	10	COMPRA	2026-07-10 12:38:00	1.000000	725.5100	0.0050	\N
1287	60	259	COMPRA	2026-07-10 12:41:00	1.000000	5244.8000	0.0050	0.1069
1288	66	4	VENTA	2026-07-10 13:17:00	9.000000	385.1000	0.0050	\N
1289	74	315	VENTA	2026-07-13 10:13:00	1.000000	40911.4822	0.0050	\N
1290	46	192	VENTA	2026-07-13 10:57:00	1.000000	16881.6898	0.0050	\N
1291	49	207	VENTA	2026-07-13 11:18:00	1.000000	3994.9582	0.0050	\N
1292	5	4	COMPRA	2026-07-14 10:10:00	2.000000	384.9300	0.0050	\N
1293	5	10	COMPRA	2026-07-14 10:13:00	1.000000	719.6900	0.0050	\N
1294	5	10	COMPRA	2026-07-14 10:16:00	1.000000	719.6900	0.0050	\N
1295	5	33	COMPRA	2026-07-14 10:19:00	1.000000	1972.6100	0.0050	0.1102
1296	42	1	COMPRA	2026-07-15 10:32:00	135.000000	15.9800	0.0050	\N
1297	42	11	COMPRA	2026-07-15 10:35:00	14.000000	307.4927	0.0050	0.0960
1298	42	182	COMPRA	2026-07-15 10:38:00	1.000000	6633.7800	0.0050	0.1219
1299	15	9	COMPRA	2026-07-15 11:23:00	9.000000	754.8100	0.0050	\N
1300	15	81	COMPRA	2026-07-15 11:26:00	1.000000	40372.0500	0.0050	0.0892
1301	16	2	COMPRA	2026-07-15 11:27:00	139.000000	81.5500	0.0050	\N
1302	16	2	COMPRA	2026-07-15 11:30:00	139.000000	81.5500	0.0050	\N
1303	16	2	COMPRA	2026-07-15 11:33:00	139.000000	81.5500	0.0050	\N
1304	16	89	COMPRA	2026-07-15 11:36:00	1.000000	35362.9400	0.0050	0.0885
1305	17	1	COMPRA	2026-07-15 11:37:00	757.000000	15.9800	0.0050	\N
1306	17	95	COMPRA	2026-07-15 11:40:00	1.000000	12630.0700	0.0050	0.1010
1307	51	213	VENTA	2026-07-16 11:32:00	1.000000	12221.4394	0.0050	\N
1308	3	7	COMPRA	2026-07-17 09:56:00	5.000000	380.8400	0.0050	\N
1309	3	9	COMPRA	2026-07-17 09:59:00	2.000000	743.2900	0.0050	\N
1310	3	3	COMPRA	2026-07-17 10:02:00	6.000000	333.7400	0.0050	\N
1311	3	11	COMPRA	2026-07-17 10:05:00	9.000000	310.4231	0.0050	0.0980
1312	3	23	COMPRA	2026-07-17 10:08:00	1.000000	4587.9700	0.0050	0.1163
1313	63	9	VENTA	2026-07-20 12:56:00	1.000000	742.0900	0.0050	\N
1314	65	1	COMPRA	2026-07-23 13:13:00	275.000000	16.3300	0.0050	\N
1315	65	1	COMPRA	2026-07-23 13:16:00	275.000000	16.3300	0.0050	\N
1316	14	71	VENTA	2026-07-27 11:13:00	1.000000	75163.6767	0.0050	\N
1317	50	210	VENTA	2026-07-27 11:25:00	1.000000	6447.6910	0.0050	\N
1318	70	298	VENTA	2026-07-28 09:45:00	1.000000	9124.9543	0.0050	\N
1319	77	8	VENTA	2026-07-30 10:34:00	42.000000	255.8200	0.0050	\N
1320	79	1	COMPRA	2026-07-31 10:48:00	300.000000	16.7700	0.0050	\N
1321	79	11	COMPRA	2026-07-31 10:51:00	7.000000	319.2420	0.0050	0.1130
1322	79	341	COMPRA	2026-07-31 10:54:00	1.000000	3418.1900	0.0050	0.1107
1323	49	9	COMPRA	2026-07-31 11:21:00	1.000000	747.0300	0.0050	\N
1324	49	4	COMPRA	2026-07-31 11:24:00	2.000000	464.7200	0.0050	\N
1325	49	209	COMPRA	2026-07-31 11:27:00	1.000000	3065.8400	0.0050	0.1013
1326	56	8	VENTA	2026-07-31 12:07:00	8.000000	256.3500	0.0050	\N
1327	71	305	COMPRA	2026-08-03 09:55:00	1.000000	19113.2700	0.0050	0.1225
1328	18	98	VENTA	2026-08-03 11:41:00	1.000000	2551.5876	0.0050	\N
1329	20	1	COMPRA	2026-08-03 11:58:00	162.000000	16.6000	0.0050	\N
1330	20	1	COMPRA	2026-08-03 12:01:00	162.000000	16.6000	0.0050	\N
1331	20	109	COMPRA	2026-08-03 12:04:00	1.000000	12930.5300	0.0050	0.1015
1332	1	7	COMPRA	2026-08-04 09:45:00	7.000000	327.3500	0.0050	\N
1333	53	8	COMPRA	2026-08-04 11:46:00	10.000000	254.9300	0.0050	\N
1334	53	223	COMPRA	2026-08-04 11:49:00	1.000000	2828.2200	0.0050	0.1223
1335	30	5	VENTA	2026-08-04 13:05:00	267.000000	277.4200	0.0050	\N
1336	47	6	COMPRA	2026-08-05 11:07:00	4.000000	362.4300	0.0050	\N
1337	47	197	COMPRA	2026-08-05 11:10:00	1.000000	11212.0200	0.0050	0.1144
1338	22	5	COMPRA	2026-08-06 12:12:00	4.000000	272.2600	0.0050	\N
1339	22	9	COMPRA	2026-08-06 12:15:00	1.000000	768.5600	0.0050	\N
1340	22	121	COMPRA	2026-08-06 12:18:00	1.000000	10282.6300	0.0050	0.1045
1341	80	4	COMPRA	2026-08-07 10:58:00	14.000000	499.9900	0.0050	\N
1342	80	9	COMPRA	2026-08-07 11:01:00	9.000000	773.2600	0.0050	\N
1343	80	3	COMPRA	2026-08-07 11:04:00	23.000000	313.3300	0.0050	\N
1344	80	12	COMPRA	2026-08-07 11:07:00	9.000000	316.7133	0.0050	0.0932
1345	80	345	COMPRA	2026-08-07 11:10:00	1.000000	4716.9500	0.0050	0.0894
1346	15	77	VENTA	2026-08-07 11:20:00	1.000000	49501.8104	0.0050	\N
1347	63	267	VENTA	2026-08-07 12:56:00	1.000000	35288.5319	0.0050	\N
1348	33	4	COMPRA	2026-08-07 13:29:00	2.000000	499.9900	0.0050	\N
1349	33	4	COMPRA	2026-08-07 13:32:00	2.000000	499.9900	0.0050	\N
1350	33	10	COMPRA	2026-08-07 13:35:00	1.000000	723.0300	0.0050	\N
1351	71	1	COMPRA	2026-08-10 09:55:00	254.000000	17.0500	0.0050	\N
1352	71	6	COMPRA	2026-08-10 09:58:00	12.000000	357.5200	0.0050	\N
1353	71	306	COMPRA	2026-08-10 10:01:00	1.000000	14185.1700	0.0050	0.1030
1354	50	6	COMPRA	2026-08-10 11:28:00	3.000000	357.5200	0.0050	\N
1355	50	6	COMPRA	2026-08-10 11:31:00	3.000000	357.5200	0.0050	\N
1356	23	6	VENTA	2026-08-13 12:16:00	2.000000	346.3600	0.0050	\N
1357	58	6	VENTA	2026-08-13 12:21:00	19.000000	346.3600	0.0050	\N
1358	2	10	COMPRA	2026-08-17 09:52:00	3.000000	729.8700	0.0050	\N
1359	11	4	VENTA	2026-08-17 10:52:00	1.000000	480.3500	0.0050	\N
1360	16	84	VENTA	2026-08-17 11:27:00	1.000000	15352.1178	0.0050	\N
1361	56	238	VENTA	2026-08-17 12:07:00	1.000000	14124.8483	0.0050	\N
1362	24	6	VENTA	2026-08-17 12:23:00	6.000000	344.0000	0.0050	\N
1363	32	5	VENTA	2026-08-17 13:19:00	2.000000	261.3100	0.0050	\N
1364	54	7	VENTA	2026-08-18 11:53:00	8.000000	336.8700	0.0050	\N
1365	12	2	COMPRA	2026-08-21 11:02:00	19.000000	101.4300	0.0050	\N
1366	12	2	COMPRA	2026-08-21 11:05:00	19.000000	101.4300	0.0050	\N
1367	12	10	COMPRA	2026-08-21 11:08:00	2.000000	713.4400	0.0050	\N
1368	12	13	COMPRA	2026-08-21 11:11:00	4.000000	326.4816	0.0050	0.1131
1369	12	66	COMPRA	2026-08-21 11:14:00	1.000000	2023.9500	0.0050	0.1222
1370	61	3	VENTA	2026-08-21 12:42:00	12.000000	309.3500	0.0050	\N
1371	52	219	VENTA	2026-08-24 11:39:00	1.000000	3259.3198	0.0050	\N
1372	59	6	COMPRA	2026-08-25 12:31:00	17.000000	346.9600	0.0050	\N
1373	59	8	COMPRA	2026-08-25 12:34:00	22.000000	273.1400	0.0050	\N
1374	59	12	COMPRA	2026-08-25 12:37:00	8.000000	327.1705	0.0050	0.1048
1375	59	254	COMPRA	2026-08-25 12:40:00	1.000000	3982.5100	0.0050	0.0924
1376	57	6	COMPRA	2026-08-26 12:17:00	26.000000	342.0000	0.0050	\N
1377	57	1	COMPRA	2026-08-26 12:20:00	544.000000	16.5200	0.0050	\N
1378	57	246	COMPRA	2026-08-26 12:23:00	1.000000	4471.0400	0.0050	0.1084
1379	69	6	COMPRA	2026-08-31 09:38:00	6.000000	339.3500	0.0050	\N
1380	69	10	COMPRA	2026-08-31 09:41:00	3.000000	716.7600	0.0050	\N
1381	69	10	COMPRA	2026-08-31 09:44:00	3.000000	716.7600	0.0050	\N
1382	69	12	COMPRA	2026-08-31 09:47:00	9.000000	312.2278	0.0050	0.0950
1383	69	295	COMPRA	2026-08-31 09:50:00	1.000000	4412.8200	0.0050	0.1267
1384	78	336	VENTA	2026-08-31 10:41:00	1.000000	15932.9328	0.0050	\N
1385	7	8	VENTA	2026-09-03 10:24:00	339.000000	278.4300	0.0050	\N
1386	3	3	VENTA	2026-09-08 09:56:00	1.000000	316.2200	0.0050	\N
1387	55	230	VENTA	2026-09-09 12:00:00	1.000000	10544.2202	0.0050	\N
1388	63	9	VENTA	2026-09-09 12:56:00	1.000000	762.4000	0.0050	\N
1389	61	261	VENTA	2026-09-10 12:42:00	1.000000	3715.7032	0.0050	\N
1390	43	5	COMPRA	2026-09-11 10:36:00	5.000000	256.7800	0.0050	\N
1391	74	316	VENTA	2026-09-14 10:13:00	1.000000	5411.9174	0.0050	\N
1392	75	8	COMPRA	2026-09-16 10:23:00	7.000000	267.2800	0.0050	\N
1393	75	12	COMPRA	2026-09-16 10:26:00	16.000000	322.5338	0.0050	0.1137
1394	75	323	COMPRA	2026-09-16 10:29:00	1.000000	8013.1900	0.0050	0.1044
1395	65	271	VENTA	2026-09-16 13:10:00	1.000000	24451.8266	0.0050	\N
1396	34	1	VENTA	2026-09-16 13:33:00	100.000000	17.4600	0.0050	\N
1397	37	158	VENTA	2026-09-17 09:54:00	1.000000	28430.8187	0.0050	\N
1398	79	1	VENTA	2026-09-17 10:48:00	131.000000	17.3800	0.0050	\N
1399	17	94	VENTA	2026-09-18 11:34:00	1.000000	48084.1886	0.0050	\N
1400	68	285	VENTA	2026-09-18 13:31:00	1.000000	2712.2518	0.0050	\N
1401	9	52	VENTA	2026-09-21 10:38:00	1.000000	6930.3997	0.0050	\N
1402	51	8	VENTA	2026-09-23 11:32:00	2.000000	269.1700	0.0050	\N
1403	8	8	COMPRA	2026-09-24 10:34:00	6.000000	270.6800	0.0050	\N
1404	8	46	COMPRA	2026-09-24 10:37:00	1.000000	5240.0600	0.0050	0.1103
1405	70	7	COMPRA	2026-09-25 09:45:00	8.000000	372.1100	0.0050	\N
1406	70	2	COMPRA	2026-09-25 09:48:00	34.000000	95.1500	0.0050	\N
1407	70	300	COMPRA	2026-09-25 09:51:00	1.000000	6829.3100	0.0050	0.1024
1408	13	3	COMPRA	2026-09-25 11:09:00	11.000000	341.0700	0.0050	\N
1409	13	8	COMPRA	2026-09-25 11:12:00	14.000000	271.2200	0.0050	\N
1410	13	70	COMPRA	2026-09-25 11:15:00	1.000000	12854.1900	0.0050	0.0949
1411	47	6	VENTA	2026-09-28 11:04:00	6.000000	342.7500	0.0050	\N
1412	14	72	VENTA	2026-09-28 11:13:00	1.000000	6783.8245	0.0050	\N
1413	18	96	VENTA	2026-09-28 11:41:00	1.000000	37899.0693	0.0050	\N
1414	19	6	VENTA	2026-09-29 11:48:00	2.000000	340.9200	0.0050	\N
1415	80	4	COMPRA	2026-09-30 10:55:00	5.000000	512.9000	0.0050	\N
1416	80	7	COMPRA	2026-09-30 10:58:00	7.000000	354.8100	0.0050	\N
1417	80	346	COMPRA	2026-09-30 11:01:00	1.000000	2973.0700	0.0050	0.1018
1418	15	1	COMPRA	2026-10-01 11:23:00	261.000000	16.2700	0.0050	\N
1419	15	9	COMPRA	2026-10-01 11:26:00	5.000000	763.9900	0.0050	\N
1420	15	82	COMPRA	2026-10-01 11:29:00	1.000000	23713.0900	0.0050	0.0943
1421	26	9	COMPRA	2026-10-02 12:37:00	1.000000	769.6400	0.0050	\N
1422	26	9	COMPRA	2026-10-02 12:40:00	1.000000	769.6400	0.0050	\N
1423	26	4	COMPRA	2026-10-02 12:43:00	2.000000	517.5300	0.0050	\N
1424	58	247	VENTA	2026-10-05 12:21:00	1.000000	27174.2624	0.0050	\N
1425	30	144	VENTA	2026-10-05 13:05:00	1.000000	17182.6963	0.0050	\N
1426	9	7	COMPRA	2026-10-06 10:41:00	3.000000	380.6800	0.0050	\N
1427	9	7	COMPRA	2026-10-06 10:44:00	3.000000	380.6800	0.0050	\N
1428	9	11	COMPRA	2026-10-06 10:47:00	10.000000	311.5478	0.0050	0.1146
1429	9	55	COMPRA	2026-10-06 10:50:00	1.000000	4893.9900	0.0050	0.1025
1430	58	248	VENTA	2026-10-06 12:21:00	1.000000	2019.3997	0.0050	\N
1431	1	3	COMPRA	2026-10-07 09:45:00	6.000000	336.6700	0.0050	\N
1432	1	17	COMPRA	2026-10-07 09:48:00	1.000000	1665.0300	0.0050	0.0916
1433	21	6	COMPRA	2026-10-07 12:05:00	7.000000	350.5000	0.0050	\N
1434	21	4	COMPRA	2026-10-07 12:08:00	4.000000	529.7600	0.0050	\N
1435	21	117	COMPRA	2026-10-07 12:11:00	1.000000	2831.5300	0.0050	0.0967
1436	47	196	VENTA	2026-10-09 11:04:00	1.000000	49363.3792	0.0050	\N
1437	17	8	VENTA	2026-10-09 11:34:00	7.000000	261.4400	0.0050	\N
1438	45	2	COMPRA	2026-10-12 10:53:00	160.000000	94.9600	0.0050	\N
1439	45	190	COMPRA	2026-10-12 10:56:00	1.000000	6289.9200	0.0050	0.1181
1440	72	309	VENTA	2026-10-13 09:59:00	1.000000	2169.4596	0.0050	\N
1441	76	8	COMPRA	2026-10-13 10:30:00	2.000000	248.6100	0.0050	\N
1442	76	8	COMPRA	2026-10-13 10:33:00	2.000000	248.6100	0.0050	\N
1443	78	3	COMPRA	2026-10-13 10:44:00	1.000000	341.2700	0.0050	\N
1444	78	2	COMPRA	2026-10-13 10:47:00	3.000000	95.4900	0.0050	\N
1445	78	5	COMPRA	2026-10-13 10:50:00	1.000000	258.5800	0.0050	\N
1446	78	11	COMPRA	2026-10-13 10:53:00	6.000000	313.0439	0.0050	0.1085
1447	78	338	COMPRA	2026-10-13 10:56:00	1.000000	3136.1900	0.0050	0.1261
1448	73	1	COMPRA	2026-10-15 10:09:00	96.000000	17.7000	0.0050	\N
1449	73	2	COMPRA	2026-10-15 10:12:00	17.000000	97.6500	0.0050	\N
1450	73	314	COMPRA	2026-10-15 10:15:00	1.000000	13741.8800	0.0050	0.1206
1451	62	1	COMPRA	2026-10-15 12:49:00	291.000000	17.7000	0.0050	\N
1452	62	266	COMPRA	2026-10-15 12:52:00	1.000000	6979.9000	0.0050	0.0997
1453	30	4	VENTA	2026-10-15 13:05:00	30.000000	539.4400	0.0050	\N
1454	46	2	COMPRA	2026-10-16 11:00:00	6.000000	97.9100	0.0050	\N
1455	46	195	COMPRA	2026-10-16 11:03:00	1.000000	4414.3800	0.0050	0.1125
1456	11	63	COMPRA	2026-10-19 10:55:00	1.000000	2633.9000	0.0050	0.1066
1457	23	3	VENTA	2026-10-19 12:16:00	19.000000	342.9400	0.0050	\N
1458	20	6	VENTA	2026-10-23 11:55:00	28.000000	320.2100	0.0050	\N
1459	77	8	COMPRA	2026-10-29 10:37:00	7.000000	275.2000	0.0050	\N
1460	77	7	COMPRA	2026-10-29 10:40:00	5.000000	403.3000	0.0050	\N
1461	77	332	COMPRA	2026-10-29 10:43:00	1.000000	13515.7600	0.0050	0.1278
1462	55	8	VENTA	2026-10-30 12:00:00	141.000000	273.2000	0.0050	\N
1463	60	10	VENTA	2026-11-02 12:35:00	6.000000	681.0900	0.0050	\N
1464	61	3	VENTA	2026-11-02 12:42:00	4.000000	338.3200	0.0050	\N
1465	58	6	VENTA	2026-11-05 12:21:00	4.000000	282.5700	0.0050	\N
1466	59	8	VENTA	2026-11-05 12:28:00	22.000000	272.3200	0.0050	\N
1467	52	220	VENTA	2026-11-06 11:39:00	1.000000	3128.6726	0.0050	\N
1468	63	9	COMPRA	2026-11-06 12:56:00	7.000000	735.2900	0.0050	\N
1469	63	9	COMPRA	2026-11-06 12:59:00	7.000000	735.2900	0.0050	\N
1470	63	268	COMPRA	2026-11-06 13:02:00	1.000000	23788.8100	0.0050	0.1058
1471	80	344	VENTA	2026-11-09 10:55:00	1.000000	20957.3508	0.0050	\N
1472	24	6	COMPRA	2026-11-10 12:23:00	9.000000	287.3800	0.0050	\N
1473	50	5	COMPRA	2026-11-12 11:25:00	12.000000	267.4400	0.0050	\N
1474	50	5	COMPRA	2026-11-12 11:28:00	12.000000	267.4400	0.0050	\N
1475	50	211	COMPRA	2026-11-12 11:31:00	1.000000	2246.6500	0.0050	0.0945
1476	54	224	VENTA	2026-11-12 11:53:00	1.000000	33819.7638	0.0050	\N
1477	71	3	COMPRA	2026-11-16 09:55:00	8.000000	352.7800	0.0050	\N
1478	71	1	COMPRA	2026-11-16 09:58:00	194.000000	14.9100	0.0050	\N
1479	71	307	COMPRA	2026-11-16 10:01:00	1.000000	9494.5200	0.0050	0.1041
1480	15	9	COMPRA	2026-11-16 23:45:29.804164	1.000000	739.9500	0.0050	\N
1482	15	9	COMPRA	2026-11-16 23:45:33.313477	181.000000	739.9500	0.0050	\N
\.


--
-- Data for Name: trm; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.trm (fecha_desde, fecha_hasta, valor_cop) FROM stdin;
2023-12-01	2023-12-01	4045.22
2023-12-02	2023-12-04	3983.15
2023-12-05	2023-12-05	3999.91
2023-12-06	2023-12-06	4023.21
2023-12-07	2023-12-07	3989.55
2023-12-08	2023-12-11	3998.51
2023-12-12	2023-12-12	3982.50
2023-12-13	2023-12-13	3990.88
2023-12-14	2023-12-14	3999.43
2023-12-15	2023-12-15	3955.88
2023-12-16	2023-12-18	3956.76
2023-12-19	2023-12-19	3932.59
2023-12-20	2023-12-20	3925.77
2023-12-21	2023-12-21	3948.54
2023-12-22	2023-12-22	3943.03
2023-12-23	2023-12-26	3915.43
2023-12-27	2023-12-27	3871.45
2023-12-28	2023-12-28	3844.81
2023-12-29	2024-01-02	3822.05
2024-01-03	2024-01-03	3895.53
2024-01-04	2024-01-04	3914.60
2024-01-05	2024-01-05	3927.64
2024-01-06	2024-01-09	3912.93
2024-01-10	2024-01-10	3934.13
2024-01-11	2024-01-11	3946.39
2024-01-12	2024-01-12	3929.79
2024-01-13	2024-01-16	3901.38
2024-01-17	2024-01-17	3940.85
2024-01-18	2024-01-18	3969.50
2024-01-19	2024-01-19	3939.89
2024-01-20	2024-01-22	3916.39
2024-01-23	2024-01-23	3904.49
2024-01-24	2024-01-24	3934.62
2024-01-25	2024-01-25	3929.95
2024-01-26	2024-01-26	3932.96
2024-01-27	2024-01-29	3925.26
2024-01-30	2024-01-30	3918.93
2024-01-31	2024-01-31	3925.60
2024-02-01	2024-02-01	3915.56
2024-02-02	2024-02-02	3889.05
2024-02-03	2024-02-05	3928.11
2024-02-06	2024-02-06	3975.74
2024-02-07	2024-02-07	3950.57
2024-02-08	2024-02-08	3962.23
2024-02-09	2024-02-09	3954.68
2024-02-10	2024-02-12	3926.08
2024-02-13	2024-02-13	3915.28
2024-02-14	2024-02-14	3929.00
2024-02-15	2024-02-15	3916.61
2024-02-16	2024-02-16	3909.89
2024-02-17	2024-02-20	3917.84
2024-02-21	2024-02-21	3912.97
2024-02-22	2024-02-22	3930.26
2024-02-23	2024-02-23	3935.64
2024-02-24	2024-02-26	3949.36
2024-02-27	2024-02-27	3963.08
2024-02-28	2024-02-28	3935.59
2024-02-29	2024-02-29	3933.56
2024-03-01	2024-03-01	3931.31
2024-03-02	2024-03-04	3934.82
2024-03-05	2024-03-05	3948.67
2024-03-06	2024-03-06	3945.32
2024-03-07	2024-03-07	3932.55
2024-03-08	2024-03-08	3920.79
2024-03-09	2024-03-11	3905.45
2024-03-12	2024-03-12	3907.81
2024-03-13	2024-03-13	3919.86
2024-03-14	2024-03-14	3908.02
2024-03-15	2024-03-15	3899.39
2024-03-16	2024-03-18	3884.64
2024-03-19	2024-03-19	3880.59
2024-03-20	2024-03-20	3894.37
2024-03-21	2024-03-21	3886.94
2024-03-22	2024-03-22	3888.02
2024-03-23	2024-03-26	3901.51
2024-03-27	2024-03-27	3865.97
2024-03-28	2024-04-01	3842.30
2024-04-02	2024-04-02	3863.05
2024-04-03	2024-04-03	3845.22
2024-04-04	2024-04-04	3812.13
2024-04-05	2024-04-05	3775.37
2024-04-06	2024-04-08	3764.23
2024-04-09	2024-04-09	3768.80
2024-04-10	2024-04-10	3763.43
2024-04-11	2024-04-11	3815.44
2024-04-12	2024-04-12	3820.10
2024-04-13	2024-04-15	3864.97
2024-04-16	2024-04-16	3889.58
2024-04-17	2024-04-17	3938.11
2024-04-18	2024-04-18	3901.94
2024-04-19	2024-04-19	3918.23
2024-04-20	2024-04-22	3937.13
2024-04-23	2024-04-23	3924.82
2024-04-24	2024-04-24	3910.01
2024-04-25	2024-04-25	3935.65
2024-04-26	2024-04-26	3964.59
2024-04-27	2024-04-29	3926.02
2024-04-30	2024-04-30	3873.44
2024-05-01	2024-05-02	3899.07
2024-05-03	2024-05-03	3898.62
2024-05-04	2024-05-06	3895.41
2024-05-07	2024-05-07	3894.23
2024-05-08	2024-05-08	3884.84
2024-05-09	2024-05-09	3902.63
2024-05-10	2024-05-10	3900.38
2024-05-11	2024-05-14	3888.21
2024-05-15	2024-05-15	3861.82
2024-05-16	2024-05-16	3825.42
2024-05-17	2024-05-17	3828.98
2024-05-18	2024-05-20	3832.26
2024-05-21	2024-05-21	3822.39
2024-05-22	2024-05-22	3814.94
2024-05-23	2024-05-23	3829.59
2024-05-24	2024-05-24	3837.58
2024-05-25	2024-05-28	3878.07
2024-05-29	2024-05-29	3853.09
2024-05-30	2024-05-30	3867.02
2024-05-31	2024-05-31	3874.32
2024-06-01	2024-06-04	3860.92
2024-06-05	2024-06-05	3909.65
2024-06-06	2024-06-06	3927.91
2024-06-07	2024-06-07	3938.53
2024-06-08	2024-06-11	3944.14
2024-06-12	2024-06-12	3960.83
2024-06-13	2024-06-13	4023.26
2024-06-14	2024-06-14	4107.52
2024-06-15	2024-06-17	4151.55
2024-06-18	2024-06-18	4144.63
2024-06-19	2024-06-20	4101.87
2024-06-21	2024-06-21	4175.96
2024-06-22	2024-06-24	4143.72
2024-06-25	2024-06-25	4104.38
2024-06-26	2024-06-26	4093.66
2024-06-27	2024-06-27	4133.61
2024-06-28	2024-06-28	4158.10
2024-06-29	2024-07-02	4148.04
2024-07-03	2024-07-03	4130.03
2024-07-04	2024-07-05	4096.09
2024-07-06	2024-07-08	4093.72
2024-07-09	2024-07-09	4052.99
2024-07-10	2024-07-10	4022.05
2024-07-11	2024-07-11	3979.91
2024-07-12	2024-07-12	3968.87
2024-07-13	2024-07-15	3944.97
2024-07-16	2024-07-16	3948.41
2024-07-17	2024-07-17	3977.63
2024-07-18	2024-07-18	4011.19
2024-07-19	2024-07-19	4036.73
2024-07-20	2024-07-22	4040.20
2024-07-23	2024-07-23	4006.01
2024-07-24	2024-07-24	4010.53
2024-07-25	2024-07-25	4047.66
2024-07-26	2024-07-26	4035.00
2024-07-27	2024-07-29	4014.56
2024-07-30	2024-07-30	4059.91
2024-07-31	2024-07-31	4089.05
2024-08-01	2024-08-01	4060.34
2024-08-02	2024-08-02	4057.14
2024-08-03	2024-08-05	4110.37
2024-08-06	2024-08-06	4184.30
2024-08-07	2024-08-08	4136.27
2024-08-09	2024-08-09	4100.79
2024-08-10	2024-08-12	4064.51
2024-08-13	2024-08-13	4063.26
2024-08-14	2024-08-14	4038.87
2024-08-15	2024-08-15	4021.10
2024-08-16	2024-08-16	4014.18
2024-08-17	2024-08-20	4021.63
2024-08-21	2024-08-21	4011.37
2024-08-22	2024-08-22	4013.98
2024-08-23	2024-08-23	4064.03
2024-08-24	2024-08-26	4030.52
2024-08-27	2024-08-27	4023.92
2024-08-28	2024-08-28	4045.64
2024-08-29	2024-08-29	4065.34
2024-08-30	2024-08-30	4132.11
2024-08-31	2024-09-03	4160.31
2024-09-04	2024-09-04	4185.80
2024-09-05	2024-09-05	4185.82
2024-09-06	2024-09-06	4172.50
2024-09-07	2024-09-09	4149.79
2024-09-10	2024-09-10	4220.68
2024-09-11	2024-09-11	4285.61
2024-09-12	2024-09-12	4278.28
2024-09-13	2024-09-13	4236.63
2024-09-14	2024-09-16	4172.13
2024-09-17	2024-09-17	4220.58
2024-09-18	2024-09-18	4239.33
2024-09-19	2024-09-19	4189.46
2024-09-20	2024-09-20	4175.10
2024-09-21	2024-09-23	4156.89
2024-09-24	2024-09-24	4155.31
2024-09-25	2024-09-25	4139.43
2024-09-26	2024-09-26	4192.74
2024-09-27	2024-09-27	4188.11
2024-09-28	2024-09-30	4164.21
2024-10-01	2024-10-01	4178.30
2024-10-02	2024-10-02	4224.21
2024-10-03	2024-10-03	4203.43
2024-10-04	2024-10-04	4197.73
2024-10-05	2024-10-07	4173.66
2024-10-08	2024-10-08	4194.97
2024-10-09	2024-10-09	4233.54
2024-10-10	2024-10-10	4233.17
2024-10-11	2024-10-11	4217.40
2024-10-12	2024-10-15	4192.56
2024-10-16	2024-10-16	4244.84
2024-10-17	2024-10-17	4266.20
2024-10-18	2024-10-18	4263.17
2024-10-19	2024-10-21	4252.15
2024-10-22	2024-10-22	4286.96
2024-10-23	2024-10-23	4262.30
2024-10-24	2024-10-24	4293.91
2024-10-25	2024-10-25	4311.83
2024-10-26	2024-10-28	4316.73
2024-10-29	2024-10-29	4342.90
2024-10-30	2024-10-30	4367.39
2024-10-31	2024-10-31	4413.46
2024-11-01	2024-11-01	4409.57
2024-11-02	2024-11-05	4414.00
2024-11-06	2024-11-06	4421.86
2024-11-07	2024-11-07	4430.40
2024-11-08	2024-11-08	4344.55
2024-11-09	2024-11-12	4346.70
2024-11-13	2024-11-13	4413.79
2024-11-14	2024-11-14	4478.21
2024-11-15	2024-11-15	4475.57
2024-11-16	2024-11-18	4454.68
2024-11-19	2024-11-19	4400.69
2024-11-20	2024-11-20	4401.34
2024-11-21	2024-11-21	4414.06
2024-11-22	2024-11-22	4387.09
2024-11-23	2024-11-25	4418.58
2024-11-26	2024-11-26	4381.99
2024-11-27	2024-11-27	4405.96
2024-11-28	2024-11-29	4406.16
2024-11-30	2024-12-02	4419.59
2024-12-03	2024-12-03	4462.97
2024-12-04	2024-12-04	4443.53
2024-12-05	2024-12-05	4424.56
2024-12-06	2024-12-06	4407.13
2024-12-07	2024-12-09	4396.52
2024-12-10	2024-12-10	4379.71
2024-12-11	2024-12-11	4377.34
2024-12-12	2024-12-12	4361.22
2024-12-13	2024-12-13	4335.20
2024-12-14	2024-12-16	4341.32
2024-12-17	2024-12-17	4324.19
2024-12-18	2024-12-18	4345.32
2024-12-19	2024-12-19	4359.11
2024-12-20	2024-12-20	4394.50
2024-12-21	2024-12-23	4374.62
2024-12-24	2024-12-24	4395.44
2024-12-25	2024-12-26	4380.94
2024-12-27	2024-12-27	4375.86
2024-12-28	2024-12-30	4401.98
2024-12-31	2025-01-02	4409.15
2025-01-03	2025-01-03	4410.50
2025-01-04	2025-01-07	4355.51
2025-01-08	2025-01-08	4342.31
2025-01-09	2025-01-09	4347.42
2025-01-10	2025-01-10	4321.19
2025-01-11	2025-01-13	4343.48
2025-01-14	2025-01-14	4331.23
2025-01-15	2025-01-15	4300.24
2025-01-16	2025-01-16	4294.11
2025-01-17	2025-01-17	4338.15
2025-01-18	2025-01-21	4344.27
2025-01-22	2025-01-22	4307.07
2025-01-23	2025-01-23	4278.01
2025-01-24	2025-01-24	4245.65
2025-01-25	2025-01-27	4188.46
2025-01-28	2025-01-28	4220.86
2025-01-29	2025-01-29	4219.00
2025-01-30	2025-01-30	4195.60
2025-01-31	2025-01-31	4170.01
2025-02-01	2025-02-03	4183.93
2025-02-04	2025-02-04	4198.66
2025-02-05	2025-02-05	4153.54
2025-02-06	2025-02-06	4180.06
2025-02-07	2025-02-07	4150.99
2025-02-08	2025-02-10	4113.70
2025-02-11	2025-02-11	4132.93
2025-02-12	2025-02-12	4153.80
2025-02-13	2025-02-13	4165.07
2025-02-14	2025-02-14	4161.46
2025-02-15	2025-02-18	4100.66
2025-02-19	2025-02-19	4111.38
2025-02-20	2025-02-20	4098.67
2025-02-21	2025-02-21	4077.56
2025-02-22	2025-02-24	4073.56
2025-02-25	2025-02-25	4112.63
2025-02-26	2025-02-26	4126.54
2025-02-27	2025-02-27	4123.10
2025-02-28	2025-02-28	4120.11
2025-03-01	2025-03-03	4134.04
2025-03-04	2025-03-04	4116.61
2025-03-05	2025-03-05	4144.18
2025-03-06	2025-03-06	4125.63
2025-03-07	2025-03-07	4104.56
2025-03-08	2025-03-10	4116.80
2025-03-11	2025-03-11	4161.96
2025-03-12	2025-03-12	4152.76
2025-03-13	2025-03-13	4110.08
2025-03-14	2025-03-14	4114.18
2025-03-15	2025-03-17	4102.67
2025-03-18	2025-03-18	4076.70
2025-03-19	2025-03-19	4126.03
2025-03-20	2025-03-20	4143.14
2025-03-21	2025-03-21	4187.72
2025-03-22	2025-03-25	4168.82
2025-03-26	2025-03-26	4107.14
2025-03-27	2025-03-27	4131.42
2025-03-28	2025-03-28	4152.59
2025-03-29	2025-03-31	4192.57
2025-04-01	2025-04-01	4191.79
2025-04-02	2025-04-02	4149.24
2025-04-03	2025-04-03	4146.07
2025-04-04	2025-04-04	4130.01
2025-04-05	2025-04-07	4274.03
2025-04-08	2025-04-08	4374.53
2025-04-09	2025-04-09	4387.98
2025-04-10	2025-04-10	4416.69
2025-04-11	2025-04-11	4351.55
2025-04-12	2025-04-14	4338.36
2025-04-15	2025-04-15	4286.17
2025-04-16	2025-04-16	4329.90
2025-04-17	2025-04-21	4306.54
2025-04-22	2025-04-22	4272.83
2025-04-23	2025-04-23	4283.22
2025-04-24	2025-04-24	4298.31
2025-04-25	2025-04-25	4274.57
2025-04-26	2025-04-28	4239.62
2025-04-29	2025-04-29	4227.32
2025-04-30	2025-04-30	4198.83
2025-05-01	2025-05-02	4222.25
2025-05-03	2025-05-05	4243.80
2025-05-06	2025-05-06	4283.62
2025-05-07	2025-05-07	4305.02
2025-05-08	2025-05-08	4306.79
2025-05-09	2025-05-09	4260.22
2025-05-10	2025-05-12	4239.23
2025-05-13	2025-05-13	4218.60
2025-05-14	2025-05-14	4204.63
2025-05-15	2025-05-15	4194.18
2025-05-16	2025-05-16	4196.66
2025-05-17	2025-05-19	4194.28
2025-05-20	2025-05-20	4168.03
2025-05-21	2025-05-21	4172.76
2025-05-22	2025-05-22	4169.47
2025-05-23	2025-05-23	4176.54
2025-05-24	2025-05-27	4165.41
2025-05-28	2025-05-28	4128.15
2025-05-29	2025-05-29	4126.44
2025-05-30	2025-05-30	4106.79
2025-05-31	2025-06-03	4148.72
2025-06-04	2025-06-04	4136.71
2025-06-05	2025-06-05	4107.85
2025-06-06	2025-06-06	4097.66
2025-06-07	2025-06-09	4138.72
2025-06-10	2025-06-10	4138.53
2025-06-11	2025-06-11	4190.90
2025-06-12	2025-06-12	4190.61
2025-06-13	2025-06-13	4169.13
2025-06-14	2025-06-16	4147.34
2025-06-17	2025-06-17	4096.44
2025-06-18	2025-06-18	4098.83
2025-06-19	2025-06-20	4076.32
2025-06-21	2025-06-24	4080.06
2025-06-25	2025-06-25	4081.15
2025-06-26	2025-06-26	4067.64
2025-06-27	2025-06-27	4042.87
2025-06-28	2025-07-01	4069.67
2025-07-02	2025-07-02	4047.71
2025-07-03	2025-07-03	4006.46
2025-07-04	2025-07-07	3974.37
2025-07-08	2025-07-08	4022.29
2025-07-09	2025-07-09	4054.13
2025-07-10	2025-07-10	4026.09
2025-07-11	2025-07-11	4013.50
2025-07-12	2025-07-14	4003.90
2025-07-15	2025-07-15	4011.79
2025-07-16	2025-07-16	4015.04
2025-07-17	2025-07-17	4031.86
2025-07-18	2025-07-18	4016.44
2025-07-19	2025-07-21	4000.61
2025-07-22	2025-07-22	4026.27
2025-07-23	2025-07-23	4061.36
2025-07-24	2025-07-24	4052.86
2025-07-25	2025-07-25	4063.31
2025-07-26	2025-07-28	4110.48
2025-07-29	2025-07-29	4170.59
2025-07-30	2025-07-30	4154.79
2025-07-31	2025-07-31	4179.69
2025-08-01	2025-08-01	4186.71
2025-08-02	2025-08-04	4129.42
2025-08-05	2025-08-05	4097.38
2025-08-06	2025-08-06	4093.12
2025-08-07	2025-08-08	4049.35
2025-08-09	2025-08-11	4034.74
2025-08-12	2025-08-12	4045.87
2025-08-13	2025-08-13	4017.12
2025-08-14	2025-08-14	4020.64
2025-08-15	2025-08-15	4048.74
2025-08-16	2025-08-19	4019.24
2025-08-20	2025-08-20	4036.42
2025-08-21	2025-08-21	4025.51
2025-08-22	2025-08-22	4034.18
2025-08-23	2025-08-25	4008.70
2025-08-26	2025-08-26	4017.44
2025-08-27	2025-08-27	4044.51
2025-08-28	2025-08-28	4051.97
2025-08-29	2025-08-29	4019.09
2025-08-30	2025-09-02	4018.41
2025-09-03	2025-09-03	4016.94
2025-09-04	2025-09-04	4002.86
2025-09-05	2025-09-05	3991.09
2025-09-06	2025-09-08	3960.94
2025-09-09	2025-09-09	3945.29
2025-09-10	2025-09-10	3919.13
2025-09-11	2025-09-11	3921.58
2025-09-12	2025-09-12	3903.18
2025-09-13	2025-09-15	3906.24
2025-09-16	2025-09-16	3897.57
2025-09-17	2025-09-17	3881.92
2025-09-18	2025-09-18	3880.01
2025-09-19	2025-09-19	3892.45
2025-09-20	2025-09-22	3891.19
2025-09-23	2025-09-23	3852.16
2025-09-24	2025-09-24	3844.47
2025-09-25	2025-09-25	3881.26
2025-09-26	2025-09-26	3898.87
2025-09-27	2025-09-29	3908.12
2025-09-30	2025-09-30	3901.29
2025-10-01	2025-10-01	3923.55
2025-10-02	2025-10-02	3890.00
2025-10-03	2025-10-03	3897.64
2025-10-04	2025-10-06	3874.18
2025-10-07	2025-10-07	3853.19
2025-10-08	2025-10-08	3867.54
2025-10-09	2025-10-09	3879.80
2025-10-10	2025-10-10	3894.99
2025-10-11	2025-10-14	3913.24
2025-10-15	2025-10-15	3933.31
2025-10-16	2025-10-16	3902.16
2025-10-17	2025-10-17	3877.07
2025-10-18	2025-10-20	3808.12
2025-10-21	2025-10-21	3877.26
2025-10-22	2025-10-22	3876.60
2025-10-23	2025-10-23	3900.82
2025-10-24	2025-10-24	3888.76
2025-10-25	2025-10-27	3858.63
2025-10-28	2025-10-28	3844.20
2025-10-29	2025-10-29	3874.84
2025-10-30	2025-10-30	3885.29
2025-10-31	2025-10-31	3870.42
2025-11-01	2025-11-04	3860.12
2025-11-05	2025-11-05	3872.47
2025-11-06	2025-11-06	3839.47
2025-11-07	2025-11-07	3807.06
2025-11-08	2025-11-10	3779.20
2025-11-11	2025-11-12	3760.93
2025-11-13	2025-11-13	3719.71
2025-11-14	2025-11-14	3719.60
2025-11-15	2025-11-18	3764.77
2025-11-19	2025-11-19	3737.55
2025-11-20	2025-11-20	3716.73
2025-11-21	2025-11-21	3741.27
2025-11-22	2025-11-24	3808.77
2025-11-25	2025-11-25	3804.09
2025-11-26	2025-11-26	3806.16
2025-11-27	2025-11-28	3773.60
2025-11-29	2025-12-01	3744.43
2025-12-02	2025-12-02	3784.43
2025-12-03	2025-12-03	3817.66
2025-12-04	2025-12-04	3780.80
2025-12-05	2025-12-05	3757.92
2025-12-06	2025-12-09	3830.02
2025-12-10	2025-12-10	3861.34
2025-12-11	2025-12-11	3854.28
2025-12-12	2025-12-12	3810.99
2025-12-13	2025-12-15	3788.53
2025-12-16	2025-12-16	3817.59
2025-12-17	2025-12-17	3847.10
2025-12-18	2025-12-18	3866.77
2025-12-19	2025-12-19	3874.71
2025-12-20	2025-12-22	3817.93
2025-12-23	2025-12-23	3792.59
2025-12-24	2025-12-24	3759.48
2025-12-25	2025-12-26	3706.94
2025-12-27	2025-12-29	3716.05
2025-12-30	2025-12-30	3706.97
2025-12-31	2026-01-02	3757.08
2026-01-03	2026-01-05	3790.77
2026-01-06	2026-01-06	3770.03
2026-01-07	2026-01-07	3730.26
2026-01-08	2026-01-08	3748.83
2026-01-09	2026-01-09	3734.67
2026-01-10	2026-01-13	3717.09
2026-01-14	2026-01-14	3663.24
2026-01-15	2026-01-15	3655.16
2026-01-16	2026-01-16	3687.32
2026-01-17	2026-01-20	3700.05
2026-01-21	2026-01-21	3682.97
2026-01-22	2026-01-22	3669.15
2026-01-23	2026-01-23	3630.33
2026-01-24	2026-01-26	3637.88
2026-01-27	2026-01-27	3676.02
2026-01-28	2026-01-28	3678.59
2026-01-29	2026-01-29	3665.97
2026-01-30	2026-01-30	3661.29
2026-01-31	2026-02-02	3670.47
2026-02-03	2026-02-03	3628.16
2026-02-04	2026-02-04	3622.00
2026-02-05	2026-02-05	3644.93
2026-02-06	2026-02-06	3691.75
2026-02-07	2026-02-09	3670.20
2026-02-10	2026-02-10	3651.90
2026-02-11	2026-02-11	3659.71
2026-02-12	2026-02-12	3671.01
2026-02-13	2026-02-13	3665.78
2026-02-14	2026-02-17	3652.89
2026-02-18	2026-02-18	3664.26
2026-02-19	2026-02-19	3669.21
2026-02-20	2026-02-20	3695.72
2026-02-21	2026-02-23	3691.34
2026-02-24	2026-02-24	3697.36
2026-02-25	2026-02-25	3703.28
2026-02-26	2026-02-26	3703.69
2026-02-27	2026-02-27	3745.78
2026-02-28	2026-03-02	3766.30
2026-03-03	2026-03-03	3768.73
2026-03-04	2026-03-04	3797.64
2026-03-05	2026-03-05	3751.41
2026-03-06	2026-03-06	3767.94
2026-03-07	2026-03-09	3795.55
2026-03-10	2026-03-10	3744.84
2026-03-11	2026-03-11	3710.50
2026-03-12	2026-03-12	3687.87
2026-03-13	2026-03-13	3700.46
2026-03-14	2026-03-16	3685.53
2026-03-17	2026-03-17	3691.90
2026-03-18	2026-03-18	3689.97
2026-03-19	2026-03-19	3704.17
2026-03-20	2026-03-20	3692.48
2026-03-21	2026-03-24	3704.87
2026-03-25	2026-03-25	3700.67
2026-03-26	2026-03-26	3688.46
2026-03-27	2026-03-27	3675.29
2026-03-28	2026-03-30	3668.89
2026-03-31	2026-03-31	3669.96
2026-04-01	2026-04-01	3660.10
2026-04-02	2026-04-06	3675.81
2026-04-07	2026-04-07	3664.41
2026-04-08	2026-04-08	3678.19
2026-04-09	2026-04-09	3640.63
2026-04-10	2026-04-10	3642.93
2026-04-11	2026-04-13	3631.49
2026-04-14	2026-04-14	3608.10
2026-04-15	2026-04-15	3578.82
2026-04-16	2026-04-16	3603.19
2026-04-17	2026-04-17	3615.10
2026-04-18	2026-04-20	3593.14
2026-04-21	2026-04-21	3573.30
2026-04-22	2026-04-22	3576.05
2026-04-23	2026-04-23	3568.88
2026-04-24	2026-04-24	3560.62
2026-04-25	2026-04-27	3551.17
2026-04-28	2026-04-28	3593.17
2026-04-29	2026-04-29	3633.76
2026-04-30	2026-04-30	3621.86
2026-05-01	2026-05-04	3637.51
2026-05-05	2026-05-05	3707.58
2026-05-06	2026-05-06	3723.33
2026-05-07	2026-05-07	3706.44
2026-05-08	2026-05-08	3729.27
2026-05-09	2026-05-11	3747.10
2026-05-12	2026-05-12	3759.00
2026-05-13	2026-05-13	3775.07
2026-05-14	2026-05-14	3794.91
2026-05-15	2026-05-15	3784.70
2026-05-16	2026-05-19	3796.78
2026-05-20	2026-05-20	3796.87
2026-05-21	2026-05-21	3730.49
2026-05-22	2026-05-22	3701.37
2026-05-23	2026-05-26	3667.06
2026-05-27	2026-05-27	3644.47
2026-05-28	2026-05-28	3631.57
2026-05-29	2026-05-29	3646.58
2026-05-30	2026-06-01	3678.15
2026-06-02	2026-06-02	3560.24
2026-06-03	2026-06-03	3562.00
2026-06-04	2026-06-04	3572.85
2026-06-05	2026-06-05	3565.32
2026-06-06	2026-06-09	3588.09
2026-06-10	2026-06-10	3581.46
2026-06-11	2026-06-11	3567.11
2026-06-12	2026-06-12	3513.54
2026-06-13	2026-06-16	3475.72
2026-06-17	2026-06-17	3427.07
2026-06-18	2026-06-18	3439.91
2026-06-19	2026-06-22	3459.53
2026-06-23	2026-06-23	3406.14
2026-06-24	2026-06-24	3425.95
2026-06-25	2026-06-25	3428.32
2026-06-26	2026-06-26	3433.71
2026-06-27	2026-06-30	3443.59
2026-07-01	2026-07-01	3440.83
2026-07-02	2026-07-02	3403.35
2026-07-03	2026-07-03	3357.82
2026-07-04	2026-07-06	3334.93
2026-07-07	2026-07-07	3350.68
2026-07-08	2026-07-08	3335.50
2026-07-09	2026-07-09	3339.65
2026-07-10	2026-07-10	3305.38
2026-07-11	2026-07-14	3248.87
2026-07-15	2026-07-15	3252.11
2026-07-16	2026-07-16	3233.91
2026-07-17	2026-07-17	3221.41
2026-07-18	2026-07-21	3262.58
2026-07-22	2026-07-22	3238.19
2026-07-23	2026-07-23	3206.86
2026-07-24	2026-07-24	3219.31
2026-07-25	2026-07-27	3210.56
2026-07-28	2026-07-28	3205.80
2026-07-29	2026-07-29	3205.87
2026-07-30	2026-07-30	3206.18
2026-07-31	2026-07-31	3132.42
2026-08-01	2026-08-03	3144.14
2026-08-04	2026-08-04	3230.44
2026-08-05	2026-08-05	3204.51
2026-08-06	2026-08-06	3179.40
2026-08-07	2026-08-10	3157.43
2026-08-11	2026-08-11	3125.47
2026-08-12	2026-08-12	3121.07
2026-08-13	2026-08-13	3123.28
2026-08-14	2026-08-14	3127.51
2026-08-15	2026-08-18	3128.65
2026-08-19	2026-08-19	3098.79
2026-08-20	2026-08-20	3053.48
2026-08-21	2026-08-21	3062.96
2026-08-22	2026-08-24	3048.12
2026-08-25	2026-08-25	3056.51
2026-08-26	2026-08-26	3081.67
2026-08-27	2026-08-27	3118.24
2026-08-28	2026-08-28	3144.28
2026-08-29	2026-08-31	3202.79
2026-09-01	2026-09-01	3213.97
2026-09-02	2026-09-02	3184.00
2026-09-03	2026-09-03	3140.55
2026-09-04	2026-09-04	3141.36
2026-09-05	2026-09-08	3126.08
2026-09-09	2026-09-09	3116.47
2026-09-10	2026-09-10	3099.48
2026-09-11	2026-09-11	3101.00
2026-09-12	2026-09-14	3072.27
2026-09-15	2026-09-15	3109.30
2026-09-16	2026-09-16	3100.45
2026-09-17	2026-09-17	3128.46
2026-09-18	2026-09-18	3151.73
2026-09-19	2026-09-21	3192.92
2026-09-22	2026-09-22	3192.53
2026-09-23	2026-09-23	3208.66
2026-09-24	2026-09-24	3264.39
2026-09-25	2026-09-25	3329.61
2026-09-26	2026-09-28	3306.86
2026-09-29	2026-09-29	3349.63
2026-09-30	2026-09-30	3341.23
2026-10-01	2026-10-01	3312.84
2026-10-02	2026-10-02	3307.73
2026-10-03	2026-10-05	3273.49
2026-10-06	2026-10-06	3209.78
2026-10-07	2026-10-07	3216.01
2026-10-08	2026-10-08	3238.88
2026-10-09	2026-10-09	3218.75
2026-10-10	2026-10-13	3194.44
2026-10-14	2026-10-14	3181.74
2026-10-15	2026-10-15	3197.65
2026-10-16	2026-10-16	3170.46
2026-10-17	2026-10-19	3174.67
2026-10-20	2026-10-20	3156.32
2026-10-21	2026-10-21	3163.76
2026-10-22	2026-10-22	3191.47
2026-10-23	2026-10-23	3185.01
2026-10-24	2026-10-26	3158.43
2026-10-27	2026-10-27	3157.94
2026-10-28	2026-10-28	3148.02
2026-10-29	2026-10-29	3162.35
2026-10-30	2026-10-30	3166.91
2026-10-31	2026-11-03	3182.99
2026-11-04	2026-11-04	3235.59
2026-11-05	2026-11-05	3221.19
2026-11-06	2026-11-06	3228.26
2026-11-07	2026-11-09	3237.83
2026-11-10	2026-11-10	3269.88
2026-11-11	2026-11-12	3297.07
2026-11-13	2026-11-13	3301.91
2026-11-14	2026-11-17	3316.70
\.


--
-- Name: activo_id_activo_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.activo_id_activo_seq', 346, true);


--
-- Name: asesor_id_asesor_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.asesor_id_asesor_seq', 6, true);


--
-- Name: cliente_id_cliente_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.cliente_id_cliente_seq', 60, true);


--
-- Name: cuenta_id_cuenta_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.cuenta_id_cuenta_seq', 80, true);


--
-- Name: movimiento_efectivo_id_movimiento_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.movimiento_efectivo_id_movimiento_seq', 410, true);


--
-- Name: rendimiento_id_rendimiento_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.rendimiento_id_rendimiento_seq', 1367, true);


--
-- Name: transaccion_id_transaccion_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.transaccion_id_transaccion_seq', 1483, true);


--
-- Name: accion_fondo accion_fondo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accion_fondo
    ADD CONSTRAINT accion_fondo_pkey PRIMARY KEY (id_activo);


--
-- Name: accion_fondo accion_fondo_ticker_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accion_fondo
    ADD CONSTRAINT accion_fondo_ticker_key UNIQUE (ticker);


--
-- Name: activo activo_nombre_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activo
    ADD CONSTRAINT activo_nombre_key UNIQUE (nombre);


--
-- Name: activo activo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activo
    ADD CONSTRAINT activo_pkey PRIMARY KEY (id_activo);


--
-- Name: asesor asesor_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asesor
    ADD CONSTRAINT asesor_email_key UNIQUE (email);


--
-- Name: asesor asesor_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asesor
    ADD CONSTRAINT asesor_pkey PRIMARY KEY (id_asesor);


--
-- Name: cdt cdt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cdt
    ADD CONSTRAINT cdt_pkey PRIMARY KEY (id_activo);


--
-- Name: cliente cliente_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente
    ADD CONSTRAINT cliente_email_key UNIQUE (email);


--
-- Name: cliente cliente_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente
    ADD CONSTRAINT cliente_pkey PRIMARY KEY (id_cliente);


--
-- Name: cuenta cuenta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuenta
    ADD CONSTRAINT cuenta_pkey PRIMARY KEY (id_cuenta);


--
-- Name: trm ex_trm_sin_solape; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trm
    ADD CONSTRAINT ex_trm_sin_solape EXCLUDE USING gist (daterange(fecha_desde, fecha_hasta, '[]'::text) WITH &&);


--
-- Name: movimiento_efectivo movimiento_efectivo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimiento_efectivo
    ADD CONSTRAINT movimiento_efectivo_pkey PRIMARY KEY (id_movimiento);


--
-- Name: perfil_riesgo perfil_riesgo_nombre_perfil_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil_riesgo
    ADD CONSTRAINT perfil_riesgo_nombre_perfil_key UNIQUE (nombre_perfil);


--
-- Name: perfil_riesgo perfil_riesgo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfil_riesgo
    ADD CONSTRAINT perfil_riesgo_pkey PRIMARY KEY (id_perfil);


--
-- Name: precio_historico precio_historico_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.precio_historico
    ADD CONSTRAINT precio_historico_pkey PRIMARY KEY (id_activo, fecha);


--
-- Name: rendimiento rendimiento_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rendimiento
    ADD CONSTRAINT rendimiento_pkey PRIMARY KEY (id_rendimiento);


--
-- Name: tes tes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tes
    ADD CONSTRAINT tes_pkey PRIMARY KEY (id_activo);


--
-- Name: tes tes_serie_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tes
    ADD CONSTRAINT tes_serie_key UNIQUE (serie);


--
-- Name: tipo_activo tipo_activo_nombre_tipo_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tipo_activo
    ADD CONSTRAINT tipo_activo_nombre_tipo_key UNIQUE (nombre_tipo);


--
-- Name: tipo_activo tipo_activo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tipo_activo
    ADD CONSTRAINT tipo_activo_pkey PRIMARY KEY (id_tipo_activo);


--
-- Name: transaccion transaccion_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transaccion
    ADD CONSTRAINT transaccion_pkey PRIMARY KEY (id_transaccion);


--
-- Name: trm trm_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trm
    ADD CONSTRAINT trm_pkey PRIMARY KEY (fecha_desde);


--
-- Name: activo uq_activo_tipo; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activo
    ADD CONSTRAINT uq_activo_tipo UNIQUE (id_activo, id_tipo_activo);


--
-- Name: asesor uq_asesor_documento; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asesor
    ADD CONSTRAINT uq_asesor_documento UNIQUE (tipo_documento, numero_documento);


--
-- Name: cliente uq_cliente_documento; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente
    ADD CONSTRAINT uq_cliente_documento UNIQUE (tipo_documento, numero_documento);


--
-- Name: cuenta uq_cuenta_nombre; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuenta
    ADD CONSTRAINT uq_cuenta_nombre UNIQUE (id_cliente, nombre_cuenta);


--
-- Name: ix_transaccion_cuenta_fecha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_transaccion_cuenta_fecha ON public.transaccion USING btree (id_cuenta, fecha_hora);


--
-- Name: activo trg_activo_subtipo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_activo_subtipo AFTER INSERT ON public.activo DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.trg_fn_activo_subtipo();


--
-- Name: cuenta trg_cuenta_proteger_saldo; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_cuenta_proteger_saldo BEFORE INSERT OR UPDATE OF saldo_efectivo ON public.cuenta FOR EACH ROW EXECUTE FUNCTION public.trg_fn_cuenta_proteger_saldo();


--
-- Name: movimiento_efectivo trg_movimiento_aplicar; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_movimiento_aplicar BEFORE INSERT ON public.movimiento_efectivo FOR EACH ROW EXECUTE FUNCTION public.trg_fn_movimiento_aplicar();


--
-- Name: movimiento_efectivo trg_movimiento_inmutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_movimiento_inmutable BEFORE DELETE OR UPDATE ON public.movimiento_efectivo FOR EACH ROW EXECUTE FUNCTION public.trg_fn_registro_inmutable();


--
-- Name: rendimiento trg_rendimiento_aplicar; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rendimiento_aplicar BEFORE INSERT ON public.rendimiento FOR EACH ROW EXECUTE FUNCTION public.trg_fn_rendimiento_aplicar();


--
-- Name: rendimiento trg_rendimiento_inmutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_rendimiento_inmutable BEFORE DELETE OR UPDATE ON public.rendimiento FOR EACH ROW EXECUTE FUNCTION public.trg_fn_registro_inmutable();


--
-- Name: transaccion trg_transaccion_inmutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_transaccion_inmutable BEFORE DELETE OR UPDATE ON public.transaccion FOR EACH ROW EXECUTE FUNCTION public.trg_fn_registro_inmutable();


--
-- Name: transaccion trg_transaccion_validar; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_transaccion_validar BEFORE INSERT ON public.transaccion FOR EACH ROW EXECUTE FUNCTION public.trg_fn_transaccion_validar();


--
-- Name: activo activo_id_tipo_activo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activo
    ADD CONSTRAINT activo_id_tipo_activo_fkey FOREIGN KEY (id_tipo_activo) REFERENCES public.tipo_activo(id_tipo_activo);


--
-- Name: cliente cliente_id_asesor_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente
    ADD CONSTRAINT cliente_id_asesor_fkey FOREIGN KEY (id_asesor) REFERENCES public.asesor(id_asesor);


--
-- Name: cliente cliente_id_perfil_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cliente
    ADD CONSTRAINT cliente_id_perfil_fkey FOREIGN KEY (id_perfil) REFERENCES public.perfil_riesgo(id_perfil);


--
-- Name: cuenta cuenta_id_cliente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cuenta
    ADD CONSTRAINT cuenta_id_cliente_fkey FOREIGN KEY (id_cliente) REFERENCES public.cliente(id_cliente);


--
-- Name: accion_fondo fk_accion_fondo_activo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accion_fondo
    ADD CONSTRAINT fk_accion_fondo_activo FOREIGN KEY (id_activo, id_tipo_activo) REFERENCES public.activo(id_activo, id_tipo_activo);


--
-- Name: cdt fk_cdt_activo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cdt
    ADD CONSTRAINT fk_cdt_activo FOREIGN KEY (id_activo, id_tipo_activo) REFERENCES public.activo(id_activo, id_tipo_activo);


--
-- Name: tes fk_tes_activo; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tes
    ADD CONSTRAINT fk_tes_activo FOREIGN KEY (id_activo, id_tipo_activo) REFERENCES public.activo(id_activo, id_tipo_activo);


--
-- Name: movimiento_efectivo movimiento_efectivo_id_cuenta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movimiento_efectivo
    ADD CONSTRAINT movimiento_efectivo_id_cuenta_fkey FOREIGN KEY (id_cuenta) REFERENCES public.cuenta(id_cuenta);


--
-- Name: precio_historico precio_historico_id_activo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.precio_historico
    ADD CONSTRAINT precio_historico_id_activo_fkey FOREIGN KEY (id_activo) REFERENCES public.accion_fondo(id_activo);


--
-- Name: rendimiento rendimiento_id_activo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rendimiento
    ADD CONSTRAINT rendimiento_id_activo_fkey FOREIGN KEY (id_activo) REFERENCES public.activo(id_activo);


--
-- Name: rendimiento rendimiento_id_cuenta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rendimiento
    ADD CONSTRAINT rendimiento_id_cuenta_fkey FOREIGN KEY (id_cuenta) REFERENCES public.cuenta(id_cuenta);


--
-- Name: transaccion transaccion_id_activo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transaccion
    ADD CONSTRAINT transaccion_id_activo_fkey FOREIGN KEY (id_activo) REFERENCES public.activo(id_activo);


--
-- Name: transaccion transaccion_id_cuenta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transaccion
    ADD CONSTRAINT transaccion_id_cuenta_fkey FOREIGN KEY (id_cuenta) REFERENCES public.cuenta(id_cuenta);


--
-- PostgreSQL database dump complete
--

\unrestrict BFkbLWVcO243u3cEfHwS2kt05vhnKq3Lx5RcSLqbRxKGZABiLg4GMEpdYbIgcFa

