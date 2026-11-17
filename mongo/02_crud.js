// =====================================================================
// mongo/02_crud.js   (mongosh portafolios_nosql --file mongo/02_crud.js)
// Operaciones CRUD sobre la coleccion mercado_activos.
// Caso de uso: el equipo de analisis registra un activo EN EVALUACION
// (aun no habilitado para los clientes, por eso no existe en PostgreSQL)
// con una ficha propia, distinta de las que trae la API.
// =====================================================================
db = db.getSiblingDB("portafolios_nosql");
const col = db.mercado_activos;
col.deleteOne({ _id: "NVDA" });   // permite re-ejecutar el script

// ------------------------------- CREATE ------------------------------
print("\n=== CREATE: insertOne de un activo en evaluacion ===");
printjson(col.insertOne({
  _id: "NVDA",
  ticker: "NVDA",
  nombre: "NVIDIA Corporation",
  tipo: "ACCION",
  mercado: "NASDAQ",
  fuente: "registro manual del comite de inversiones",
  descargado_en: new Date(),
  estado: "EN_EVALUACION",                   // campo que no tienen los demas
  info: {
    sector: "Technology",
    industry: "Semiconductors",
    analisis: {                              // subdocumento propio del analista
      analista: "Comite de inversiones",
      perfiles_sugeridos: ["AGRESIVO"],
      riesgos: ["alta volatilidad", "concentracion sectorial"],
    },
  },
  historia: [],                              // sin precios aun
}));

// -------------------------------- READ -------------------------------
print("\n=== READ 1: fondos indexados (proyeccion de campos) ===");
printjson(col.find({ tipo: "FONDO" }, { _id: 0, ticker: 1, nombre: 1, mercado: 1 }).toArray());

print("\n=== READ 2: ultimos 3 cierres de AAPL ($slice sobre el arreglo embebido) ===");
printjson(col.find({ _id: "AAPL" }, { _id: 0, ticker: 1, historia: { $slice: -3 } }).toArray());

print("\n=== READ 3: activos cuya ficha trae el campo dividendYield ($exists) ===");
printjson(col.find({ "info.dividendYield": { $exists: true } },
                   { _id: 0, ticker: 1, "info.dividendYield": 1 }).toArray());

print("\n=== READ 4: el activo en evaluacion ===");
printjson(col.findOne({ estado: "EN_EVALUACION" }, { historia: 0 }));

// ------------------------------- UPDATE ------------------------------
print("\n=== UPDATE 1: se aprueba el activo y se registra su primer cierre ===");
printjson(col.updateOne(
  { _id: "NVDA" },
  {
    $set: { estado: "APROBADO", "info.analisis.perfiles_sugeridos": ["MODERADO", "AGRESIVO"] },
    $push: { historia: { fecha: new Date(), cierre: null, nota: "precio pendiente de la siguiente carga" } },
    $currentDate: { actualizado_en: true },
  }
));
printjson(col.findOne({ _id: "NVDA" }, { _id: 0, estado: 1, "info.analisis": 1, historia: 1, actualizado_en: 1 }));

print("\n=== UPDATE 2: updateMany agrega una etiqueta a todos los fondos ===");
printjson(col.updateMany({ tipo: "FONDO" }, { $addToSet: { etiquetas: "indexado" } }));
printjson(col.find({ etiquetas: "indexado" }, { _id: 0, ticker: 1, etiquetas: 1 }).toArray());

// ------------------------------- DELETE ------------------------------
print("\n=== DELETE: el comite descarta el activo ===");
printjson(col.deleteOne({ _id: "NVDA" }));
print("Documentos con estado definido despues del borrado: " + col.countDocuments({ estado: { $exists: true } }));
printjson(col.updateMany({}, { $unset: { etiquetas: "" } }));   // deja la coleccion como estaba
print("Total de documentos en mercado_activos: " + col.countDocuments());
