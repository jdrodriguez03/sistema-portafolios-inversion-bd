// =====================================================================
// mongo/01_indices.js   (mongosh portafolios_nosql --file mongo/01_indices.js)
// Indices del componente documental, con evidencia antes/despues.
// =====================================================================
db = db.getSiblingDB("portafolios_nosql");

// Resume un plan de explain("executionStats"): etapas, documentos y claves leidas
function resumen(exp) {
  const wp = exp.queryPlanner.winningPlan;
  let st = wp.queryPlan || wp;
  const etapas = [];
  while (st) {
    etapas.push(st.stage);
    st = st.inputStage || (st.inputStages ? st.inputStages[0] : null);
  }
  const s = exp.executionStats;
  return {
    etapas: etapas.join(" <- "),
    documentos_examinados: s.totalDocsExamined,
    claves_examinadas: s.totalKeysExamined,
    documentos_devueltos: s.nReturned,
    tiempo_ms: s.executionTimeMillis,
  };
}

// ---------------------------------------------------------------------
// Indice 1: trm_raw.vigenciadesde
// Consulta frecuente: "TRM vigente en una fecha" = la ultima publicacion
// con vigenciadesde <= fecha. Sin indice se recorre y ordena toda la
// coleccion; con el indice se lee una sola entrada en orden descendente.
// Es unico: la API publica una TRM por fecha de inicio de vigencia.
// ---------------------------------------------------------------------
const consultaTrm = (proyeccion = {}) =>
  db.trm_raw.find({ vigenciadesde: { $lte: "2026-03-15T00:00:00.000" } }, proyeccion)
            .sort({ vigenciadesde: -1 }).limit(1);

db.trm_raw.dropIndexes();
print("\n=== INDICE 1 - trm_raw: TRM vigente al 2026-03-15 ===");
print("ANTES (sin indice):");
printjson(resumen(consultaTrm().explain("executionStats")));

db.trm_raw.createIndex({ vigenciadesde: 1 }, { name: "ix_trm_vigencia", unique: true });
print("DESPUES (indice { vigenciadesde: 1 }):");
printjson(resumen(consultaTrm().explain("executionStats")));
print("Resultado:");
printjson(consultaTrm({ _id: 0, valor: 1, vigenciadesde: 1, vigenciahasta: 1 }).toArray());

// ---------------------------------------------------------------------
// Indice 2: mercado_activos { "info.sector": 1, tipo: 1 }
// Consulta del asesor: "acciones de un sector" para diversificar. El
// campo sector solo existe en las fichas de acciones (los ETF no lo
// traen): es un dato semiestructurado que el indice cubre igual.
// ---------------------------------------------------------------------
const consultaSector = () =>
  db.mercado_activos.find({ "info.sector": "Technology", tipo: "ACCION" },
                          { ticker: 1, nombre: 1, "info.industry": 1 });

db.mercado_activos.dropIndexes();
print("\n=== INDICE 2 - mercado_activos: acciones del sector Technology ===");
print("ANTES (sin indice):");
printjson(resumen(consultaSector().explain("executionStats")));

db.mercado_activos.createIndex({ "info.sector": 1, tipo: 1 }, { name: "ix_sector_tipo" });
print("DESPUES (indice { info.sector: 1, tipo: 1 }):");
printjson(resumen(consultaSector().explain("executionStats")));
print("Resultado:");
printjson(consultaSector().toArray());

print("\n=== Indices definidos ===");
printjson(db.mercado_activos.getIndexes().map(i => ({ coleccion: "mercado_activos", nombre: i.name, clave: i.key })));
printjson(db.trm_raw.getIndexes().map(i => ({ coleccion: "trm_raw", nombre: i.name, clave: i.key })));
