// Motor de motion ao vivo do Nardoto Editor.
//
// Processo auxiliar (Electron offscreen) que abre composicoes HyperFrames e
// devolve o quadro exato de um tempo t. O editor (C++) nao embute navegador:
// ele conversa com este processo pelo stdin/stdout.
//
// Canal: socket local que o editor abre (QLocalServer) e passa em --canal=.
// Named pipe no Windows, Unix socket no Mac. Nao usa stdin/stdout: o Electron
// no Windows nao entrega o stdin ao processo principal (medido: so chega o fim
// do cano) e solta "\r\n" no stdout ao iniciar.
//
// Protocolo
//   entrada, uma linha JSON por comando:
//     {"cmd":"abrir","id":"c1","pasta":"C:/.../intro","escala":0.5}
//     {"cmd":"quadro","id":"c1","t":1.25,"seq":7}
//     {"cmd":"recarregar","id":"c1"}
//     {"cmd":"fechar","id":"c1"}
//   saida, sempre um cabecalho de 16 bytes + corpo:
//     4 bytes "NMH1" | uint32 tipo (1 = json, 2 = quadro) | uint32 tamanho | uint32 reservado
//     json:   corpo = UTF-8 de um objeto (respostas e eventos)
//     quadro: corpo = 24 bytes (uint32 seq, largura, altura, stride, 0, 0) + BGRA premultiplicado
//
// A captura do quadro reaproveita o que o render proprio do Nardoto Frames
// provou (8.000 de 8.000 quadros exatos): o ouvinte do "paint" e armado ANTES
// do seek e invalidate() nunca e chamado -- invalidate() devolve o quadro
// anterior.

const { app, BrowserWindow } = require("electron");
const fs = require("fs");
const path = require("path");
const net = require("net");
const os = require("os");
const crypto = require("crypto");
const { execFile } = require("child_process");
const { fileURLToPath, pathToFileURL } = require("url");
const { PREPARO } = require("./preparo");

const canal = (process.argv.find((a) => a.startsWith("--canal=")) || "").slice(8);
const log = process.env.NMH_DEBUG ? (...a) => process.stderr.write(`[motion-host] ${a.join(" ")}\n`) : () => {};
let sock = null;

app.commandLine.appendSwitch("disable-gpu-vsync");
app.commandLine.appendSwitch("force-device-scale-factor", "1");
if (process.env.NMH_GPU_ALTA) app.commandLine.appendSwitch("force_high_performance_gpu");
if (process.env.NMH_SEM_GPU) app.disableHardwareAcceleration();
app.on("window-all-closed", () => { /* vive enquanto o editor quiser */ });

// ---- saida binaria -------------------------------------------------------

const MAGICO = Buffer.from("NMH1");
const fila = [];
let escrevendo = false;

// partes: o corpo pode ir em pedacos (cabecalho do quadro + pixels) sem
// juntar num buffer novo -- juntar copiava 8 MB a cada quadro de 1080p.
function enfileirar(tipo, ...partes) {
  const cab = Buffer.alloc(16);
  MAGICO.copy(cab, 0);
  cab.writeUInt32LE(tipo, 4);
  cab.writeUInt32LE(partes.reduce((n, b) => n + b.length, 0), 8);
  fila.push(cab, ...partes);
  drenar();
}

function drenar() {
  if (escrevendo || !sock) return;
  while (fila.length) {
    if (!sock.write(fila.shift())) {
      escrevendo = true;
      sock.once("drain", () => { escrevendo = false; drenar(); });
      return;
    }
  }
}

function json(obj) { enfileirar(1, Buffer.from(JSON.stringify(obj), "utf8")); }

// ---- anel em arquivo ------------------------------------------------------
//
// Os 8 MB de cada quadro de 1080p passavam pelo named pipe, um por vez, a ~20 ms
// cada: era o teto do export (44 s de video em 51 s, medido) mesmo com as
// paginas ajudantes desenhando em paralelo. Agora o quadro vai para uma vaga de
// um arquivo de troca em %TEMP% (copia para o cache do sistema) e o cano so leva
// o aviso "quadro N na vaga K". O editor mapeia o arquivo e le a vaga direto.
// VAGAS folgado: o editor copia a vaga assim que recebe o aviso, e no maximo uns
// 5 quadros estao em transito (4 adiantados + o preview).
const VAGAS = 16;
const aneis = new Map();

function anel(w, h) {
  const chaveAnel = `${w}x${h}`;
  let a = aneis.get(chaveAnel);
  if (!a) {
    const bytes = w * h * 4;
    const arquivo = path.join(os.tmpdir(), `nardoto-motion-anel-${process.pid}-${chaveAnel}.bin`);
    const fd = fs.openSync(arquivo, "w+");
    fs.ftruncateSync(fd, bytes * VAGAS);
    a = { arquivo, fd, bytes, proxima: 0 };
    aneis.set(chaveAnel, a);
  }
  return a;
}

// Sobras de motores anteriores (o editor mapeia o arquivo, entao so da para
// apagar depois que ele fecha): limpa os aneis de processos que nao existem mais.
function limparAneisVelhos() {
  try {
    for (const nome of fs.readdirSync(os.tmpdir())) {
      const m = /^nardoto-motion-anel-(\d+)-/.exec(nome);
      if (!m || Number(m[1]) === process.pid) continue;
      try { process.kill(Number(m[1]), 0); continue; } catch { /* processo morto */ }
      try { fs.unlinkSync(path.join(os.tmpdir(), nome)); } catch { /* em uso */ }
    }
  } catch { /* sem tmp */ }
}

function quadro(seq, q) {
  const meta = Buffer.alloc(24);
  meta.writeUInt32LE(seq >>> 0, 0);
  meta.writeUInt32LE(q.w, 4);
  meta.writeUInt32LE(q.h, 8);
  meta.writeUInt32LE(q.w * 4, 12);
  if (process.env.NMH_SEM_ANEL) { enfileirar(2, meta, q.bmp); return; }
  const a = anel(q.w, q.h);
  const vaga = a.proxima;
  a.proxima = (a.proxima + 1) % VAGAS;
  fs.writeSync(a.fd, q.bmp, 0, q.bmp.length, vaga * a.bytes);
  meta.writeUInt32LE(vaga, 16);
  enfileirar(3, meta, Buffer.from(a.arquivo, "utf8"));
}

// ---- composicoes ---------------------------------------------------------

const comps = new Map();
let sessoes = 0;

// Aceita a pasta da composicao ou o proprio .html (o editor guarda o .html no
// caminho do clipe).
function acharIndex(pasta) {
  if (pasta.toLowerCase().endsWith(".html") && fs.existsSync(pasta)) return pasta;
  const direto = path.join(pasta, "index.html");
  return fs.existsSync(direto) ? direto : null;
}

// ---- video em quadros prontos ----------------------------------------------
//
// Buscar o quadro de um <video> a cada quadro custava 100-300 ms e errava o
// quadro (medido: vitrine com 10 videos, 44 s em 2 min 55 s). O ffmpeg extrai
// so o trecho que aparece, ja no tamanho da moldura, uma vez por trecho -- as
// paginas ajudantes e as proximas aberturas reaproveitam a pasta.
const FPS_QUADROS = 30;
const extracoes = new Map();

function ffmpegExe() {
  const exe = process.platform === "win32" ? "ffmpeg.exe" : "ffmpeg";
  const candidatos = [process.env.NMH_FFMPEG, path.join(__dirname, exe),
    path.join(__dirname, "..", ".tools", "deps", "ffmpeg", "bin", exe)];
  return candidatos.find((c) => c && fs.existsSync(c)) || "ffmpeg";
}

async function extrairQuadros(videos, escala) {
  const saida = [];
  await Promise.all(videos.map(async (v) => {
    if (!(v.dur > 0) || !v.w || !v.h || !String(v.src).startsWith("file:")) return;
    const arq = fileURLToPath(v.src);
    if (!fs.existsSync(arq)) { log("video da composicao nao existe:", arq); return; }
    const w = Math.max(2, Math.round((v.w * escala) / 2) * 2);
    const h = Math.max(2, Math.round((v.h * escala) / 2) * 2);
    const chave = crypto.createHash("sha1")
      .update([arq, fs.statSync(arq).mtimeMs, v.midia, v.dur, w, h, FPS_QUADROS].join("|")).digest("hex").slice(0, 16);
    const dir = path.join(os.tmpdir(), "nardoto-motion-quadros", chave);
    if (!extracoes.has(chave)) extracoes.set(chave, extrair(arq, v, w, h, dir));
    const n = await extracoes.get(chave);
    if (n > 0) saida.push({ i: v.i, base: pathToFileURL(dir).href + "/", n, fps: FPS_QUADROS, w, h });
  }));
  return saida;
}

function extrair(arq, v, w, h, dir) {
  const feito = path.join(dir, "feito.txt");
  if (fs.existsSync(feito)) return Promise.resolve(Number(fs.readFileSync(feito, "utf8")) || 0);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const t0 = Date.now();
  const args = ["-v", "error", "-ss", String(v.midia), "-t", String(v.dur), "-i", arq,
    "-vf", `fps=${FPS_QUADROS},scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}`,
    "-q:v", "3", path.join(dir, "%05d.jpg")];
  return new Promise((ok) => {
    execFile(ffmpegExe(), args, { windowsHide: true }, (erro, _out, errTxt) => {
      if (erro) { log("ffmpeg falhou:", String(errTxt || erro.message).slice(0, 300)); ok(0); return; }
      const n = fs.readdirSync(dir).filter((f) => f.endsWith(".jpg")).length;
      fs.writeFileSync(feito, String(n));
      log(`quadros extraidos: ${path.basename(arq)} ${n} em ${Date.now() - t0} ms`);
      ok(n);
    });
  });
}

// Uma "pagina" e uma janela offscreen com a composicao carregada. A composicao
// tem a principal (preview, print e export) e, no export, ajudantes que
// desenham os proximos quadros em paralelo (ver adiantar).
function novaPagina(base) {
  const janela = new BrowserWindow({
    width: 800, height: 600, show: false, useContentSize: true, frame: false,
    transparent: true, backgroundColor: "#00000000",
    webPreferences: {
      offscreen: true, webSecurity: false, backgroundThrottling: false,
      // sessao so em memoria, uma por pagina: isola o zoom (ver carregar)
      partition: `nmh-${++sessoes}`,
      // O runtime do HyperFrames cria window.__timelines antes da composicao,
      // e ha composicao que so registra a timeline se o objeto ja existir (a
      // animacao desenhada, por exemplo). O preload faz isso no mundo da
      // pagina, por isso sem isolamento; a pagina continua sem Node.
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: false, nodeIntegration: false, sandbox: false,
    },
  });
  const wc = janela.webContents;
  wc.setFrameRate(240);
  wc.setAudioMuted(true);
  const pg = Object.assign(base || {}, { janela, wc, esperando: null, ultimo: null, carimbo: 0 });
  wc.on("paint", (_e, _r, img) => {
    const e = pg.esperando;
    if (!e || !pg.info) return;
    const bmp = img.toBitmap();
    // Paint de outro pedido (atrasado ou adiantado) nao serve: quadro trocado.
    if (lerCarimbo(bmp, img.getSize().width, pg.info.saidaAltura) !== e.seq) { pg.descartados = (pg.descartados || 0) + 1; return; }
    pg.esperando = null;
    e.ok({ bmp: bmp.subarray(0, pg.info.saidaLargura * pg.info.saidaAltura * 4),
      w: pg.info.saidaLargura, h: pg.info.saidaAltura });
  });
  return pg;
}

async function abrir({ id, pasta, escala = 1, larguraMax = 0, alturaMax = 0 }) {
  const index = acharIndex(pasta);
  if (!index) throw new Error(`index.html não encontrado em ${pasta}`);
  fechar({ id });
  const c = novaPagina({ id, pasta, index, escala, larguraMax, alturaMax, info: null,
    vigia: null, recarga: null, ajudantes: [], cache: new Map(), passo: 0, ultExato: null });
  comps.set(id, c);
  await carregarComTrava(c);
  vigiar(c);
  return c.info;
}

// O editor pede quadro assim que poe o clipe, antes de a composicao terminar de
// abrir. Sem esta trava o pedido roda window.__nf.ir() numa pagina ainda sem
// __nf, da erro e o preview fica preto (medido no editor). Os pedidos esperam
// a carga (ou a recarga, quando o chat edita o arquivo) terminar.
function carregarComTrava(c) {
  c.carregando = carregar(c);
  return c.carregando;
}

async function carregar(c) {
  log("carregando", c.index);
  await c.wc.loadFile(c.index);
  log("carregado; preparando");
  const info = await c.wc.executeJavaScript(PREPARO, true);
  log("preparado", JSON.stringify(info));
  // larguraMax/alturaMax: o tamanho que o compositor do editor pede. Escala
  // so pra baixo -- a composicao nunca sai maior que a propria resolucao.
  if (c.larguraMax > 0 && c.alturaMax > 0) {
    c.escala = Math.min(1, c.larguraMax / info.largura, c.alturaMax / info.altura);
  }
  const L = Math.max(2, Math.round((info.largura * c.escala) / 2) * 2);
  const A = Math.max(2, Math.round((info.altura * c.escala) / 2) * 2);
  // A janela nao pode nascer maior que a tela, mas aceita o tamanho depois.
  c.janela.setBounds({ x: 0, y: 0, width: L, height: A + FAIXA });
  c.janela.setContentSize(L, A + FAIXA);
  // A escala do zoom vale para a SESSAO inteira no Chromium (devicePixelRatio
  // compartilhado): com o preview (518 px) e o export (1920 px) na mesma sessao,
  // o de 1920 desenhava encolhido no canto (medido: dpr 0,27 nos dois). Cada
  // composicao tem sessao propria (ver abrir), entao aqui o zoom e so dela.
  c.wc.setZoomFactor(c.escala);
  await c.wc.executeJavaScript(`window.__nf.prepararCarimbo(${c.escala}, ${FAIXA}, ${CELULA})`, true);
  await new Promise((r) => setTimeout(r, 200));
  // Video dentro da composicao: troca a busca do <video> por quadros prontos.
  if (info.videos && info.videos.length) {
    const lista = await extrairQuadros(info.videos, c.escala);
    if (lista.length) await c.wc.executeJavaScript(`window.__nf.usarQuadros(${JSON.stringify(lista)})`, true);
  }
  c.ultimo = null;
  c.info = { id: c.id, duracao: info.duracao, largura: info.largura, altura: info.altura, saidaLargura: L, saidaAltura: A };
  // Aquecimento: os primeiros seeks chegam antes de o compositor estabilizar.
  for (let k = 0; k < 4; k++) await capturar(c, k / 30);
}

// ---- carimbo de quadro --------------------------------------------------
//
// A pagina desenha o numero do pedido numa faixa de FAIXA px abaixo da
// composicao (8 celulas cinza, um nibble cada). O motor so aceita o paint que
// traz esse numero e corta a faixa antes de mandar. Resolve dois defeitos
// medidos: o prazo de "nada mudou" devolvia o quadro velho (6 s preto, 18 s com
// a cena de 12 s) e custava 150 ms por quadro parado. Como o carimbo muda a cada
// pedido, sempre ha paint -- e de qual pedido ele e, a gente sabe.
const FAIXA = 4;   // px reais
const CELULA = 8;  // px reais por nibble
const PRAZO_QUADRO = 5000;

function lerCarimbo(bmp, largura, alturaConteudo) {
  const y = alturaConteudo + (FAIXA >> 1);
  let seq = 0;
  for (let k = 0; k < 8; k++) {
    const x = k * CELULA + (CELULA >> 1);
    const i = (y * largura + x) * 4;
    if (i + 2 >= bmp.length) return -1;
    const v = (bmp[i] + bmp[i + 1] + bmp[i + 2]) / 3;
    seq = ((seq << 4) | Math.max(0, Math.min(15, Math.round((v - 8) / 16)))) >>> 0;
  }
  return seq;
}

async function capturar(c, t) {
  const t0 = Date.now();
  // fase 1 (ver preparo.js): decodifica os quadros de video antes de armar
  await c.wc.executeJavaScript(`Promise.resolve(window.__nf.preparar && window.__nf.preparar(${Number(t) || 0}))`, true);
  const t1 = Date.now();
  c.carimbo = ((c.carimbo + 1) & 0x7fffffff) || 1;
  const seq = c.carimbo;
  const quadroPronto = new Promise((ok, falha) => {
    c.esperando = { seq, ok };
    setTimeout(() => {
      if (c.esperando && c.esperando.seq === seq) {
        c.esperando = null;
        falha(new Error(`o quadro de ${Number(t).toFixed(3)} s não chegou em ${PRAZO_QUADRO / 1000} s`));
      }
    }, PRAZO_QUADRO);
  });
  await c.wc.executeJavaScript(`Promise.resolve(window.__nf.ir(${Number(t) || 0}, ${seq}))`, true);
  const t2 = Date.now();
  const q = await quadroPronto;
  if (process.env.NMH_TEMPOS) log(`tempos preparar=${t1 - t0} ir=${t2 - t1} paint=${Date.now() - t2} paintsDescartados=${c.descartados || 0}`);
  c.descartados = 0;
  c.ultimo = q;
  return q;
}

// Pedidos de quadro sao servidos um de cada vez por composicao. Se chegarem
// varios enquanto um esta em andamento (scrub rapido), so o mais novo vale.
// Preview: so o pedido mais novo vale (scrub rapido descarta os velhos).
// Exato (export e print): fila em ordem, nenhum descartado -- o editor pede
// quadros adiantados e precisa de todos, cada um com o seu seq.
function pedirQuadro({ id, t, seq, exato }) {
  log(`pedido seq=${seq} t=${t} exato=${!!exato}`);
  const c = comps.get(id);
  if (!c) { json({ evento: "erro", id, seq, erro: "composição não aberta" }); return; }
  if (exato) (c.filaExata || (c.filaExata = [])).push({ t, seq, exato });
  else c.pendente = { t, seq, exato };
  if (c.ocupado) return;
  c.ocupado = true;
  const proximo = () => (c.filaExata && c.filaExata.length ? c.filaExata.shift() : (() => { const p = c.pendente; c.pendente = null; return p; })());
  (async () => {
    let p;
    while ((p = proximo())) {
      try {
        if (c.carregando) await c.carregando;
        const img = p.exato ? await quadroExato(c, p.t) : await capturar(c, p.t);
        c.entregue = img;
        quadro(p.seq, img);
        log(`enviou seq=${p.seq} t=${p.t} exato=${!!p.exato}`);
      } catch (e) {
        json({ evento: "erro", id, seq: p.seq, erro: e.message });
      }
    }
    c.ocupado = false;
  })();
}

// ---- export em paralelo ---------------------------------------------------
//
// O export pede quadro exato atras de quadro exato, em fila: a composicao ficava
// parada enquanto o editor comprimia, e cada quadro de 1080p custava ~55 ms
// (44 s de video em 1 min 38 s, medido). Quando os pedidos exatos chegam em
// sequencia, as paginas ajudantes desenham os proximos quadros ao mesmo tempo e
// o editor pega o quadro pronto. Cada ajudante usa o mesmo metodo exato, entao
// o resultado nao muda -- so chega antes.
const AJUDANTES = Math.max(0, Number(process.env.NMH_AJUDANTES || 3));
const chave = (t) => Math.round(t * 1000);

async function quadroExato(c, t) {
  // passo do export: a diferenca entre dois pedidos exatos seguidos
  if (c.ultExato !== null && t > c.ultExato && t - c.ultExato < 0.25) {
    c.passo = t - c.ultExato;
    garantirAjudantes(c);
  }
  c.ultExato = t;
  const k = chave(t);
  let img;
  if (c.cache.has(k)) img = await c.cache.get(k);
  else img = await capturar(c, t);
  for (const kk of c.cache.keys()) if (kk <= k) c.cache.delete(kk);
  if (c.passo > 0) adiantar(c, t);
  return img;
}

function garantirAjudantes(c) {
  if (c.ajudantes.length || !AJUDANTES) return;
  for (let i = 0; i < AJUDANTES; i++) {
    const a = novaPagina({ index: c.index, escala: c.escala, larguraMax: c.larguraMax,
      alturaMax: c.alturaMax, ocupado: true });
    a.carregando = carregar(a).then(() => { a.ocupado = false; adiantar(c, c.ultExato); })
      .catch((e) => log("ajudante falhou", e.message));
    c.ajudantes.push(a);
  }
  log(`export em paralelo: ${AJUDANTES} ajudantes`);
}

function adiantar(c, t) {
  if (t === null || !(c.passo > 0)) return;
  const dur = c.info ? c.info.duracao : Infinity;
  for (let j = 1; j <= c.ajudantes.length * 2; j++) {
    const tj = t + j * c.passo;
    if (tj > dur + c.passo) break;
    const kj = chave(tj);
    if (c.cache.has(kj)) continue;
    const livre = c.ajudantes.find((a) => !a.ocupado);
    if (!livre) break;
    livre.ocupado = true;
    c.cache.set(kj, capturar(livre, tj).finally(() => {
      livre.ocupado = false;
      adiantar(c, c.ultExato);
    }));
  }
}

function fecharAjudantes(c) {
  for (const a of c.ajudantes) if (!a.janela.isDestroyed()) a.janela.destroy();
  c.ajudantes = [];
  c.cache.clear();
  c.passo = 0;
  c.ultExato = null;
}

// O chat edita o index.html no disco: recarrega sozinho e avisa o editor,
// que pede o quadro de novo. Agrupa rajadas de gravacao em 300 ms.
function vigiar(c) {
  try {
    c.vigia = fs.watch(path.dirname(c.index), { recursive: true }, () => {
      clearTimeout(c.recarga);
      c.recarga = setTimeout(() => recarregar({ id: c.id }).catch(() => {}), 300);
    });
  } catch { /* pasta sem suporte a vigia: recarregar manual continua valendo */ }
}

async function recarregar({ id }) {
  const c = comps.get(id);
  if (!c) throw new Error("composição não aberta");
  fecharAjudantes(c);
  await carregarComTrava(c);
  json({ evento: "mudou", ...c.info });
  return c.info;
}

function fechar({ id }) {
  const c = comps.get(id);
  if (!c) return;
  comps.delete(id);
  try { c.vigia && c.vigia.close(); } catch { /* ja fechou */ }
  clearTimeout(c.recarga);
  fecharAjudantes(c);
  if (!c.janela.isDestroyed()) c.janela.destroy();
}

// ---- cache em video --------------------------------------------------------
//
// Desenhar ao vivo no export custa ~55-70 ms por quadro em 1080p (o processo
// principal repassa 8 MB por quadro) e 44 s de video levavam 72 s. O cache grava
// a composicao inteira em segundo plano, com o mesmo metodo exato; o editor le
// esse arquivo como um video comum no preview e no export. Composicao opaca vai
// em H.264 (132 s de 1080p exportados em 26 s com NVENC, medido; o ProRes de 10
// bits levava 241 s porque o leitor do editor converte devagar). So quando
// algum quadro tem transparencia o cache e refeito em ProRes 4444. O nome do arquivo vem do conteudo da pasta: mudou o
// HTML (o chat editou), muda o nome e o cache e refeito.
const caches = new Map(); // arquivo -> Promise

function carimboDaPasta(dir) {
  const h = crypto.createHash("sha1");
  const andar = (d) => {
    for (const nome of fs.readdirSync(d).sort()) {
      const p = path.join(d, nome);
      const st = fs.statSync(p);
      if (st.isDirectory()) andar(p);
      else h.update(`${path.relative(dir, p)}|${st.size}|${st.mtimeMs}
`);
    }
  };
  andar(dir);
  return h.digest("hex").slice(0, 16);
}

async function pedirCache({ pasta, largura, altura, fps }) {
  const index = acharIndex(pasta);
  if (!index) throw new Error(`index.html não encontrado em ${pasta}`);
  fps = Number(fps) || 30;
  const carimbo = carimboDaPasta(path.dirname(index));
  const dir = path.join(os.tmpdir(), "nardoto-motion-cache");
  fs.mkdirSync(dir, { recursive: true });
  const arquivo = path.join(dir, `${carimbo}-${largura}x${altura}-${fps}.mov`);
  if (fs.existsSync(arquivo)) {
    json({ evento: "cache-pronto", pasta, fps, arquivo });
    return { arquivo, pronto: true };
  }
  if (!caches.has(arquivo)) {
    const job = gravarCache(index, arquivo, largura, altura, fps)
      .then(() => json({ evento: "cache-pronto", pasta, fps, arquivo }))
      .catch((e) => { log("cache falhou:", e.message); json({ evento: "cache-erro", pasta, fps, erro: e.message }); })
      .finally(() => caches.delete(arquivo));
    caches.set(arquivo, job);
  }
  return { arquivo, pronto: false };
}

async function gravarCache(index, arquivo, largura, altura, fps) {
  const t0 = Date.now();
  const id = `cache:${arquivo}`;
  const info = await abrir({ id, pasta: index, larguraMax: largura, alturaMax: altura });
  const c = comps.get(id);
  try {
    const L = info.saidaLargura, A = info.saidaAltura;
    const total = Math.max(1, Math.round(info.duracao * fps));
    const parcial = arquivo + ".parcial.mov";
    let alfa = false;
    while (!(await gravarPassada(c, parcial, L, A, fps, total, alfa, arquivo))) alfa = true;
    fs.renameSync(parcial, arquivo);
    log(`cache pronto: ${path.basename(arquivo)} ${total} quadros em ${Date.now() - t0} ms`);
  } finally {
    fechar({ id });
  }
}

// Uma passada do cache. Sem alfa devolve false no primeiro quadro transparente
// (o chamador refaz com alfa); composicao de sobreposicao ja mostra isso no
// primeiro quadro, entao a volta custa quase nada.
async function gravarPassada(c, parcial, L, A, fps, total, alfa, arquivo) {
  const codec = alfa
    // o paint vem com alfa pre-multiplicado; o ProRes guarda alfa reto.
    // qscale 9: 1/4 do tamanho do padrao (1,5 GB -> ~400 MB em 44 s de 1080p, medido)
    ? ["-vf", "unpremultiply=inplace=1", "-c:v", "prores_ks", "-profile:v", "4444", "-qscale:v", "9",
      "-pix_fmt", "yuva444p10le", "-vendor", "apl0"]
    // GOP curto: o preview pula para qualquer ponto sem decodificar muito
    : ["-vf", "scale=out_color_matrix=bt709:out_range=tv", "-c:v", "libx264", "-preset", "ultrafast",
      "-crf", "12", "-g", String(fps), "-pix_fmt", "yuv420p",
      "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"];
  const ff = require("child_process").spawn(ffmpegExe(), ["-v", "error", "-y",
    "-f", "rawvideo", "-pix_fmt", "bgra", "-s", `${L}x${A}`, "-r", String(fps), "-i", "pipe:0",
    ...codec, "-f", "mov", parcial], { stdio: ["pipe", "ignore", "pipe"], windowsHide: true });
  let erroFf = "";
  ff.stderr.on("data", (d) => { erroFf = String(d).slice(-300); });
  ff.stdin.on("error", () => {});
  const fechou = new Promise((r) => ff.on("close", r));
  let avisado = 0;
  for (let i = 0; i < total; i++) {
    const bgra = (await quadroExato(c, i / fps)).bmp;
    if (!alfa && temTransparencia(bgra)) {
      log(`cache: quadro ${i} transparente, refazendo com alfa`);
      ff.kill();
      await fechou;
      return false;
    }
    if (!ff.stdin.write(bgra)) await new Promise((r) => ff.stdin.once("drain", r));
    if (Date.now() - avisado > 1000) {
      avisado = Date.now();
      json({ evento: "cache-progresso", arquivo, feito: i + 1, total });
    }
  }
  ff.stdin.end();
  const codigo = await fechou;
  if (codigo !== 0) throw new Error(`ffmpeg: ${erroFf || codigo}`);
  return true;
}

// Amostra 1 pixel a cada 61 (primo: nao cai sempre na mesma coluna).
function temTransparencia(bgra) {
  for (let i = 3; i < bgra.length; i += 61 * 4) if (bgra[i] < 255) return true;
  return false;
}

// ---- entrada -------------------------------------------------------------

async function tratar(msg) {
  log("comando", msg.cmd, msg.id || "");
  const resp = (extra) => json({ resposta: msg.cmd, id: msg.id, req: msg.req, ...extra });
  try {
    switch (msg.cmd) {
      case "abrir": resp({ ok: true, ...(await abrir(msg)) }); break;
      case "quadro": pedirQuadro(msg); break;
      case "recarregar": resp({ ok: true, ...(await recarregar(msg)) }); break;
      case "fechar": fechar(msg); resp({ ok: true }); break;
      case "cache": resp({ ok: true, ...(await pedirCache(msg)) }); break;
      // diagnostico: salva o ultimo quadro em PNG
      case "salvar": {
        const c = comps.get(msg.id);
        const q = c && (c.entregue || c.ultimo);
        if (!q) throw new Error("sem quadro");
        const { nativeImage } = require("electron");
        fs.writeFileSync(msg.arquivo, nativeImage.createFromBitmap(Buffer.from(q.bmp), { width: q.w, height: q.h }).toPNG());
        resp({ ok: true, tamanho: { width: q.w, height: q.h } });
        break;
      }
      // diagnostico: avalia uma expressao na pagina da composicao
      case "avaliar": {
        const c = comps.get(msg.id);
        if (!c) throw new Error("composição não aberta");
        resp({ ok: true, valor: await c.wc.executeJavaScript(msg.js, true) });
        break;
      }
      case "sair": app.quit(); break;
      default: resp({ ok: false, erro: `comando desconhecido: ${msg.cmd}` });
    }
  } catch (e) {
    resp({ ok: false, erro: e.message });
  }
}

app.whenReady().then(() => {
  limparAneisVelhos();
  if (!canal) { process.stderr.write("motion-host: falta --canal=\n"); app.quit(); return; }
  let resto = "";
  sock = net.connect(canal, () => json({ evento: "pronto", versao: 1, electron: process.versions.electron }));
  sock.setEncoding("utf8");
  sock.on("error", (e) => { process.stderr.write(`motion-host: ${e.message}\n`); app.quit(); });
  sock.on("data", (d) => {
    resto += d;
    let i;
    while ((i = resto.indexOf("\n")) >= 0) {
      const linha = resto.slice(0, i).trim();
      resto = resto.slice(i + 1);
      if (!linha) continue;
      let msg;
      try { msg = JSON.parse(linha); } catch { json({ evento: "erro", erro: "linha inválida" }); continue; }
      tratar(msg);
    }
  });
  // Editor fechou o canal: nao sobra processo orfao.
  sock.on("close", () => app.quit());
});
