/**
 * Контент-скрипт: плавающая кнопка + панель загрузки на страницах аниме.
 * Всю сеть делает background-воркер, здесь только UI и сообщения.
 */

(function () {
  "use strict";
  if (document.getElementById("agdl-fab")) return; // уже вставлены

  const PLAYER_LABELS = { cvh: "CVH", kodik: "Kodik" };
  const QUALITIES = ["best", "1080", "720", "480", "360"];

  const state = {
    info: null,       // { title, episodes: [{number,id}], dubs: {cvh:[...],kodik:[...]} }
    player: "cvh",
    dub: null,
    quality: "best",
    folder: "animego",
    selected: new Set(),
  };

  /* --------------------------------- DOM --------------------------------- */

  const fab = document.createElement("button");
  fab.id = "agdl-fab";
  fab.title = "Скачать аниме (AnimeGO Downloader)";
  fab.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="M6 11l6 6 6-6"/><path d="M4 21h16"/></svg>`;

  const panel = document.createElement("div");
  panel.id = "agdl-panel";
  panel.hidden = true;
  panel.innerHTML = `
    <div class="agdl-head">
      <span class="agdl-title">Скачать аниме</span>
      <button class="agdl-close" title="Закрыть">×</button>
    </div>
    <div class="agdl-body">
      <div class="agdl-status agdl-muted">Загружаю данные о тайтле…</div>

      <div class="agdl-row agdl-hidden" data-row="form">
        <label>Плеер
          <select id="agdl-player"></select>
        </label>
        <label>Озвучка
          <select id="agdl-dub"></select>
        </label>
        <label>Качество ≤
          <select id="agdl-quality"></select>
        </label>
      </div>

      <div class="agdl-eps agdl-hidden" data-row="eps">
        <div class="agdl-eps-head">
          <span>Серии</span>
          <button id="agdl-all" class="agdl-mini">все</button>
        </div>
        <div id="agdl-eps-list"></div>
      </div>

      <button id="agdl-go" class="agdl-go agdl-hidden" data-row="form" disabled>
        Скачать выбранные (<span id="agdl-count">0</span>)
      </button>

      <div id="agdl-log" class="agdl-log"></div>
    </div>`;
  document.documentElement.appendChild(fab);
  document.documentElement.appendChild(panel);

  const $ = (sel) => panel.querySelector(sel);
  // data-row может быть у нескольких элементов (например, селекты и кнопка),
  // поэтому показываем/прячем все совпадающие
  const show = (row, on) =>
    panel.querySelectorAll(`[data-row="${row}"]`).forEach((el) =>
      el.classList.toggle("agdl-hidden", !on)
    );

  fab.addEventListener("click", togglePanel);
  $(".agdl-close").addEventListener("click", () => togglePanel(false));

  function togglePanel(force) {
    const open = force !== undefined ? force : panel.hidden;
    panel.hidden = !open;
    fab.classList.toggle("agdl-active", open);
    if (open && !state.info) loadInfo();
  }

  /* ------------------------------ данные ------------------------------ */

  async function loadInfo() {
    $(".agdl-status").textContent = "Загружаю данные о тайтле…";
    try {
      const resp = await chrome.runtime.sendMessage({ type: "agdl-get-info", url: location.href });
      if (!resp || !resp.ok) throw new Error(resp && resp.error ? resp.error : "нет ответа");
      state.info = resp.data;
      state.selected = new Set([state.info.episodes[0].number]);
      $(".agdl-status").innerHTML = `<b>${escapeHtml(state.info.title)}</b> — серий: ${state.info.episodes.length}`;
      buildForm();
      show("form", true);
      show("eps", true);
    } catch (e) {
      $(".agdl-status").textContent = "Ошибка: " + e.message;
      $(".agdl-status").classList.add("agdl-error");
    }
  }

  async function loadSettings() {
    const s = await chrome.storage.sync.get({ player: "cvh", quality: "best", folder: "animego" });
    state.player = s.player;
    state.quality = s.quality;
    state.folder = s.folder;
  }

  function buildForm() {
    const players = Object.keys(state.info.dubs);
    if (!players.includes(state.player)) state.player = players[0];

    $("#agdl-player").innerHTML = players
      .map((p) => `<option value="${p}">${PLAYER_LABELS[p] || p}</option>`)
      .join("");
    $("#agdl-player").value = state.player;

    $("#agdl-quality").innerHTML = QUALITIES.map(
      (q) => `<option value="${q}">${q === "best" ? "максимальное" : q + "p"}</option>`
    ).join("");
    $("#agdl-quality").value = state.quality;

    rebuildDubs();
    rebuildEpisodes();

    $("#agdl-player").addEventListener("change", (e) => {
      state.player = e.target.value;
      rebuildDubs();
    });
    $("#agdl-dub").addEventListener("change", (e) => (state.dub = e.target.value));
    $("#agdl-quality").addEventListener("change", (e) => (state.quality = e.target.value));
    $("#agdl-all").addEventListener("click", () => {
      const all = state.selected.size === state.info.episodes.length;
      state.selected = all
        ? new Set()
        : new Set(state.info.episodes.map((e) => e.number));
      rebuildEpisodes();
    });
    $("#agdl-go").addEventListener("click", startDownload);
  }

  function rebuildDubs() {
    const dubs = state.info.dubs[state.player] || [];
    if (!dubs.includes(state.dub)) state.dub = dubs[0];
    $("#agdl-dub").innerHTML = dubs.map((d) => `<option value="${escapeHtml(d)}">${escapeHtml(d)}</option>`).join("");
    $("#agdl-dub").value = state.dub;
  }

  function rebuildEpisodes() {
    const list = $("#agdl-eps-list");
    list.innerHTML = "";
    for (const ep of state.info.episodes) {
      const chip = document.createElement("button");
      chip.className = "agdl-chip" + (state.selected.has(ep.number) ? " agdl-on" : "");
      chip.textContent = ep.number;
      chip.addEventListener("click", () => {
        if (state.selected.has(ep.number)) state.selected.delete(ep.number);
        else state.selected.add(ep.number);
        chip.classList.toggle("agdl-on", state.selected.has(ep.number));
        updateCount();
      });
      list.appendChild(chip);
    }
    updateCount();
  }

  function updateCount() {
    $("#agdl-count").textContent = state.selected.size;
    $("#agdl-go").disabled = state.selected.size === 0;
  }

  /* ----------------------------- скачивание ----------------------------- */

  /**
   * Кнопка всегда выглядит одинаково и не блокируется: статус — только в логе
   * (итоговое количество переданных в загрузки серий и ошибки).
   * Повторный клик просто отправляет новую задачу (например, после отмены
   * диалога выбора каталога).
   */
  async function startDownload() {
    const episodes = state.info.episodes.filter((e) => state.selected.has(e.number));
    if (!episodes.length) return;
    try {
      const resp = await chrome.runtime.sendMessage({
        type: "agdl-download",
        url: location.href,
        title: state.info.title,
        episodes,
        player: state.player,
        dub: state.dub,
        quality: state.quality,
        folder: state.folder,
      });
      if (!resp || !resp.ok) throw new Error(resp && resp.error ? resp.error : "нет ответа");
    } catch (e) {
      failed++; // одна строка — только счётчик; текст ошибки не добавляем
      updateSummary();
    }
  }

  /** Итоговая строка: всегда ровно одна, обновляется на месте. */
  let transferred = 0;
  let failed = 0;
  let summaryEl = null;
  function updateSummary() {
    if (!summaryEl) {
      summaryEl = document.createElement("div");
      summaryEl.className = "agdl-log-line agdl-log-head";
      $("#agdl-log").prepend(summaryEl);
    }
    summaryEl.textContent = failed
      ? `Передано в загрузки: ${transferred} (ошибок: ${failed})`
      : `Передано в загрузки: ${transferred}`;
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type !== "agdl-progress") return;
    if (msg.status === "started") return; // построчный прогресс не показываем
    if (msg.status === "error") failed++; // детали — в консоли воркера
    else if (msg.status === "finished") transferred += Number(msg.passed) || 0;
    updateSummary();
  });

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  loadSettings();
})();
