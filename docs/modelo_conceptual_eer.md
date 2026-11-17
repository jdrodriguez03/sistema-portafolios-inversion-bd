# Modelo conceptual EER

Sistema de Gestión de Portafolios de Inversión · Entregable 2
Diagrama: `diagramas/eer_conceptual.png` (fuente editable: `diagramas/eer_conceptual.dot`)

## 1. Reglas de negocio actualizadas

Las reglas 1 a 12 vienen de la formulación; se precisan las que cambiaron al modelar y se agregan las 13 a 16.

| # | Regla | Cambio frente a la formulación |
|---|---|---|
| 1 | Cada cliente tiene un único perfil de riesgo (conservador, moderado, agresivo). | Sin cambio. |
| 2 | El porcentaje del portafolio en acciones y fondos no debe superar el límite del perfil: 20 % conservador, 50 % moderado, 100 % agresivo. | El límite es atributo del perfil. Se controla con una vista de cumplimiento, porque el porcentaje cambia con los precios aunque el cliente no opere. El efectivo cuenta como parte del portafolio. |
| 3 | Cada cliente está asignado a un único asesor; un asesor gestiona varios clientes. | Sin cambio. |
| 4 | Toda compra requiere saldo en efectivo suficiente para el monto más la comisión. | Se precisa que incluye la comisión. |
| 5 | Toda compra o venta genera una comisión del 0,5 % de su valor. | La tasa se guarda en cada transacción para conservar el histórico si la tarifa cambia. |
| 6 | CDT y TES no se liquidan antes del vencimiento. | Se agrega: la redención es por el total de la posición. |
| 7 | La tasa de un CDT o TES se pacta en la compra y no cambia. | La tasa es atributo de la compra, no del título. |
| 8 | Dividendos e intereses se registran como ingresos de la cuenta. | Dividendos solo para acciones y fondos; intereses solo para CDT y TES. |
| 9 | Acciones y fondos se valoran con el precio de cierre más reciente cargado desde la API. | Sin cambio. |
| 10 | Un cliente puede tener varias cuentas; cada cuenta es de un único cliente. | El asesor de la cuenta es el asesor del cliente. |
| 11 | No se vende más cantidad de la que la cuenta posee. | Sin cambio. |
| 12 | Cada activo es de un único tipo, que determina sus atributos. | Especialización disjunta y total. |
| 13 | El sistema valora en USD. CDT y TES se pactan en COP y se convierten con la TRM oficial vigente en la fecha. | Nueva. |
| 14 | El efectivo solo cambia por depósitos, retiros, compras, ventas y rendimientos; nunca por edición directa. | Nueva. |
| 15 | Transacciones, movimientos y rendimientos no se modifican ni se eliminan. | Nueva. |
| 16 | Solo se vinculan personas naturales mayores de edad; documento y correo no se repiten. | Nueva. |

## 2. Entidades

| Entidad | Tipo | Qué representa | Identificador |
|---|---|---|---|
| Asesor | Fuerte | Empleado de la firma que gestiona clientes | id_asesor (candidata: documento, email) |
| PerfilRiesgo | Fuerte (catálogo) | Nivel de riesgo y su límite de renta variable | id_perfil |
| Cliente | Fuerte | Persona natural que invierte | id_cliente (candidata: documento, email) |
| Cuenta | Fuerte | Portafolio de un cliente, con su efectivo | id_cuenta |
| MovimientoEfectivo | Fuerte | Depósito o retiro de una cuenta | id_movimiento |
| Activo | Fuerte, supertipo | Instrumento en el que se invierte | id_activo |
| AcciónFondo, CDT, TES | Subtipos | Atributos propios de cada tipo de activo | heredan id_activo |
| PrecioHistórico | Débil | Precio de cierre de una acción o fondo en un día | id_activo + fecha (clave parcial) |
| Transacción | Fuerte | Compra o venta de un activo desde una cuenta | id_transaccion |
| Rendimiento | Fuerte | Dividendo o interés recibido | id_rendimiento |
| TRM | Fuerte (referencia) | Tasa de cambio oficial por rango de vigencia | fecha_desde |

Son 10 entidades significativas; los tres subtipos se cuentan dentro de Activo.

**Atributos especiales.** Compuestos: documento (tipo, número) y nombre (nombres, apellidos). Derivados: saldo_efectivo de Cuenta, monto y comisión de Transacción, plazo de CDT. Multivaluado: el precio de una acción en el tiempo, que por tener atributo propio (la fecha) se modela como la entidad débil PrecioHistórico.

## 3. Justificación de las cardinalidades

La notación es (mínimo, máximo) junto a cada entidad: cuántas veces participa una instancia en la relación.

| Relación | Cardinalidad | Justificación |
|---|---|---|
| PerfilRiesgo clasifica Cliente | Perfil (0,N) · Cliente (1,1) | Regla 1: el cliente tiene exactamente un perfil. Un perfil puede no tener clientes todavía. |
| Asesor gestiona Cliente | Asesor (0,N) · Cliente (1,1) | Regla 3. Un asesor recién ingresado puede no tener clientes. |
| Cliente posee Cuenta | Cliente (0,N) · Cuenta (1,1) | Regla 10. El cliente puede estar vinculado y aún no haber abierto cuenta. |
| Cuenta registra MovimientoEfectivo | Cuenta (0,N) · Movimiento (1,1) | Un movimiento afecta una sola cuenta; una cuenta nueva no tiene movimientos. |
| Cuenta ordena Transacción | Cuenta (0,N) · Transacción (1,1) | Cada orden sale de una única cuenta. |
| Transacción se negocia en Activo | Transacción (1,1) · Activo (0,N) | Cada orden es sobre un solo activo; un activo puede no haberse negociado. |
| Cuenta recibe Rendimiento | Cuenta (0,N) · Rendimiento (1,1) | Regla 8: el pago se abona a una cuenta. |
| Rendimiento generado por Activo | Rendimiento (1,1) · Activo (0,N) | Todo dividendo o interés proviene de un activo específico. |
| AcciónFondo cotiza PrecioHistórico | AcciónFondo (0,N) · Precio (1,1) | Relación identificadora: un precio no existe sin su activo. Solo la renta variable tiene precio de mercado (Regla 9). |

**¿Por qué Transacción es entidad y no una relación M:N entre Cuenta y Activo?** Porque la misma cuenta compra el mismo activo muchas veces, y cada ocurrencia tiene atributos propios (fecha, cantidad, precio, tasa). Una relación M:N admite una sola ocurrencia por par.

## 4. Construcciones EER utilizadas

**Especialización de Activo (disjunta, total).**
- *Necesaria* porque los subtipos tienen atributos distintos (ticker y mercado; entidad emisora y fechas; serie y cupón) y relaciones distintas: solo AcciónFondo participa en "cotiza".
- *Disjunta*: un instrumento no puede ser a la vez CDT y TES (Regla 12).
- *Total*: el universo de activos de la firma es cerrado; no existe un activo "genérico" sin tipo.
- Acción y Fondo forman un solo subtipo porque comparten atributos y relaciones; el discriminador los distingue.

**Entidad débil PrecioHistórico.** Depende existencialmente de AcciónFondo y se identifica con la clave del propietario más la fecha.

**No se usaron** categorías (unión) ni agregación: ninguna regla del dominio las requiere. Asesor y Cliente no se generalizaron en "Persona" porque no comparten relaciones y la generalización no aportaría semántica.

**TRM** no se conecta por una relación con identificador: se asocia por fecha (la TRM vigente el día de la operación). Se documenta como entidad de referencia.
