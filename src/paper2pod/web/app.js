/* paper2pod — frontend app. Vanilla JS, no build step. */
"use strict";

/* ------------------------------------------------------------------ */
/*  Config                                                             */
/* ------------------------------------------------------------------ */

const POLL_MS = 1500;
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
  listHead: $("#lib-list-head"),
  list: $("#lib-list"),
  empty: $("#empty"),
  emptyTitle: $("#empty-title"),
  emptyMsg: $("#empty-msg"),
  detail: $("#detail"),
  detailBody: $("#detail-body"),
  detailClose: $("#detail-close"),
  toolbar: $("#toolbar"),
  tbIndex: $("#tb-index"),
  tbTitle: $("#tb-title"),
  tbStage: $("#tb-stage"),
  tbFill: $("#tb-fill"),
  toolbarOpen: $("#toolbar-open"),
  toastRegion: $("#toast-region"),
  headerNote: $("#header-note"),
};

/* ------------------------------------------------------------------ */
/*  State                                                              */
/* ------------------------------------------------------------------ */

const store = {
  papers: new Map(),          // id -> library record
  byNumber: [],               // ordered ids for toolbar index
  activeConverting: [],       // ids currently converting (running/queued)
  selectedId: null,           // paper shown in detail panel
  pollTimers: new Map(),      // id -> interval handle
  audioEl: null,              // currently playing <audio>
  statusCache: {},            // id -> latest /status payload
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

function rowMeta(p) {
  const date = formatDate(p.created_iso || p.created_at);
  let tags = "";
  const tagArr = Array.isArray(p.tags) ? p.tags : [];
  if (tagArr.length) {
    tags = `<span class="row-tags">${tagArr.map((t) =>
      `<button class="tag-chip" data-rowtag="${escaped(t)}" type="button">#${escaped(t)}</button>`
    ).join("")}</span>`;
  }
  return { date, tags, tagArr };
}

function stateBadge(p) {
  const st = p.state || "queued";
  if (st === "running" || st === "queued") {
    const prog = Math.round((p.progress || 0) * 100);
    return `<span class="row-state">
      <span class="state-badge running">${st === "running" ? "Running" : "Queued"}</span>
      <span class="state-pct">${prog}%</span>
    </span>`;
  }
  if (st === "done") {
    return `<span class="row-state"><span class="state-badge done">Done</span></span>`;
  }
  return `<span class="row-state"><span class="state-badge error">Error</span></span>`;
}

function fileIcons(p) {
  const audioCls = (isDone(p) || p.has_audio) ? "on" : "dim";
  const scriptCls = p.has_script ? "on" : "dim";
  return `
    <span class="file-ic ${audioCls}" title="Audio">
      <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 21a9 9 0 1 0-9-9m9 9a5 5 0 1 1 2-9.9m-2 9.9v-3"/><path d="M12 16a3 3 0 1 0-3-3"/></svg>
    </span>
    <span class="file-ic ${scriptCls}" title="Script">
      <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M8 6l-5 6 5 6M16 6l5 6-5 6M13 4l-2 16"/></svg>
    </span>`;
}

function rowContent(p) {
  const { date, tags } = rowMeta(p);
  const title = p.title || p.filename || "Untitled";
  const fav = p.favorite ? "on" : "";
  const isSel = store.selectedId === p.id ? "selected" : "";
  return `
    <li class="row ${isSel}" data-id="${escaped(p.id)}">
      <button class="row-star ${fav}" data-fav="${escaped(p.id)}" type="button"
        aria-label="${p.favorite ? "Remove from favorites" : "Add to favorites"}" aria-pressed="${p.favorite ? "true" : "false"}">
        <svg viewBox="0 0 24 24" width="16" height="16" stroke="currentColor" stroke-width="1.6"><path d="M12 3.6l2.6 5.3 5.9.9-4.3 4.1 1 5.9-5.2-2.7-5.2 2.7 1-5.9-4.3-4.1 5.9-.9z"/></svg>
      </button>
      <div class="row-main">
        <button class="row-open" data-open="${escaped(p.id)}" type="button">${escaped(title)}</button>
        ${tags}
      </div>
      ${stateBadge(p)}
      <span class="row-date">${date}</span>
      <span class="row-files">${fileIcons(p)}</span>
    </li>`;
}

function renderList() {
  const papers = filteredPapers();
  const hasPapers = store.papers.size > 0;
  const hasAny = papers.length > 0;
  const isFiltering = !!(store.search || store.statusFilter !== "all" || store.view !== "all");

  els.listHead.hidden = !hasPapers;
  els.empty.hidden = hasAny || !hasPapers;
  if (!hasPapers) {
    els.emptyTitle.textContent = "Your library is empty";
    els.emptyMsg.textContent = "Upload a PDF to start converting it into a podcast.";
    els.list.innerHTML = "";
    return;
  }
  if (!hasAny) {
    els.emptyTitle.textContent = "No results";
    els.emptyMsg.textContent = isFiltering
      ? "Nothing matches your current filters. Try clearing the search or status filter."
      : "Nothing in this collection yet.";
    els.list.innerHTML = "";
    return;
  }
  els.list.innerHTML = papers.map(rowContent).join("");
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
      stopPolling(id);
      if (store.selectedId === id) closeDetail();
    }
  }
  reconcileConverting();
  renderAll();
  renderToolbar();
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

function currentConverting() {
  return store.activeConverting[0];
}

function renderToolbar() {
  const id = currentConverting();
  if (!id) {
    els.toolbar.hidden = true;
    return;
  }
  const p = store.papers.get(id);
  const total = store.activeConverting.length;
  const idx = store.activeConverting.indexOf(id) + 1;
  els.toolbar.hidden = false;
  if (total > 1) els.tbIndex.textContent = `${idx} / ${total}`;
  else els.tbIndex.textContent = "";
  els.tbTitle.textContent = p.title || p.filename || "Converting…";
  els.tbStage.textContent = p.statusMessage || p.stageLabel || stageLabel(p.stage);
  const prog = Math.round((p.progress || 0) * 100);
  els.tbFill.style.width = prog + "%";
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

  els.detailBody.innerHTML = `
    <p class="d-kicker">Paper</p>
    <div class="d-head">
      <input class="d-title-input" id="d-title" type="text" value="${escaped(title)}"
        placeholder="Untitled" aria-label="Paper title" maxlength="200" />
      <div class="d-head-row">
        <p class="d-meta">${escaped(p.filename || "—")}${date ? " · " + date : ""}</p>
        ${favBtn}
      </div>
    </div>

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
    ${hasAudio ? `<div class="d-audio">
      <audio class="player-audio" id="d-audio" controls preload="metadata" src="${API_BASE}/papers/${p.id}/audio?t=${cacheBust}"></audio>
    </div>` : ""}

    <div class="d-downloads">
      <a class="dl-btn" href="${API_BASE}/papers/${p.id}/file?kind=pdf">PDF</a>
      <a class="dl-btn ${p.has_script ? "" : "disabled"}" href="${API_BASE}/papers/${p.id}/file?kind=script">Script</a>
      <a class="dl-btn ${p.has_script ? "" : "disabled"}" href="${API_BASE}/papers/${p.id}/file?kind=srt">SRT</a>
    </div>

    <div class="d-danger">
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
  if (audio) store.audioEl = audio;

  $("#d-rerun").addEventListener("click", onRerun);
  $("#d-delete").addEventListener("click", onDelete);
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
    startPolling(id);
    renderAll();
    renderToolbar();
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
  stopPolling(id);
  store.papers.delete(id);
  reconcileConverting();
  renderAll();
  renderToolbar();
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
        onUploaded(data.id);
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

function onUploaded(id) {
  const rec = {
    id, title: "", filename: els.fileInput.files[0]?.name || "New paper",
    has_audio: false, has_pdf: true, has_script: false,
    created_iso: new Date().toISOString(),
    state: "queued", stage: "extract", progress: 0, message: "Queued",
    tags: [], favorite: false,
  };
  store.papers.set(id, rec);
  adoptStatus(id, { state: "queued", stage: "extract", progress: 0, message: "Queued" });
  reconcileConverting();
  renderAll();
  renderToolbar();
  openDetail(id);
  startPolling(id);
  els.fileInput.value = "";
}

/* ================================================================== */
/*  Polling                                                            */
/* ================================================================== */

function startPolling(id) {
  if (store.pollTimers.has(id)) return;
  pollOnce(id);
  const timer = setInterval(() => pollOnce(id), POLL_MS);
  store.pollTimers.set(id, timer);
}

function stopPolling(id) {
  const t = store.pollTimers.get(id);
  if (t) { clearInterval(t); store.pollTimers.delete(id); }
}

async function pollOnce(id) {
  let status;
  try {
    status = await api(`/papers/${id}/status`);
  } catch (err) {
    return; // transient — keep record as-is
  }
  store.statusCache = store.statusCache || {};
  store.statusCache[id] = status;
  adoptStatus(id, status);

  if (status.state === "done") {
    stopPolling(id);
    await loadLibrary();
    if (store.selectedId === id) renderDetail();
  } else if (status.state === "error") {
    stopPolling(id);
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
  renderToolbar();
  if (store.selectedId === id) renderDetail();
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
  const row = e.target.closest(".row");
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
  // Open detail
  const open = e.target.closest("[data-open]");
  if (open) {
    openDetail(id);
  }
});

// ---- Detail close ----
els.detailClose.addEventListener("click", closeDetail);

// ---- Toolbar "View" ----
els.toolbarOpen.addEventListener("click", () => {
  const id = currentConverting();
  if (id) openDetail(id);
});

// ---- Refresh ----
// (bind on demand in loadLibrary; no refresh button in new layout, so keep global poll)

// Block default browser drag-away.
document.addEventListener("dragover", (e) => e.preventDefault());
document.addEventListener("drop", (e) => e.preventDefault());

// ==================================================================
//  Init
// ==================================================================

loadLibrary();
setInterval(() => {
  // Refresh library when nothing is converting to avoid clobbering optimistic records.
  if (!store.activeConverting.length) loadLibrary();
}, 30000);