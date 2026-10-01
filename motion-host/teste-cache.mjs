// Teste do cache em video: grava a composicao inteira e mede tempo e tamanho.
// Uso: node motion-host/teste-cache.mjs <pasta-da-composicao> [largura altura fps]
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
    else if (tipo === 1 && msg.evento !== "cache-progresso") console.log("evento:", msg);
  }
}
const esperar = (casa) => new Promise((ok) => esperas.push({ casa, ok }));
const mandar = (o) => sock.write(JSON.stringify(o) + "\n");

const [largura, altura, fps] = [Number(process.argv[3] || 1920), Number(process.argv[4] || 1080), Number(process.argv[5] || 30)];
const pronto = esperar((m) => m.evento === "pronto");
await conectou; await pronto;
const t0 = Date.now();
const fim = esperar((m) => m.evento === "cache-pronto" || m.evento === "cache-erro");
mandar({ cmd: "cache", pasta, largura, altura, fps });
const r = await fim;
const fs = await import("node:fs");
console.log(r.evento, `${((Date.now() - t0) / 1000).toFixed(1)} s`, r.arquivo || r.erro,
  r.arquivo ? `${(fs.statSync(r.arquivo).size / 1048576).toFixed(0)} MB` : "");
mandar({ cmd: "sair" });
setTimeout(() => process.exit(0), 500);
