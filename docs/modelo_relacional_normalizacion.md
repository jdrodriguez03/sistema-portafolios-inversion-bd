# Modelo relacional y normalización

Sistema de Gestión de Portafolios de Inversión · Entregable 3
Julian David Rodriguez Ramirez y Juan Esteban Acosta Morales

Este documento describe el esquema que implementa `sql/01_ddl.sql`. Diagrama: `diagramas/modelo_relacional.png`. Convención: **PK en negrita**, *FK en cursiva*, `(g)` = columna generada por el motor.

## 1. Esquema relacional

| Relación | Atributos |
|---|---|
| perfil_riesgo | **id_perfil**, nombre_perfil, limite_max_renta_var |
| asesor | **id_asesor**, tipo_documento, numero_documento, nombres, apellidos, email, telefono, fecha_ingreso |
| cliente | **id_cliente**, *id_perfil*, *id_asesor*, tipo_documento, numero_documento, nombres, apellidos, email, telefono, fecha_nacimiento, fecha_vinculacion |
| cuenta | **id_cuenta**, *id_cliente*, nombre_cuenta, fecha_apertura, saldo_efectivo, estado |
| movimiento_efectivo | **id_movimiento**, *id_cuenta*, tipo_movimiento, fecha_hora, monto |
| tipo_activo | **id_tipo_activo**, nombre_tipo, clase_activo |
| activo | **id_activo**, *id_tipo_activo*, nombre, fecha_registro |
| accion_fondo | ***id_activo***, *id_tipo_activo*, ticker, mercado |
| cdt | ***id_activo***, *id_tipo_activo*, entidad_emisora, fecha_emision, fecha_vencimiento |
| tes | ***id_activo***, *id_tipo_activo*, serie, tasa_cupon, fecha_emision, fecha_vencimiento |
| precio_historico | ***id_activo***, **fecha**, precio_cierre |
| trm | **fecha_desde**, fecha_hasta, valor_cop |
| transaccion | **id_transaccion**, *id_cuenta*, *id_activo*, tipo_transaccion, fecha_hora, cantidad, precio_unitario, tasa_comision, tasa_pactada, monto (g), comision (g) |
| rendimiento | **id_rendimiento**, *id_cuenta*, *id_activo*, fecha, tipo_rendimiento, monto |

Son 14 tablas que provienen de 10 entidades del modelo conceptual: Asesor, PerfilRiesgo, Cliente, Cuenta, MovimientoEfectivo, Activo (con tres subtipos), Transacción, Rendimiento, PrecioHistórico y TRM. `tipo_activo` es el discriminador de la especialización.

## 2. Claves primarias, candidatas y foráneas

| Relación | Clave primaria | Otras claves candidatas (UNIQUE) | Claves foráneas |
|---|---|---|---|
| perfil_riesgo | id_perfil | nombre_perfil | — |
| asesor | id_asesor | (tipo_documento, numero_documento); email | — |
| cliente | id_cliente | (tipo_documento, numero_documento); email | id_perfil → perfil_riesgo; id_asesor → asesor |
| cuenta | id_cuenta | (id_cliente, nombre_cuenta) | id_cliente → cliente |
| movimiento_efectivo | id_movimiento | — | id_cuenta → cuenta |
| tipo_activo | id_tipo_activo | nombre_tipo | — |
| activo | id_activo | nombre | id_tipo_activo → tipo_activo |
| accion_fondo | id_activo | ticker | (id_activo, id_tipo_activo) → activo |
| cdt | id_activo | — | (id_activo, id_tipo_activo) → activo |
| tes | id_activo | serie | (id_activo, id_tipo_activo) → activo |
| precio_historico | (id_activo, fecha) | — | id_activo → accion_fondo |
| trm | fecha_desde | fecha_hasta (los rangos no se solapan) | — |
| transaccion | id_transaccion | — | id_cuenta → cuenta; id_activo → activo |
| rendimiento | id_rendimiento | — | id_cuenta → cuenta; id_activo → activo |

Todas las FK son `NOT NULL` (participación obligatoria del lado hijo) y usan `NO ACTION`: no se puede borrar un cliente con cuentas ni un activo con transacciones, porque el historial financiero debe conservarse.

## 3. Transformación del modelo conceptual al relacional

| Construcción conceptual | Transformación | Justificación |
|---|---|---|
| Entidades fuertes | Una tabla por entidad con clave sustituta | Los documentos de identidad pueden corregirse; la clave sustituta es estable. El documento queda como clave candidata. |
| Asesor 1:N Cliente (Regla 3) | FK `id_asesor` en cliente | La FK va en el lado N. |
| PerfilRiesgo 1:N Cliente (Regla 1) | FK `id_perfil` en cliente | El límite de renta variable depende del perfil, no del cliente: va en `perfil_riesgo`. |
| Cliente 1:N Cuenta (Regla 10) | FK `id_cliente` en cuenta | El asesor de la cuenta se obtiene a través del cliente; guardarlo en cuenta crearía una dependencia transitiva. |
| Especialización de Activo, disjunta y total (Regla 12) | Tabla del supertipo + una tabla por subtipo que comparte la PK | Los subtipos tienen atributos distintos y solo acción/fondo participa en PrecioHistórico. Una sola tabla tendría muchos nulos; solo tablas de subtipo impediría que transacción referencie a "un activo". |
| Acción y Fondo | Una sola tabla `accion_fondo` | Tienen exactamente los mismos atributos y relaciones; el discriminador los distingue. |
| PrecioHistórico (entidad débil) | PK compuesta (id_activo, fecha) | Un precio no existe sin su activo; la fecha es el discriminador parcial. |
| Cuenta M:N Activo | Tabla `transaccion` con atributos propios | Es una relación con atributos (cantidad, precio, tasa) y múltiples ocurrencias por par, por eso lleva identificador propio. |
| Tenencia (atributo derivado) | No se almacena: vista `v_tenencia` | Se calcula de las transacciones; así nunca contradice al historial. |

**Cómo se garantiza la especialización.** *Disjunta*: cada subtipo incluye `id_tipo_activo` con un `CHECK` que fija su valor y una FK compuesta (id_activo, id_tipo_activo) hacia `activo`; un activo de tipo CDT no puede aparecer en `tes`. *Total*: un trigger de restricción diferido verifica al confirmar la transacción que todo activo tenga su fila de subtipo.

## 4. Dependencias funcionales

| Relación | Dependencias funcionales |
|---|---|
| perfil_riesgo | id_perfil → nombre_perfil, limite_max_renta_var · nombre_perfil → id_perfil |
| asesor | id_asesor → todos · (tipo_documento, numero_documento) → id_asesor · email → id_asesor |
| cliente | id_cliente → todos · (tipo_documento, numero_documento) → id_cliente · email → id_cliente |
| cuenta | id_cuenta → id_cliente, nombre_cuenta, fecha_apertura, saldo_efectivo, estado · (id_cliente, nombre_cuenta) → id_cuenta |
| movimiento_efectivo | id_movimiento → id_cuenta, tipo_movimiento, fecha_hora, monto |
| tipo_activo | id_tipo_activo → nombre_tipo, clase_activo · nombre_tipo → id_tipo_activo |
| activo | id_activo → id_tipo_activo, nombre, fecha_registro · nombre → id_activo |
| accion_fondo | id_activo → id_tipo_activo, ticker, mercado · ticker → id_activo |
| cdt | id_activo → id_tipo_activo, entidad_emisora, fecha_emision, fecha_vencimiento |
| tes | id_activo → id_tipo_activo, serie, tasa_cupon, fecha_emision, fecha_vencimiento · serie → id_activo |
| precio_historico | (id_activo, fecha) → precio_cierre |
| trm | fecha_desde → fecha_hasta, valor_cop · fecha_hasta → fecha_desde |
| transaccion | id_transaccion → id_cuenta, id_activo, tipo_transaccion, fecha_hora, cantidad, precio_unitario, tasa_comision, tasa_pactada |
| rendimiento | id_rendimiento → id_cuenta, id_activo, fecha, tipo_rendimiento, monto |

No se declara (id_cuenta, id_activo, fecha_hora) como clave de transacción: una cuenta puede ejecutar dos órdenes del mismo activo en el mismo instante.

## 5. Proceso de normalización

El punto de partida es el modelo relacional preliminar (diagrama inicial). Estos son los problemas detectados y su corrección.

### 5.1 Primera forma normal (1FN)

Todos los atributos son atómicos y no hay grupos repetidos. Decisiones:

- El nombre se separa en `nombres` y `apellidos`, y el documento en `tipo_documento` y `numero_documento`.
- Los precios de un activo son un atributo multivaluado en el modelo conceptual: se llevan a la tabla `precio_historico`, una fila por día.
- Los cuatro tipos de activo no se guardan como columnas opcionales de una sola tabla sino como subtipos.

### 5.2 Segunda forma normal (2FN)

Solo `precio_historico` tiene clave compuesta. Su único atributo no clave, `precio_cierre`, depende de la clave completa: no lo determina el activo solo ni la fecha sola. El atributo `fuente` del diseño preliminar se eliminó porque era constante. Las demás relaciones tienen clave simple y cumplen 2FN de forma trivial.

### 5.3 Tercera forma normal (3FN): dependencias transitivas eliminadas

| Relación (diseño preliminar) | Dependencia transitiva | Corrección |
|---|---|---|
| transaccion | id_transaccion → (cantidad, precio_unitario) → monto | `monto` pasa a ser columna generada: el motor la calcula y no se puede escribir. |
| transaccion | id_transaccion → (monto, tarifa) → comision | Se agrega `tasa_comision` y `comision` pasa a ser generada. La tasa se guarda por transacción porque es un hecho histórico: un cambio de tarifa no debe alterar comisiones pasadas. |
| tes | id_activo → fecha_vencimiento → plazo_categoria | Se elimina `plazo_categoria`; se calcula en consulta a partir del vencimiento. |
| cdt | fecha_emision, fecha_vencimiento → plazo | El plazo no se almacena. |
| cdt | `tasa_fija` y `monto_principal` describen la compra, no el título | Pasan a `transaccion` (`tasa_pactada`, `monto`). Cumple la Regla 7: la tasa se pacta al comprar. |
| accion_fondo | tipo de activo → moneda | Se elimina `moneda`: todo el sistema valora en USD y los CDT/TES se convierten con la TRM. |
| cliente | id_cliente → id_perfil → limite_max_renta_var | Ya estaba resuelto: el límite vive en `perfil_riesgo`. |

Las columnas generadas (`monto`, `comision`) no son atributos independientes del esquema lógico: son atributos derivados que el motor materializa. No generan anomalías de actualización porque es imposible modificarlas sin modificar sus fuentes.

### 5.4 Forma normal de Boyce-Codd (BCNF)

Una relación está en BCNF si el determinante de toda dependencia funcional no trivial es una superclave.

| Relación | ¿BCNF? | Justificación |
|---|---|---|
| perfil_riesgo, tipo_activo | Sí | Determinantes: la PK y el nombre, ambos claves candidatas. |
| asesor, cliente | Sí | Tres determinantes (id, documento, email) y los tres son claves candidatas. |
| cuenta | Sí | Determinantes: id_cuenta y (id_cliente, nombre_cuenta), ambos claves candidatas. |
| activo, accion_fondo, tes | Sí | Determinantes: la PK y nombre / ticker / serie, todos claves candidatas. |
| cdt, movimiento_efectivo, rendimiento | Sí | El único determinante es la PK. |
| precio_historico | Sí | El único determinante es la clave compuesta completa. |
| trm | Sí | fecha_desde y fecha_hasta son ambas claves candidatas, porque los rangos no se solapan. |
| transaccion | Sí | Sobre los atributos base el único determinante es la PK. |

Ninguna relación requirió descomposición adicional para llegar a BCNF: una vez eliminadas las dependencias transitivas de la sección 5.3, todos los determinantes restantes son claves candidatas. No se crearon descomposiciones innecesarias.

### 5.5 Redundancias controladas (decisiones conscientes)

| Redundancia | Por qué se mantiene | Cómo se controla |
|---|---|---|
| `cuenta.saldo_efectivo` (derivable del historial) | La compra debe validar el saldo bloqueando una sola fila (`SELECT ... FOR UPDATE`); recalcularlo sumando el historial no permite ese bloqueo y es más costoso. | Solo lo modifican los triggers; un trigger rechaza cambios directos; el historial es inmutable; la consulta C15 audita que coincida con el valor reconstruido. |
| `id_tipo_activo` repetido en los subtipos | Es lo que permite garantizar por FK que la especialización sea disjunta. | La FK compuesta impide que difiera del valor en `activo`. |

No es una violación de forma normal: las formas normales analizan dependencias dentro de una relación, y el saldo depende de filas de otras tablas.

## 6. Integridad: dominios y restricciones semánticas

| Tipo | Ejemplos en el DDL |
|---|---|
| Dominio (CHECK) | montos, cantidades y precios > 0; tasas entre 0 y 1; límite del perfil entre 0 y 100; valores permitidos en tipo_movimiento, tipo_transaccion, tipo_rendimiento, estado |
| Entre atributos (CHECK) | vencimiento > emisión; fecha_hasta ≥ fecha_desde; cliente mayor de edad al vincularse |
| Unicidad | documento y email; ticker; serie; un precio por activo y día |
| No solapamiento | `EXCLUDE` sobre el rango de vigencia de la TRM |
| Valores por defecto | estado 'ACTIVA', saldo 0, tasa_comision 0,005, fechas actuales |
| Entre tablas (triggers) | saldo suficiente, tenencia suficiente, bloqueo de venta de renta fija, tasa pactada obligatoria, especialización total |

## 7. Trazabilidad: regla de negocio → implementación

| # | Regla de negocio | Dónde queda representada |
|---|---|---|
| 1 | Un único perfil de riesgo por cliente | `cliente.id_perfil` FK NOT NULL |
| 2 | Límite de renta variable por perfil | `perfil_riesgo.limite_max_renta_var` + vista `v_cumplimiento_perfil` |
| 3 | Un asesor por cliente; un asesor, varios clientes | `cliente.id_asesor` FK NOT NULL |
| 4 | Compra solo con saldo suficiente | CHECK `saldo_efectivo >= 0` + trigger `trg_transaccion_validar` |
| 5 | Comisión automática del 0,5 % | `tasa_comision` DEFAULT 0.005 + columna generada `comision` |
| 6 | CDT y TES no se venden antes del vencimiento | trigger `trg_transaccion_validar` |
| 7 | Tasa fija pactada en la compra | `transaccion.tasa_pactada` + trigger (obligatoria) + historial inmutable (no cambia) |
| 8 | Rendimientos como ingresos del portafolio | tabla `rendimiento` + trigger `trg_rendimiento_aplicar` |
| 9 | Valoración con el precio más reciente | `precio_historico` + función `fn_precio` |
| 10 | Varias cuentas por cliente; cada cuenta de un único cliente | `cuenta.id_cliente` FK NOT NULL; el asesor se obtiene por el cliente |
| 11 | No vender más de lo que se posee | función `fn_tenencia` + trigger `trg_transaccion_validar` |
| 12 | Cada activo es de un único tipo, que define sus atributos | especialización disjunta (FK compuesta + CHECK) y total (trigger diferido) |

La Regla 2 se implementa como vista de control y no como bloqueo en la compra: el porcentaje en renta variable cambia con los precios aunque el cliente no opere, de modo que un portafolio puede exceder el límite sin que exista una transacción que rechazar. La vista permite al asesor detectarlo y rebalancear.

## 8. Limitaciones del modelo

- **Cambio de asesor.** La comisión por asesor se obtiene por la cadena transacción → cuenta → cliente → asesor. Si un cliente cambia de asesor, sus comisiones históricas se atribuyen al nuevo. Solución futura: tabla de historial de asignaciones.
- **Renta fija simplificada.** CDT y TES se valoran capitalizando la tasa pactada (interés compuesto, base 365), sin precio de mercado, coherente con la política de compra y retención. En los TES no se descuentan del valor los cupones ya pagados, por lo que su valoración queda levemente sobrestimada.
- **Redención total.** Un CDT o TES se redime por la totalidad de la posición al vencimiento.
- **Rentabilidad simple.** (Vf − Vi − aportes) / (Vi + aportes); no pondera la fecha de cada aporte.
- **Efecto cambiario.** Como CDT y TES están en pesos y el sistema valora en dólares, su rentabilidad en USD incluye la variación de la TRM.
