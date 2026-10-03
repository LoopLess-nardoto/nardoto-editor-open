// Roda antes de qualquer script da composicao (ver main.js).
window.__timelines = window.__timelines || {};

// Variaveis editaveis da peca (textos, numeros, cor). O Editor grava os valores em
// variaveis.json ao lado do index.html; o vigia da pasta recarrega a composicao.
// Mesmo contrato do HyperFrames: data-composition-variables traz os padroes,
// window.__hyperframes.getVariables() devolve os valores, data-var-text recebe texto
// e a cor vira a variavel CSS --<id>.
(() => {
  let gravadas = {};
  try {
    const fs = require("fs");
    const path = require("path");
    const { fileURLToPath } = require("url");
    const arq = path.join(path.dirname(fileURLToPath(location.href)), "variaveis.json");
    if (fs.existsSync(arq)) gravadas = JSON.parse(fs.readFileSync(arq, "utf8")) || {};
  } catch { gravadas = {}; }

  function padroes() {
    const out = {};
    try {
      const raw = document.documentElement.getAttribute("data-composition-variables");
      for (const v of JSON.parse(raw || "[]")) out[v.id] = v.default;
    } catch { /* sem declaracao: so o que foi gravado */ }
    return out;
  }

  window.__hyperframes = window.__hyperframes || {};
  window.__hyperframes.getVariables = () => Object.assign(padroes(), gravadas);

  document.addEventListener("DOMContentLoaded", () => {
    const valores = window.__hyperframes.getVariables();
    for (const [id, valor] of Object.entries(gravadas)) {
      if (typeof valor === "string" && /^#[0-9a-f]{3,8}$/i.test(valor))
        document.documentElement.style.setProperty(`--${id}`, valor);
    }
    for (const el of document.querySelectorAll("[data-var-text]")) {
      const id = el.getAttribute("data-var-text");
      if (id in gravadas) el.textContent = String(valores[id]);
    }
  });
})();
