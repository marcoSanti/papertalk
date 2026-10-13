// Expose the remote Library server config to the page. main.js passes it via
// the URL query (?base=&token=); app.js reads window.PAPER2POD_SERVER.
const q = new URLSearchParams(location.search);
window.PAPER2POD_SERVER = {
  apiBase: q.get("base") || "http://localhost:8170/api",
  token: q.get("token") || "",
};

// Bridge for the in-page Connection settings overlay. In Electron this reads
// & writes the desktop's server config (server.json) via the main process; in a
// plain browser it falls back to localStorage so the overlay is still usable.
const { ipcRenderer } = require("electron");
window.PAPER2POD = {
  isDesktop: true,
  getConfig: () => ipcRenderer.invoke("cfg:get"),
  setConfig: (c) => ipcRenderer.invoke("cfg:set", c),
};