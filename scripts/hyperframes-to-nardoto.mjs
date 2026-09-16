#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { NardotoMcpStdioClient, defaultEditorExecutable } from "./lib/nardoto-mcp-stdio.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EDITOR_ROOT = path.resolve(HERE, "..");
const WORKSPACE_ROOT = path.resolve(EDITOR_ROOT, "..");
const DEFAULT_OUTPUT_ROOT = path.join(WORKSPACE_ROOT, ".nardoto", "hyperframes-translations");
const MAX_SYNTHETIC_SECONDS = 299.5;
const SCENE_FADE_SECONDS = 20 / 30;
const CARD_DURATION_MS = 13000;
const CHIP_DURATION_MS = 3400;

const COLORS = {
  gold: "#E4A94F",
  cream: "#F4EADA",
  dimCream: "#B8F4EADA",
  background: "#FF100C09",
  panel: "#E10B0805",
  grade: "#66080604",
};

const CAST = {
  sarah: { name: "SARAH", color: "#D9758A", centerX: 364 },
  michael: { name: "MICHAEL", color: "#E8A84C", centerX: 960 },
  james: { name: "JAMES", color: "#6BA9CF", centerX: 1556 },
};

const VERSE_ANCHORS = [
  { n: 1, anchor: "I CRY OUT TO GOD" },
  { n: 2, anchor: "IN MY DAY OF TROUBLE" },
  { n: 3, anchor: "I THINK ABOUT GOD AND I HURT" },
  { n: 4, anchor: "YOU HOLD MY EYES OPEN I AM TOO SHAKEN" },
  { n: 5, anchor: "I THINK ABOUT THE OLD DAYS ABOUT YEARS" },
  { n: 6, anchor: "AT NIGHT I REMEMBER MY SONG I TALK" },
  { n: 7, anchor: "WILL THE LORD SAY NO FOREVER WILL HE" },
  { n: 8, anchor: "IS HIS LOVE GONE FOR GOOD IS HIS" },
  { n: 9, anchor: "HAS GOD FORGOTTEN HOW TO BE KIND HAS HE" },
  { n: 10, anchor: "THEN I SAID THIS IS MY PAIN I WILL" },
  { n: 11, anchor: "I WILL REMEMBER WHAT THE LORD DID" },
  { n: 12, anchor: "I WILL THINK ABOUT ALL YOUR WORK" },
  { n: 13, anchor: "YOUR WAY O GOD IS HOLY" },
  { n: 14, anchor: "YOU ARE THE GOD WHO DOES WONDERS YOU SHOWED" },
  { n: 15, anchor: "WITH YOUR ARM YOU SAVED" },
  { n: 16, anchor: "THE WATERS SAW YOU GOD THE WATERS" },
  { n: 17, anchor: "THE CLOUDS POURED DOWN RAIN THE SKY" },
  { n: 18, anchor: "YOUR THUNDER ROLLED IN THE WIND LIGHTNING" },
  { n: 19, anchor: "YOUR ROAD WENT THROUGH THE SEA YOUR PATH" },
  { n: 20, anchor: "YOU LED YOUR PEOPLE LIKE A FLOCK BY THE HAND" },
  { n: 4, anchor: "CUT INTO WATCHES" },
  { n: 2, anchor: "A LINE UP THERE I SKIPPED" },
  { n: 7, anchor: "THEN COME THE SIX QUESTIONS" },
  { n: 10, anchor: "WHAT HAPPENS IS A DECISION" },
  { n: 6, anchor: "STAY WITH THE SONG" },
  { n: 15, anchor: "CROWD OF SLAVES" },
  { n: 18, anchor: "THATS THE LIGHTNING" },
  { n: 19, anchor: "HE LANDS THE WHOLE POEM IN ONE LINE" },
  { n: 20, anchor: "LET ME GIVE YOU THE LAST LINE" },
];

function parseArgs(argv) {
  const out = { apply: false };
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === "--apply") out.apply = true;
    else if (arg === "--project") out.project = argv[++i];
    else if (arg === "--manifest") out.manifest = argv[++i];
    else if (arg === "--output") out.output = argv[++i];
    else if (arg === "--editor-exe") out.editorExe = argv[++i];
    else if (arg === "--backup-only") out.backupOnly = true;
    else if (arg === "--help" || arg === "-h") out.help = true;
    else throw new Error(`Argumento desconhecido: ${arg}`);
  }
  return out;
}

function usage() {
  return [
    "Uso:",
    "  node scripts/hyperframes-to-nardoto.mjs --project <pasta> [--manifest <json>]",
    "  node scripts/hyperframes-to-nardoto.mjs --project <pasta> --apply --output <projeto.drift>",
    "",
    "A tradução lê o HyperFrames final, gera um manifesto neutro e, com --apply, cria um projeto",
    "novo no Nardoto Editor pela ponte MCP stdio. O projeto aberto é salvo antes da substituição.",
  ].join("\n");
}

function ensureDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true });
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function round(value, digits = 3) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function normaliseSpeech(text) {
  return String(text)
    .toUpperCase()
    .replace(/[^A-Z0-9 ]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function parseComposition(html) {
  const root = html.match(/<[^>]+data-composition-id="([^"]+)"[^>]*>/i)?.[0];
  if (!root) throw new Error("Composição HyperFrames não encontrada em index.html");
  const attr = (name) => root.match(new RegExp(`${name}="([^"]+)"`, "i"))?.[1];
  const duration = Number(attr("data-duration"));
  const fps = Number(attr("data-fps"));
  const width = Number(attr("data-width"));
  const height = Number(attr("data-height"));
  if (![duration, fps, width, height].every(Number.isFinite))
    throw new Error("Metadados incompletos na composição HyperFrames");
  return { id: attr("data-composition-id"), duration, fps, width, height };
}

function findPhraseFactory(lines) {
  let stream = "";
  const marks = [];
  for (const line of lines) {
    marks.push({ position: stream.length, startMs: line.startMs });
    stream += `${normaliseSpeech(line.text)} `;
  }
  return (phrase) => {
    const position = stream.indexOf(normaliseSpeech(phrase));
    if (position < 0) return null;
    let time = marks[0]?.startMs ?? 0;
    for (const mark of marks) {
      if (mark.position > position) break;
      time = mark.startMs;
    }
    return time;
  };
}

function fixedWindows(duration, maximum = MAX_SYNTHETIC_SECONDS) {
  const windows = [];
  for (let start = 0; start < duration - 0.001; start += maximum)
    windows.push({ start: round(start), duration: round(Math.min(maximum, duration - start)) });
  return windows;
}

function groupSubtitlePages(pages, maximumMs = MAX_SYNTHETIC_SECONDS * 1000) {
  const groups = [];
  for (const page of pages) {
    let group = groups.at(-1);
    if (!group || page.endMs - group.startMs > maximumMs) {
      group = { startMs: page.startMs, endMs: page.endMs, pages: [] };
      groups.push(group);
    }
    group.pages.push(page);
    group.endMs = Math.max(group.endMs, page.endMs);
  }
  return groups;
}

async function buildManifest(projectDirectory) {
  const project = path.resolve(projectDirectory);
  const htmlPath = path.join(project, "index.html");
  const remotion = path.resolve(project, "..", "remotion");
  const scripturePath = path.join(project, "scripts", "escritura.mjs");
  for (const required of [htmlPath, scripturePath, path.join(remotion, "falas.json"), path.join(remotion, "cenas.json"), path.join(remotion, "palavras.json")]) {
    if (!fs.existsSync(required)) throw new Error(`Arquivo obrigatório ausente: ${required}`);
  }

  const composition = parseComposition(fs.readFileSync(htmlPath, "utf8"));
  const lines = readJson(path.join(remotion, "falas.json"));
  const sourceScenes = readJson(path.join(remotion, "cenas.json"));
  const pages = readJson(path.join(remotion, "palavras.json"));
  const { ESCRITURAS, CARDS_DEF, TERMOS } = await import(pathToFileURL(scripturePath).href);
  const findPhrase = findPhraseFactory(lines);
  const endMs = Math.max(lines.at(-1).endMs, sourceScenes.at(-1).endMs);

  const scenes = sourceScenes.map((scene, index) => {
    const startMs = Math.max(0, scene.startMs - (index > 0 ? SCENE_FADE_SECONDS * 1000 : 0));
    const endWithFadeMs = scene.endMs + SCENE_FADE_SECONDS * 1000;
    const zoomIn = index % 2 === 0;
    const pan = index % 3 === 0 ? [-18, 18] : index % 3 === 1 ? [18, -18] : [0, 0];
    return {
      id: `scene-${index}`,
      asset: path.join(project, "assets", "cenas", scene.image.replace(/\.png$/i, ".jpg")),
      label: scene.label,
      start: round(startMs / 1000),
      duration: round((endWithFadeMs - startMs) / 1000),
      lane: index % 2,
      fade: index > 0 ? round(SCENE_FADE_SECONDS) : 0,
      kenBurns: { scaleFrom: zoomIn ? 1.04 : 1.14, scaleTo: zoomIn ? 1.14 : 1.04, panFrom: pan[0], panTo: pan[1] },
    };
  });

  const turns = [];
  for (const line of lines) {
    const previous = turns.at(-1);
    if (previous?.speaker === line.speaker) previous.endMs = line.endMs;
    else turns.push({ speaker: line.speaker, startMs: line.startMs, endMs: line.endMs });
  }
  for (let i = 0; i < turns.length; ++i)
    turns[i].untilMs = turns[i + 1]?.startMs ?? endMs;

  const cards = CARDS_DEF.map((definition) => ({ ...definition, startMs: findPhrase(definition.ancora) }))
    .filter((card) => card.startMs !== null)
    .map((card) => ({ ...card, startMs: card.startMs - 600, durationMs: CARD_DURATION_MS }));

  const endVerses = findPhrase("OUT OF THE POEM");
  const verseStarts = VERSE_ANCHORS.map((verse) => ({ ...verse, startMs: findPhrase(verse.anchor) })).filter(
    (verse) => verse.startMs !== null,
  );
  const verses = [];
  for (let index = 0; index < verseStarts.length; ++index) {
    const verse = verseStarts[index];
    let finish = verseStarts[index + 1]?.startMs ?? endMs;
    if (endVerses !== null && endVerses > verse.startMs) finish = Math.min(finish, endVerses);
    const data = ESCRITURAS.find((entry) => entry.verso === verse.n);
    if (!data || finish <= verse.startMs) continue;
    const focuses = data.foco
      .map((focus) => {
        const at = focus.inicio ? verse.startMs : findPhrase(focus.ancora);
        return at === null ? null : { mark: focus.marca, at: round(Math.max(at, verse.startMs) / 1000) };
      })
      .filter(Boolean)
      .sort((a, b) => a.at - b.at);
    verses.push({
      verse: verse.n,
      start: round(verse.startMs / 1000),
      duration: round((finish - verse.startMs) / 1000),
      text: data.partes.map((part) => part.t).join(""),
      focuses,
    });
  }

  const chips = [];
  for (const page of pages) {
    for (const word of page.words) {
      const term = word.t.toUpperCase().replace(/[^A-Z]/g, "");
      if (!TERMOS[term] || chips.some((chip) => chip.term === term)) continue;
      const previous = chips.at(-1);
      if (previous && word.s - previous.atMs < CHIP_DURATION_MS + 800) continue;
      chips.push({ term, gloss: TERMOS[term], atMs: word.s, speaker: page.speaker, durationMs: CHIP_DURATION_MS });
    }
  }

  const assets = [
    { id: "audio", kind: "audio", path: path.join(project, "assets", "audio.mp3") },
    ...[...new Set(scenes.map((scene) => scene.asset))].map((asset, index) => ({ id: `scene-asset-${index}`, kind: "image", path: asset })),
    ...Object.keys(CAST).flatMap((speaker) => [
      { id: `${speaker}-idle`, kind: "image", path: path.join(project, "assets", "avatars", `${speaker}_a.webp`) },
      { id: `${speaker}-active`, kind: "image", path: path.join(project, "assets", "avatars", `${speaker}_b.webp`) },
    ]),
  ];
  const missingAssets = assets.filter((asset) => !fs.existsSync(asset.path));
  if (missingAssets.length)
    throw new Error(`Mídias ausentes: ${missingAssets.map((asset) => asset.path).join(", ")}`);

  return {
    schema: "nardoto.hyperframes.translation/v1",
    generatedAt: new Date().toISOString(),
    source: { project, html: htmlPath, generator: path.join(project, "scripts", "build.mjs") },
    composition,
    assets,
    cast: CAST,
    scenes,
    turns: turns.map((turn) => ({
      speaker: turn.speaker,
      start: round(turn.startMs / 1000),
      duration: round((turn.untilMs - turn.startMs) / 1000),
    })),
    captions: pages.map((page) => ({
      speaker: page.speaker,
      startMs: page.startMs,
      endMs: page.endMs,
      text: page.words.map((word) => word.t).join(" "),
      wordStartsMs: page.words.map((word) => word.s),
    })),
    verses,
    cards: cards.map((card) => ({
      start: round(card.startMs / 1000),
      duration: round(card.durationMs / 1000),
      eyebrow: card.eyebrow,
      title: card.titulo,
      lines: card.linhas,
    })),
    chips: chips.map((chip) => ({
      start: round(chip.atMs / 1000),
      duration: round(chip.durationMs / 1000),
      speaker: chip.speaker,
      term: chip.term,
      gloss: chip.gloss,
    })),
    stats: {
      scenes: scenes.length,
      turns: turns.length,
      captionPages: pages.length,
      words: pages.reduce((sum, page) => sum + page.words.length, 0),
      verses: verses.length,
      cards: cards.length,
      chips: chips.length,
      duration: composition.duration,
    },
  };
}

function chunks(array, size) {
  const out = [];
  for (let index = 0; index < array.length; index += size) out.push(array.slice(index, index + size));
  return out;
}

function requireOk(result, label) {
  if (result?.ok) return result;
  throw new Error(`${label}: ${result?.error ?? "falha"} ${result?.detail ?? JSON.stringify(result)}`);
}

async function applyBatches(client, operations, label, batchSize = 60) {
  const results = [];
  let done = 0;
  for (const batch of chunks(operations, batchSize)) {
    const result = requireOk(await client.call("apply", { ops: batch }), label);
    results.push(...(result.done ?? []));
    done += batch.length;
    process.stdout.write(`\r${label}: ${done}/${operations.length}`);
  }
  if (operations.length) process.stdout.write("\n");
  return results;
}

async function mintClips(client, operations, label, batchSize = 40) {
  const replies = await applyBatches(client, operations, label, batchSize);
  return replies.map((reply, index) => {
    const id = reply.result?.id ?? reply.result?.ids?.[0];
    if (!id) throw new Error(`${label}: operação ${index + 1} não devolveu UUID`);
    return id;
  });
}

function basenameKey(file) {
  return path.basename(file).toLowerCase();
}

function textStyle(patch = {}) {
  return {
    fontFamily: "Inter",
    fontWeight: 700,
    pixelSize: 46,
    color: COLORS.cream,
    align: "center",
    valign: "center",
    lineHeight: 1.26,
    letterSpacing: -0.4,
    wordWrap: true,
    shadowEnabled: true,
    shadowOffsetX: 0,
    shadowOffsetY: 4,
    shadowBlur: 18,
    shadowOpacity: 0.9,
    shadowColor: "#FF000000",
    ...patch,
  };
}

function textClipConfig(id, item) {
  const operations = [
    { tool: "move_to_track", args: { clip: id, to_track: item.track, at: item.start } },
    { tool: "set_duration", args: { clip: id, duration: item.duration } },
    { tool: "set_transform", args: { clip: id, ...item.transform } },
    { tool: "set_text", args: { clip: id, style: item.style } },
  ];
  if (item.fade !== false) {
    operations.push(
      { tool: "set_clip_animation", args: { clip: id, which: "animIn", kind: "fade", duration: Math.min(0.45, item.duration / 3), ease: "easeOut" } },
      { tool: "set_clip_animation", args: { clip: id, which: "animOut", kind: "fade", duration: Math.min(0.35, item.duration / 3), ease: "easeInOut" } },
    );
  }
  return operations;
}

async function createTextItems(client, items, label) {
  if (!items.length) return [];
  const ids = await mintClips(
    client,
    items.map((item) => ({ tool: "add_text", args: { text: item.text, at: item.start, ...(item.preset ? { preset: item.preset } : {}) } })),
    `${label} — criar`,
  );
  await applyBatches(client, ids.flatMap((id, index) => textClipConfig(id, items[index])), `${label} — configurar`, 70);
  return ids;
}

function imageRect(asset, centerX, height, y) {
  const ratio = asset?.w > 0 && asset?.h > 0 ? asset.w / asset.h : 1;
  const width = height * ratio;
  return { x: round(centerX - width / 2), y, w: round(width), h: height };
}

async function saveCurrentProject(client, outputDirectory) {
  const state = requireOk(await client.call("inspect", { clips: false }), "Inspecionar projeto aberto");
  if (!state.dirty) return { saved: false, path: state.path ?? "" };
  ensureDirectory(outputDirectory);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const backup = path.join(outputDirectory, `backup-antes-da-traducao-${stamp}.drift`);
  requireOk(await client.call("save_project", { path: backup }), "Salvar projeto aberto");
  const verified = requireOk(await client.call("inspect", { clips: false }), "Confirmar salvamento");
  if (verified.dirty) throw new Error("O projeto aberto continuou marcado como alterado após o salvamento");
  return { saved: true, path: backup };
}

async function createTracks(client, trackDefinitions) {
  const state = requireOk(await client.call("inspect", { clips: false }), "Ler faixas iniciais");
  if (state.tracks?.length) {
    await applyBatches(
      client,
      Array.from({ length: state.tracks.length }, () => ({ tool: "remove_track", args: { track: 0 } })),
      "Remover faixas vazias",
    );
  }
  await applyBatches(
    client,
    [...trackDefinitions].reverse().map((track) => ({ tool: "add_track", args: { type: track.type } })),
    "Criar faixas nativas",
  );
  const next = requireOk(await client.call("inspect", { clips: false }), "Confirmar faixas");
  if (next.tracks.length !== trackDefinitions.length)
    throw new Error(`Esperadas ${trackDefinitions.length} faixas, recebidas ${next.tracks.length}`);
  return Object.fromEntries(trackDefinitions.map((track, index) => [track.id, index]));
}

async function importAssets(client, manifest) {
  const paths = manifest.assets.map((asset) => asset.path);
  const imported = requireOk(await client.call("import_media", { paths }), "Importar mídias");
  if (imported.missing?.length) throw new Error(`Mídias não encontradas pelo Editor: ${imported.missing.join(", ")}`);
  const listed = requireOk(await client.call("list_assets", {}), "Listar mídias").assets;
  const byName = new Map(listed.map((asset) => [String(asset.name).toLowerCase(), asset]));
  const resolved = new Map();
  for (const asset of manifest.assets) {
    const match = byName.get(basenameKey(asset.path));
    if (!match) throw new Error(`Mídia importada não localizada no bin: ${asset.path}`);
    resolved.set(asset.path, match);
  }
  return resolved;
}

async function placeBackground(client, manifest, tracks, assets) {
  const ids = await mintClips(
    client,
    manifest.scenes.map((scene) => ({
      tool: "place_clip",
      args: { asset: assets.get(scene.asset).id, at: scene.start, track: scene.lane === 0 ? tracks.backgroundA : tracks.backgroundB },
    })),
    "Cenas — posicionar",
  );
  const operations = [];
  for (let index = 0; index < ids.length; ++index) {
    const id = ids[index];
    const scene = manifest.scenes[index];
    const start = scene.start;
    const end = round(scene.start + scene.duration);
    const fromScale = scene.kenBurns.scaleFrom;
    const toScale = scene.kenBurns.scaleTo;
    const rect = (scale, pan) => ({
      width: round(manifest.composition.width * scale),
      height: round(manifest.composition.height * scale),
      x: round((manifest.composition.width - manifest.composition.width * scale) / 2 + pan),
      y: round((manifest.composition.height - manifest.composition.height * scale) / 2),
    });
    const first = rect(fromScale, scene.kenBurns.panFrom);
    const last = rect(toScale, scene.kenBurns.panTo);
    operations.push(
      { tool: "set_duration", args: { clip: id, duration: scene.duration } },
      { tool: "set_transform", args: { clip: id, x: first.x, y: first.y, w: first.width, h: first.height, opacity: 1 } },
      { tool: "set_keyframe", args: { clip: id, prop: "x", at: start, value: first.x } },
      { tool: "set_keyframe", args: { clip: id, prop: "x", at: end, value: last.x } },
      { tool: "set_keyframe", args: { clip: id, prop: "y", at: start, value: first.y } },
      { tool: "set_keyframe", args: { clip: id, prop: "y", at: end, value: last.y } },
      { tool: "set_keyframe", args: { clip: id, prop: "width", at: start, value: first.width } },
      { tool: "set_keyframe", args: { clip: id, prop: "width", at: end, value: last.width } },
      { tool: "set_keyframe", args: { clip: id, prop: "height", at: start, value: first.height } },
      { tool: "set_keyframe", args: { clip: id, prop: "height", at: end, value: last.height } },
    );
    if (scene.fade > 0) {
      operations.push(
        { tool: "set_keyframe", args: { clip: id, prop: "opacity", at: start, value: 0 } },
        { tool: "set_keyframe", args: { clip: id, prop: "opacity", at: round(start + scene.fade), value: 1 } },
      );
    }
    if (index + 1 < ids.length) {
      operations.push(
        { tool: "set_keyframe", args: { clip: id, prop: "opacity", at: round(end - SCENE_FADE_SECONDS), value: 1 } },
        { tool: "set_keyframe", args: { clip: id, prop: "opacity", at: end, value: 0 } },
      );
    }
  }
  await applyBatches(client, operations, "Cenas — Ken Burns e crossfade", 70);
  return ids;
}

async function placeAudio(client, manifest, tracks, assets) {
  const audio = manifest.assets.find((asset) => asset.id === "audio");
  const [id] = await mintClips(
    client,
    [{ tool: "place_clip", args: { asset: assets.get(audio.path).id, at: 0, track: tracks.audio } }],
    "Áudio",
  );
  await applyBatches(client, [{ tool: "set_duration", args: { clip: id, duration: manifest.composition.duration } }], "Áudio — duração");
  return id;
}

async function placeGrade(client, manifest, tracks) {
  const catalog = requireOk(await client.call("list_shapes", {}), "Listar formas").shapes;
  const rectangle = catalog.find((shape) => /rounded.?rect/i.test(shape.id)) ?? catalog.find((shape) => /rect/i.test(shape.id)) ?? catalog[0];
  if (!rectangle) throw new Error("O Editor não informou nenhuma forma nativa");
  const windows = fixedWindows(manifest.composition.duration);
  const ids = await mintClips(
    client,
    windows.map((window) => ({ tool: "add_shape", args: { shape: rectangle.id, at: window.start, track: tracks.grade } })),
    "Grade — criar",
  );
  const operations = ids.flatMap((id, index) => [
    { tool: "set_duration", args: { clip: id, duration: windows[index].duration } },
    { tool: "set_transform", args: { clip: id, x: 0, y: 0, w: manifest.composition.width, h: manifest.composition.height } },
    { tool: "set_shape_style", args: { clip: id, style: { kind: rectangle.id, fillKind: "solid", fill: COLORS.grade, strokeWidth: 0, cornerRadius: 0 } } },
  ]);
  await applyBatches(client, operations, "Grade — configurar", 60);
  return ids;
}

async function placeIdleAvatars(client, manifest, tracks, assets) {
  const windows = fixedWindows(manifest.composition.duration);
  const entries = [];
  for (const speaker of Object.keys(CAST)) {
    const media = manifest.assets.find((asset) => asset.id === `${speaker}-idle`);
    for (const window of windows) entries.push({ speaker, media, ...window });
  }
  const ids = await mintClips(
    client,
    entries.map((entry) => ({
      tool: "place_clip",
      args: { asset: assets.get(entry.media.path).id, at: entry.start, track: tracks[`idle-${entry.speaker}`] },
    })),
    "Avatares inativos — posicionar",
  );
  const operations = ids.flatMap((id, index) => {
    const entry = entries[index];
    const rect = imageRect(assets.get(entry.media.path), CAST[entry.speaker].centerX, 378, 626);
    return [
      { tool: "set_duration", args: { clip: id, duration: entry.duration } },
      { tool: "set_transform", args: { clip: id, ...rect, opacity: 0.5 } },
    ];
  });
  await applyBatches(client, operations, "Avatares inativos — configurar", 70);
  return ids;
}

async function placeActiveAvatars(client, manifest, tracks, assets) {
  const ids = await mintClips(
    client,
    manifest.turns.map((turn) => {
      const media = manifest.assets.find((asset) => asset.id === `${turn.speaker}-active`);
      return { tool: "place_clip", args: { asset: assets.get(media.path).id, at: turn.start, track: tracks.activeAvatar } };
    }),
    "Avatares ativos — posicionar",
  );
  const operations = ids.flatMap((id, index) => {
    const turn = manifest.turns[index];
    const media = manifest.assets.find((asset) => asset.id === `${turn.speaker}-active`);
    const rect = imageRect(assets.get(media.path), CAST[turn.speaker].centerX, 420, 584);
    return [
      { tool: "set_duration", args: { clip: id, duration: Math.max(0.05, turn.duration) } },
      { tool: "set_transform", args: { clip: id, ...rect, opacity: 1 } },
      { tool: "set_clip_animation", args: { clip: id, which: "animIn", kind: "fade", duration: 0.28, ease: "easeOut" } },
      { tool: "set_clip_animation", args: { clip: id, which: "animOut", kind: "fade", duration: 0.3, ease: "easeOut" } },
    ];
  });
  await applyBatches(client, operations, "Avatares ativos — configurar", 70);
  return ids;
}

async function placeSpeakerNames(client, manifest, tracks) {
  const items = manifest.turns.map((turn) => ({
    text: CAST[turn.speaker].name,
    start: turn.start,
    duration: Math.max(0.05, turn.duration),
    track: tracks.names,
    transform: { x: CAST[turn.speaker].centerX - 170, y: 995, w: 340, h: 54 },
    style: textStyle({
      pixelSize: 26,
      fontWeight: 800,
      letterSpacing: 3,
      color: CAST[turn.speaker].color,
      boxEnabled: true,
      boxColor: "#DB0E0A07",
      boxPadding: 10,
      boxRadius: 12,
    }),
  }));
  return createTextItems(client, items, "Identificação dos personagens");
}

async function placeCaptions(client, manifest, tracks) {
  const entries = [];
  for (const speaker of Object.keys(CAST)) {
    const pages = manifest.captions.filter((page) => page.speaker === speaker);
    for (const group of groupSubtitlePages(pages)) entries.push({ speaker, group });
  }
  entries.sort((a, b) => a.group.startMs - b.group.startMs);
  const ids = await mintClips(
    client,
    entries.map((entry) => ({ tool: "add_subtitle_clip", args: { at: round(entry.group.startMs / 1000) } })),
    "Legendas — criar faixas temporizadas",
  );
  const operations = [];
  for (let index = 0; index < ids.length; ++index) {
    const id = ids[index];
    const { speaker, group } = entries[index];
    const start = group.startMs / 1000;
    const duration = (group.endMs - group.startMs) / 1000;
    const cues = group.pages.map((page) => ({
      start: round((page.startMs - group.startMs) / 1000),
      end: round((page.endMs - group.startMs) / 1000),
      text: page.text,
      wordStarts: page.wordStartsMs.map((wordStart) => round((wordStart - group.startMs) / 1000)),
    }));
    operations.push(
      { tool: "move_to_track", args: { clip: id, to_track: tracks[`captions-${speaker}`], at: round(start) } },
      { tool: "set_duration", args: { clip: id, duration: round(duration) } },
      { tool: "set_transform", args: { clip: id, x: 180, y: 405, w: 1560, h: 170 } },
      {
        tool: "set_text",
        args: {
          clip: id,
          style: textStyle({
            color: COLORS.dimCream,
            boxEnabled: true,
            boxColor: COLORS.panel,
            boxPadding: 16,
            boxRadius: 22,
            accent: {
              rule: "karaoke",
              colorEnabled: true,
              color: CAST[speaker].color,
              sizeScale: 1.06,
            },
          }),
        },
      },
      { tool: "set_subtitle_cues", args: { clip: id, cues } },
    );
  }
  await applyBatches(client, operations, "Legendas — texto, cor e palavras", 24);
  return ids;
}

async function placeScripture(client, manifest, tracks) {
  const eyebrow = manifest.verses.map((verse) => ({
    text: `PSALM 77  •  VERSE ${verse.verse}`,
    start: verse.start,
    duration: verse.duration,
    track: tracks.scriptureEyebrow,
    transform: { x: 92, y: 78, w: 580, h: 45 },
    style: textStyle({ pixelSize: 22, fontWeight: 700, letterSpacing: 6, color: COLORS.gold, align: "left", shadowBlur: 14 }),
  }));
  const body = manifest.verses.map((verse) => ({
    text: verse.text,
    start: verse.start,
    duration: verse.duration,
    track: tracks.scriptureBody,
    transform: { x: 64, y: 64, w: 640, h: 350 },
    style: textStyle({
      fontFamily: "Playfair Display",
      pixelSize: 38,
      fontWeight: 500,
      align: "left",
      valign: "top",
      lineHeight: 1.32,
      boxEnabled: true,
      boxColor: "#E6060403",
      boxPadding: 28,
      boxRadius: 18,
    }),
  }));
  return [
    ...(await createTextItems(client, body, "Painéis bíblicos")),
    ...(await createTextItems(client, eyebrow, "Referências bíblicas")),
  ];
}

async function placeCards(client, manifest, tracks) {
  const items = manifest.cards.map((card) => ({
    text: `${card.eyebrow}\n${card.title}\n${card.lines.join("\n")}`,
    start: card.start,
    duration: card.duration,
    track: tracks.cards,
    transform: { x: 1364, y: 88, w: 480, h: 330 },
    style: textStyle({
      pixelSize: 24,
      fontWeight: 600,
      align: "left",
      valign: "top",
      lineHeight: 1.35,
      color: COLORS.cream,
      boxEnabled: true,
      boxColor: "#EB100B08",
      boxPadding: 26,
      boxRadius: 18,
      outlineEnabled: true,
      outlineWidth: 1,
      outlineColor: "#55E4A94F",
    }),
  }));
  return createTextItems(client, items, "Cards didáticos");
}

async function placeChips(client, manifest, tracks) {
  const items = manifest.chips.map((chip) => ({
    text: `${chip.term}  —  ${chip.gloss}`,
    start: chip.start,
    duration: chip.duration,
    track: tracks.chips,
    transform: { x: 610, y: 96, w: 700, h: 74 },
    style: textStyle({
      pixelSize: 22,
      fontWeight: 700,
      color: CAST[chip.speaker].color,
      boxEnabled: true,
      boxColor: "#F0100B08",
      boxPadding: 12,
      boxRadius: 32,
      outlineEnabled: true,
      outlineWidth: 1,
      outlineColor: CAST[chip.speaker].color,
    }),
  }));
  return createTextItems(client, items, "Chips de vocabulário");
}

async function saveCapture(client, at, destination) {
  const result = await client.callResult("capture", { at, full: true });
  const image = result?.content?.find((item) => item.type === "image");
  if (!image?.data) return null;
  ensureDirectory(path.dirname(destination));
  fs.writeFileSync(destination, Buffer.from(image.data, "base64"));
  return destination;
}

async function importManifest(manifest, options) {
  const outputDirectory = path.dirname(options.output);
  ensureDirectory(outputDirectory);
  const client = new NardotoMcpStdioClient({ executable: options.editorExe });
  const report = { startedAt: new Date().toISOString(), output: options.output, backup: null, captures: [] };
  try {
    await client.connect();
    report.backup = await saveCurrentProject(client, outputDirectory);
    if (options.backupOnly) return report;

    requireOk(await client.call("new_project", {}), "Criar projeto novo");
    requireOk(
      await client.call("apply", {
        ops: [
          { tool: "pause", args: {} },
          { tool: "seek", args: { at: 0 } },
          { tool: "set_overlap", args: { enabled: true } },
          { tool: "set_project_setup", args: { width: manifest.composition.width, height: manifest.composition.height, fps: manifest.composition.fps } },
          { tool: "set_background", args: { kind: "color", color: COLORS.background } },
          { tool: "set_metadata", args: { title: "Psalm 77 — HyperFrames traduzido", author: "Nardoto", description: "Estrutura nativa traduzida do projeto HyperFrames final." } },
        ],
      }),
      "Preparar projeto",
    );

    const trackDefinitions = [
      { id: "chips", type: "text" },
      { id: "cards", type: "text" },
      { id: "scriptureEyebrow", type: "text" },
      { id: "scriptureBody", type: "text" },
      { id: "captions-sarah", type: "subtitle" },
      { id: "captions-michael", type: "subtitle" },
      { id: "captions-james", type: "subtitle" },
      { id: "names", type: "text" },
      { id: "activeAvatar", type: "video" },
      { id: "idle-sarah", type: "video" },
      { id: "idle-michael", type: "video" },
      { id: "idle-james", type: "video" },
      { id: "grade", type: "shape" },
      { id: "backgroundA", type: "video" },
      { id: "backgroundB", type: "video" },
      { id: "audio", type: "audio" },
    ];
    const tracks = await createTracks(client, trackDefinitions);
    const assets = await importAssets(client, manifest);

    const counts = {};
    counts.audio = (await placeAudio(client, manifest, tracks, assets)) ? 1 : 0;
    counts.backgrounds = (await placeBackground(client, manifest, tracks, assets)).length;
    counts.grade = (await placeGrade(client, manifest, tracks)).length;
    counts.idleAvatars = (await placeIdleAvatars(client, manifest, tracks, assets)).length;
    counts.activeAvatars = (await placeActiveAvatars(client, manifest, tracks, assets)).length;
    counts.names = (await placeSpeakerNames(client, manifest, tracks)).length;
    counts.captions = (await placeCaptions(client, manifest, tracks)).length;
    counts.scripture = (await placeScripture(client, manifest, tracks)).length;
    counts.cards = (await placeCards(client, manifest, tracks)).length;
    counts.chips = (await placeChips(client, manifest, tracks)).length;

    requireOk(await client.call("save_project", { path: options.output }), "Salvar tradução");
    const state = requireOk(await client.call("inspect", { clips: true, cues: true }), "Validar projeto traduzido");
    if (state.dirty) throw new Error("O projeto traduzido continuou marcado como alterado após salvar");
    if (path.resolve(state.path) !== path.resolve(options.output))
      throw new Error(`O Editor confirmou outro caminho: ${state.path}`);

    const captureDirectory = path.join(path.dirname(options.manifest), "captures");
    for (const at of [11.13, 46.9, 122.7, 656.7, 1289.9, 1777.0]) {
      const destination = path.join(captureDirectory, `editor-${String(at).replace(".", "-")}s.jpg`);
      const saved = await saveCapture(client, at, destination);
      if (saved) report.captures.push(saved);
    }

    report.finishedAt = new Date().toISOString();
    report.counts = counts;
    report.validation = {
      path: state.path,
      dirty: state.dirty,
      duration: state.duration,
      tracks: state.tracks?.length ?? 0,
      revision: state.revision,
    };
    const reportPath = path.join(path.dirname(options.manifest), "relatorio-importacao.json");
    fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
    report.reportPath = reportPath;
    return report;
  } catch (error) {
    try {
      const partial = options.output.replace(/\.drift$/i, "-parcial.drift");
      await client.call("save_project", { path: partial });
      report.partial = partial;
    } catch {
      // O erro original é mais importante; a tentativa de recuperação é melhor esforço.
    }
    throw error;
  } finally {
    await client.close();
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }
  if (!args.project) throw new Error("Use --project para informar a pasta do HyperFrames");

  const project = path.resolve(args.project);
  const slug = path.basename(path.dirname(project)).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "hyperframes";
  const translationDirectory = path.join(DEFAULT_OUTPUT_ROOT, slug);
  ensureDirectory(translationDirectory);
  const manifestPath = path.resolve(args.manifest ?? path.join(translationDirectory, "manifesto.json"));
  const outputPath = path.resolve(args.output ?? path.join(WORKSPACE_ROOT, ".nardoto", "nardoto-editor-projects", `${slug}-hyperframes-traduzido.drift`));
  const editorExe = path.resolve(args.editorExe ?? defaultEditorExecutable());

  const manifest = await buildManifest(project);
  ensureDirectory(path.dirname(manifestPath));
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(`Manifesto: ${manifestPath}`);
  console.log(`Duração: ${manifest.composition.duration}s | cenas: ${manifest.stats.scenes} | páginas: ${manifest.stats.captionPages} | palavras: ${manifest.stats.words}`);

  if (!args.apply && !args.backupOnly) return;
  const report = await importManifest(manifest, {
    output: outputPath,
    manifest: manifestPath,
    editorExe,
    backupOnly: args.backupOnly,
  });
  if (args.backupOnly) console.log(`Projeto aberto preservado em: ${report.backup?.path || "já estava salvo"}`);
  else {
    console.log(`Projeto traduzido: ${report.output}`);
    console.log(`Faixas: ${report.validation.tracks} | duração: ${report.validation.duration}s | capturas: ${report.captures.length}`);
  }
}

main().catch((error) => {
  console.error(error.stack ?? error.message ?? String(error));
  process.exitCode = 1;
});

