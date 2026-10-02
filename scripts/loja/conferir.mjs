// Confere um .driftpkg como o Editor faz ao instalar (AddonPackage.cpp): formato, hash de cada
// arquivo, digest e assinatura com a chave publica do Editor (src/engine/AddonSigningKey.h).
// Com <destino>, extrai os arquivos ali, como a instalacao faria.
// Uso: node scripts/loja/conferir.mjs <pacote.driftpkg> [destino]
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const [pacote, destino] = process.argv.slice(2);
const aqui = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"));
const h = fs.readFileSync(path.join(aqui, "..", "..", "src", "engine", "AddonSigningKey.h"), "utf8");
const bytes = [...h.slice(h.indexOf("{")).matchAll(/0x([0-9a-f]{2})/gi)].map((m) => parseInt(m[1], 16));
const publica = crypto.createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(bytes).toString("base64url") }, format: "jwk" });

const b = fs.readFileSync(pacote);
if (b.subarray(0, 8).toString("latin1") !== "DRIFTPKG") throw new Error("magic errado");
if (b.readUInt32LE(8) !== 1) throw new Error("versão de formato inesperada");
const nMeta = b.readUInt32LE(12);
const meta = JSON.parse(b.subarray(16, 16 + nMeta).toString("utf8"));
let pos = 16 + nMeta;
const comp = Number(b.readBigUInt64LE(pos)), bruto = Number(b.readBigUInt64LE(pos + 8));
pos += 16;
const payload = b.subarray(pos, pos + comp);
const digest = b.subarray(pos + comp, pos + comp + 32);
const assinatura = b.subarray(pos + comp + 32);
if (assinatura.length !== 64) throw new Error("tamanho do arquivo não fecha com a assinatura");

const calc = crypto.createHash("sha256").update(b.subarray(0, pos + comp)).digest();
if (!calc.equals(digest)) throw new Error("digest não confere");
if (!crypto.verify(null, digest, publica, assinatura)) throw new Error("assinatura NÃO confere com a chave do Editor");

const dados = zlib.zstdDecompressSync(payload);
if (dados.length !== bruto) throw new Error("tamanho descompactado errado");
let esperado = 0;
for (const f of meta.files) {
  if (f.offset !== esperado) throw new Error(`tabela não contígua em ${f.path}`);
  const pedaco = dados.subarray(f.offset, f.offset + f.size);
  if (crypto.createHash("sha256").update(pedaco).digest("hex") !== f.sha256) throw new Error(`hash errado em ${f.path}`);
  if (destino) {
    const alvo = path.join(destino, ...f.path.split("/"));
    fs.mkdirSync(path.dirname(alvo), { recursive: true });
    fs.writeFileSync(alvo, pedaco);
  }
  esperado += f.size;
}
console.log(`OK: ${meta.id} ${meta.version}, ${meta.files.length} arquivos, assinatura válida para esta versão do Editor`);
