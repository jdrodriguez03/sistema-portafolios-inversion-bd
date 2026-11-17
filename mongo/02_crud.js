// mongo/02_crud.js
// Operaciones CRUD sobre la coleccion mercado_activos.
db = db.getSiblingDB("portafolios_nosql");
db.mercado_activos.deleteOne({ _id: "NVDA" });   // permite volver a ejecutar el script

// CREATE: se registra un activo que el comite esta evaluando
print("\n=== CREATE ===");
printjson(db.mercado_activos.insertOne({
  _id: "NVDA",
  ticker: "NVDA",
  nombre: "NVIDIA Corporation",
  tipo: "ACCION",
  mercado: "NASDAQ",
  estado: "EN_EVALUACION",
  info: { sector: "Technology", industry: "Semiconductors" },
  historia: []
}));

// READ: consultas con filtro y proyeccion
print("\n=== READ 1: fondos indexados ===");
printjson(db.mercado_activos.find({ tipo: "FONDO" }, { _id: 0, ticker: 1, nombre: 1 }).toArray());

print("\n=== READ 2: acciones del sector tecnologia ===");
printjson(db.mercado_activos.find({ "info.sector": "Technology" }, { _id: 0, ticker: 1, nombre: 1 }).toArray());

print("\n=== READ 3: el activo en evaluacion ===");
printjson(db.mercado_activos.findOne({ _id: "NVDA" }));

// UPDATE: el activo se aprueba y se le agrega un precio
print("\n=== UPDATE ===");
printjson(db.mercado_activos.updateOne(
  { _id: "NVDA" },
  { $set: { estado: "APROBADO" },
    $push: { historia: { fecha: new Date("2026-11-16"), cierre: 0 } } }
));
printjson(db.mercado_activos.findOne({ _id: "NVDA" }, { _id: 0, ticker: 1, estado: 1, historia: 1 }));

// DELETE: el activo se descarta
print("\n=== DELETE ===");
printjson(db.mercado_activos.deleteOne({ _id: "NVDA" }));
print("Documentos en mercado_activos: " + db.mercado_activos.countDocuments());
