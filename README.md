# Sistema de Gestión de Portafolios de Inversión

Proyecto final de Bases de Datos 2026-2.
Julian David Rodriguez Ramirez y Juan Esteban Acosta Morales.

Base de datos para una firma independiente de asesoría financiera que gestiona portafolios de clientes personas naturales en Colombia. Centraliza clientes, asesores, activos (acciones, fondos indexados, CDT y TES), transacciones, rendimientos y comisiones; calcula el valor, la rentabilidad y la diversificación de cada portafolio en USD; alerta los vencimientos de renta fija y consolida las comisiones por asesor.

- **PostgreSQL**: modelo relacional en BCNF, 14 tablas, reglas de negocio en restricciones y triggers, 15 consultas analíticas, pruebas de optimización y de concurrencia.
- **MongoDB**: respuestas crudas de las API de mercado (fichas semiestructuradas e historial de precios embebido).
- **Datos reales**: precios y dividendos de Yahoo Finance (yfinance) y TRM oficial de la Superintendencia Financiera ([datos.gov.co](https://www.datos.gov.co/resource/32sa-8pi3.json)). Clientes y operaciones son sintéticos, generados con semilla fija.

## Estructura

| Carpeta | Contenido |
| --- | --- |
| `sql/` | `01_ddl` · `02_funciones_triggers` · `03_carga_catalogos` · `04_carga_datos` · `05_vistas` · `06_consultas` · `07_optimizacion` · `08_transacciones` · `concurrencia/` |
| `scripts/` | `generar_datos.py` (descarga y generación de datos), `cargar_mongo.py`, `generar_diagramas.py` |
| `mongo/` | Índices, CRUD y agregaciones para mongosh |
| `datos/` | Precios y TRM en CSV; `raw/` con las respuestas originales de las API |
| `backup/` | `portafolios.backup` (pg_dump), `portafolios.sql` y exportación de MongoDB |
| `evidencias/` | Salida de cada paso: consultas, planes de ejecución, transacciones, concurrencia y MongoDB |
| `diagramas/` | Modelo conceptual EER y modelo relacional (PNG, SVG y fuente Graphviz) |
| `docs/` | Modelo conceptual, normalización y diccionario de datos |

## Requisitos

- PostgreSQL 16 o superior (`psql` y `pg_dump`)
- MongoDB con `mongosh`
- Python 3 con `pip install yfinance pandas requests pymongo`

## Cómo ejecutar

1. Crear `config.ps1` en la raíz con la conexión (no se incluye en el repositorio):

   ```powershell
   $env:PGHOST = "localhost"
   $env:PGPORT = "5432"
   $env:PGUSER = "postgres"
   $env:PGPASSWORD = "<su contraseña>"
   $env:PGDATABASE = "portafolios"
   ```

2. Ejecutar todo (Windows): doble clic en `EJECUTAR_TODO.bat`, o

   ```powershell
   powershell -ExecutionPolicy Bypass -File run_all.ps1
   ```

   Pasos: `datos`, `base`, `consultas`, `optimizacion`, `transacciones`, `concurrencia`, `mongo`, `backup`. Para correr solo algunos: `-Pasos base,consultas`. Sin internet: `-Simular` (precios simulados). Para volver a descargar: `-Descargar`.

3. Revisar `evidencias/00_resumen_ejecucion.txt`.

Restaurar solo la base desde el backup:

```powershell
createdb portafolios
pg_restore -d portafolios backup\portafolios.backup
```

## Resultados principales

| Prueba | Resultado |
| --- | --- |
| Carga | 1.479 transacciones, 407 movimientos y 1.367 rendimientos validados por los triggers, sin rechazos |
| Integridad | 0 cuentas con saldo distinto del reconstruido desde el historial |
| Optimización 1 | Último precio por posición: 98,1 ms → 2,0 ms con índice (id_activo, fecha) |
| Optimización 2 | Historial de un cliente (221.850 filas): 23,2 ms → 7,1 ms con índice (id_cuenta, fecha_hora) |
| Optimización 3 | Índice sobre `tipo_transaccion` descartado: el planificador no lo usa (baja selectividad) |
| Concurrencia | Sin bloqueo: dos compras aprobadas con saldo para una. Con `SELECT ... FOR UPDATE`: la segunda espera y es rechazada |
| MongoDB | Índice sobre la vigencia de la TRM: de 698 documentos leídos a 1 |
