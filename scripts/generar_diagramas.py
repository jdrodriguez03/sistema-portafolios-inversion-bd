# Genera los .dot del EER y del modelo relacional. Uso (desde la raiz): python scripts/generar_diagramas.py ; luego: dot -Tpng diagramas/X.dot -o diagramas/X.png
HEAD='digraph G {\n  graph [fontname="Helvetica", bgcolor="white", pad=0.3, nodesep=0.45, ranksep=0.9, splines=true, %s];\n  node [fontname="Helvetica", fontsize=11];\n  edge [fontname="Helvetica", fontsize=10, color="#34495e", arrowhead=none];\n'
def ent(name, attrs, weak=False, sub=False):
    color = "#1f3a5f" if not sub else "#3d6a8f"
    rows = "".join(f'<TR><TD ALIGN="LEFT" BGCOLOR="white">{a}</TD></TR>' for a in attrs)
    border = 'BORDER="3" CELLBORDER="1" COLOR="%s"' % color if not weak else 'BORDER="6" CELLBORDER="1" COLOR="%s" STYLE="rounded"' % color
    title = name.replace("_", " ")
    return f'  {name} [shape=plain, label=<<TABLE {border} CELLSPACING="0" CELLPADDING="5"><TR><TD BGCOLOR="{color}"><FONT COLOR="white"><B>{title}</B></FONT></TD></TR>{rows}</TABLE>>];\n'
def rel(name, label, ident=False):
    per = 2 if ident else 1
    return f'  {name} [shape=diamond, label="{label}", style=filled, fillcolor="#f4e4b8", color="#8a6d1f", peripheries={per}, fontsize=10, margin="0.02,0.02"];\n'
K = lambda s: f"<U><B>{s}</B></U>"
D = lambda s: f"<I>/ {s}</I>"
P = lambda s: f'<U>{s}</U> <FONT POINT-SIZE="9" COLOR="#777777">(clave parcial)</FONT>'
s = HEAD % 'rankdir=LR, label="Modelo conceptual EER - Sistema de Gestion de Portafolios de Inversion\\nNotacion (min,max) junto a cada entidad: cuantas veces participa en la relacion.  Subrayado = identificador.  / = atributo derivado.  Borde doble = entidad debil / relacion identificadora.", labelloc=t, fontsize=13'
s += ent("PERFIL_RIESGO", [K("id_perfil"), "nombre_perfil", "limite_max_renta_var"])
s += ent("ASESOR", [K("id_asesor"), "documento (tipo, numero)", "nombre (nombres, apellidos)", "email", "telefono", "fecha_ingreso"])
s += ent("CLIENTE", [K("id_cliente"), "documento (tipo, numero)", "nombre (nombres, apellidos)", "email", "telefono", "fecha_nacimiento", "fecha_vinculacion"])
s += ent("CUENTA", [K("id_cuenta"), "nombre_cuenta", "fecha_apertura", "estado", D("saldo_efectivo")])
s += ent("MOVIMIENTO_EFECTIVO", [K("id_movimiento"), "tipo_movimiento", "fecha_hora", "monto"])
s += ent("TRANSACCION", [K("id_transaccion"), "tipo_transaccion", "fecha_hora", "cantidad", "precio_unitario", "tasa_comision", "tasa_pactada", D("monto"), D("comision")])
s += ent("RENDIMIENTO", [K("id_rendimiento"), "tipo_rendimiento", "fecha", "monto"])
s += ent("ACTIVO", [K("id_activo"), "nombre", "fecha_registro", "tipo (discriminador)"])
s += ent("ACCION_FONDO", ["ticker", "mercado"], sub=True)
s += ent("CDT", ["entidad_emisora", "fecha_emision", "fecha_vencimiento", D("plazo")], sub=True)
s += ent("TES", ["serie", "tasa_cupon", "fecha_emision", "fecha_vencimiento"], sub=True)
s += ent("PRECIO_HISTORICO", [P("fecha"), "precio_cierre"], weak=True)
s += ent("TRM", [K("fecha_desde"), "fecha_hasta", "valor_cop"])
for n,l,i in [("r_gest","gestiona",0),("r_clas","clasifica",0),("r_posee","posee",0),("r_mov","registra",0),("r_ord","ordena",0),("r_obj","se negocia en",0),("r_rec","recibe",0),("r_gen","genera",0),("r_cot","cotiza",1)]:
    s += rel(n,l,i)
s += '  esp [shape=circle, label="d", style=filled, fillcolor="white", color="#1f3a5f", penwidth=2, width=0.35, fixedsize=true, fontsize=12];\n'
def e(a,b,lab="",extra=""): return f'  {a} -> {b} [label=" {lab} "{extra}];\n'
s += e("PERFIL_RIESGO","r_clas","(0,N)") + e("r_clas","CLIENTE","(1,1)")
s += e("ASESOR","r_gest","(0,N)") + e("r_gest","CLIENTE","(1,1)")
s += e("CLIENTE","r_posee","(0,N)") + e("r_posee","CUENTA","(1,1)")
s += e("CUENTA","r_mov","(0,N)") + e("r_mov","MOVIMIENTO_EFECTIVO","(1,1)")
s += e("CUENTA","r_ord","(0,N)") + e("r_ord","TRANSACCION","(1,1)")
s += e("CUENTA","r_rec","(0,N)") + e("r_rec","RENDIMIENTO","(1,1)")
s += e("TRANSACCION","r_obj","(1,1)") + e("r_obj","ACTIVO","(0,N)")
s += e("RENDIMIENTO","r_gen","(1,1)") + e("r_gen","ACTIVO","(0,N)")
s += e("ACTIVO","esp","total",', color="#1f3a5f:white:#1f3a5f", penwidth=1.5')
for sub in ["ACCION_FONDO","CDT","TES"]:
    s += f'  esp -> {sub} [arrowhead=icurve, color="#1f3a5f", penwidth=1.5];\n'
s += e("ACCION_FONDO","r_cot","(0,N)") + e("r_cot","PRECIO_HISTORICO","(1,1)",', color="#34495e:white:#34495e"')
s += '  nota [shape=note, style=filled, fillcolor="#fdf6e3", color="#b58900", fontsize=10, label="TRM es una entidad de referencia: no se relaciona\\npor identificador sino por fecha. La TRM vigente en la\\nfecha de una operacion convierte CDT y TES (COP) a USD."];\n  TRM -> nota [style=dashed, color="#b58900"];\n  { rank=same; TRM; nota; }\n  PRECIO_HISTORICO -> TRM [style=invis];\n'
s += "}\n"
open("diagramas/eer_conceptual.dot","w").write(s)

# ---------------- relacional ----------------
T = {
 "perfil_riesgo":[("id_perfil","SMALLINT","PK"),("nombre_perfil","VARCHAR(20)","UQ"),("limite_max_renta_var","NUMERIC(5,2)","")],
 "asesor":[("id_asesor","INTEGER","PK"),("tipo_documento","VARCHAR(3)","UQ1"),("numero_documento","VARCHAR(20)","UQ1"),("nombres","VARCHAR(100)",""),("apellidos","VARCHAR(100)",""),("email","VARCHAR(150)","UQ2"),("telefono","VARCHAR(20)",""),("fecha_ingreso","DATE","")],
 "cliente":[("id_cliente","INTEGER","PK"),("id_perfil","SMALLINT","FK"),("id_asesor","INTEGER","FK"),("tipo_documento","VARCHAR(3)","UQ1"),("numero_documento","VARCHAR(20)","UQ1"),("nombres","VARCHAR(100)",""),("apellidos","VARCHAR(100)",""),("email","VARCHAR(150)","UQ2"),("telefono","VARCHAR(20)",""),("fecha_nacimiento","DATE",""),("fecha_vinculacion","DATE","")],
 "cuenta":[("id_cuenta","INTEGER","PK"),("id_cliente","INTEGER","FK,UQ"),("nombre_cuenta","VARCHAR(100)","UQ"),("fecha_apertura","DATE",""),("saldo_efectivo","NUMERIC(15,2)",""),("estado","VARCHAR(10)","")],
 "movimiento_efectivo":[("id_movimiento","INTEGER","PK"),("id_cuenta","INTEGER","FK"),("tipo_movimiento","VARCHAR(10)",""),("fecha_hora","TIMESTAMP",""),("monto","NUMERIC(15,2)","")],
 "tipo_activo":[("id_tipo_activo","SMALLINT","PK"),("nombre_tipo","VARCHAR(20)","UQ"),("clase_activo","VARCHAR(15)","")],
 "activo":[("id_activo","INTEGER","PK"),("id_tipo_activo","SMALLINT","FK"),("nombre","VARCHAR(150)","UQ"),("fecha_registro","DATE","")],
 "accion_fondo":[("id_activo","INTEGER","PK,FK"),("id_tipo_activo","SMALLINT","FK"),("ticker","VARCHAR(10)","UQ"),("mercado","VARCHAR(20)","")],
 "cdt":[("id_activo","INTEGER","PK,FK"),("id_tipo_activo","SMALLINT","FK"),("entidad_emisora","VARCHAR(100)",""),("fecha_emision","DATE",""),("fecha_vencimiento","DATE","")],
 "tes":[("id_activo","INTEGER","PK,FK"),("id_tipo_activo","SMALLINT","FK"),("serie","VARCHAR(20)","UQ"),("tasa_cupon","NUMERIC(6,4)",""),("fecha_emision","DATE",""),("fecha_vencimiento","DATE","")],
 "precio_historico":[("id_activo","INTEGER","PK,FK"),("fecha","DATE","PK"),("precio_cierre","NUMERIC(15,4)","")],
 "trm":[("fecha_desde","DATE","PK"),("fecha_hasta","DATE",""),("valor_cop","NUMERIC(10,2)","")],
 "transaccion":[("id_transaccion","INTEGER","PK"),("id_cuenta","INTEGER","FK"),("id_activo","INTEGER","FK"),("tipo_transaccion","VARCHAR(10)",""),("fecha_hora","TIMESTAMP",""),("cantidad","NUMERIC(15,6)",""),("precio_unitario","NUMERIC(15,4)",""),("tasa_comision","NUMERIC(6,4)",""),("tasa_pactada","NUMERIC(6,4)","NULL"),("monto","NUMERIC(15,2)","GEN"),("comision","NUMERIC(15,2)","GEN")],
 "rendimiento":[("id_rendimiento","INTEGER","PK"),("id_cuenta","INTEGER","FK"),("id_activo","INTEGER","FK"),("fecha","DATE",""),("tipo_rendimiento","VARCHAR(10)",""),("monto","NUMERIC(15,2)","")],
}
FK=[("cliente","id_perfil","perfil_riesgo","id_perfil"),("cliente","id_asesor","asesor","id_asesor"),("cuenta","id_cliente","cliente","id_cliente"),("movimiento_efectivo","id_cuenta","cuenta","id_cuenta"),("activo","id_tipo_activo","tipo_activo","id_tipo_activo"),("accion_fondo","id_activo","activo","id_activo"),("cdt","id_activo","activo","id_activo"),("tes","id_activo","activo","id_activo"),("precio_historico","id_activo","accion_fondo","id_activo"),("transaccion","id_cuenta","cuenta","id_cuenta"),("transaccion","id_activo","activo","id_activo"),("rendimiento","id_cuenta","cuenta","id_cuenta"),("rendimiento","id_activo","activo","id_activo")]
r = HEAD % 'rankdir=RL, label="Modelo relacional normalizado (BCNF)\\nPK = clave primaria   FK = clave foranea   UQ = clave candidata (UNIQUE)   GEN = columna generada   La flecha apunta de la FK a la tabla referenciada.\\nLos subtipos referencian a activo con la FK compuesta (id_activo, id_tipo_activo).", labelloc=t, fontsize=13'
for t,cols in T.items():
    rows=""
    for c,ty,k in cols:
        name = f"<B>{c}</B>" if "PK" in k else c
        bg = "#fff3cd" if "PK" in k else ("#e3eef9" if "FK" in k else "white")
        rows += f'<TR><TD ALIGN="LEFT" BGCOLOR="{bg}" PORT="{c}_l"><FONT POINT-SIZE="9" COLOR="#555555">{k or " "}</FONT></TD><TD ALIGN="LEFT" BGCOLOR="{bg}">{name}</TD><TD ALIGN="LEFT" BGCOLOR="{bg}" PORT="{c}_r"><FONT POINT-SIZE="9" COLOR="#555555">{ty}</FONT></TD></TR>'
    r += f'  {t} [shape=plain, label=<<TABLE BORDER="2" CELLBORDER="1" CELLSPACING="0" CELLPADDING="4" COLOR="#1f3a5f"><TR><TD COLSPAN="3" BGCOLOR="#1f3a5f"><FONT COLOR="white"><B>{t}</B></FONT></TD></TR>{rows}</TABLE>>];\n'
for a,ca,b,cb in FK:
    r += f'  {a}:{ca}_l:w -> {b}:{cb}_r:e [arrowhead=normal, arrowtail=crow, dir=both, color="#34495e"];\n'
r += "  precio_historico -> trm [style=invis];\n}\n"
open("diagramas/modelo_relacional.dot","w").write(r)
