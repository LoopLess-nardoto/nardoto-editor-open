// Teste ponta a ponta do motion ao vivo no editor de desenvolvimento (build-dev), pelo MCP stdio:
// projeto vazio -> add_motion -> captura do preview em varios tempos -> export de um trecho.
// Uso: node motion-host/teste-editor.mjs <pasta-da-composicao> <pasta-de-saida>
import fs from "node:fs";
import path from "node:path";
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const [comp, saida] = process.argv.slice(2);
fs.mkdirSync(saida, { recursive: true });
const c = new NardotoMcpStdioClient();
await c.connect();
const passo = async (nome, tool, args) => {
  const t0 = Date.now();
  const r = await c.call(tool, args);
  console.log(`${nome} (${Date.now() - t0} ms):`, JSON.stringify(r).slice(0, 300));
  return r;
};

try {
  await passo("novo projeto", "apply", { ops: [{ tool: "new_project" }] });
  const add = await passo("add_motion", "apply", { ops: [{ tool: "add_motion", args: { path: comp, at: 0 } }] });
  if (!add.ok) throw new Error("add_motion falhou");
  await passo("inspect", "inspect", { clips: true });

  for (const at of [0.5, 2, 6, 12, 20]) {
    const r = await passo(`capture ${at}s`, "capture", { at, full: true });
    const p = r.path || r.full;
    if (p && fs.existsSync(p)) fs.copyFileSync(p, path.join(saida, `preview-${at}s.png`));
  }

  const mp4 = path.join(saida, "trecho.mp4");
  const exp = await passo("export", "apply", {
    ops: [{ tool: "export_video", args: { path: mp4, work_area: true, in: 0, out: 3, fps: 30, height: Number(process.env.ALTURA || 540) } }],
  });
  const t0 = Date.now();
  while (Date.now() - t0 < 300000) {
    await new Promise((r) => setTimeout(r, 2000));
    const s = await c.call("apply", { ops: [{ tool: "export_status" }] });
    const st = s.done?.[0]?.result ?? s;
    process.stdout.write(`\rexport: ${JSON.stringify(st).slice(0, 160)}   `);
    if (st.busy === false) break;
  }
  console.log("\nexport em", (Date.now() - t0) / 1000, "s ->", exp.done?.[0]?.path || mp4);
} finally {
  await c.close();
}
