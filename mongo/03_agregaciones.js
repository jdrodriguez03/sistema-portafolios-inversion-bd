// mongo/03_agregaciones.js
// Agregaciones sobre la coleccion mercado_activos.
db = db.getSiblingDB("portafolios_nosql");

// AGREGACION 1: precio promedio, minimo y maximo de cada activo desde junio de 2026
print("\n=== AGREGACION 1: precios de cada activo desde junio de 2026 ===");
printjson(db.mercado_activos.aggregate([
  { $unwind: "$historia" },
  { $match: { "historia.fecha": { $gte: new Date("2026-06-01") } } },
  { $group: {
      _id: "$ticker",
      precio_promedio: { $avg: "$historia.cierre" },
      precio_minimo: { $min: "$historia.cierre" },
      precio_maximo: { $max: "$historia.cierre" },
      dias: { $sum: 1 } } },
  { $sort: { precio_promedio: -1 } }
]).toArray());

// AGREGACION 2: total de dividendos pagados por cada activo (Regla 8)
print("\n=== AGREGACION 2: dividendos por activo ===");
printjson(db.mercado_activos.aggregate([
  { $unwind: "$historia" },
  { $match: { "historia.dividendo": { $gt: 0 } } },
  { $group: {
      _id: "$ticker",
      pagos: { $sum: 1 },
      total_dividendos_usd: { $sum: "$historia.dividendo" } } },
  { $sort: { total_dividendos_usd: -1 } }
]).toArray());

// AGREGACION 3: numero de acciones por sector (apoyo a la diversificacion, P3)
print("\n=== AGREGACION 3: acciones por sector ===");
printjson(db.mercado_activos.aggregate([
  { $match: { tipo: "ACCION" } },
  { $group: {
      _id: "$info.sector",
      acciones: { $sum: 1 },
      tickers: { $push: "$ticker" } } },
  { $sort: { acciones: -1 } }
]).toArray());
