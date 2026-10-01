// Cache em video pelo editor de desenvolvimento (MCP): poe as composicoes em sequencia, espera o
// editor gravar o cache de cada uma (em segundo plano, como durante a edicao) e exporta.
// Uso: node motion-host/teste-cache-editor.mjs <saida.mp4> <index.html> [...] [--conferir]   (NMH_CODEC=h264_nvenc)
// --conferir: le de volta o numero que cada quadro da composicao carimbo-44s pintou em cor.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const conferir = process.argv.includes("--conferir");
const [mp4, ...pastas] = process.argv.slice(2).filter((a) => a !== "--conferir");
const diario = path.join(os.tmpdir(), "nardoto-motion.log");
const inicioDiario = process.env.NMH_CACHE_ANTIGO ? 0 : fs.existsSync(diario) ? fs.statSync(diario).size : 0;
const c = new NardotoMcpStdioClient();
await c.connect();
const um = async (tool, args) => (await c.call("apply", { ops: [{ tool, args }] })).done[0].result;
// pronto = o editor registrou o cache da composicao no diario desde o inicio do teste
const prontos = () => {
  const novo = fs.readFileSync(diario, "utf8").slice(inicioDiario).replaceAll("\\", "/");
  return pastas.filter((p) => novo.includes(`cache pronto: ${p.replaceAll("\\", "/")}|`));
};
try {
  await um("new_project");
  let dur = 0;
  for (const p of pastas) { const r = await um("add_motion", { path: p, at: dur }); dur += r.duration || 44; }
  const t0 = Date.now();
  while (prontos().length < pastas.length) await new Promise((r) => setTimeout(r, 1000));
  console.log(`cache: ${pastas.length} prontos em ${((Date.now() - t0) / 1000).toFixed(1)} s (em segundo plano)`);
  await new Promise((r) => setTimeout(r, 1500));
  const t1 = Date.now();
  await um("export_video", { path: mp4, fps: 30, height: 1080, ...(process.env.NMH_CODEC ? { video: process.env.NMH_CODEC } : {}) });
  let msg = "";
  while (true) {
    await new Promise((r) => setTimeout(r, 500));
    const s = await um("export_status");
    if (s.busy === false) { msg = s.message || ""; break; }
  }
  const seg = (Date.now() - t1) / 1000;
  console.log(`export: ${dur.toFixed(1)} s de video em ${seg.toFixed(1)} s (${((seg / dur) * 100).toFixed(0)}%) ${msg}`);
} finally {
  await c.close();
}

if (conferir) {
  const ffmpeg = path.join(path.dirname(new URL(import.meta.url).pathname.slice(1)), "..", ".tools", "deps", "ffmpeg", "bin", "ffmpeg.exe");
  const raw = execFileSync(ffmpeg, ["-v", "error", "-i", mp4, "-vf", "crop=640:360:1200:640,scale=64:36", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], { maxBuffer: 1 << 30 });
  const tam = 64 * 36 * 3, n = raw.length / tam, px = tam / 3;
  const nib = (v) => Math.max(0, Math.min(15, Math.round((v / px - 8) / 16)));
  let erros = 0; const primeiros = [];
  for (let q = 0; q < n; q++) {
    let r = 0, g = 0, b = 0;
    for (let p = q * tam; p < (q + 1) * tam; p += 3) { r += raw[p]; g += raw[p + 1]; b += raw[p + 2]; }
    const lido = nib(r) | (nib(g) << 4) | (nib(b) << 8);
    if (lido !== (q & 0xfff)) { erros++; if (primeiros.length < 10) primeiros.push(`quadro ${q} trouxe ${lido}`); }
  }
  console.log(`quadros no MP4: ${n}, errados: ${erros}`);
  if (primeiros.length) console.log(primeiros.join("\n"));
}
