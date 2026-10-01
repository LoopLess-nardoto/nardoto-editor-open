// Teste de bancada do motion-host: abre uma composicao, pede quadros e mede.
// Uso: node motion-host/teste.mjs <pasta-da-composicao> [escala]
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const aqui = path.dirname(fileURLToPath(import.meta.url));
const pasta = process.argv[2];
const escala = Number(process.argv[3] || 0.5);
const electron = process.env.NMH_ELECTRON ||
  createRequire(path.join(aqui, "..", "..", "package.json"))("electron");

const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;
const canal = process.platform === "win32" ? `\\\\.\\pipe\\nmh-teste-${process.pid}` : `/tmp/nmh-teste-${process.pid}.sock`;
let sock = null;
const conectou = new Promise((ok) => net.createServer((s) => { sock = s; ok(); s.on("data", receber); }).listen(canal));
spawn(electron, [path.join(aqui, "main.js"), `--canal=${canal}`], { env, stdio: ["ignore", "ignore", "inherit"] });

let buf = Buffer.alloc(0);
const esperas = [];
function receber(d) {
  buf = Buffer.concat([buf, d]);
  while (buf.length >= 16) {
    // O Electron no Windows solta "\r\n" no stdout ao iniciar: pula ate a marca.
    const m = buf.indexOf("NMH1");
    if (m < 0) { buf = buf.subarray(Math.max(0, buf.length - 3)); break; }
    if (m > 0) { buf = buf.subarray(m); continue; }
    const tipo = buf.readUInt32LE(4), n = buf.readUInt32LE(8);
    if (buf.length < 16 + n) break;
    const corpo = buf.subarray(16, 16 + n);
    buf = buf.subarray(16 + n);
    const msg = tipo === 1 ? JSON.parse(corpo.toString("utf8"))
      : { quadro: true, seq: corpo.readUInt32LE(0), w: corpo.readUInt32LE(4), h: corpo.readUInt32LE(8), px: corpo.subarray(24) };
    const i = esperas.findIndex((e) => e.casa(msg));
    if (i >= 0) esperas.splice(i, 1)[0].ok(msg);
    else if (tipo === 1) console.log("evento:", msg);
  }
}
const esperar = (casa) => new Promise((ok) => esperas.push({ casa, ok }));
const mandar = (o) => sock.write(JSON.stringify(o) + "\n");

const pronto = esperar((m) => m.evento === "pronto");
await conectou; console.log("conectou");
await pronto; console.log("pronto");
let t0 = Date.now();
mandar({ cmd: "abrir", id: "c1", pasta, escala });
const info = await esperar((m) => m.resposta === "abrir");
console.log("abrir:", Date.now() - t0, "ms", info);
if (!info.ok) process.exit(1);

const assinaturas = new Set();
const tempos = [];
const N = 60;
for (let i = 0; i < N; i++) {
  const t = (i / N) * info.duracao;
  t0 = Date.now();
  mandar({ cmd: "quadro", id: "c1", t, seq: i, exato: process.argv[4] === "exato" });
  const q = await esperar((m) => m.seq === i);
  if (!q.quadro) { console.log("falhou:", q); process.exit(1); }
  tempos.push(Date.now() - t0);
  let h = 0;
  for (let k = 0; k < q.px.length; k += 4093) h = (h * 31 + q.px[k]) | 0;
  assinaturas.add(h);
  if (i === 0) console.log("quadro:", q.w, "x", q.h, q.px.length, "bytes");
}
tempos.sort((a, b) => a - b);
console.log(`quadros: ${N}, distintos: ${assinaturas.size}, mediana ${tempos[N >> 1]} ms, p90 ${tempos[Math.floor(N * 0.9)]} ms, max ${tempos[N - 1]} ms`);
mandar({ cmd: "sair" });
setTimeout(() => process.exit(0), 500);
