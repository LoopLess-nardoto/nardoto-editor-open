// Prova de exatidao e de tempo do export de motion ao vivo, pelo editor de desenvolvimento (MCP):
// projeto vazio -> add_motion -> export 1080p30 -> le de volta, de dentro do MP4, o numero que cada
// quadro pintou em cor (composicao carimbo-44s) e compara com a posicao do quadro.
// Uso: node motion-host/teste-exatidao.mjs <pasta-da-composicao> <saida.mp4> [--sem-conferir]
import { execFileSync } from "node:child_process";
import path from "node:path";
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const [comp, mp4] = process.argv.slice(2);
const conferir = !process.argv.includes("--sem-conferir");
const ffmpeg = path.join(path.dirname(new URL(import.meta.url).pathname.slice(1)), "..", ".tools", "deps", "ffmpeg", "bin", "ffmpeg.exe");

const c = new NardotoMcpStdioClient();
await c.connect();
let exportSeg = 0, mensagem = "";
try {
  await c.call("apply", { ops: [{ tool: "new_project" }] });
  await c.call("apply", { ops: [{ tool: "add_motion", args: { path: comp, at: 0 } }] });
  const t0 = Date.now();
  await c.call("apply", { ops: [{ tool: "export_video", args: { path: mp4, fps: 30, height: 1080 } }] });
  while (true) {
    await new Promise((r) => setTimeout(r, 500));
    const s = (await c.call("apply", { ops: [{ tool: "export_status" }] })).done[0].result;
    if (s.busy === false) { mensagem = s.message || ""; break; }
  }
  exportSeg = (Date.now() - t0) / 1000;
} finally {
  await c.close();
}
console.log(`export: ${exportSeg.toFixed(1)} s (${((exportSeg / 44) * 100).toFixed(0)}% do video) ${mensagem}`);

if (conferir) {
  // amostra 64x36 do centro-baixo (longe do numero escrito), um quadro de cada vez
  const raw = execFileSync(ffmpeg, ["-v", "error", "-i", mp4, "-vf", "crop=640:360:1200:640,scale=64:36", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"],
    { maxBuffer: 1 << 30 });
  const tam = 64 * 36 * 3;
  const n = raw.length / tam;
  let erros = 0, primeiros = [];
  for (let q = 0; q < n; q++) {
    let r = 0, g = 0, b = 0;
    for (let p = q * tam; p < (q + 1) * tam; p += 3) { r += raw[p]; g += raw[p + 1]; b += raw[p + 2]; }
    const px = tam / 3;
    const nib = (v) => Math.max(0, Math.min(15, Math.round((v / px - 8) / 16)));
    const lido = nib(r) | (nib(g) << 4) | (nib(b) << 8);
    if (lido !== (q & 0xfff)) { erros++; if (primeiros.length < 10) primeiros.push(`quadro ${q} trouxe ${lido}`); }
  }
  console.log(`quadros no MP4: ${n}, errados: ${erros}`);
  if (primeiros.length) console.log(primeiros.join("\n"));
}
