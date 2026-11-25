/**
 * Service worker расширения: ходит по цепочке animego -> плеер -> прямая ссылка
 * и отдаёт ссылку в chrome.downloads. Вся сеть — отсюда: host_permissions
 * снимают CORS, chrome.downloads шлёт нормальный UA браузера (CVH его требует).
 *
 * Экстракторы (портированы с anime-dl-core) — в extractors.js.
 * Работают только CVH и Kodik: оба отдают прямые mp4. Код AniBoom в
 * extractors.js оставлен, но из UI убран (HLS со отдельной дорожкой звука
 * в браузере не склеить без ffmpeg).
 */

importScripts("extractors.js");
const X = self.AnimeExtractors;

/**
 * MV3 service worker не может ставить Referer через fetch (запрещённый заголовок),
 * а CVH-эндпоинт /video без Referer отвечает ошибкой. Поэтому Referer добавляет
 * session-rule declarativeNetRequest — только на наши запросы к plapi.
 */
async function installHeaderRules() {
  await chrome.declarativeNetRequest.updateSessionRules({
    removeRuleIds: [1],
    addRules: [
      {
        id: 1,
        priority: 1,
        action: {
          type: "modifyHeaders",
          requestHeaders: [
            { header: "Referer", operation: "set", value: "https://animego.org/" },
          ],
        },
        condition: {
          urlFilter: "||plapi.cdnvideohub.com/",
          resourceTypes: ["xmlhttprequest"],
          initiatorDomains: [chrome.runtime.id],
        },
      },
    ],
  });
}
installHeaderRules().catch(console.error);

// клик по иконке в тулбаре -> настройки
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());

const BASE = "https://animego.me";
const ANIME_HEADERS = {
  "X-Requested-With": "XMLHttpRequest",
  Accept: "application/json",
};

// какие плееры из разметки animego поддерживаем: title на сайте -> ключ
const SUPPORTED_PLAYERS = { CVH: "cvh", Kodik: "kodik" };

/* ------------------------------ fetch-хелперы ------------------------------ */

async function fetchPage(url, opts = {}) {
  const r = await fetch(url, { headers: opts.headers || {} });
  if (!r.ok) throw new Error(`GET ${url} -> HTTP ${r.status}`);
  return r.json();
}

async function fetchText(url, opts = {}) {
  const r = await fetch(url, { headers: opts.headers || {} });
  if (!r.ok) throw new Error(`GET ${url} -> HTTP ${r.status}`);
  return r.text();
}

async function postForm(url, form, opts = {}) {
  const r = await fetch(url, {
    method: "POST",
    body: form.toString(),
    headers: opts.headers || {},
  });
  if (!r.ok) throw new Error(`POST ${url} -> HTTP ${r.status}`);
  return r.json();
}

/* --------------------------- цепочка animego.me ---------------------------- */

async function fetchAnimeMeta(animeUrl) {
  const page = await fetchText(animeUrl, { headers: { "Accept-Language": "ru-RU,ru;q=0.9" } });
  const m = page.match(/data-anime-player-loader-url-value="\/player\/(\d+)"/);
  if (!m) throw new Error("Не нашёл плеер на странице — это точно страница аниме?");
  const t = page.match(/<h1[^>]*>(.*?)<\/h1>/s);
  return {
    animeId: m[1],
    title: t ? t[1].replace(/<[^>]+>/g, "").trim() : "anime_" + m[1],
  };
}

async function fetchEpisodes(animeUrl, animeId) {
  const byNumber = new Map();
  for (let page = 0; page <= 50; page++) {
    const d = await fetchPage(`${BASE}/player/${animeId}/episodes?page=${page}`, {
      headers: { ...ANIME_HEADERS, Referer: animeUrl },
    });
    const content = d.data.content;
    let found = 0;
    for (const m of content.matchAll(
      /data-episode-number="([^"]+)"[^>]*data-episode-page="\d+"[^>]*data-episode-index="\d+"[^>]*data-episode-type="\d+"[^>]*data-episode="(\d+)"/g
    )) {
      found++;
      if (!byNumber.has(m[1])) byNumber.set(m[1], { number: m[1], id: m[2] });
    }
    const returned = d.data.page;
    if (!found || (returned != null && returned !== page)) break; // дальше страниц нет
  }
  return [...byNumber.values()].sort(
    (a, b) => (parseInt(a.number, 10) || 1e9) - (parseInt(b.number, 10) || 1e9)
  );
}

/** Список плееров (CVH/Kodik + озвучка) для конкретного эпизода. */
async function fetchProviders(animeUrl, episodeId) {
  const d = await fetchPage(`${BASE}/player/videos/${episodeId}`, {
    headers: { ...ANIME_HEADERS, Referer: animeUrl },
  });
  const items = [];
  for (const m of d.data.content.matchAll(
    /data-player="([^"]+)"[^>]*data-provider-title="([^"]+)"[^>]*data-translation-title="([^"]+)"/g
  )) {
    const key = SUPPORTED_PLAYERS[m[2]];
    if (!key) continue; // AniBoom и прочие не поддерживаем
    items.push({ key, url: "https:" + X.unescapeHtml(m[1]), dub: m[3] });
  }
  return items;
}

/* ------------------------------- скачивание -------------------------------- */

function sanitizeName(s) {
  return String(s).replace(/[<>:"/\\|?*]+/g, "_").replace(/\s+/g, " ").trim();
}

/** mp4 не хуже запрошенного качества (streams уже отсортированы по убыванию). */
function pickMp4(streams, maxQuality) {
  const mp4 = streams.filter((s) => s.kind === "mp4");
  if (!mp4.length) return null;
  if (!maxQuality || maxQuality === "best") return mp4[0];
  const want = parseInt(maxQuality, 10);
  return mp4.find((s) => (s.quality || 0) <= want) || mp4[mp4.length - 1];
}

function progress(tabId, payload) {
  if (tabId == null) return;
  chrome.tabs.sendMessage(tabId, { type: "agdl-progress", ...payload }).catch(() => {});
}

/**
 * Ставит ссылку в chrome.downloads и ждёт реального старта загрузки.
 * Нюанс: если у пользователя включено «спрашивать, куда сохранять»,
 * браузер показывает диалог выбора каталога, и промис download() при
 * отмене диалога может не завершиться никогда. Поэтому дополнительно
 * слушаем события загрузки и подстраховываемся таймаутом.
 * Возвращает { status: 'started' | 'canceled' | 'error' | 'timeout', detail }.
 */
function startChromeDownload(url, filename) {
  return new Promise((resolve) => {
    let settled = false;
    let downloadId = null;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      chrome.downloads.onChanged.removeListener(onChanged);
      chrome.downloads.onErased.removeListener(onErased);
      clearTimeout(timer);
      resolve(result);
    };
    const onChanged = (delta) => {
      if (downloadId == null || delta.id !== downloadId) return;
      // состояние элемента меняется — файл реально качается
      finish({ status: "started" });
    };
    const onErased = (id) => {
      if (downloadId == null || id !== downloadId) return;
      finish({ status: "canceled" });
    };
    const timer = setTimeout(() => finish({ status: "timeout" }), 120000);

    chrome.downloads.onChanged.addListener(onChanged);
    chrome.downloads.onErased.addListener(onErased);

    chrome.downloads
      .download({ url, filename })
      .then((id) => {
        if (id === undefined) {
          const msg = chrome.runtime.lastError?.message || "";
          finish({ status: /cancel/i.test(msg) ? "canceled" : "error", detail: msg });
          return;
        }
        downloadId = id;
        // без диалога сохранения элемент сразу in_progress — событие уже
        // могло пройти до подписки, проверяем текущее состояние сами
        chrome.downloads
          .search({ id })
          .then((items) => {
            const st = items[0] && items[0].state;
            if (st === "in_progress" || st === "complete") finish({ status: "started" });
          })
          .catch(() => {});
      })
      .catch((e) =>
        finish({ status: /cancel/i.test(e && e.message) ? "canceled" : "error", detail: e && e.message })
      );
  });
}

async function downloadEpisode({ animeUrl, player, dub, quality, folder, title, episode }) {
  const providers = await fetchProviders(animeUrl, episode.id);
  const provider = providers.find((p) => p.key === player && p.dub === dub);
  if (!provider)
    throw new Error(`у этого эпизода нет плеера ${player} с озвучкой «${dub}»`);

  let streams;
  if (player === "cvh") {
    // embed-ссылка уже несёт cvh_id, озвучку и номер серии
    ({ streams } = await X.cvhExtract(fetchPage, provider.url));
  } else {
    ({ streams } = await X.kodikExtract(fetchPage, fetchText, postForm, provider.url));
  }

  const stream = pickMp4(streams, quality);
  if (!stream) throw new Error("плеер отдал только HLS, прямого mp4 нет");

  const name = sanitizeName(
    `${title} - эпизод ${episode.number} [${dub}][${stream.quality || "?"}p].mp4`
  );
  const filename = folder ? `${sanitizeName(folder)}/${name}` : name;

  const result = await startChromeDownload(stream.url, filename);
  return { ...result, quality: stream.quality, filename };
}

async function runDownloadTask(msg, tabId) {
  const { episodes, player, dub, quality, folder, title, animeUrl } = msg;
  let done = 0;
  let canceled = false;
  for (const episode of episodes) {
    try {
      const res = await downloadEpisode({ animeUrl, player, dub, quality, folder, title, episode });
      if (res.status === "started") {
        done++;
        progress(tabId, {
          episode: episode.number,
          status: "started",
          text: `эпизод ${episode.number}: ${res.quality}p — загрузка передана браузеру → ${res.filename}`,
        });
      } else if (res.status === "canceled") {
        canceled = true;
        progress(tabId, {
          episode: episode.number,
          status: "error",
          text: `эпизод ${episode.number}: выбор каталога отменён — останавливаю остальные серии`,
        });
        break;
      } else if (res.status === "timeout") {
        console.error(`[AnimeGO DL] эпизод ${episode.number}: браузер не начал загрузку за 120 с`);
        progress(tabId, {
          episode: episode.number,
          status: "error",
          text: `эпизод ${episode.number}: браузер слишком долго не начинал загрузку (открыт диалог?) — пропускаю`,
        });
      } else {
        console.error(`[AnimeGO DL] эпизод ${episode.number}: ${res.detail || res.status}`);
        progress(tabId, {
          episode: episode.number,
          status: "error",
          text: `эпизод ${episode.number}: браузер не принял загрузку${res.detail ? " — " + res.detail : ""}`,
        });
      }
    } catch (e) {
      console.error(`[AnimeGO DL] эпизод ${episode.number}:`, e && e.message);
      progress(tabId, {
        episode: episode.number,
        status: "error",
        text: `эпизод ${episode.number}: ошибка — ${e.message}`,
      });
    }
    // пауза между сериями: у Kodik подписи одноразовые, Rate limit близко
    if (episode !== episodes[episodes.length - 1]) await new Promise((r) => setTimeout(r, 1500));
  }
  progress(tabId, {
    status: "finished",
    passed: done,
    total: episodes.length,
    canceled,
  });
}

/* -------------------------------- сообщения -------------------------------- */

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    try {
      if (msg.type === "agdl-get-info") {
        const meta = await fetchAnimeMeta(msg.url);
        const episodes = await fetchEpisodes(msg.url, meta.animeId);
        if (!episodes.length) throw new Error("у тайтла нет эпизодов");
        const providers = await fetchProviders(msg.url, episodes[0].id);
        // озвучки по каждому плееру (порядок как на сайте), без дублей
        const dubs = {};
        for (const p of providers) {
          dubs[p.key] = dubs[p.key] || [];
          if (!dubs[p.key].includes(p.dub)) dubs[p.key].push(p.dub);
        }
        if (!Object.keys(dubs).length)
          throw new Error("на странице нет поддерживаемых плееров (нужен CVH или Kodik)");
        sendResponse({ ok: true, data: { ...meta, episodes, dubs } });
      } else if (msg.type === "agdl-download") {
        runDownloadTask(msg, sender.tab?.id ?? null);
        sendResponse({ ok: true });
      } else {
        sendResponse({ ok: false, error: "неизвестный тип сообщения" });
      }
    } catch (e) {
      sendResponse({ ok: false, error: String(e && e.message ? e.message : e) });
    }
  })();
  return true; // ответ будет асинхронным
});
