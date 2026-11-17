// =====================================================================
// mongo/03_agregaciones.js   (mongosh portafolios_nosql --file mongo/03_agregaciones.js)
// Agregaciones que responden preguntas del proyecto.
// =====================================================================
db = db.getSiblingDB("portafolios_nosql");
const hace6m = new Date(); hace6m.setMonth(hace6m.getMonth() - 6);
const hace12m = new Date(); hace12m.setMonth(hace12m.getMonth() - 12);

// ---------------------------------------------------------------------
// AGREGACION 1 (apoyo a P2 y P6: rentabilidad)
// Rendimiento y volatilidad de cada accion/fondo en los ultimos 6 meses.
// Recorre el historial embebido: $unwind lo convierte en un documento
// por dia; $sort + $first/$last toman el primer y el ultimo cierre.
// Volatilidad = desviacion estandar de los cierres / promedio.
// ---------------------------------------------------------------------
print("\n=== AGREGACION 1: rendimiento y volatilidad, ultimos 6 meses ===");
printjson(db.mercado_activos.aggregate([
  { $match: { "historia.0": { $exists: true } } },
  { $unwind: "$historia" },
  { $match: { "historia.fecha": { $gte: hace6m }, "historia.cierre": { $gt: 0 } } },
  { $sort: { ticker: 1, "historia.fecha": 1 } },
  { $group: {
      _id: "$ticker",
      tipo: { $first: "$tipo" },
      cierre_inicial: { $first: "$historia.cierre" },
      cierre_final: { $last: "$historia.cierre" },
      minimo: { $min: "$historia.cierre" },
      maximo: { $max: "$historia.cierre" },
      promedio: { $avg: "$historia.cierre" },
      desviacion: { $stdDevSamp: "$historia.cierre" },
      dias: { $sum: 1 } } },
  { $project: {
      _id: 0, ticker: "$_id", tipo: 1, dias: 1,
      cierre_inicial: { $round: ["$cierre_inicial", 2] },
      cierre_final: { $round: ["$cierre_final", 2] },
      minimo: { $round: ["$minimo", 2] },
      maximo: { $round: ["$maximo", 2] },
      rendimiento_pct: { $round: [{ $multiply: [{ $subtract: [{ $divide: ["$cierre_final", "$cierre_inicial"] }, 1] }, 100] }, 2] },
      volatilidad_pct: { $round: [{ $multiply: [{ $divide: ["$desviacion", "$promedio"] }, 100] }, 2] } } },
  { $sort: { rendimiento_pct: -1 } },
]).toArray());

// ---------------------------------------------------------------------
// AGREGACION 2 (apoyo a la Regla 8 y a P2: rendimientos)
// Dividendos pagados por accion/fondo, por anio, y rendimiento por
// dividendo (dividendos del anio / precio promedio del anio).
// ---------------------------------------------------------------------
print("\n=== AGREGACION 2: dividendos por activo y anio ===");
printjson(db.mercado_activos.aggregate([
  { $unwind: "$historia" },
  { $group: {
      _id: { ticker: "$ticker", anio: { $year: "$historia.fecha" } },
      dividendos_usd: { $sum: { $ifNull: ["$historia.dividendo", 0] } },
      pagos: { $sum: { $cond: [{ $gt: [{ $ifNull: ["$historia.dividendo", 0] }, 0] }, 1, 0] } },
      precio_promedio: { $avg: "$historia.cierre" } } },
  { $match: { pagos: { $gt: 0 } } },
  { $project: {
      _id: 0, ticker: "$_id.ticker", anio: "$_id.anio", pagos: 1,
      dividendos_por_unidad_usd: { $round: ["$dividendos_usd", 4] },
      rendimiento_dividendo_pct: { $round: [{ $multiply: [{ $divide: ["$dividendos_usd", "$precio_promedio"] }, 100] }, 2] } } },
  { $sort: { ticker: 1, anio: 1 } },
]).toArray());

// ---------------------------------------------------------------------
// AGREGACION 3 (apoyo a P3: diversificacion)
// Agrupa el universo de activos por sector usando la ficha semiestructurada
// de la API. Los ETF no traen "sector": $ifNull los clasifica aparte.
// ---------------------------------------------------------------------
print("\n=== AGREGACION 3: universo de activos por sector ===");
printjson(db.mercado_activos.aggregate([
  { $group: {
      _id: { $ifNull: ["$info.sector",
              { $cond: [{ $eq: ["$tipo", "FONDO"] }, "Fondo indexado (diversificado)", "Sin dato de sector"] }] },
      activos: { $sum: 1 },
      tickers: { $push: "$ticker" },
      capitalizacion_usd: { $sum: { $ifNull: ["$info.marketCap", { $ifNull: ["$info.totalAssets", 0] }] } } } },
  { $project: { _id: 0, sector: "$_id", activos: 1, tickers: 1,
                capitalizacion_miles_millones_usd: { $round: [{ $divide: ["$capitalizacion_usd", 1e9] }, 1] } } },
  { $sort: { activos: -1, sector: 1 } },
]).toArray());

// ---------------------------------------------------------------------
// AGREGACION 4 (apoyo a la Regla 13: conversion COP/USD)
// TRM mensual de los ultimos 12 meses a partir de los datos crudos de la
// API: los valores llegan como texto y se convierten dentro del pipeline.
// ---------------------------------------------------------------------
print("\n=== AGREGACION 4: TRM mensual (ultimos 12 meses) ===");
printjson(db.trm_raw.aggregate([
  { $addFields: { fecha: { $toDate: "$vigenciadesde" }, valor_num: { $toDouble: "$valor" } } },
  { $match: { fecha: { $gte: hace12m } } },
  { $group: {
      _id: { $dateToString: { format: "%Y-%m", date: "$fecha" } },
      trm_promedio: { $avg: "$valor_num" },
      trm_minima: { $min: "$valor_num" },
      trm_maxima: { $max: "$valor_num" },
      publicaciones: { $sum: 1 } } },
  { $project: { _id: 0, mes: "$_id", publicaciones: 1,
                trm_promedio: { $round: ["$trm_promedio", 2] },
                trm_minima: 1, trm_maxima: 1 } },
  { $sort: { mes: 1 } },
]).toArray());
