import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const EDITOR_ROOT = path.resolve(HERE, "..", "..");

function newestDirectory(parent) {
  if (!fs.existsSync(parent)) return null;
  const entries = fs
    .readdirSync(parent, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
  return entries[0] ? path.join(parent, entries[0]) : null;
}

export function defaultEditorExecutable() {
  if (process.platform === "win32")
    return path.join(EDITOR_ROOT, "build-dev", "Release", "nardoto-editor.exe");
  return path.join(EDITOR_ROOT, "build-dev", "nardoto-editor");
}

function editorEnvironment() {
  const env = { ...process.env };
  if (process.platform !== "win32") return env;

  const qtVersion = newestDirectory(path.join(EDITOR_ROOT, ".tools", "qt"));
  if (!qtVersion) return env;
  const kit = newestDirectory(qtVersion);
  if (!kit) return env;
  const bin = path.join(kit, "bin");
  const plugins = path.join(kit, "plugins");
  env.PATH = `${bin}${path.delimiter}${env.PATH ?? ""}`;
  if (fs.existsSync(plugins)) env.QT_PLUGIN_PATH = plugins;
  return env;
}

function parseToolPayload(result) {
  const textBlock = result?.content?.find((item) => item.type === "text");
  if (!textBlock) return result;
  try {
    return JSON.parse(textBlock.text);
  } catch {
    return { ok: false, error: "invalid_tool_payload", detail: textBlock.text };
  }
}

export class NardotoMcpStdioClient {
  constructor({ executable = defaultEditorExecutable(), cwd = path.dirname(executable) } = {}) {
    this.executable = path.resolve(executable);
    this.cwd = path.resolve(cwd);
    this.process = null;
    this.buffer = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = "";
  }

  async connect() {
    if (this.process) return;
    if (!fs.existsSync(this.executable))
      throw new Error(`Executável do Nardoto Editor não encontrado: ${this.executable}`);

    this.process = spawn(this.executable, ["--mcp-stdio"], {
      cwd: this.cwd,
      env: editorEnvironment(),
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.process.stdout.on("data", (chunk) => this.#onStdout(chunk));
    this.process.stderr.on("data", (chunk) => {
      this.stderr += chunk.toString("utf8");
    });
    this.process.on("exit", (code) => {
      const detail = this.stderr.trim();
      for (const { reject } of this.pending.values())
        reject(new Error(`Ponte MCP encerrada (${code ?? "sem código"}). ${detail}`.trim()));
      this.pending.clear();
      this.process = null;
    });
    this.process.on("error", (error) => {
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
    });

    await this.request("initialize", {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "hyperframes-to-nardoto", version: "1.0.0" },
    });
    this.notify("notifications/initialized", {});
  }

  #onStdout(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length) {
      const crlf = this.buffer.indexOf("\r\n\r\n");
      const lf = this.buffer.indexOf("\n\n");
      const headerEnd = crlf >= 0 ? crlf : lf;
      if (headerEnd < 0) return;
      const separatorLength = crlf >= 0 ? 4 : 2;
      const header = this.buffer.subarray(0, headerEnd).toString("ascii");
      const match = header.match(/Content-Length:\s*(\d+)/i);
      if (!match) {
        this.buffer = this.buffer.subarray(headerEnd + separatorLength);
        continue;
      }
      const length = Number(match[1]);
      const bodyStart = headerEnd + separatorLength;
      if (this.buffer.length < bodyStart + length) return;
      const body = this.buffer.subarray(bodyStart, bodyStart + length).toString("utf8");
      this.buffer = this.buffer.subarray(bodyStart + length);
      let message;
      try {
        message = JSON.parse(body);
      } catch {
        continue;
      }
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message ?? JSON.stringify(message.error)));
      else pending.resolve(message.result);
    }
  }

  request(method, params = {}) {
    if (!this.process?.stdin.writable) throw new Error("Ponte MCP não conectada");
    const id = this.nextId++;
    const message = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.process.stdin.write(`${message}\n`, "utf8", (error) => {
        if (!error) return;
        this.pending.delete(id);
        reject(error);
      });
    });
  }

  notify(method, params = {}) {
    if (!this.process?.stdin.writable) return;
    this.process.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  async callResult(name, args = {}) {
    return this.request("tools/call", { name, arguments: args });
  }

  async call(name, args = {}) {
    return parseToolPayload(await this.callResult(name, args));
  }

  async close() {
    const child = this.process;
    if (!child) return;
    child.stdin.end();
    await new Promise((resolve) => {
      const timer = setTimeout(() => {
        child.kill();
        resolve();
      }, 2000);
      child.once("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
    this.process = null;
  }
}
