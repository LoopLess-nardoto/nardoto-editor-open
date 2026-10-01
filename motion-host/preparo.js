// Injetado na composicao depois do load. Monta as sub-composicoes, acha as
// timelines e expoe window.__nf.ir(t). Veio do render proprio do Nardoto
// Frames (nardoto-frames/render-proprio.js), sem a parte de audio: no editor o
// som da composicao fica mudo e a trilha mora nas faixas de audio da timeline.

exports.PREPARO = `(async () => {
  const esperar = (cond, ms) => new Promise((ok, falha) => {
    const t0 = Date.now();
    (function tenta() {
      if (cond()) return ok();
      if (Date.now() - t0 > ms) return falha(new Error("a composição não ficou pronta a tempo"));
      setTimeout(tenta, 30);
    })();
  });

  // Sub-composicao: o conteudo vem dentro de um <template> e o <script>
  // importado precisa ser RECRIADO, senao nao executa.
  for (const cont of document.querySelectorAll("[data-composition-src]")) {
    try {
      const url = new URL(cont.getAttribute("data-composition-src"), location.href).href;
      const doc = new DOMParser().parseFromString(await (await fetch(url)).text(), "text/html");
      const tpl = doc.querySelector("template");
      cont.appendChild(document.importNode(tpl ? tpl.content : doc.body, true));
      for (const s of cont.querySelectorAll("script")) {
        const novo = document.createElement("script");
        for (const a of s.attributes) novo.setAttribute(a.name, a.value);
        novo.textContent = s.textContent;
        s.replaceWith(novo);
      }
    } catch (e) { console.error("sub-composição:", e.message); }
  }

  await esperar(() => window.__timelines && Object.keys(window.__timelines).length, 30000);
  await new Promise((r) => setTimeout(r, 300));

  const todas = Object.values(window.__timelines).filter((t) => t && t.duration);
  if (!todas.length) throw new Error("nenhuma timeline encontrada na composição");
  const principal = todas.slice().sort((a, b) => b.duration() - a.duration())[0];
  const donos = [...document.querySelectorAll("[data-composition-src]")];
  const extras = [];
  for (const tl of todas) {
    if (tl === principal) continue;
    const dono = donos[extras.length];
    extras.push({ tl, offset: dono ? Number(dono.dataset.start || 0) : 0 });
  }

  // Visibilidade e do runtime do HyperFrames, nao do arquivo: sem isso todos
  // os clips aparecem empilhados de uma vez.
  const clips = [...document.querySelectorAll("[data-start]")].map((el) => {
    const ini = Number(el.dataset.start || 0);
    const d = Number(el.dataset.duration);
    return { el, ini, fim: ini + (isFinite(d) && d > 0 ? d : Infinity), disp: el.style.display };
  });

  for (const m of document.querySelectorAll("audio,video")) {
    try { m.pause(); m.muted = true; } catch { /* midia teimosa */ }
  }
  // data-media-start: de que ponto do arquivo o video comeca (contrato do
  // HyperFrames). Sem ele cada video tocava do trecho errado.
  const videos = [...document.querySelectorAll("video")].map((el) => {
    const dono = el.closest("[data-start]");
    const midia = Number(el.dataset.mediaStart || (dono && dono.dataset.mediaStart) || 0);
    const inicio = dono ? Number(dono.dataset.start || 0) : 0;
    const d = Number((dono && dono.dataset.duration) || el.dataset.duration);
    return { el, offset: inicio - midia, inicio, midia, dur: isFinite(d) && d > 0 ? d : 0, quadros: null };
  });

  // Video em quadros prontos: buscar o quadro de um <video> a cada quadro custa
  // 100-300 ms (o navegador decodifica do ultimo quadro-chave) e erra o quadro
  // quando o prazo estoura. O motor extrai com o ffmpeg so o trecho que aparece,
  // no tamanho da moldura, e aqui o <video> vira um <canvas> que desenha o
  // quadro certo -- como o CLI do HyperFrames e o OffthreadVideo do Remotion.
  // Duas fases, de proposito: preparar(t) so carrega e decodifica as imagens;
  // ir(t) desenha na hora, sem esperar nada. Assim o motor arma a espera do
  // paint entre as duas e o paint seguinte ja traz o canvas desenhado. Desenhar
  // depois de uma espera (dentro do ir) soltava o paint antes de o motor rearmar
  // e o quadro saia com a moldura vazia (medido).
  const indice = (v, t) => Math.min(v.quadros.n - 1, Math.max(0, Math.floor((t - v.inicio) * v.quadros.fps + 1e-6)));
  const pegar = (q, k) => {
    let img = q.cache.get(k);
    if (!img) {
      img = new Image();
      img.src = q.base + String(k + 1).padStart(5, "0") + ".jpg";
      img.pronta = img.decode().then(() => (img.ok = true), () => false);
      q.cache.set(k, img);
      if (q.cache.size > 32) q.cache.delete(q.cache.keys().next().value);
    }
    return img;
  };
  const visivel = (v, t) => t >= v.inicio && t < v.inicio + (v.dur || Infinity);
  await Promise.all([...document.images].map((i) => i.complete ? 0 :
    new Promise((r) => { i.onload = i.onerror = r; })));
  if (document.fonts && document.fonts.ready) await document.fonts.ready;

  window.__nf = {
    // seq: numero do pedido, carimbado na faixa abaixo da composicao (ver
    // carimbar). O motor so aceita o paint que traz este numero.
    ir(t, seq) {
      for (const c of clips) {
        c.el.style.display = (t >= c.ini && t < c.fim) ? (c.disp || "") : "none";
      }
      // O segundo argumento TEM que ser false: tweens com onUpdate (karaoke,
      // onda) congelam com o seek que suprime eventos.
      principal.seek(t, false);
      for (const x of extras) { const l = t - x.offset; if (l >= 0) x.tl.seek(l, false); }
      const esperando = [];
      for (const v of videos) {
        if (v.quadros) {
          if (!visivel(v, t)) continue;
          const q = v.quadros, n = indice(v, t), img = q.cache.get(n);
          if (q.desenhado !== n && img && img.ok) { q.ctx.drawImage(img, 0, 0, q.w, q.h); q.desenhado = n; }
          continue;
        }
        const local = t - v.offset;
        if (local < 0 || !isFinite(v.el.duration)) continue;
        const alvo = Math.min(local, Math.max(0, v.el.duration - 0.001));
        if (Math.abs(v.el.currentTime - alvo) > 0.005) {
          v.el.currentTime = alvo;
          esperando.push(new Promise((r) => {
            const pronto = () => { v.el.removeEventListener("seeked", pronto); r(); };
            v.el.addEventListener("seeked", pronto);
            setTimeout(pronto, 300);
          }));
        }
      }
      // O carimbo vai por ultimo, depois de tudo o que o quadro precisa: o paint
      // que o traz ja tem o video e a animacao do instante t.
      if (esperando.length) return Promise.all(esperando).then(() => { window.__nf.carimbar(seq); return true; });
      window.__nf.carimbar(seq);
      return false;
    },
    // Carimbo de quadro: faixa de FAIXA px reais abaixo da composicao, com 8
    // celulas cinza (um nibble cada) do numero do pedido. Muda a cada pedido,
    // entao sempre ha paint (acabou a espera de "quadro parado") e o motor sabe
    // de qual pedido e cada paint (acabou o quadro velho ou trocado).
    prepararCarimbo(escala, faixa, celula) {
      let cv = document.getElementById("__nf_carimbo");
      if (!cv) {
        cv = document.createElement("canvas");
        cv.id = "__nf_carimbo";
        cv.width = 8; cv.height = 1;
        document.documentElement.appendChild(cv);
      }
      cv.style.cssText = "position:fixed;left:0;top:" + altura + "px;width:" + (8 * celula) / escala + "px;" +
        "height:" + faixa / escala + "px;image-rendering:pixelated;z-index:2147483647;pointer-events:none;margin:0";
      this._carimbo = cv.getContext("2d");
      this._carimbo.imageSmoothingEnabled = false;
      this._img = this._carimbo.createImageData(8, 1);
    },
    carimbar(seq) {
      if (!this._carimbo || seq === undefined) return;
      const d = this._img.data;
      for (let k = 0; k < 8; k++) {
        const v = ((seq >>> (28 - 4 * k)) & 15) * 16 + 8;
        d[k * 4] = v; d[k * 4 + 1] = v; d[k * 4 + 2] = v; d[k * 4 + 3] = 255;
      }
      this._carimbo.putImageData(this._img, 0, 0);
    },
    // Fase 1: decodifica as imagens do instante t (e adianta as proximas).
    preparar(t) {
      const prontas = [];
      for (const v of videos) {
        if (!v.quadros) continue;
        // Video que entra em ate 1 s: carrega os primeiros quadros antes, senao
        // o preview engasgava na troca de cena decodificando na hora.
        if (!visivel(v, t)) {
          if (v.inicio > t && v.inicio - t <= 1) for (let k = 0; k < 6; k++) pegar(v.quadros, k);
          continue;
        }
        const n = indice(v, t);
        for (let k = n + 1; k <= Math.min(v.quadros.n - 1, n + 6); k++) pegar(v.quadros, k);
        prontas.push(pegar(v.quadros, n).pronta);
      }
      return prontas.length ? Promise.all(prontas).then(() => true) : true;
    },
    // lista: [{ i, base, n, fps, w, h }] -- quadros extraidos pelo motor
    usarQuadros(lista) {
      for (const q of lista) {
        const v = videos[q.i];
        if (!v || v.quadros) continue;
        const cs = getComputedStyle(v.el);
        const cv = document.createElement("canvas");
        cv.width = q.w; cv.height = q.h;
        for (const a of v.el.attributes) if (a.name !== "src") cv.setAttribute(a.name, a.value);
        for (const prop of ["position", "top", "left", "right", "bottom", "width", "height", "borderRadius", "zIndex"]) cv.style[prop] = cs[prop];
        const ctx = cv.getContext("2d");
        v.el.replaceWith(cv);
        for (const c of clips) if (c.el === v.el) c.el = cv;
        v.el = cv;
        v.quadros = { ...q, ctx, cache: new Map(), desenhado: -1 };
      }
      return true;
    },
  };
  const raiz = document.querySelector("[data-composition-id]") ||
    document.getElementById("root") || document.documentElement;
  let largura = Number(raiz.dataset && raiz.dataset.width) || 0;
  let altura = Number(raiz.dataset && raiz.dataset.height) || 0;
  if (!largura || !altura) {
    const cs = getComputedStyle(document.documentElement);
    largura = parseInt(cs.width, 10) || document.documentElement.scrollWidth || 1920;
    altura = parseInt(cs.height, 10) || document.documentElement.scrollHeight || 1080;
  }
  // O runtime do HyperFrames da a raiz o tamanho de data-width/data-height.
  // Sem isso a raiz fica com altura 0, nada aparece, nada muda na tela e o
  // compositor nao emite quadro nenhum (medido na vitrine da galeria).
  if (raiz !== document.documentElement) {
    raiz.style.width = largura + "px";
    raiz.style.height = altura + "px";
    raiz.style.position = raiz.style.position || "relative";
    raiz.style.overflow = "hidden";
  }
  document.documentElement.style.overflow = "hidden";
  document.body.style.margin = "0";
  return { duracao: principal.duration(), largura, altura,
    videos: videos.map((v, i) => ({ i, src: v.el.currentSrc || new URL(v.el.getAttribute("src"), location.href).href,
      midia: v.midia, dur: v.dur, w: v.el.offsetWidth, h: v.el.offsetHeight })) };
})()`;
