/* paper2pod — frontend app. Vanilla JS, no build step. */
"use strict";

/* ------------------------------------------------------------------ */
/*  Config                                                             */
/* ------------------------------------------------------------------ */

const API_BASE = "/api";

const STAGE_LABELS = {
  extract: "Extracting text from PDF",
  notes: "Summarizing paper",
  outline: "Planning episode",
  segments: "Writing dialogue",
  audio: "Synthesizing audio",
  finalize: "Finalizing",
  done: "Done",
};

const TERMINAL_STATES = new Set(["done", "error"]);

/* ------------------------------------------------------------------ */
/*  Elements                                                           */
/* ------------------------------------------------------------------ */

const $ = (sel) => document.querySelector(sel);
const els = {
  menuBtn: $("#menu-btn"),
  backdrop: $("#drawer-backdrop"),
  sidebar: $("#sidebar"),
  dropzone: $("#dropzone"),
  fileInput: $("#file-input"),
  dzHint: $("#dz-hint"),
  dzPreview: $("#dz-preview"),
  tagList: $("#tag-list"),
  searchInput: $("#search-input"),
  searchClear: $("#search-clear"),
  sortSelect: $("#sort-select"),
  statusFilter: $("#status-filter"),
  libContext: $("#lib-context"),
  list: $("#lib-list"),
  empty: $("#empty"),
  emptyTitle: $("#empty-title"),
  emptyMsg: $("#empty-msg"),
  detail: $("#detail"),
  detailBody: $("#detail-body"),
  detailClose: $("#detail-close"),
  txOverlay: $("#transcript-overlay"),
  txBody: $("#tx-body"),
  txTitle: $("#tx-title"),
  txClose: $("#tx-close"),
  toastRegion: $("#toast-region"),
  headerNote: $("#header-note"),
  settingsBtn: $("#settings-btn"),
  settingsOverlay: $("#settings-overlay"),
  settingsClose: $("#settings-close"),
  settingsNote: $("#settings-note"),
  settingsForm: $("#settings-form"),
  setBaseUrl: $("#set-base-url"),
  setApiKey: $("#set-api-key"),
  setModel: $("#set-model"),
  setBackend: $("#set-backend"),
  setDevice: $("#set-device"),
  editOverlay: $("#edit-overlay"),
  editClose: $("#edit-close"),
  editForm: $("#edit-form"),
  editTitle: $("#edit-title"),
  editAuthors: $("#edit-authors"),
  editAffils: $("#edit-affils"),
  editDoi: $("#edit-doi"),
  editFilename: $("#edit-filename"),
};

/* ------------------------------------------------------------------ */
/*  State                                                              */
/* ------------------------------------------------------------------ */

const store = {
  papers: new Map(),          // id -> library record
  activeConverting: [],       // ids currently converting (running/queued)
  selectedId: null,           // paper shown in detail panel
  audioEl: null,              // currently playing <audio>
  overlayAudio: null,         // audio currently inside the transcript overlay
  statusCache: {},            // id -> latest /status payload
  cueCache: {},               // id -> [{start,end,speaker,words}] captions
  // UI filters
  view: "all",                // "all" | "fav" | "tag"
  activeTag: null,            // tag name when filtering by tag
  search: "",
  sort: "newest",
  statusFilter: "all",
};

/* ------------------------------------------------------------------ */
/*  HTTP helpers                                                       */
/* ------------------------------------------------------------------ */

async function api(path, opts) {
  const res = await fetch(API_BASE + path, opts);
  if (!res.ok) {
    let msg = `Request failed (${res.status})`;
    try {
      const data = await res.clone().json();
      msg = data.error || data.detail || msg;
    } catch (_) { /* non-json body, keep default */ }
    throw new Error(msg);
  }
  return res.status === 204 ? null : res.json();
}

/** PATCH a subset of { title, tags, favorite }. Returns updated library item. */
function patchMeta(id, body) {
  return api(`/papers/${id}/meta`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function uppercaseFirst(s) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

function formatDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return "";
  return d.toLocaleDateString(undefined, {
    year: "numeric", month: "short", day: "numeric",
  });
}

function formatBytes(bytes) {
  if (bytes == null || isNaN(bytes)) return "";
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / 1048576).toFixed(1) + " MB";
}

function escaped(s) {
  const div = document.createElement("div");
  div.textContent = s == null ? "" : String(s);
  // + encode quotes so the result is also safe inside attribute values ("value=...").
  return div.innerHTML.replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/* ------------------------------------------------------------------ */
/*  Toasts                                                             */
/* ------------------------------------------------------------------ */

function toast(message, ok) {
  const el = document.createElement("div");
  el.className = "toast " + (ok ? "ok" : "dot");
  const msg = document.createElement("span");
  msg.textContent = message;
  el.appendChild(msg);
  els.toastRegion.appendChild(el);
  setTimeout(() => {
    el.style.opacity = "0";
    el.style.transition = "opacity 0.3s";
    setTimeout(() => el.remove(), 300);
  }, 4200);
}

/* ------------------------------------------------------------------ */
/*  Settings (web UI config for when no config.yaml is present)        */
/* ------------------------------------------------------------------ */

let settingsState = { config_file: true, applied: { llm: {} }, editable: {} };

async function openSettings() {
  try {
    settingsState = await api("/settings");
  } catch (_) { /* keep last known state */ }
  const a = settingsState.applied || {};
  const e = settingsState.editable || {};
  // Show the EFFECTIVE values (config.yaml/env/CLI) when the web file leaves them
  // unset. The API key is returned only as a boolean when it comes from config or
  // env, so it can't be echoed — only a web-saved value is shown there.
  els.setBaseUrl.value = (a.llm && a.llm.base_url) || (e.llm && e.llm.base_url) || "";
  els.setApiKey.value = (e.llm && e.llm.api_key) || "";
  els.setModel.value = (a.llm && a.llm.model) || (e.llm && e.llm.model) || "";
  els.setBackend.value = (a.tts && a.tts.backend) || (e.tts && e.tts.backend) || "";
  els.setDevice.value = (a.tts && a.tts.device) || (e.tts && e.tts.device) || "";
  els.setApiKey.placeholder = (a.llm && a.llm.api_key) && !(e.llm && e.llm.api_key)
    ? "Configured by config.yaml / env (not shown)"
    : "sk-…";
  els.settingsNote.textContent = settingsState.config_file
    ? "Configured by config.yaml — these fields show the effective values; the file and env vars take precedence."
    : "No config.yaml found. Configure the LLM endpoint and key here to enable conversions.";
  els.settingsOverlay.hidden = false;
  els.settingsOverlay.setAttribute("aria-hidden", "false");
}

function closeSettings() {
  els.settingsOverlay.hidden = true;
  els.settingsOverlay.setAttribute("aria-hidden", "true");
}

async function saveSettings(e) {
  e.preventDefault();
  const body = {
    llm: {
      base_url: els.setBaseUrl.value.trim(),
      api_key: els.setApiKey.value.trim(),
      model: els.setModel.value.trim(),
    },
    tts: {
      backend: els.setBackend.value.trim(),
      device: els.setDevice.value.trim(),
    },
  };
  try {
    const res = await api("/settings", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    settingsState = res;
    closeSettings();
    toast("Settings saved", true);
    refreshConfigWarning();
  } catch (err) {
    toast("Could not save settings: " + err.message);
  }
}

function refreshConfigWarning() {
  const a = settingsState.applied && settingsState.applied.llm;
  const needsSetup = !settingsState.config_file && (!a || !a.model || !a.base_url ||
    a.base_url === "http://localhost:3000/api");
  if (needsSetup) {
    els.headerNote.textContent = "⚠ Needs LLM setup — open Settings";
    els.headerNote.style.color = "var(--bad, #e5484d)";
  } else {
    els.headerNote.textContent = "Local conversion";
    els.headerNote.style.color = "";
  }
}

els.settingsBtn.addEventListener("click", openSettings);
els.settingsClose.addEventListener("click", closeSettings);
els.settingsOverlay.addEventListener("click", (e) => { if (e.target === els.settingsOverlay) closeSettings(); });
els.settingsForm.addEventListener("submit", saveSettings);

/* ------------------------------------------------------------------ */
/*  Edit metadata (per-paper manual fixes)                             */
/* ------------------------------------------------------------------ */

function openEdit(id) {
  const p = store.papers.get(id);
  if (!p) return;
  els.editTitle.value = p.title || "";
  els.editAuthors.value = (Array.isArray(p.authors) ? p.authors : []).join("\n");
  els.editAffils.value = (Array.isArray(p.affiliations) ? p.affiliations : []).join("\n");
  els.editDoi.value = p.doi || "";
  els.editFilename.value = p.filename || "";
  els.editOverlay.hidden = false;
  els.editOverlay.setAttribute("aria-hidden", "false");
}

function closeEdit() {
  els.editOverlay.hidden = true;
  els.editOverlay.setAttribute("aria-hidden", "true");
}

async function saveEdit(e) {
  e.preventDefault();
  const p = store.papers.get(store.selectedId);
  if (!p) return;
  const splitLines = (s) => s.split("\n").map((x) => x.trim()).filter(Boolean);
  const body = {
    title: els.editTitle.value.trim(),
    filename: els.editFilename.value.trim(),
    authors: splitLines(els.editAuthors.value),
    affiliations: splitLines(els.editAffils.value),
    doi: els.editDoi.value.trim(),
  };
  try {
    const updated = await patchMeta(p.id, body);
    store.papers.set(p.id, updated);
    closeEdit();
    renderDetail();
    renderAll();
    toast("Saved", true);
  } catch (err) {
    toast("Could not save: " + err.message);
  }
}

els.editClose.addEventListener("click", closeEdit);
els.editOverlay.addEventListener("click", (e) => { if (e.target === els.editOverlay) closeEdit(); });
els.editForm.addEventListener("submit", saveEdit);

/* ------------------------------------------------------------------ */
/*  Stage helpers                                                      */
/* ------------------------------------------------------------------ */

function stageLabel(stage) {
  return STAGE_LABELS[stage] || (stage ? uppercaseFirst(stage) + "…" : "Processing…");
}

function isActive(p) {
  return p && (p.state === "running" || p.state === "queued");
}

function isDone(p) {
  return p && p.state === "done";
}

/* ================================================================== */
/*  Filtering + sorting                                               */
/* ================================================================== */

function tagCounts() {
  const counts = new Map();
  for (const p of store.papers.values()) {
    const tags = Array.isArray(p.tags) ? p.tags : [];
    for (const t of new Set(tags)) counts.set(t, (counts.get(t) || 0) + 1);
  }
  return counts;
}

function filteredPapers() {
  let out = [...store.papers.values()];

  // View / tag filter
  if (store.view === "fav") {
    out = out.filter((p) => !!p.favorite);
  } else if (store.view === "tag" && store.activeTag != null) {
    out = out.filter((p) => (Array.isArray(p.tags) ? p.tags : []).includes(store.activeTag));
  }

  // Status filter
  if (store.statusFilter !== "all") {
    out = out.filter((p) => p.state === store.statusFilter);
  }

  // Search (title / filename / tags)
  const q = store.search.trim().toLowerCase();
  if (q) {
    out = out.filter((p) => {
      const hay = [
        p.title || "",
        p.filename || "",
        (Array.isArray(p.tags) ? p.tags : []).join(" "),
      ].join(" ").toLowerCase();
      return hay.includes(q);
    });
  }

  // Sort
  const sort = store.sort;
  out.sort((a, b) => {
    if (sort === "title") {
      return (a.title || a.filename || "").localeCompare(b.title || b.filename || "");
    }
    if (sort === "oldest") {
      return (a.created_iso || "").localeCompare(b.created_iso || "");
    }
    if (sort === "recent") {
      // Recently converted first: done/with-audio at the top, then newest created.
      const aConv = isDone(a) || a.has_audio ? 1 : 0;
      const bConv = isDone(b) || b.has_audio ? 1 : 0;
      if (aConv !== bConv) return bConv - aConv;
      return (b.created_iso || "").localeCompare(a.created_iso || "");
    }
    // newest (default)
    return (b.created_iso || "").localeCompare(a.created_iso || "");
  });

  return out;
}

/* ================================================================== */
/*  Rendering                                                         */
/* ================================================================== */

function renderSidebar() {
  const counts = tagCounts();
  let favCount = 0;
  for (const p of store.papers.values()) if (p.favorite) favCount++;

  // View counts
  document.querySelectorAll("[data-count-for]").forEach((el) => {
    el.textContent = el.dataset.countFor === "fav" ? favCount : store.papers.size;
  });

  // Mark active view link
  document.querySelectorAll(".side-link").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.view === store.view);
  });

  // Tags
  const sortedTags = [...counts.keys()].sort((a, b) => a.localeCompare(b));
  if (sortedTags.length === 0) {
    els.tagList.innerHTML = '<span class="tag-empty">No tags yet</span>';
  } else {
    els.tagList.innerHTML = sortedTags.map((t) => `
      <button class="tag-item${store.view === "tag" && store.activeTag === t ? " active" : ""}"
        data-tag="${escaped(t)}" type="button">
        <span>${escaped(t)}</span>
        <span class="tag-item-count">${counts.get(t)}</span>
      </button>`).join("");
  }
  renderContext();
}

function renderContext() {
  const show = store.view === "fav" || store.view === "tag";
  els.libContext.hidden = !show;
  if (!show) return;
  const label = store.view === "fav"
    ? "Viewing: <b>Favorites</b>"
    : `Tag filter: <b>#${escaped(store.activeTag || "")}</b>`;
  els.libContext.innerHTML = `
    <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="var(--accent)" stroke-width="1.8"><path d="M22 3H2l8 9.5V19l4 2v-8.5z"/></svg>
    <span>${label}</span>
    <button class="context-clear" id="context-clear" type="button">Clear</button>`;
  $("#context-clear").addEventListener("click", clearView);
}

function clearView() {
  store.view = "all";
  store.activeTag = null;
  renderAll();
}

/* -- Library list -- */

function rowContent(p) {
  const title = p.title || p.filename || "Untitled";
  const st = (p.state === "running" || p.state === "queued") ? "running"
    : p.state === "done" ? "done" : p.state === "error" ? "error" : "unknown";
  const fav = p.favorite ? "on" : "";
  const isSel = store.selectedId === p.id ? "selected" : "";
  const busy = st === "running";
  const read = !!p.read;
  const frac = p.duration > 0 && p.progress > 0 ? Math.min(1, p.progress / p.duration) : 0;
  const coverUrl = p.has_pdf ? `${API_BASE}/papers/${p.id}/cover` : null;
  return `
    <li class="book book-${st} ${isSel} ${read ? "read" : "new"}" data-id="${escaped(p.id)}">
      <button class="book-open" data-open="${escaped(p.id)}" type="button" aria-label="Open ${escaped(title)}">
        <span class="book-cover">
          ${read ? "" : '<span class="book-badge" aria-hidden="true">NEW</span>'}
          ${coverUrl
            ? `<img class="book-img" src="${coverUrl}" alt="" loading="lazy" decoding="async" />`
            : '<span class="book-ic" aria-hidden="true"><svg viewBox="0 0 24 24" width="24" height="24" fill="currentColor"><path d="M4 4h7a2 2 0 0 1 2 2v13a2 2 0 0 0-2 2H4V4zm11 0v15a2 2 0 0 1 2-2V4h-2z"/><path d="M17 4h3v13a2 2 0 0 1-3 1.7V4z" opacity=".85"/></svg></span>'}
          ${busy ? '<span class="book-spin" aria-hidden="true"></span>' : ""}
          ${frac > 0 && !busy ? `<span class="book-readbar" aria-hidden="true"><i style="width:${Math.round(frac * 100)}%"></i></span>` : ""}
        </span>
        <span class="book-title">${escaped(title)}</span>
      </button>
      <button class="book-star ${fav}" data-fav="${escaped(p.id)}" type="button"
        aria-label="${p.favorite ? "Remove from favorites" : "Add to favorites"}" aria-pressed="${p.favorite ? "true" : "false"}">
        <svg viewBox="0 0 24 24" width="15" height="15" stroke="currentColor" stroke-width="1.6"><path d="M12 3.6l2.6 5.3 5.9.9-4.3 4.1 1 5.9-5.2-2.7-5.2 2.7 1-5.9-4.3-4.1 5.9-.9z"/></svg>
      </button>
      <button class="book-read" data-read="${escaped(p.id)}" type="button"
        aria-label="${read ? "Mark as unread" : "Mark as read"}" title="${read ? "Mark as unread" : "Mark as read"}">
        <svg viewBox="0 0 24 24" width="13" height="13" stroke="currentColor" stroke-width="2.2" fill="none"><path d="M4 12.5l5 5L20 6.5"/></svg>
      </button>
    </li>`;
}

function cardSig(p) {
  const st = (p.state === "running" || p.state === "queued") ? "running"
    : p.state === "done" ? "done" : p.state === "error" ? "error" : "unknown";
  const frac = p.duration > 0 && p.progress > 0 ? Math.min(1, p.progress / p.duration) : 0;
  return [p.title || p.filename || "Untitled", st, !!p.favorite, !!p.read,
          Math.round(frac * 100), store.selectedId === p.id, !!p.has_pdf].join("|");
}

/** Signature of the detail-panel fields, so poll ticks don't rebuild/mute the player. */
function detailSig(p) {
  return [p.title, !!p.has_audio, !!p.has_script, p.state, p.stage, p.message,
          p.stageLabel, p.statusMessage, (p.authors || []).join("|"),
          (p.tags || []).join("|"), !!p.favorite, !!p.read].join("|");
}

function renderList() {
  const papers = filteredPapers();
  const hasPapers = store.papers.size > 0;
  const hasAny = papers.length > 0;
  const isFiltering = !!(store.search || store.statusFilter !== "all" || store.view !== "all");

  els.empty.hidden = hasAny || !hasPapers;
  if (!hasPapers) { els.emptyTitle.textContent = "Your library is empty"; els.emptyMsg.textContent = "Upload a PDF to start converting it into a podcast."; els.list.innerHTML = ""; return; }
  if (!hasAny) { els.emptyTitle.textContent = "No results"; els.emptyMsg.textContent = isFiltering ? "Nothing matches your current filters. Try clearing the search or status filter." : "Nothing in this collection yet."; els.list.innerHTML = ""; return; }

  const seen = new Set();
  const frag = document.createDocumentFragment();
  for (const p of papers) {
    seen.add(p.id);
    const existing = els.list.querySelector(`li[data-id="${CSS.escape(p.id)}"]`);
    if (existing && existing.dataset.sig === cardSig(p)) { frag.appendChild(existing); continue; }
    if (existing) existing.remove();
    const li = document.createElement("li");
    li.innerHTML = rowContent(p);
    li.dataset.sig = cardSig(p);
    frag.appendChild(li.firstElementChild);
  }
  // Drop cards that are no longer visible (e.g. removed by a filter).
  els.list.querySelectorAll("li[data-id]").forEach((li) => {
    if (!seen.has(li.dataset.id)) li.remove();
  });
  els.list.appendChild(frag);
}

/** Re-render sidebar + list (cheap for single-record updates when supplied). */
function renderAll() { renderSidebar(); renderList(); }

/** Update a single row in place; also refresh sidebar nav counts + detail. */
function updateRow(id) {
  renderSidebar();
  renderList();
  if (store.selectedId === id) renderDetail();
}

/* ================================================================== */
/*  Favorite / tags / title editing (optimistic + rollback)           */
/* ================================================================== */

async function toggleFavorite(id) {
  const p = store.papers.get(id);
  if (!p) return;
  const prev = !!p.favorite;
  const next = !prev;
  p.favorite = next;
  updateRow(id);
  try {
    const updated = await patchMeta(id, { favorite: next });
    store.papers.set(id, updated);
  } catch (err) {
    p.favorite = prev;
    toast("Could not update favorite: " + err.message);
  }
  updateRow(id);
}

async function saveTitle(id, title) {
  const p = store.papers.get(id);
  if (!p) return;
  const clean = (title || "").replace(/\s+/g, " ").trim();
  const prev = p.title;
  if (clean === prev) return;
  if (!clean) { toast("Title cannot be empty", true); return; }
  p.title = clean;
  updateRow(id);
  try {
    const updated = await patchMeta(id, { title: clean });
    store.papers.set(id, updated);
  } catch (err) {
    p.title = prev;
    toast("Could not rename: " + err.message);
  }
  updateRow(id);
}

/** Add a tag. Calls PATCH with the FULL new tag list. */
async function addTag(id, tag) {
  const p = store.papers.get(id);
  if (!p) return;
  const tagList = (Array.isArray(p.tags) ? p.tags : []).slice();
  const clean = (tag || "").trim().replace(/\s+/g, "_");
  if (!clean) return;
  if (tagList.includes(clean)) {
    toast(`Tag "#${clean}" already exists`, true);
    return;
  }
  tagList.push(clean);
  const prevTags = p.tags || [];
  p.tags = tagList;
  updateRow(id);
  try {
    const updated = await patchMeta(id, { tags: tagList });
    store.papers.set(id, updated);
  } catch (err) {
    p.tags = prevTags;
    toast("Could not add tag: " + err.message);
  }
  updateRow(id);
}

/** Remove a tag by setting the FULL new list. */
async function removeTag(id, tag) {
  const p = store.papers.get(id);
  if (!p) return;
  const prevTags = (Array.isArray(p.tags) ? p.tags : []).slice();
  const next = prevTags.filter((t) => t !== tag);
  if (next.length === prevTags.length) return;
  p.tags = next;
  updateRow(id);
  try {
    const updated = await patchMeta(id, { tags: next });
    store.papers.set(id, updated);
  } catch (err) {
    p.tags = prevTags;
    toast("Could not remove tag: " + err.message);
  }
  updateRow(id);
}

/* ================================================================== */
/*  Library loading                                                   */
/* ================================================================== */

async function loadLibrary() {
  let items;
  try {
    items = await api("/library");
  } catch (err) {
    toast("Could not load library: " + err.message);
    if (!store.papers.size) renderList();
    return;
  }
  if (!Array.isArray(items)) items = [];
  const seen = new Set();
  for (const p of items) {
    seen.add(p.id);
    if (p.tags == null) p.tags = [];
    if (p.favorite == null) p.favorite = false;
    store.papers.set(p.id, p);
  }
  for (const id of store.papers.keys()) {
    if (!seen.has(id)) {
      store.papers.delete(id);
      if (store.selectedId === id) closeDetail();
    }
  }
  reconcileConverting();
  renderAll();
}

/* ================================================================== */
/*  Toolbar (floating active-conversion bar)                          */
/* ================================================================== */

function reconcileConverting() {
  store.activeConverting = [...store.papers.entries()]
    .filter(([, p]) => p.state === "running" || p.state === "queued")
    .sort((a, b) => (b[1].created_iso || "").localeCompare(a[1].created_iso || ""))
    .map(([id]) => id);
}

/* ================================================================== */
/*  Detail panel                                                      */
/* ================================================================== */

function openDetail(id) {
  store.selectedId = id;
  els.detail.hidden = false;
  els.detailBody.innerHTML = "";
  renderDetail();
  renderList(); // highlight selected row
  if (window.innerWidth <= 980) els.detail.scrollIntoView({ behavior: "smooth" });
}

function closeDetail() {
  if (store.audioEl) {
    store.audioEl.pause();
    store.audioEl = null;
  }
  store.selectedId = null;
  els.detail.hidden = true;
  els.detailBody.innerHTML = "";
  renderList();
}

function audioReady(p) {
  return p.has_audio || (isDone(p) && store.statusCache?.[p.id]?.state === "done");
}

function statusBlockHTML(p) {
  const state = p.state || "queued";
  const prog = Math.round((p.progress || 0) * 100);
  const cls = state === "done" ? "done" : (state === "error" ? "error" : "shimmer");
  const stage = state === "done" ? "Done" : stageLabel(p.stage);
  const msg = state === "error"
    ? (p.error || p.message || "Something went wrong.")
    : (p.statusMessage || stageLabel(p.stage || "extract"));
  return `
    <div class="d-status">
      <p class="d-status-stage">${escaped(stage)}</p>
      <p class="d-status-msg${state === "error" ? " error" : ""}">${escaped(msg)}</p>
      <div class="pbar"><div class="pfill ${cls}" style="width:${prog}%"></div></div>
      <span class="pnum">${prog}%</span>
    </div>`;
}

function renderDetail() {
  const p = store.papers.get(store.selectedId);
  if (!p) { closeDetail(); return; }

  const date = formatDate(p.created_iso || p.created_at);
  const title = p.title || p.filename || "Untitled";
  const cacheBust = Date.now();
  const hasAudio = audioReady(p);

  const favBtn = `<button class="d-star ${p.favorite ? "on" : ""}" id="d-fav" type="button"
    aria-pressed="${p.favorite ? "true" : "false"}" aria-label="Toggle favorite">
    <svg viewBox="0 0 24 24" width="18" height="18" stroke="currentColor" stroke-width="1.6"><path d="M12 3.6l2.6 5.3 5.9.9-4.3 4.1 1 5.9-5.2-2.7-5.2 2.7 1-5.9L3.6 9.8l5.9-.9z"/></svg>
  </button>`;

  const tagChips = (Array.isArray(p.tags) ? p.tags : []).map((t) =>
    `<span class="d-tag-chip">#${escaped(t)}<button data-del-tag="${escaped(t)}" type="button" aria-label="Remove tag ${escaped(t)}">×</button></span>`
  ).join("");

  const statusHTML = hasAudio
    ? `<p class="detail-kicker">Ready to play</p>`
    : statusBlockHTML(p);

  const authors = Array.isArray(p.authors) ? p.authors : [];
  const affils = Array.isArray(p.affiliations) ? p.affiliations : [];
  const metaBlock = (authors.length || affils.length || p.doi)
    ? `<div class="d-meta-block">
        ${authors.length ? `<p class="d-authors">${escaped(authors.join(" · "))}</p>` : ""}
        ${affils.length ? `<p class="d-affil">${escaped(affils.join(" · "))}</p>` : ""}
        ${p.doi ? `<p class="d-doi">DOI: <a href="https://doi.org/${escaped(p.doi)}" target="_blank" rel="noopener">${escaped(p.doi)}</a></p>` : ""}
      </div>`
    : "";

  const dHeadRow = `
        <p class="d-meta">${escaped(p.filename || "—")}${date ? " · " + date : ""}</p>
        <div class="d-head-actions">
          ${favBtn}
          <button class="icon-btn d-edit" id="d-edit" type="button" aria-label="Edit metadata"
            title="Edit metadata">
            <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>
          </button>
        </div>`;

  const dHead = `
    <div class="d-head">
      <input class="d-title-input" id="d-title" type="text" value="${escaped(title)}"
        placeholder="Untitled" aria-label="Paper title" maxlength="200" />
      ${dHeadRow}
    </div>`;

  els.detailBody.innerHTML = `
    <p class="d-kicker">Paper</p>
    ${dHead}

    ${metaBlock}

    <div class="d-tags">
      <div class="d-tags-head">
        <span>Tags</span>
      </div>
      <div class="d-tag-chips" id="d-tag-chips">${tagChips || '<span class="tag-empty">No tags</span>'}</div>
      <form class="d-tag-add" id="d-tag-form">
        <input class="d-tag-input" id="d-tag-input" placeholder="Add a tag…" aria-label="New tag" maxlength="30" autocomplete="off" />
        <button type="submit">Add</button>
      </form>
    </div>

    ${statusHTML}
    ${hasAudio ? `
    <div class="d-player" id="d-player">
      <audio class="player-audio" id="d-audio" preload="metadata" src="${API_BASE}/papers/${p.id}/audio?t=${cacheBust}"></audio>
      <button class="p-play" id="d-play" type="button" aria-label="Play or pause"></button>
      <div class="p-main">
        <div class="p-caption" id="p-caption">
          <span class="p-spk" id="p-spk"></span><span class="p-txt" id="p-txt"></span>
        </div>
        <div class="p-bar">
          <input class="p-seek" id="p-seek" type="range" min="0" max="1000" value="0" aria-label="Seek" />
        </div>
        <div class="p-time"><span id="p-cur">0:00</span>/<span id="p-dur">–:––</span></div>
      </div>
    </div>` : ""}

    <div class="d-downloads">
      <a class="dl-btn" href="${API_BASE}/papers/${p.id}/file?kind=pdf">PDF</a>
      <button class="dl-btn ${p.has_script ? "" : "disabled"}" id="d-transcript" type="button">Transcript</button>
      <button class="dl-btn ${p.has_script ? "" : "disabled"}" id="d-script" type="button">Script</button>
      <a class="dl-btn ${p.has_script ? "" : "disabled"}" href="${API_BASE}/papers/${p.id}/file?kind=srt">SRT</a>
    </div>

    <div class="d-danger">
      <button id="d-refresh-meta" type="button">Refresh metadata</button>
      <button id="d-rerun" type="button">Rerun</button>
      <button id="d-delete" class="d-del" type="button">Delete</button>
    </div>`;

  // Wire detail interactions
  const titleEl = $("#d-title");
  const saveTitleNow = () => { saveTitle(store.selectedId, titleEl.value); };
  titleEl.addEventListener("change", saveTitleNow);
  titleEl.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); titleEl.blur(); }
    if (e.key === "Escape") { titleEl.value = title; titleEl.blur(); }
  });

  $("#d-fav").addEventListener("click", () => toggleFavorite(store.selectedId));
  const editBtn = $("#d-edit");
  if (editBtn) editBtn.addEventListener("click", () => openEdit(store.selectedId));

  const tagForm = $("#d-tag-form");
  const tagInput = $("#d-tag-input");
  tagForm.addEventListener("submit", (e) => {
    e.preventDefault();
    addTag(store.selectedId, tagInput.value);
    tagInput.value = "";
  });
  els.detailBody.querySelectorAll("[data-del-tag]").forEach((b) => {
    b.addEventListener("click", () => removeTag(store.selectedId, b.dataset.delTag));
  });

  const audio = $("#d-audio");
  if (audio) {
    store.audioEl = audio;
    wirePlayer(p);
  }

  $("#d-rerun").addEventListener("click", onRerun);
  $("#d-delete").addEventListener("click", onDelete);

  const refreshBtn = $("#d-refresh-meta");
  if (refreshBtn) refreshBtn.addEventListener("click", onRefreshMeta);

  const txBtn = $("#d-transcript");
  if (txBtn) txBtn.addEventListener("click", () => openTranscript(store.selectedId));

  const scriptBtn = $("#d-script");
  if (scriptBtn) scriptBtn.addEventListener("click", () => openScript(store.selectedId));
}

/* ================================================================== */
/*  Transcript overlay                                                */
/* ================================================================== */

function openTranscript(id) {
  const p = store.papers.get(id);
  els.txTitle.textContent = (p && (p.title || p.filename)) || "Transcript";
  if (store.overlayAudio) { store.overlayAudio.pause(); store.overlayAudio = null; }
  els.txBody.innerHTML = '<p class="tx-loading">Loading…</p>';
  els.txOverlay.hidden = false;
  els.txOverlay.setAttribute("aria-hidden", "false");
  els.txBody.scrollTop = 0;

  api(`/papers/${id}/captions`)
    .then((cues) => {
      if (!Array.isArray(cues) || !cues.length) {
        // No timed audio yet: fall back to the static structured transcript.
        api(`/papers/${id}/transcript`)
          .then((script) => renderTranscript(id, script))
          .catch((err) => { els.txBody.innerHTML = `<p class="tx-error">${escaped(err.message)}</p>`; });
        return;
      }
      els.txBody.innerHTML = "";
      const playerWrap = document.createElement("div");
      playerWrap.className = "tx-player";
      els.txBody.appendChild(playerWrap);

      const list = document.createElement("div");
      list.className = "tx-live";
      list.innerHTML = cues.map((c, i) =>
        `<div class="tx-turn" data-i="${i}">
          <span class="tx-speaker tx-c${i % 2}">${escaped(c.speaker || "Speaker")}</span>
          <span class="tx-text">${escaped(c.text)}</span>
        </div>`).join("");
      els.txBody.appendChild(list);

      store.overlayAudio = installPlayer(playerWrap, p, (t) => {
        let idx = cues.findIndex((c) => t >= c.start && t <= c.end);
        if (idx === -1 && cues.length && t > 0 && t < cues[0].start) idx = 0;
        list.querySelectorAll(".tx-turn.on").forEach((n) => n.classList.remove("on"));
        if (idx !== -1) {
          const el = list.querySelector(`[data-i="${idx}"]`);
          if (el) { el.classList.add("on"); el.scrollIntoView({ block: "nearest", behavior: "smooth" }); }
        }
      });
    })
    .catch(() => {
      els.txBody.innerHTML = '<p class="tx-error">Could not load captions.</p>';
    });
}

/** Build a self-contained player inside `host` and wire it. Returns the <audio>. */
function installPlayer(host, p, onTick) {
  host.innerHTML = `
    <div class="d-player">
      <audio class="player-audio" preload="metadata" src="${API_BASE}/papers/${p.id}/audio?t=${Date.now()}"></audio>
      <button class="p-play" type="button" aria-label="Play or pause"></button>
      <div class="p-main">
        <div class="p-caption"><span class="p-spk"></span><span class="p-txt"></span></div>
        <div class="p-bar"><input class="p-seek" type="range" min="0" max="1000" value="0" aria-label="Seek" /></div>
        <div class="p-time"><span class="p-cur">0:00</span>/<span class="p-dur">–:––</span></div>
      </div>
    </div>`;
  return wirePlayerCtl({
    audio: host.querySelector(".player-audio"),
    playBtn: host.querySelector(".p-play"),
    seek: host.querySelector(".p-seek"),
    curEl: host.querySelector(".p-cur"),
    durEl: host.querySelector(".p-dur"),
    spkEl: host.querySelector(".p-spk"),
    txtEl: host.querySelector(".p-txt"),
  }, p, onTick);
}

function closeTranscript() {
  if (store.overlayAudio) { store.overlayAudio.pause(); store.overlayAudio = null; }
  els.txOverlay.hidden = true;
  els.txOverlay.setAttribute("aria-hidden", "true");
}

/** Show the full written episode script in the same floating overlay (no navigation). */
function openScript(id) {
  const p = store.papers.get(id);
  els.txTitle.textContent = (p && (p.title || p.filename)) || "Script";
  if (store.overlayAudio) { store.overlayAudio.pause(); store.overlayAudio = null; }
  els.txBody.innerHTML = '<p class="tx-loading">Loading…</p>';
  els.txOverlay.hidden = false;
  els.txOverlay.setAttribute("aria-hidden", "false");
  els.txBody.scrollTop = 0;
  api(`/papers/${id}/transcript`)
    .then((script) => renderTranscript(id, script))
    .catch((err) => { els.txBody.innerHTML = `<p class="tx-error">${escaped(err.message)}</p>`; });
}

function renderTranscript(id, script) {
  const speakers = new Map((script.speakers || []).map((s, i) => [s.name, { color: i % 2, name: s.name, persona: s.persona }]));
  const speakersInUse = new Set();
  const blocks = (script.segments || []).map((seg, si) => {
    const turns = (seg.turns || []).map((t) => {
      speakersInUse.add(t.speaker);
      return `<div class="tx-turn">
        <span class="tx-speaker tx-c${speakers.get(t.speaker)?.color ?? 0}">${escaped(t.speaker)}</span>
        <span class="tx-text">${escaped(t.text)}</span>
      </div>`;
    }).join("");
    return `<section class="tx-seg">
      <h4 class="tx-seg-head"><span>${si + 1}</span> ${escaped(seg.title || "")}</h4>
      ${turns}
    </section>`;
  }).join("");
  els.txBody.innerHTML = blocks || '<p class="tx-error">No transcript yet.</p>';
}

/* ================================================================== */
/*  Actions: rerun / delete                                           */
/* ================================================================== */

async function onRerun() {
  const id = store.selectedId;
  if (!id || !store.papers.has(id)) return;
  if (!confirm("Regenerate the audio for this paper? This replaces the current audio.")) return;
  try {
    await api(`/papers/${id}/rerun`, { method: "POST" });
    adoptStatus(id, { state: "queued", stage: "extract", progress: 0, message: "Queued" });
    renderAll();
    renderDetail();
  } catch (err) {
    toast("Rerun failed: " + err.message);
  }
}

async function onDelete() {
  const id = store.selectedId;
  if (!id || !store.papers.has(id)) return;
  if (!confirm("Delete this paper and its audio?")) return;
  try {
    await api(`/papers/${id}`, { method: "DELETE" });
  } catch (err) {
    toast("Delete failed: " + err.message);
    return;
  }
  if (store.audioEl) { store.audioEl.pause(); store.audioEl = null; }
  if (store.selectedId === id) closeDetail();
  store.papers.delete(id);
  reconcileConverting();
  renderAll();
}

async function toggleRead(id) {
  const p = store.papers.get(id);
  if (!p) return;
  const next = !p.read;
  const prev = p.read;
  p.read = next;
  updateRow(id);
  try {
    store.papers.set(id, await patchMeta(id, { read: next }));
  } catch (err) {
    p.read = prev;
    toast("Could not update read state: " + err.message);
  }
  updateRow(id);
}

/** Persist a paper's listening position + known duration. Fire-and-forget. */
async function saveProgress(id, progress, duration) {
  const p = store.papers.get(id);
  if (p) { p.progress = progress; if (duration) p.duration = duration; }
  try {
    const updated = await patchMeta(id, {
      progress: Math.round((progress || 0) * 10) / 10,
      ...(duration ? { duration: Math.round(duration * 10) / 10 } : {}),
    });
    store.papers.set(id, updated);
    renderList(); // refresh shelf read-bars only; detail must not be rebuilt mid-play
  } catch (_) { /* ignore transient save errors */ }
}

async function onRefreshMeta() {
  const id = store.selectedId;
  if (!id || !store.papers.has(id)) return;
  const btn = $("#d-refresh-meta");
  if (btn) btn.disabled = true;
  try {
    const entry = await api(`/papers/${id}/refresh-meta`, { method: "POST" });
    store.papers.set(id, entry);
    renderAll();
    renderDetail();
    toast("Metadata refreshed");
  } catch (err) {
    toast("Refresh failed: " + err.message);
  } finally {
    if (btn) btn.disabled = false;
  }
}

/* ================================================================== */
/*  Custom audio player (word-tracked captions)                        */
/* ================================================================== */

function fmtTime(s) {
  if (!isFinite(s)) return "–:––";
  const m = Math.floor(s / 60), sec = Math.floor(s % 60);
  return `${m}:${String(sec).padStart(2, "0")}`;
}

function wirePlayerCtl(a, p, onTick) {
  // a = { audio, playBtn, seek, curEl, durEl, spkEl, txtEl } — each an element.
  let cues = store.cueCache[p.id] || null;
  let duration = 0;
  let lastSave = 0;

  const persistPos = (force) => {
    const now = Date.now();
    if (!force && now - lastSave < 5000) return;
    lastSave = now;
    const cur = a.audio.currentTime || 0;
    const dur = a.audio.duration || 0;
    if (!dur) return;
    saveProgress(p.id, cur, dur);
  };

  const syncCaptions = (t) => {
    if (!cues) return;
    const c = cues.find((x) => t >= x.start && t <= x.end);
    a.spkEl.textContent = c && c.speaker ? c.speaker + ":" : "";
    if (!c) { a.txtEl.innerHTML = ""; return; }
    const frac = c.end > c.start ? Math.min(1, Math.max(0, (t - c.start) / (c.end - c.start))) : 1;
    const active = Math.floor(frac * c.words.length);
    a.txtEl.innerHTML = c.words.map((w, i) =>
      `<span class="p-w${i < active ? " on" : ""}">${escaped(w)}</span>`).join(" ");
  };

  const syncSeek = () => {
    if (!duration) return;
    a.seek.value = String(Math.round((a.audio.currentTime / duration) * 1000));
    a.curEl.textContent = fmtTime(a.audio.currentTime);
  };

  const refreshPlayBtn = () => {
    a.playBtn.classList.toggle("playing", !a.audio.paused);
    a.playBtn.setAttribute("aria-label", a.audio.paused ? "Play" : "Pause");
  };

  const togglePlay = () => {
    if (!cues) fetchCaptions(); // kick off captions on first interaction
    if (a.audio.paused) { a.audio.play().catch(() => {}); }
    else a.audio.pause();
  };

  const fetchCaptions = () => {
    if (cues !== null) return;
    syncCaptions(0);
    api(`/papers/${p.id}/captions`).then((list) => {
      cues = Array.isArray(list) ? list : [];
      store.cueCache[p.id] = cues;
      syncCaptions(a.audio.currentTime);
    }).catch(() => { cues = []; store.cueCache[p.id] = []; });
  };

  a.playBtn.addEventListener("click", togglePlay);
  a.playBtn.addEventListener("keydown", (e) => {
    if (e.code === "Space") { e.preventDefault(); togglePlay(); }
  });

  a.seek.addEventListener("input", () => {
    if (!duration) return;
    a.audio.currentTime = (a.seek.value / 1000) * duration;
    syncSeek();
    syncCaptions(a.audio.currentTime);
    if (onTick) onTick(a.audio.currentTime);
  });

  a.audio.addEventListener("loadedmetadata", () => {
    duration = a.audio.duration;
    a.durEl.textContent = fmtTime(duration);
    // Resume where the user left off (unless they'd already finished it).
    const saved = p.progress > 0 && p.progress < duration - 5 ? p.progress : 0;
    if (saved > 0) {
      a.audio.currentTime = saved;
      syncSeek();
      syncCaptions(saved);
      if (onTick) onTick(saved);
    } else {
      syncSeek();
    }
  });
  a.audio.addEventListener("timeupdate", () => {
    syncSeek();
    syncCaptions(a.audio.currentTime);
    if (onTick) onTick(a.audio.currentTime);
    persistPos(false);
  });
  a.audio.addEventListener("play", refreshPlayBtn);
  a.audio.addEventListener("pause", refreshPlayBtn);
  a.audio.addEventListener("ended", () => {
    refreshPlayBtn();
    a.seek.value = "0";
    a.curEl.textContent = "0:00";
    syncCaptions(0);
    if (onTick) onTick(0);
    persistPos(true);
  });

  fetchCaptions();
  return a.audio;
}

function wirePlayer(p) {
  store.audioEl = wirePlayerCtl({
    audio: $("#d-audio"),
    playBtn: $("#d-play"),
    seek: $("#p-seek"),
    curEl: $("#p-cur"),
    durEl: $("#p-dur"),
    spkEl: $("#p-spk"),
    txtEl: $("#p-txt"),
  }, p, null);
}

/* ================================================================== */
/*  Upload                                                             */
/* ================================================================== */

function setDropzoneBusy(busy, label) {
  els.dropzone.classList.toggle("busy", busy);
  if (busy) {
    els.dropzone.querySelector(".dz-title").textContent = "Uploading…";
    els.dzHint.textContent = label || "Uploading…";
    els.dropzone.removeAttribute("tabindex");
  } else {
    els.dropzone.querySelector(".dz-title").textContent = "Upload a PDF";
    els.dzHint.textContent = "Drag & drop or click";
    els.dropzone.setAttribute("tabindex", "0");
  }
}

function uploadFile(file) {
  if (!file) return;
  els.dzPreview.hidden = false;
  els.dzPreview.innerHTML = `<span>${escaped(file.name)}</span>${formatBytes(file.size) ? `<small>${formatBytes(file.size)}</small>` : ""}`;

  const fd = new FormData();
  fd.append("pdf", file);
  setDropzoneBusy(true, file.name);

  // XHR for real upload progress.
  const xhr = new XMLHttpRequest();
  xhr.open("POST", API_BASE + "/papers");
  xhr.upload.onprogress = (e) => {
    if (e.lengthComputable) {
      const pct = Math.round((e.loaded / e.total) * 100);
      setDropzoneBusy(true, `Uploading… ${pct}%`);
    }
  };
  xhr.onload = () => {
    setDropzoneBusy(false);
    els.dzPreview.hidden = true;
    if (xhr.status >= 200 && xhr.status < 300) {
      try {
        const data = JSON.parse(xhr.responseText);
        onUploaded(data.id, file.name);
        toast("Upload started", true);
      } catch (_) {
        toast("Upload succeeded but response was malformed.");
        loadLibrary();
      }
    } else {
      let msg = `Upload failed (${xhr.status})`;
      try {
        const d = JSON.parse(xhr.responseText);
        msg = d.error || d.detail || msg;
      } catch (_) {}
      toast(msg);
    }
  };
  xhr.onerror = () => {
    setDropzoneBusy(false);
    els.dzPreview.hidden = true;
    toast("Upload failed — is the server running?");
  };
  xhr.send(fd);
}

function onUploaded(id, filename) {
  const rec = {
    id, title: "", filename: filename || "Untitled",
    has_audio: false, has_pdf: true, has_script: false,
    created_iso: new Date().toISOString(),
    state: "queued", stage: "extract", progress: 0, message: "Queued",
    tags: [], favorite: false,
  };
  store.papers.set(id, rec);
  adoptStatus(id, { state: "queued", stage: "extract", progress: 0, message: "Queued" });
  reconcileConverting();
  renderAll();
  openDetail(id);
  startStatusStream();
  els.fileInput.value = "";
}

/* ================================================================== */
/*  Polling                                                            */
/* ================================================================== */

let statusStream = null;

/** Open one persistent SSE stream; the server pushes status changes (no polling). */
function startStatusStream() {
  if (statusStream) return;
  const es = new EventSource(API_BASE + "/events");
  statusStream = es;
  es.addEventListener("status", (e) => {
    let data;
    try { data = JSON.parse(e.data); } catch (_) { return; }
    onStatusEvent(data);
  });
  // On reconnect (or first open) re-sync so we don't miss changes while disconnected.
  es.onopen = () => loadLibrary();
  es.onerror = () => loadLibrary(); // EventSource auto-reconnects; refresh state meanwhile
}

function onStatusEvent(status) {
  const id = status.paper_id;
  if (!store.papers.get(id)) return; // unknown/just-deleted paper
  store.statusCache = store.statusCache || {};
  store.statusCache[id] = status;
  adoptStatus(id, status);
  if (status.state === "done") {
    loadLibrary();
    if (store.selectedId === id) renderDetail();
  } else if (status.state === "error") {
    if (store.selectedId === id) renderDetail();
  }
}

function adoptStatus(id, status) {
  const p = store.papers.get(id);
  if (!p) return;
  p.state = status.state;
  p.stage = status.stage;
  p.progress = status.progress != null ? status.progress : p.progress;
  p.message = status.message;
  p.error = status.error;
  p.stageLabel = status.stage ? STAGE_LABELS[status.stage] : undefined;
  p.statusMessage = status.message
    ? status.message
    : (status.stage ? STAGE_LABELS[status.stage] : undefined);
  if (status.state === "done") {
    p.has_audio = true;
    p.id = status.paper_id || p.id;
  }
  reconcileConverting();
  renderAll();
  if (store.selectedId === id && detailSig(p) !== p.__detailSig) {
    renderDetail();
    p.__detailSig = detailSig(p);
  }
}

/* ================================================================== */
/*  Wiring                                                             */
/* ================================================================== */

// ---- Sidebar / mobile ----
els.menuBtn.addEventListener("click", () => {
  const open = els.sidebar.classList.toggle("open");
  els.menuBtn.setAttribute("aria-expanded", open ? "true" : "false");
  els.backdrop.classList.toggle("show", open);
});
els.backdrop.addEventListener("click", () => {
  els.sidebar.classList.remove("open");
  els.backdrop.classList.remove("show");
  els.menuBtn.setAttribute("aria-expanded", "false");
});
// Close drawer on navigation (view/tag click) or resize to desktop
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (els.sidebar.classList.contains("open")) {
      els.sidebar.classList.remove("open");
      els.backdrop.classList.remove("show");
      els.menuBtn.setAttribute("aria-expanded", "false");
    }
    if (!els.detail.hidden) closeDetail();
  }
});

// Sidebar nav: view links
document.querySelectorAll(".side-link").forEach((btn) => {
  btn.addEventListener("click", () => {
    store.view = btn.dataset.view;
    store.activeTag = null;
    renderAll();
    closeMobileDrawer();
  });
});

// Tag list delegation (sidebar)
els.tagList.addEventListener("click", (e) => {
  const item = e.target.closest(".tag-item");
  if (!item) return;
  store.view = "tag";
  store.activeTag = item.dataset.tag;
  renderAll();
  closeMobileDrawer();
});

function closeMobileDrawer() {
  els.sidebar.classList.remove("open");
  els.backdrop.classList.remove("show");
  els.menuBtn.setAttribute("aria-expanded", "false");
}

// ---- Upload (persistent sidebar dropzone) ----
els.dropzone.addEventListener("click", () => els.fileInput.click());
els.dropzone.addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === " ") { e.preventDefault(); els.fileInput.click(); }
});
els.fileInput.addEventListener("change", () => uploadFile(els.fileInput.files[0]));
["dragenter", "dragover"].forEach((evt) =>
  els.dropzone.addEventListener(evt, (e) => {
    e.preventDefault(); els.dropzone.classList.add("dragover");
  }));
["dragleave", "drop"].forEach((evt) =>
  els.dropzone.addEventListener(evt, (e) => {
    e.preventDefault(); els.dropzone.classList.remove("dragover");
  }));
els.dropzone.addEventListener("drop", (e) => {
  const file = e.dataTransfer.files && e.dataTransfer.files[0];
  if (file) uploadFile(file);
});

// ---- Search ----
els.searchInput.addEventListener("input", () => {
  store.search = els.searchInput.value;
  els.searchClear.hidden = !els.searchInput.value;
  renderList();
});
els.searchClear.addEventListener("click", () => {
  els.searchInput.value = "";
  store.search = "";
  els.searchClear.hidden = true;
  renderList();
  els.searchInput.focus();
});

// ---- Sort ----
els.sortSelect.addEventListener("change", () => {
  store.sort = els.sortSelect.value;
  renderList();
});

// ---- Status filter pills ----
els.statusFilter.addEventListener("click", (e) => {
  const pill = e.target.closest(".status-pill");
  if (!pill) return;
  els.statusFilter.querySelectorAll(".status-pill").forEach((b) => b.classList.remove("active"));
  pill.classList.add("active");
  store.statusFilter = pill.dataset.status;
  renderList();
});

// ---- List delegation (rows) ----
els.list.addEventListener("click", (e) => {
  const row = e.target.closest(".book");
  if (!row) return;
  const id = row.dataset.id;
  // Tag chip in a row -> filter by that tag
  const chip = e.target.closest("[data-rowtag]");
  if (chip) {
    e.preventDefault();
    store.view = "tag";
    store.activeTag = chip.dataset.rowtag;
    renderAll();
    return;
  }
  // Favorite star
  const star = e.target.closest("[data-fav]");
  if (star) {
    e.preventDefault();
    toggleFavorite(id);
    return;
  }
  // Mark as read / unread
  const rd = e.target.closest("[data-read]");
  if (rd) {
    e.preventDefault();
    toggleRead(id);
    return;
  }
  // Open detail
  const open = e.target.closest("[data-open]");
  if (open) {
    openDetail(id);
  }
});

// ---- Detail close ----
els.detailClose.addEventListener("click", closeDetail);

// Persist playback position before the tab/iframe is torn down.
window.addEventListener("pagehide", () => {
  const a = store.audioEl;
  if (a && store.selectedId && !a.paused) {
    saveProgress(store.selectedId, a.currentTime || 0, a.duration || 0);
  }
});

// ---- Transcript overlay ----
els.txClose.addEventListener("click", closeTranscript);
els.txOverlay.addEventListener("click", (e) => { if (e.target === els.txOverlay) closeTranscript(); });
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !els.txOverlay.hidden) closeTranscript();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !els.settingsOverlay.hidden) closeSettings();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !els.editOverlay.hidden) closeEdit();
});

// ---- Refresh ----
// (bind on demand in loadLibrary; no refresh button in new layout, so keep global poll)

// Block default browser drag-away.
document.addEventListener("dragover", (e) => e.preventDefault());
document.addEventListener("drop", (e) => e.preventDefault());

// ==================================================================
//  Init
// ==================================================================

(async () => {
  try {
    settingsState = await api("/settings");
  } catch (_) { /* server pre-dates /api/settings; leave defaults */ }
  refreshConfigWarning();
  await loadLibrary();
  startStatusStream();  // server pushes status changes; no per-second polling
})();
setInterval(() => {
  // Refresh library when nothing is converting to avoid clobbering optimistic records.
  if (!store.activeConverting.length) loadLibrary();
}, 30000);