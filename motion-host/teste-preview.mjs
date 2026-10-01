// Teste curto: projeto vazio -> add_motion -> captura do preview em alguns tempos. Sem export.
// Uso: node motion-host/teste-preview.mjs <pasta-da-composicao> <pasta-de-saida>
import fs from "node:fs";
import path from "node:path";
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const [comp, saida] = process.argv.slice(2);
fs.mkdirSync(saida, { recursive: true });
const c = new NardotoMcpStdioClient();
await c.connect();
try {
  await c.call("apply", { ops: [{ tool: "new_project" }] });
  const add = await c.call("apply", { ops: [{ tool: "add_motion", args: { path: comp, at: 0 } }] });
  console.log("add_motion:", JSON.stringify(add).slice(0, 200));
  for (const at of [2, 6, 12]) {
    const t0 = Date.now();
    const r = await c.call("capture", { at, full: true });
    console.log(`capture ${at}s (${Date.now() - t0} ms)`);
    if (r.path && fs.existsSync(r.path)) fs.copyFileSync(r.path, path.join(saida, `preview-${at}s.png`));
  }
} finally {
  await c.close();
}
