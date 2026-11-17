// mongo/01_indices.js
// Indices de la base portafolios_nosql: se compara la consulta antes y despues de crearlos.
db = db.getSiblingDB("portafolios_nosql");

// ---------------------------------------------------------------------
// Indice 1: trm_raw por fecha de inicio de vigencia
// Consulta: la TRM vigente el 15 de marzo de 2026
// ---------------------------------------------------------------------
db.trm_raw.dropIndexes();

print("\n=== INDICE 1: trm_raw { vigenciadesde: 1 } ===");
let plan = db.trm_raw.find({ vigenciadesde: { $lte: "2026-03-15T00:00:00.000" } })
                     .sort({ vigenciadesde: -1 }).limit(1)
                     .explain("executionStats");
print("ANTES   - documentos examinados: " + plan.executionStats.totalDocsExamined);

db.trm_raw.createIndex({ vigenciadesde: 1 });

plan = db.trm_raw.find({ vigenciadesde: { $lte: "2026-03-15T00:00:00.000" } })
                 .sort({ vigenciadesde: -1 }).limit(1)
                 .explain("executionStats");
print("DESPUES - documentos examinados: " + plan.executionStats.totalDocsExamined);

print("Resultado:");
printjson(db.trm_raw.find({ vigenciadesde: { $lte: "2026-03-15T00:00:00.000" } },
                          { _id: 0, valor: 1, vigenciadesde: 1, vigenciahasta: 1 })
                    .sort({ vigenciadesde: -1 }).limit(1).toArray());

// ---------------------------------------------------------------------
// Indice 2: mercado_activos por tipo de activo
// Consulta: los fondos indexados
// ---------------------------------------------------------------------
db.mercado_activos.dropIndexes();

print("\n=== INDICE 2: mercado_activos { tipo: 1 } ===");
plan = db.mercado_activos.find({ tipo: "FONDO" }, { ticker: 1 }).explain("executionStats");
print("ANTES   - documentos examinados: " + plan.executionStats.totalDocsExamined);

db.mercado_activos.createIndex({ tipo: 1 });

plan = db.mercado_activos.find({ tipo: "FONDO" }, { ticker: 1 }).explain("executionStats");
print("DESPUES - documentos examinados: " + plan.executionStats.totalDocsExamined);

print("\n=== Indices creados ===");
printjson(db.trm_raw.getIndexes());
printjson(db.mercado_activos.getIndexes());
