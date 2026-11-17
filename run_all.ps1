# =====================================================================
# run_all.ps1 - Construye y prueba la solucion completa
#
# Uso (desde la carpeta del proyecto):
#   powershell -ExecutionPolicy Bypass -File run_all.ps1
#   powershell -ExecutionPolicy Bypass -File run_all.ps1 -Pasos base,consultas
#   powershell -ExecutionPolicy Bypass -File run_all.ps1 -Simular   (sin internet)
#
# Pasos: datos, base, consultas, optimizacion, transacciones,
#        concurrencia, mongo, backup
# Cada paso guarda su salida en evidencias\ (UTF-8).
#
# Requisitos: PostgreSQL 16+ (psql y pg_dump), MongoDB con mongosh,
# Python 3 con: yfinance pandas requests pymongo
# Conexion: config.ps1 (variables PGHOST, PGUSER, PGPASSWORD...).
# =====================================================================
param(
    [string[]]$Pasos = @("datos", "base", "consultas", "optimizacion", "transacciones",
                         "concurrencia", "mongo", "backup"),
    [switch]$Simular,
    [switch]$Descargar
)

$Raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Raiz

if (Test-Path "$Raiz\config.ps1") { . "$Raiz\config.ps1" }
if (-not $env:PGDATABASE) { $env:PGDATABASE = "portafolios" }
if (-not $env:PGCLIENTENCODING) { $env:PGCLIENTENCODING = "UTF8" }
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    $pg = Get-ChildItem "C:\Program Files\PostgreSQL\*\bin" -Directory -ErrorAction SilentlyContinue |
          Sort-Object FullName -Descending | Select-Object -First 1
    if ($pg) { $env:Path += ";" + $pg.FullName }
}
$PSQL = (Get-Command psql -ErrorAction Stop).Source

New-Item -ItemType Directory -Force "evidencias", "backup" | Out-Null
$Resumen = "evidencias\00_resumen_ejecucion.txt"
$BD = $env:PGDATABASE

function Log([string]$m) {
    $l = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Write-Host $l
    Add-Content -Path $Resumen -Value $l -Encoding UTF8
}

# Ejecuta un programa y guarda su salida (stdout y stderr) en UTF-8.
# $Agregar = $true agrega al archivo en lugar de reemplazarlo.
function Ejecutar([string]$Archivo, [string]$Exe, [string[]]$Argumentos, [bool]$Agregar = $false) {
    $salida = & $Exe @Argumentos 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    if ($null -eq $salida) { $salida = @() }
    if ($Agregar) { $salida | Add-Content -Path $Archivo -Encoding UTF8 }
    else { Set-Content -Path $Archivo -Value $salida -Encoding UTF8 }
    return $rc
}

function Paso([string]$Nombre, [scriptblock]$Bloque) {
    if ($Pasos -notcontains $Nombre) { return }
    Log "INICIO paso '$Nombre'"
    $ok = & $Bloque
    if ($ok -eq $false) { Log "ERROR en el paso '$Nombre' (ver evidencias)"; $script:Fallos += $Nombre }
    else { Log "FIN paso '$Nombre'" }
}

$Fallos = @()
Set-Content -Path $Resumen -Value "" -Encoding UTF8   # cada ejecucion empieza un resumen nuevo
Log "==== Ejecucion de run_all.ps1 (pasos: $($Pasos -join ', ')) ===="

# ---------------------------------------------------------------- datos
Paso "datos" {
    $arg = if ($Simular) { "--simular" } elseif ($Descargar) { "--descargar" } else { "" }
    $a = @("scripts\generar_datos.py"); if ($arg) { $a += $arg }
    $rc = Ejecutar "evidencias\01_generar_datos.txt" "python" $a
    Get-Content "evidencias\01_generar_datos.txt" -Encoding UTF8 | Select-Object -Last 6 | ForEach-Object { Log "   $_" }
    return ($rc -eq 0)
}
if ($Fallos -contains "datos") { Log "Se detiene: sin datos no se puede cargar la base."; exit 1 }

# ----------------------------------------------------------------- base
Paso "base" {
    $f = "evidencias\02_carga_base.txt"
    $rc = Ejecutar $f $PSQL @("-X", "-d", "postgres", "-c", "DROP DATABASE IF EXISTS $BD WITH (FORCE)", "-c", "CREATE DATABASE $BD")
    if ($rc -ne 0) { return $false }
    foreach ($s in "01_ddl", "02_funciones_triggers", "03_carga_catalogos", "04_carga_datos", "05_vistas") {
        Add-Content $f "`n===== sql\$s.sql =====" -Encoding UTF8
        $rc = Ejecutar $f $PSQL @("-X", "-q", "-v", "ON_ERROR_STOP=1", "-d", $BD, "-f", "sql\$s.sql") $true
        if ($rc -ne 0) { Log "   fallo en sql\$s.sql"; return $false }
    }
    $conteo = "SELECT 'asesor' tabla, COUNT(*) filas FROM asesor UNION ALL SELECT 'cliente', COUNT(*) FROM cliente UNION ALL SELECT 'cuenta', COUNT(*) FROM cuenta UNION ALL SELECT 'movimiento_efectivo', COUNT(*) FROM movimiento_efectivo UNION ALL SELECT 'activo', COUNT(*) FROM activo UNION ALL SELECT 'accion_fondo', COUNT(*) FROM accion_fondo UNION ALL SELECT 'cdt', COUNT(*) FROM cdt UNION ALL SELECT 'tes', COUNT(*) FROM tes UNION ALL SELECT 'precio_historico', COUNT(*) FROM precio_historico UNION ALL SELECT 'trm', COUNT(*) FROM trm UNION ALL SELECT 'transaccion', COUNT(*) FROM transaccion UNION ALL SELECT 'rendimiento', COUNT(*) FROM rendimiento"
    Ejecutar "evidencias\02b_conteo_registros.txt" $PSQL @("-X", "-d", $BD, "-P", "pager=off", "-c", $conteo) | Out-Null
    Get-Content "evidencias\02b_conteo_registros.txt" -Encoding UTF8 | ForEach-Object { Log "   $_" }
    return $true
}
if ($Fallos -contains "base") { Log "Se detiene: la base no se pudo construir."; exit 1 }

# ------------------------------------------------------------ consultas
Paso "consultas" {
    $rc = Ejecutar "evidencias\03_consultas.txt" $PSQL @("-X", "-a", "-v", "ON_ERROR_STOP=1", "-d", $BD, "-P", "pager=off", "-f", "sql\06_consultas.sql")
    return ($rc -eq 0)
}

# --------------------------------------------------------- optimizacion
Paso "optimizacion" {
    $rc = Ejecutar "evidencias\04_optimizacion.txt" $PSQL @("-X", "-a", "-v", "ON_ERROR_STOP=1", "-d", $BD, "-f", "sql\07_optimizacion.sql")
    return ($rc -eq 0)
}

# -------------------------------------------------------- transacciones
Paso "transacciones" {
    $rc = Ejecutar "evidencias\05_transacciones.txt" $PSQL @("-X", "-a", "-d", $BD, "-f", "sql\08_transacciones.sql")
    return ($rc -eq 0)
}

# --------------------------------------------------------- concurrencia
Paso "concurrencia" {
    $f = "evidencias\06_concurrencia.txt"
    Set-Content $f "ESCENARIO DE CONCURRENCIA - dos sesiones simultaneas (READ COMMITTED)`n" -Encoding UTF8
    Ejecutar $f $PSQL @("-X", "-q", "-d", $BD, "-f", "sql\concurrencia\00_preparar.sql") $true | Out-Null

    foreach ($caso in @(@{n = "sin_bloqueo"; t = "CASO 1 - Sin bloqueo (la aplicacion lee, valida y escribe): saldo 1000, dos compras de 700"},
                        @{n = "con_bloqueo"; t = "CASO 2 - Tabla real con trigger y SELECT ... FOR UPDATE"})) {
        Add-Content $f "`n==============================================================`n$($caso.t)`n==============================================================" -Encoding UTF8
        $procs = @()
        foreach ($s in @(@{id = "A"; e = 0}, @{id = "B"; e = 1})) {
            $out = "evidencias\_tmp_$($caso.n)_$($s.id).txt"
            $procs += Start-Process -FilePath $PSQL -NoNewWindow -PassThru -WorkingDirectory $Raiz `
                -ArgumentList "-X -d $BD -v sesion=$($s.id) -v espera=$($s.e) -f sql\concurrencia\sesion_$($caso.n).sql" `
                -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        }
        $procs | ForEach-Object { $_.WaitForExit() }
        # Une las salidas de ambas sesiones ordenadas por hora (orden estable)
        $n = 0
        $lineas = foreach ($s in "A", "B") {
            Get-Content "evidencias\_tmp_$($caso.n)_$s.txt" -Encoding UTF8 | Where-Object { $_.Trim() -ne "" } |
                ForEach-Object {
                    $n++
                    $k = if ($_ -match '^\[(\d\d:\d\d:\d\d\.\d+)\]') { $Matches[1] } else { "99" }
                    [pscustomobject]@{ k = $k; i = $n; t = $_ }
                }
        }
        $lineas | Sort-Object k, i | ForEach-Object { $_.t } | Add-Content $f -Encoding UTF8
        foreach ($s in "A", "B") {
            $err = Get-Content "evidencias\_tmp_$($caso.n)_$s.txt.err" -Encoding UTF8 | Where-Object { $_.Trim() -ne "" }
            if ($err) {
                Add-Content $f "`n  Mensajes del servidor en la sesion ${s}:" -Encoding UTF8
                $err | ForEach-Object { "    $_" } | Add-Content $f -Encoding UTF8
            }
        }
        Remove-Item "evidencias\_tmp_$($caso.n)_*" -ErrorAction SilentlyContinue
        if ($caso.n -eq "sin_bloqueo") {
            Add-Content $f "`nEstado final de la cuenta de demostracion:" -Encoding UTF8
            Ejecutar $f $PSQL @("-X", "-d", $BD, "-P", "pager=off", "-c", "SELECT saldo AS saldo_final, 1000 - 700 * (SELECT COUNT(*) FROM demo.compra_sin_control) AS saldo_correcto, (SELECT COUNT(*) FROM demo.compra_sin_control) AS compras_aprobadas FROM demo.cuenta_sin_control") $true | Out-Null
        } else {
            Add-Content $f "`nUltimas transacciones de la cuenta y auditoria del saldo:" -Encoding UTF8
            Ejecutar $f $PSQL @("-X", "-d", $BD, "-P", "pager=off", "-c", "SELECT t.id_transaccion, t.id_cuenta, t.tipo_transaccion, t.cantidad, t.monto, t.comision, t.fecha_hora FROM transaccion t ORDER BY t.id_transaccion DESC LIMIT 2", "-c", "SELECT COUNT(*) AS cuentas_descuadradas FROM cuenta WHERE saldo_efectivo <> fn_efectivo(id_cuenta)") $true | Out-Null
        }
    }
    Ejecutar $f $PSQL @("-X", "-q", "-d", $BD, "-c", "DROP SCHEMA demo CASCADE") $true | Out-Null
    return $true
}

# ---------------------------------------------------------------- mongo
Paso "mongo" {
    $rc = Ejecutar "evidencias\07_mongo_carga.txt" "python" @("scripts\cargar_mongo.py")
    if ($rc -ne 0) { return $false }
    $i = 8
    foreach ($s in "01_indices", "02_crud", "03_agregaciones") {
        $rc = Ejecutar ("evidencias\{0:D2}_mongo_{1}.txt" -f $i, $s) "mongosh" @("--quiet", "portafolios_nosql", "--file", "mongo\$s.js")
        if ($rc -ne 0) { Log "   fallo en mongo\$s.js"; return $false }
        $i++
    }
    return $true
}

# --------------------------------------------------------------- backup
Paso "backup" {
    $f = "evidencias\11_backup.txt"
    $dump = Join-Path (Split-Path $PSQL) "pg_dump.exe"
    $rc1 = Ejecutar $f $dump @("-Fc", "-f", "backup\portafolios.backup", $BD)
    $rc2 = Ejecutar $f $dump @("--no-owner", "--no-privileges", "-f", "backup\portafolios.sql", $BD) $true
    $rc3 = Ejecutar $f "python" @("scripts\cargar_mongo.py", "--exportar") $true
    Get-ChildItem backup -Recurse -File | ForEach-Object { Log ("   {0}  {1:N0} KB" -f $_.FullName.Replace("$Raiz\", ""), ($_.Length / 1KB)) }
    return ($rc1 -eq 0 -and $rc2 -eq 0 -and $rc3 -eq 0)
}

if ($Fallos.Count -gt 0) { Log "==== TERMINO CON ERRORES en: $($Fallos -join ', ') ====" }
else { Log "==== TERMINO SIN ERRORES ====" }
