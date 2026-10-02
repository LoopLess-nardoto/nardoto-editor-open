// Testa a sugestão de buscas por IA e o YouTube pelo servidor local do Studio (9879).
// Uso: node motion-host/teste-midias-yt.mjs "<fala>" "<contexto>" <pasta>
const [fala, contexto, pasta] = process.argv.slice(2);
function chamar(action, params) {
  return new Promise((ok, falha) => {
    const ws = new WebSocket("ws://127.0.0.1:9879");
    const t = setTimeout(() => { ws.close(); falha(new Error(`${action}: sem resposta`)); }, 240000);
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, action, params }));
    ws.onerror = () => { clearTimeout(t); falha(new Error("Studio fechado")); };
    ws.onmessage = (e) => { clearTimeout(t); ws.close(); const r = JSON.parse(e.data); r.success ? ok(r.data) : falha(new Error(`${action}: ${r.error}`)); };
  });
}
let t0 = Date.now();
const c = await chamar("midia_consultas", { fala, contexto });
console.log(`consultas (${c.origem}, ${((Date.now() - t0) / 1000).toFixed(1)} s):`);
for (const x of c.consultas) console.log(`  ${x.nivel}: ${x.termo}`);
t0 = Date.now();
const yt = await chamar("midia_youtube_buscar", { consulta: c.consultas[0].termo });
console.log(`youtube "${yt.consulta}": ${yt.opcoes.length} vídeos em ${((Date.now() - t0) / 1000).toFixed(1)} s`);
for (const v of yt.opcoes.slice(0, 4)) console.log(`  ${v.id} | ${v.canal} | ${v.duracao}s | ${v.licenca} | ${v.titulo.slice(0, 50)}`);
if (yt.opcoes.length && pasta) {
  t0 = Date.now();
  const v = yt.opcoes[0];
  const tr = await chamar("midia_youtube_trecho", { id: v.id, ini: Math.min(30, Math.max(0, v.duracao - 10)), dur: 8, pasta });
  console.log(`trecho em ${((Date.now() - t0) / 1000).toFixed(1)} s: ${tr.arquivo} | quadros: ${tr.quadros}`);
}
