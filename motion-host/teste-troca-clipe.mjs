// Testa replace_clip_media pela ponte de agentes: projeto novo com um clipe, troca o arquivo e
// confere que o clipe manteve início e duração e passou a apontar para o arquivo novo.
// Uso: node motion-host/teste-troca-clipe.mjs <video-original> <video-novo>
import { NardotoMcpStdioClient } from "../scripts/lib/nardoto-mcp-stdio.mjs";

const [original, novo] = process.argv.slice(2);
const c = new NardotoMcpStdioClient();
await c.connect();
const um = async (tool, args) => {
  const r = await c.call("apply", { ops: [{ tool, args }] });
  const feito = r.done && r.done[0];
  if (!feito || feito.result?.ok === false || r.ok === false) throw new Error(`${tool}: ${JSON.stringify(r).slice(0, 300)}`);
  return feito.result;
};
const clipe = async () => {
  const r = await c.call("inspect", { clips: true });
  for (const t of r.tracks || []) for (const k of t.items || []) if (k.kind === "video" || k.kind === "image") return k;
  return null;
};
try {
  await um("new_project");
  const imp = await um("import_media", { paths: [original] });
  await um("place_clip", { asset: imp.assets[0].id, at: 2 });
  const antes = await clipe();
  console.log("antes:", antes.id, antes.name, "início", antes.start, "duração", antes.duration);
  await um("replace_clip_media", { clip: antes.id, path: novo });
  const depois = await clipe();
  console.log("depois:", depois.id, depois.name, "início", depois.start, "duração", depois.duration);
  const igual = Math.abs(antes.start - depois.start) < 0.01 && Math.abs(antes.duration - depois.duration) < 0.01;
  console.log(igual && depois.name !== antes.name ? "OK: mesmo lugar e duração, arquivo trocado" : "FALHOU");
  await um("undo");
  const desfeito = await clipe();
  console.log("Ctrl+Z:", desfeito.name, desfeito.name === antes.name ? "(voltou ao original)" : "(NÃO voltou)");
} finally {
  await c.close();
}
