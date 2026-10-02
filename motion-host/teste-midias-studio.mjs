// Testa as ações de troca de mídia do Studio (servidor local 9879), como o Nardoto Editor chama:
// midia_consultas -> midia_buscar -> midia_baixar. Uso:
//   node motion-host/teste-midias-studio.mjs "<fala da cena>" <pasta-de-saida> [video|imagem]
// O Node 22+ tem WebSocket nativo, sem cabeçalho Origin (conta como cliente local).
const [fala, pasta, tipo = "video"] = process.argv.slice(2);
const porta = Number(process.env.NARDOTO_STUDIO_PORTA || 9879);

function chamar(action, params) {
  return new Promise((ok, falha) => {
    const ws = new WebSocket(`ws://127.0.0.1:${porta}`);
    const t = setTimeout(() => { ws.close(); falha(new Error(`${action}: sem resposta`)); }, 180000);
    ws.onopen = () => ws.send(JSON.stringify({ id: 1, action, params }));
    ws.onerror = () => { clearTimeout(t); falha(new Error("Studio fechado")); };
    ws.onmessage = (e) => {
      clearTimeout(t);
      ws.close();
      const r = JSON.parse(e.data);
      r.success ? ok(r.data) : falha(new Error(`${action}: ${r.error}`));
    };
  });
}

const t0 = Date.now();
const { consultas } = await chamar("midia_consultas", { fala });
console.log("consultas:", consultas.map((c) => `${c.nivel}: ${c.termo}`).join(" | "));
const consulta = consultas[0]?.termo || fala;
const { opcoes } = await chamar("midia_buscar", { consulta, tipo, orientacao: "horizontal", duracaoMinima: 5 });
console.log(`buscar "${consulta}": ${opcoes.length} opções em ${((Date.now() - t0) / 1000).toFixed(1)} s`);
for (const o of opcoes.slice(0, 5)) console.log(`  ${o.fonte} ${o.tipo} ${o.duracao}s ${o.largura}x${o.altura} ${o.licenca} ${o.miniatura ? "com miniatura" : "SEM miniatura"}`);
if (opcoes.length && pasta) {
  const r = await chamar("midia_baixar", { item: opcoes[0], pasta, nome: "teste-troca" });
  console.log("baixou:", r.arquivo, `${(r.bytes / 1048576).toFixed(1)} MB`);
}
