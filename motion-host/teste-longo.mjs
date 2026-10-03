// Teste de um video longo (5+ min) no editor de desenvolvimento (MCP): videos em sequencia,
// motions por cima em dois momentos, trilha de fundo e um efeito sonoro em cada corte.
// Espera o cache dos motions e exporta, medindo o tempo.
// Uso: node motion-host/teste-longo.mjs <manifesto.json> <saida.mp4> <motion.html> [...]   (NMH_CODEC=h264_nvenc)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const [manifestoArq, mp4, ...motions] = process.argv.slice(2);
const m = JSON.parse(fs.readFileSync(manifestoArq, "utf8"));
const diario = path.join(os.tmpdir(), "nardoto-motion.log");
const inicioDiario = fs.existsSync(diario) ? fs.statSync(diario).size : 0;

const c = new NardotoMcpStdioClient();
await c.connect();
const um = async (tool, args) => {
  const r = (await c.call("apply", { ops: [{ tool, args }] }));
  if (!r.done || !r.done[0]) throw new Error(`${tool}: ${JSON.stringify(r).slice(0, 300)}`);
  return r.done[0].result;
};
const importar = async (arquivos) => (await um("import_media", { paths: arquivos })).assets;

try {
  await um("new_project");

  // videos em sequencia, com os motions intercalados (tambem em sequencia, nao por cima)
  const videos = await importar(m.videos.map((v) => v.arquivo));
  const passo = Math.ceil(videos.length / (motions.length + 1));
  let cursor = 0;
  const cortes = [];
  let mi = 0;
  for (let i = 0; i < videos.length; i++) {
    await um("place_clip", { asset: videos[i].id, at: cursor });
    cursor += videos[i].dur;
    cortes.push(cursor);
    if ((i + 1) % passo === 0 && mi < motions.length) {
      const r = await um("add_motion", { path: motions[mi], at: cursor });
      const d = r.duration || 44;
      console.log(`motion ${path.basename(path.dirname(motions[mi]))} em ${cursor.toFixed(1)} s (${d} s)`);
      cursor += d;
      cortes.push(cursor);
      mi++;
    }
  }
  const total = cursor;
  console.log(`videos: ${videos.length} + ${mi} motions, ${total.toFixed(1)} s`);

  // trilha de fundo e um efeito sonoro em cada corte (alternando entre os efeitos)
  const [trilha] = await importar([m.trilha]);
  await um("place_clip", { asset: trilha.id, at: 0, new_track: true });
  const sfx = await importar(m.sfx.map((s) => s.arquivo));
  let primeiro = true;
  let sfxCount = 0;
  for (let i = 0; i < cortes.length - 1; i++) {
    const a = sfx[i % sfx.length];
    const at = Math.max(0, cortes[i] - Math.min(0.4, a.dur / 2));
    await um("place_clip", { asset: a.id, at, ...(primeiro ? { new_track: true } : {}) });
    primeiro = false;
    sfxCount++;
  }
  console.log(`trilha + ${sfxCount} efeitos sonoros`);

  // espera o cache de cada motion (o editor grava em segundo plano)
  const t0 = Date.now();
  const prontos = () => {
    const novo = fs.readFileSync(diario, "utf8").slice(inicioDiario).replaceAll("\\", "/");
    return motions.filter((p) => novo.includes(`cache pronto: ${p.replaceAll("\\", "/")}|`));
  };
  while (prontos().length < motions.length && Date.now() - t0 < 600000) await new Promise((r) => setTimeout(r, 1000));
  console.log(`cache: ${prontos().length}/${motions.length} prontos em ${((Date.now() - t0) / 1000).toFixed(1)} s`);

  const t1 = Date.now();
  await um("export_video", { path: mp4, fps: 30, height: 1080, ...(process.env.NMH_CODEC ? { video: process.env.NMH_CODEC } : {}) });
  let msg = "";
  while (true) {
    await new Promise((r) => setTimeout(r, 1000));
    const s = await um("export_status");
    if (s.busy === false) { msg = s.message || ""; break; }
  }
  const seg = (Date.now() - t1) / 1000;
  console.log(`export: ${total.toFixed(1)} s de video em ${seg.toFixed(1)} s (${((seg / total) * 100).toFixed(0)}%) ${msg}`);
} finally {
  await c.close();
}
