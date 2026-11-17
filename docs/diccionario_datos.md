# Diccionario de datos

Sistema de Gestión de Portafolios de Inversión · Base `portafolios` (PostgreSQL)

Convenciones: **PK** clave primaria · **FK** clave foránea · **UQ** clave candidata (UNIQUE) · *Nulo* indica si admite NULL · los valores monetarios están en USD salvo `trm.valor_cop`.

## perfil_riesgo

Catalogo de perfiles de riesgo

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_perfil | SMALLINT | No | PK |  | Identificador del perfil (1 conservador, 2 moderado, 3 agresivo) |
| nombre_perfil | VARCHAR(20) | No | UQ |  | Nombre del perfil |
| limite_max_renta_var | NUMERIC(5,2) | No |  |  | % maximo del portafolio en acciones y fondos (Regla 2) |

Restricciones adicionales:

- `CHECK (((limite_max_renta_var >= (0)) AND (limite_max_renta_var <= (100))))`
- `CHECK (((nombre_perfil) IN ('CONSERVADOR', 'MODERADO', 'AGRESIVO')))`

## asesor

Asesores financieros de la firma

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_asesor | INTEGER | No | PK | IDENTITY | Identificador del asesor |
| tipo_documento | VARCHAR(3) | No | UQ(tipo_documento, numero_documento) | 'CC' | CC, CE o PA |
| numero_documento | VARCHAR(20) | No | UQ(tipo_documento, numero_documento) |  | Numero de documento |
| nombres | VARCHAR(100) | No |  |  | Nombres |
| apellidos | VARCHAR(100) | No |  |  | Apellidos |
| email | VARCHAR(150) | No | UQ |  | Correo corporativo |
| telefono | VARCHAR(20) | Sí |  |  | Telefono de contacto |
| fecha_ingreso | DATE | No |  | CURRENT_DATE | Fecha de ingreso a la firma |

Restricciones adicionales:

- `CHECK (((email) LIKE '%_@_%._%'))`
- `CHECK (((tipo_documento) IN ('CC', 'CE', 'PA')))`

## cliente

Clientes personas naturales

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_cliente | INTEGER | No | PK | IDENTITY | Identificador del cliente |
| id_perfil | SMALLINT | No | FK → perfil_riesgo |  | Perfil de riesgo asignado (Regla 1) |
| id_asesor | INTEGER | No | FK → asesor |  | Asesor responsable (Regla 3) |
| tipo_documento | VARCHAR(3) | No | UQ(tipo_documento, numero_documento) | 'CC' | CC, CE o PA |
| numero_documento | VARCHAR(20) | No | UQ(tipo_documento, numero_documento) |  | Numero de documento |
| nombres | VARCHAR(100) | No |  |  | Nombres |
| apellidos | VARCHAR(100) | No |  |  | Apellidos |
| email | VARCHAR(150) | No | UQ |  | Correo personal |
| telefono | VARCHAR(20) | Sí |  |  | Telefono |
| fecha_nacimiento | DATE | No |  |  | Fecha de nacimiento (mayor de edad al vincularse) |
| fecha_vinculacion | DATE | No |  | CURRENT_DATE | Fecha de vinculacion a la firma |

Restricciones adicionales:

- `CHECK ((fecha_vinculacion >= (fecha_nacimiento + '18 years'::interval)))`
- `CHECK (((email) LIKE '%_@_%._%'))`
- `CHECK (((tipo_documento) IN ('CC', 'CE', 'PA')))`

## cuenta

Cuenta o portafolio de un cliente

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_cuenta | INTEGER | No | PK | IDENTITY | Identificador de la cuenta |
| id_cliente | INTEGER | No | FK → cliente, UQ(id_cliente, nombre_cuenta) |  | Cliente propietario (Regla 10) |
| nombre_cuenta | VARCHAR(100) | No | UQ(id_cliente, nombre_cuenta) |  | Nombre de la cuenta, unico por cliente |
| fecha_apertura | DATE | No |  | CURRENT_DATE | Fecha de apertura |
| saldo_efectivo | NUMERIC(15,2) | No |  | 0 | Efectivo disponible en USD; redundancia controlada mantenida por triggers |
| estado | VARCHAR(10) | No |  | 'ACTIVA' | ACTIVA, INACTIVA o CERRADA |

Restricciones adicionales:

- `CHECK (((estado) IN ('ACTIVA', 'INACTIVA', 'CERRADA')))`
- `CHECK ((saldo_efectivo >= (0)))`

## movimiento_efectivo

Depositos y retiros de efectivo

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_movimiento | INTEGER | No | PK | IDENTITY | Identificador del movimiento |
| id_cuenta | INTEGER | No | FK → cuenta |  | Cuenta afectada |
| tipo_movimiento | VARCHAR(10) | No |  |  | DEPOSITO o RETIRO |
| fecha_hora | TIMESTAMP | No |  | CURRENT_TIMESTAMP | Momento del movimiento |
| monto | NUMERIC(15,2) | No |  |  | Valor en USD |

Restricciones adicionales:

- `CHECK ((monto > (0)))`
- `CHECK (((tipo_movimiento) IN ('DEPOSITO', 'RETIRO')))`

## tipo_activo

Catalogo y discriminador de la especializacion de activos

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_tipo_activo | SMALLINT | No | PK |  | 1 ACCION, 2 FONDO, 3 CDT, 4 TES |
| nombre_tipo | VARCHAR(20) | No | UQ |  | Nombre del tipo |
| clase_activo | VARCHAR(15) | No |  |  | RENTA_VARIABLE o RENTA_FIJA |

Restricciones adicionales:

- `CHECK (((clase_activo) IN ('RENTA_VARIABLE', 'RENTA_FIJA')))`
- `CHECK (((id_tipo_activo >= 1) AND (id_tipo_activo <= 4)))`
- `CHECK (((nombre_tipo) IN ('ACCION', 'FONDO', 'CDT', 'TES')))`

## activo

Supertipo de todos los instrumentos de inversion

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_activo | INTEGER | No | PK, UQ(id_activo, id_tipo_activo) | IDENTITY | Identificador del activo |
| id_tipo_activo | SMALLINT | No | FK → tipo_activo, UQ(id_activo, id_tipo_activo) |  | Tipo (determina la tabla de subtipo, Regla 12) |
| nombre | VARCHAR(150) | No | UQ |  | Nombre del instrumento |
| fecha_registro | DATE | No |  | CURRENT_DATE | Fecha de alta en el sistema |

## accion_fondo

Subtipo: acciones y fondos indexados (USD)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_activo | INTEGER | No | FK → activo, PK |  | Activo (PK y FK compuesta hacia activo) |
| id_tipo_activo | SMALLINT | No | FK → activo |  | 1 o 2; garantiza la especializacion disjunta |
| ticker | VARCHAR(10) | No | UQ |  | Simbolo bursatil (EC, AAPL, SPY...) |
| mercado | VARCHAR(20) | No |  |  | Bolsa donde cotiza |

Restricciones adicionales:

- `CHECK ((id_tipo_activo IN (1, 2)))`

## cdt

Subtipo: certificados de deposito a termino (COP)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_activo | INTEGER | No | FK → activo, PK |  | Activo (PK y FK compuesta) |
| id_tipo_activo | SMALLINT | No | FK → activo |  | Siempre 3 |
| entidad_emisora | VARCHAR(100) | No |  |  | Banco emisor |
| fecha_emision | DATE | No |  |  | Fecha de constitucion |
| fecha_vencimiento | DATE | No |  |  | Fecha de vencimiento (Regla 6) |

Restricciones adicionales:

- `CHECK ((id_tipo_activo = 3))`
- `CHECK ((fecha_vencimiento > fecha_emision))`

## tes

Subtipo: bonos del Tesoro de Colombia (COP)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_activo | INTEGER | No | FK → activo, PK |  | Activo (PK y FK compuesta) |
| id_tipo_activo | SMALLINT | No | FK → activo |  | Siempre 4 |
| serie | VARCHAR(20) | No | UQ |  | Serie del titulo |
| tasa_cupon | NUMERIC(6,4) | No |  |  | Cupon anual del titulo |
| fecha_emision | DATE | No |  |  | Fecha de emision |
| fecha_vencimiento | DATE | No |  |  | Fecha de vencimiento (Regla 6) |

Restricciones adicionales:

- `CHECK ((fecha_vencimiento > fecha_emision))`
- `CHECK ((id_tipo_activo = 4))`
- `CHECK (((tasa_cupon > (0)) AND (tasa_cupon < (1))))`

## precio_historico

Entidad debil: precio de cierre diario (yfinance)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_activo | INTEGER | No | FK → accion_fondo, PK |  | Accion o fondo (Regla 9) |
| fecha | DATE | No | PK |  | Dia de negociacion (clave parcial) |
| precio_cierre | NUMERIC(15,4) | No |  |  | Precio de cierre en USD |

Restricciones adicionales:

- `CHECK ((precio_cierre > (0)))`

## trm

TRM oficial COP/USD por rango de vigencia (datos.gov.co)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| fecha_desde | DATE | No | PK |  | Inicio de la vigencia |
| fecha_hasta | DATE | No |  |  | Fin de la vigencia (sin solapes) |
| valor_cop | NUMERIC(10,2) | No |  |  | Pesos por dolar |

Restricciones adicionales:

- `CHECK ((fecha_hasta >= fecha_desde))`
- `CHECK ((valor_cop > (0)))`
- `EXCLUDE USING gist (daterange(fecha_desde, fecha_hasta, '[]') WITH &&)`

## transaccion

Compras y ventas de activos (USD)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_transaccion | INTEGER | No | PK | IDENTITY | Identificador de la operacion |
| id_cuenta | INTEGER | No | FK → cuenta |  | Cuenta que opera |
| id_activo | INTEGER | No | FK → activo |  | Activo negociado |
| tipo_transaccion | VARCHAR(10) | No |  |  | COMPRA o VENTA |
| fecha_hora | TIMESTAMP | No |  | CURRENT_TIMESTAMP | Momento de la operacion |
| cantidad | NUMERIC(15,6) | No |  |  | Unidades o titulos |
| precio_unitario | NUMERIC(15,4) | No |  |  | Precio por unidad en USD |
| tasa_comision | NUMERIC(6,4) | No |  | 0.005 | Tarifa de comision vigente (0,005 por defecto) |
| tasa_pactada | NUMERIC(6,4) | Sí |  |  | Tasa efectiva anual de CDT/TES; NULL en renta variable (Regla 7) |
| monto | NUMERIC(15,2) | Sí |  | GENERATED (columna calculada) | Generada: cantidad x precio_unitario |
| comision | NUMERIC(15,2) | Sí |  | GENERATED (columna calculada) | Generada: monto x tasa_comision (Regla 5) |

Restricciones adicionales:

- `CHECK ((cantidad > (0)))`
- `CHECK ((precio_unitario > (0)))`
- `CHECK (((tasa_comision >= (0)) AND (tasa_comision < (1))))`
- `CHECK (((tasa_pactada > (0)) AND (tasa_pactada < (1))))`
- `CHECK (((tipo_transaccion) IN ('COMPRA', 'VENTA')))`

## rendimiento

Dividendos e intereses recibidos (Regla 8)

| Columna | Tipo | Nulo | Llave | Por defecto / origen | Descripción |
|---|---|---|---|---|---|
| id_rendimiento | INTEGER | No | PK | IDENTITY | Identificador |
| id_cuenta | INTEGER | No | FK → cuenta |  | Cuenta que recibe |
| id_activo | INTEGER | No | FK → activo |  | Activo que lo genera |
| fecha | DATE | No |  | CURRENT_DATE | Fecha de pago |
| tipo_rendimiento | VARCHAR(10) | No |  |  | DIVIDENDO o INTERES |
| monto | NUMERIC(15,2) | No |  |  | Valor en USD |

Restricciones adicionales:

- `CHECK ((monto > (0)))`
- `CHECK (((tipo_rendimiento) IN ('DIVIDENDO', 'INTERES')))`
