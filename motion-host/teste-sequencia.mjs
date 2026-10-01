// Export de varias composicoes em sequencia pelo editor de desenvolvimento (MCP), ao vivo ou
// lendo o cache em video de cada uma. Mede o tempo do export.
// Uso: node motion-host/teste-sequencia.mjs <saida.mp4> <ao-vivo|cache> <pasta-ou-mov> [...]
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const [mp4, modo, ...itens] = process.argv.slice(2);
const c = new NardotoMcpStdioClient();
await c.connect();
const um = async (tool, args) => (await c.call("apply", { ops: [{ tool, args }] })).done[0].result;
let seg = 0, msg = "", dur = 0;
try {
  await um("new_project");
  if (modo === "cache") {
    const r = await um("import_media", { paths: itens });
    for (const a of r.assets) { await um("place_clip", { asset: a.id, at: dur }); dur += a.dur; }
  } else {
    for (const p of itens) { const r = await um("add_motion", { path: p, at: dur }); dur += r.duration || 44; }
  }
  const t0 = Date.now();
  await um("export_video", { path: mp4, fps: 30, height: 1080, ...(process.env.NMH_CODEC ? { video: process.env.NMH_CODEC } : {}) });
  while (true) {
    await new Promise((r) => setTimeout(r, 500));
    const s = await um("export_status");
    if (s.busy === false) { msg = s.message || ""; break; }
  }
  seg = (Date.now() - t0) / 1000;
} finally {
  await c.close();
}
console.log(`${modo}: ${itens.length} itens, ${dur.toFixed(1)} s de video, export ${seg.toFixed(1)} s (${((seg / dur) * 100).toFixed(0)}%) ${msg}`);
