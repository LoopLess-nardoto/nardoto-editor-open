// Monta e assina um extra (.driftpkg) da loja do Nardoto Editor, no formato que
// src/engine/AddonPackage.cpp le:
//   "DRIFTPKG" | u32 versao=1 | u32 tamanho dos metadados | metadados JSON
//   | u64 payload comprimido | u64 payload bruto | payload zstd (arquivos em sequencia)
//   | sha256 de tudo acima | assinatura Ed25519 do sha256
// A pasta do extra tem um addon.json (id, version, name, description, author, license,
// provides [{kind, root, items}], platform opcional) e os arquivos.
// Uso: node scripts/loja/empacotar.mjs <pasta-do-extra> <saida-dir> [--url-base <url>]
// Imprime a entrada do indice (index.json) para colar na loja.
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";

const [pasta, saidaDir] = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const iUrl = process.argv.indexOf("--url-base");
const urlBase = iUrl > 0 ? process.argv[iUrl + 1].replace(/\/$/, "") : "";
if (!pasta || !saidaDir) {
  console.error("Uso: node scripts/loja/empacotar.mjs <pasta-do-extra> <saida-dir> [--url-base <url>]");
  process.exit(1);
}

const chaveArq = process.env.NARDOTO_ADDON_KEY || path.join(os.homedir(), ".config", "nardoto", "addon-signing.key");
if (!fs.existsSync(chaveArq)) {
  console.error(`Chave de assinatura não encontrada em ${chaveArq}. Rode scripts/loja/gerar-chave.mjs.`);
  process.exit(1);
}
const chave = crypto.createPrivateKey(fs.readFileSync(chaveArq));

const meta = JSON.parse(fs.readFileSync(path.join(pasta, "addon.json"), "utf8"));
for (const campo of ["id", "version", "name", "provides"])
  if (!meta[campo]) throw new Error(`addon.json sem "${campo}"`);

// Arquivos em ordem fixa, caminhos com "/" (o Editor recusa "\" e ":").
const arquivos = [];
const andar = (dir) => {
  for (const nome of fs.readdirSync(dir).sort()) {
    const p = path.join(dir, nome);
    if (fs.statSync(p).isDirectory()) andar(p);
    else if (path.relative(pasta, p) !== "addon.json") arquivos.push(p);
  }
};
andar(pasta);

let offset = 0;
const tabela = [];
const partes = [];
for (const p of arquivos) {
  const dados = fs.readFileSync(p);
  tabela.push({ path: path.relative(pasta, p).split(path.sep).join("/"), offset, size: dados.length,
    sha256: crypto.createHash("sha256").update(dados).digest("hex") });
  partes.push(dados);
  offset += dados.length;
}
const bruto = Buffer.concat(partes);
const comprimido = zlib.zstdCompressSync(bruto, { params: { [zlib.constants.ZSTD_c_compressionLevel]: 19 } });

const metadados = Buffer.from(JSON.stringify({ schema: 1, ...meta, installedSize: bruto.length, files: tabela }), "utf8");
const cabecalho = Buffer.alloc(16);
cabecalho.write("DRIFTPKG", 0, "latin1");
cabecalho.writeUInt32LE(1, 8);
cabecalho.writeUInt32LE(metadados.length, 12);
const tamanhos = Buffer.alloc(16);
tamanhos.writeBigUInt64LE(BigInt(comprimido.length), 0);
tamanhos.writeBigUInt64LE(BigInt(bruto.length), 8);

const digest = crypto.createHash("sha256").update(cabecalho).update(metadados).update(tamanhos).update(comprimido).digest();
const assinatura = crypto.sign(null, digest, chave);

fs.mkdirSync(saidaDir, { recursive: true });
const nome = `${meta.id}-${meta.version}${meta.platform ? "-" + meta.platform : ""}.driftpkg`;
const saida = path.join(saidaDir, nome);
fs.writeFileSync(saida, Buffer.concat([cabecalho, metadados, tamanhos, comprimido, digest, assinatura]));
const tamanho = fs.statSync(saida).size;

const entrada = {
  id: meta.id, version: meta.version, name: meta.name, description: meta.description || "",
  details: meta.details || "", author: meta.author || "Nardoto", license: meta.license || "",
  kind: meta.provides[0].kind, provides: meta.provides,
  ...(meta.platform ? { platforms: [meta.platform] } : {}),
  downloadSize: tamanho, installedSize: bruto.length,
  url: urlBase ? `${urlBase}/${nome}` : nome,
};
console.error(`${nome}: ${arquivos.length} arquivos, ${(bruto.length / 1048576).toFixed(1)} MB -> ${(tamanho / 1048576).toFixed(1)} MB`);
console.log(JSON.stringify(entrada, null, 2));
