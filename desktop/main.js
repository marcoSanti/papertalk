const { app, BrowserWindow, Menu, dialog, ipcMain, nativeImage } = require("electron");
const path = require("path");
const fs = require("fs");
const { spawn, spawnSync } = require("child_process");

const APP_NAME = "paper2pod";
const ICON = path.join(__dirname, "icon.png");
app.setName(APP_NAME);

let win = null;

/* -------------------------------------------------------------------- */
/*  Client-side synthesis (dedicated venv, never the server's)          */
/* -------------------------------------------------------------------- */

const SRC_DIR = path.join(__dirname, ".."); // repo root: pyproject.toml (editable package install)
const SYNTH_SCRIPT = path.join(__dirname, "synth_worker.py");
const VENV_DIR = path.join(app.getPath("userData"), "venv");

function venvPython() {
  return process.platform === "win32"
    ? path.join(VENV_DIR, "Scripts", "python.exe")
    : path.join(VENV_DIR, "bin", "python");
}

function ensureVenv() {
  const py = venvPython();
  if (fs.existsSync(py)) return py;
  const uv = process.env.PAPER2POD_UV || "uv";
  console.log(`[synth] creating dedicated venv at ${VENV_DIR}`);
  const r1 = spawnSync(uv, ["venv", VENV_DIR, "--python", "3.13"], { stdio: "inherit" });
  if (r1.status !== 0) throw new Error(`uv venv failed (${r1.status})`);
  // Install paper2pod (editable, not the server's copy) + a local kokoro TTS stack.
  const r2 = spawnSync(uv, ["pip", "install", "--python", py, "-e", SRC_DIR], { stdio: "inherit" });
  if (r2.status !== 0) throw new Error(`paper2pod install failed (${r2.status})`);
  const r3 = spawnSync(uv, ["pip", "install", "--python", py, "kokoro", "soundfile", "numpy"],
                       { stdio: "inherit" });
  if (r3.status !== 0) throw new Error(`kokoro install failed (${r3.status})`);
  console.log("[synth] venv ready");
  return py;
}

const activeSynths = new Set(); // paper ids currently being synthesized

function cfgFor(c) {
  return {
    base: c.apiBase.replace(/\/+$/, ""),
    headers: c.token ? { Authorization: `Bearer ${c.token}` } : {},
  };
}

async function apiJson(cfg, pathname) {
  const res = await fetch(`${cfg.base}${pathname}`, { headers: cfg.headers });
  if (!res.ok) throw new Error(`GET ${pathname} -> ${res.status}`);
  return res.json();
}

async function synthPaper(py, id, cfg) {
  console.log(`[synth] synthesizing ${id}`);
  const child = spawn(py, [
    SYNTH_SCRIPT, "--api", cfg.base, "--token", cfg.token,
    "--paper", id, "--device", "auto", "--backend", "kokoro",
  ], { stdio: ["ignore", "pipe", "pipe"] });

  child.stdout.on("data", (buf) => process.stdout.write(`[synth:${id}] ${buf}`));
  child.stderr.on("data", (buf) => process.stderr.write(`[synth:${id}] ${buf}`));
  const code = await new Promise((resolve) => child.on("close", resolve));
  activeSynths.delete(id);
  if (code !== 0) console.error(`[synth] ${id} exited ${code}`);
  else console.log(`[synth] ${id} done`);
}

async function driveSynthesis(py, cfg) {
  let lib;
  try {
    lib = await apiJson(cfg, "/api/library");
  } catch (e) {
    return; // server unreachable yet; poll again next tick
  }
  for (const p of lib) {
    if (p.state === "awaiting_audio" && !activeSynths.has(p.id)) {
      activeSynths.add(p.id);
      synthPaper(py, p.id, cfg).catch((e) => {
        activeSynths.delete(p.id);
        console.error(`[synth] ${p.id} failed: ${e.message}`);
      });
    }
  }
}

function cfgPath() {
  return path.join(app.getPath("userData"), "server.json");
}

function loadCfg() {
  try {
    const c = JSON.parse(fs.readFileSync(cfgPath(), "utf8"));
    return { apiBase: String(c.apiBase || "").replace(/\/+$/, ""), token: String(c.token || "") };
  } catch (_) {
    return {
      apiBase: (process.env.PAPER2POD_SERVER_URL || "http://localhost:8170/api").replace(/\/+$/, ""),
      token: process.env.PAPER2POD_API_TOKEN || "",
    };
  }
}

function saveCfg(c) {
  fs.mkdirSync(path.dirname(cfgPath()), { recursive: true });
  fs.writeFileSync(cfgPath(), JSON.stringify({ apiBase: c.apiBase.replace(/\/+$/, ""), token: c.token }));
}

function uiEntry() {
  const candidates = [
    path.join(__dirname, "..", "src", "paper2pod", "web", "index.html"),
    path.join(__dirname, "..", "release", "web", "index.html"),
  ];
  return candidates.find((p) => fs.existsSync(p));
}

function load(win) {
  const entry = uiEntry();
  if (!entry) {
    dialog.showErrorBox("paper2pod", "web UI not found (install the Python package or build release/).");
    return;
  }
  const c = loadCfg();
  win.loadFile(entry, { query: { base: c.apiBase, token: c.token } });
}

function createWindow() {
  win = new BrowserWindow({
    width: 1280,
    height: 860,
    title: APP_NAME,
    show: false,
    ...(fs.existsSync(ICON) ? { icon: ICON } : {}),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      // preload sets window.PAPER2POD_SERVER for app.js, so it must share the
      // page's JS world (contextIsolation is true by default in modern Electron).
      contextIsolation: false,
      nodeIntegration: false,
    },
  });
  if (process.platform === "darwin" && fs.existsSync(ICON)) {
    app.dock.setIcon(nativeImage.createFromPath(ICON));
  }
  win.once("ready-to-show", () => win.show());
  load(win);
  win.on("closed", () => (win = null));
}

ipcMain.handle("cfg:get", () => loadCfg());
ipcMain.handle("cfg:set", (_e, c) => {
  saveCfg(c);
  if (win) load(win); // reload the main window against the (possibly new) server
  return true;
});

app.whenReady().then(async () => {
  createWindow();
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: "viewMenu" },
    { role: "editMenu" },
  ]));
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });

  // Client-side synthesis loop: ensure the dedicated venv, then keep pulling
  // papers that are waiting for audio and synthesize them locally.
  let py = null;
  try {
    py = ensureVenv();
  } catch (e) {
    console.error(`[synth] could not prepare venv: ${e.message}`);
  }
  if (py) {
    const cfg = cfgFor(loadCfg());
    driveSynthesis(py, cfg);
    setInterval(() => driveSynthesis(py, cfg), 4000);
  }
});

app.on("window-all-closed", () => app.quit());