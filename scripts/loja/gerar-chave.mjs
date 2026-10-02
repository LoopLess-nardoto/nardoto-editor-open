// Gera o par de chaves Ed25519 da loja de extras do Nardoto Editor.
// A chave secreta fica FORA do repositorio (~/.config/nardoto/addon-signing.key) e nunca e
// publicada: quem tem ela consegue fazer o Editor instalar qualquer pacote. A publica vai para
// src/engine/AddonSigningKey.h (imprime o array pronto).
// Uso: node scripts/loja/gerar-chave.mjs [--forcar]
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const arquivo = path.join(os.homedir(), ".config", "nardoto", "addon-signing.key");
if (fs.existsSync(arquivo) && !process.argv.includes("--forcar")) {
  console.error(`Já existe uma chave em ${arquivo}. Trocar a chave invalida os pacotes já publicados;`);
  console.error("use --forcar só se for isso mesmo.");
  process.exit(1);
}

const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
fs.mkdirSync(path.dirname(arquivo), { recursive: true });
fs.writeFileSync(arquivo, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });

const bruta = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url");
const bytes = [...bruta].map((b) => "0x" + b.toString(16).padStart(2, "0"));
const linhas = [];
for (let i = 0; i < bytes.length; i += 11) linhas.push("    " + bytes.slice(i, i + 11).join(", ") + ",");
console.log(`Chave secreta: ${arquivo}  (guarde uma cópia num lugar seguro)\n`);
console.log("Chave pública para src/engine/AddonSigningKey.h:\n");
console.log(linhas.join("\n"));
