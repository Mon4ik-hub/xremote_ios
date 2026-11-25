/**
 * Портированные на JS экстракторы плееров (CVH, Kodik, AniBoom)
 * из библиотеки anime-dl-core (https://github.com/ialakey/anime-dl-core,
 * гайд: https://habr.com/ru/articles/1079156/).
 *
 * Файл написан под две среды:
 *  - service worker Chrome-расширения (подключается через importScripts),
 *  - Node.js для тестов (module.exports).
 */

(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.AnimeExtractors = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const BROWSER_UA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
  const ANIMEGO_REFERER = "https://animego.org/";

  /* ------------------------------ общие хелперы ------------------------------ */

  function forceHttps(url) {
    return url.startsWith("//") ? "https:" + url : url;
  }

  /** JSON из html-атрибута: убирает &quot;, &amp;, &#x5B; и прочие сущности. */
  function unescapeHtml(value) {
    const named = { quot: '"', amp: "&", lt: "<", gt: ">", apos: "'", nbsp: " " };
    return String(value).replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (m, entity) => {
      if (entity[0] === "#") {
        const code =
          entity[1] === "x" || entity[1] === "X"
            ? parseInt(entity.slice(2), 16)
            : parseInt(entity.slice(1), 10);
        return Number.isFinite(code) ? String.fromCodePoint(code) : m;
      }
      return named.hasOwnProperty(entity.toLowerCase()) ? named[entity.toLowerCase()] : m;
    });
  }

  function b64Decode(value) {
    const padded = value + "=".repeat((4 - (value.length % 4)) % 4);
    // atob есть и в браузере, и в Node >= 16
    const bin = atob(padded);
    // ссылки ASCII, но на всякий случай собираем через байты
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    return new TextDecoder("utf-8").decode(bytes);
  }

  /** Шифр Цезаря по латинице с сохранением регистра (как в anime-dl-core). */
  function caesarShift(text, shift) {
    const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let out = "";
    for (const ch of text) {
      const upper = ch.toUpperCase();
      const idx = A.indexOf(upper);
      if (idx === -1) out += ch;
      else {
        const shifted = A[(idx + shift) % 26];
        out += ch === ch.toLowerCase() ? shifted.toLowerCase() : shifted;
      }
    }
    return out;
  }

  /** base64 + цезарь; сдвиг брутфорсится, удачный возвращается для кэша. */
  function decodeKodikUrl(value, knownShift) {
    const shifts = (knownShift != null ? [knownShift] : []).concat(
      Array.from({ length: 26 }, (_, i) => i)
    );
    for (const shift of shifts) {
      try {
        const decoded = b64Decode(caesarShift(value, shift));
        if (decoded.startsWith("//") || decoded.startsWith("http")) return [decoded, shift];
      } catch (e) {
        /* неверный сдвиг — просто мусор */
      }
    }
    throw new Error("Не удалось расшифровать ссылку Kodik (шифр, похоже, сменился)");
  }

  /* ================================ CVH ================================ */
  /* Открытый API plapi.cdnvideohub.com: playlist -> vkId -> video -> mp4. */

  const CVH_API = "https://plapi.cdnvideohub.com/api/v1/player/sv";
  const CVH_PUB = "747";
  const CVH_AGGR = "mali";
  const CVH_QUALITY = {
    mpegMobileUrl: 144, mpegTinyUrl: 144, mpegLowestUrl: 240, mpegLowUrl: 360,
    mpegMediumUrl: 480, mpegHighUrl: 720, mpegFullHdUrl: 1080, mpegQhdUrl: 1440,
    mpeg2kUrl: 2048, mpeg4kUrl: 2160,
  };

  /** /cdn-iframe/<id>/<studio>/<season>/<episode> (или новый формат с ?dubbing=). */
  function parseCvhUrl(url) {
    const m = url.match(/\/cdn-iframe\/(\d+)((?:\/[^/?#]+){0,3})/i);
    if (!m) throw new Error("Не узнал ссылку CVH: " + url);
    const segments = m[2].split("/").filter(Boolean);
    let studio = null;
    if (segments.length && !/^\d+$/.test(segments[0])) studio = decodeURIComponent(segments.shift());
    const dubParam = url.match(/[?&]dubbing=([^&]+)/);
    if (dubParam) studio = decodeURIComponent(dubParam[1]);
    const numbers = segments.filter((s) => /^\d+$/.test(s)).map(Number);
    return { cvhId: m[1], studio, season: numbers[0] ?? null, episode: numbers[1] ?? null };
  }

  const cvhPlaylistCache = new Map();

  async function cvhPlaylist(fetchPage, cvhId) {
    if (cvhPlaylistCache.has(cvhId)) return cvhPlaylistCache.get(cvhId);
    const url = `${CVH_API}/playlist?pub=${CVH_PUB}&aggr=${CVH_AGGR}&id=${cvhId}`;
    const data = await fetchPage(url, { headers: { Referer: ANIMEGO_REFERER, Accept: "application/json" } });
    const items = (data && data.items) || [];
    if (!items.length) throw new Error("CVH вернул пустой плейлист для id=" + cvhId);
    const parsed = items.map((it) => ({
      cvhId: String(it.cvhId ?? ""),
      videoId: String(it.vkId ?? ""),
      studio: it.voiceStudio ?? null,
      season: it.season | 0 || 1,
      episode: it.episode | 0 || 1,
    }));
    cvhPlaylistCache.set(cvhId, parsed);
    return parsed;
  }

  /** Нечёткое сравнение озвучек: "Dream Cast" == "Dream-Cast". */
  function studioKey(name) {
    return String(name || "").toLowerCase().replace(/[^0-9a-zа-яё]/gi, "");
  }

  function cvhSelect(items, { season, episode, studio }) {
    if (!items.length) throw new Error("Плейлист CVH пуст");
    const seasons = [...new Set(items.map((i) => i.season))].sort((a, b) => a - b);
    if (season == null || seasons.length === 1) season = seasons[0];
    let pool = items.filter((i) => i.season === season);
    if (!pool.length) throw new Error(`Сезон ${season} не найден; есть: ${seasons}`);
    if (episode == null) episode = Math.min(...pool.map((i) => i.episode));
    pool = pool.filter((i) => i.episode === episode);
    if (!pool.length) throw new Error(`Эпизод ${episode} не найден в сезоне ${season}`);
    if (studio) {
      const wanted = studioKey(studio);
      let hit = pool.find((i) => studioKey(i.studio) === wanted);
      if (!hit)
        hit = pool.find((i) => {
          const s = studioKey(i.studio);
          return s && (s.includes(wanted) || wanted.includes(s));
        });
      if (hit) return hit;
    }
    return pool[0];
  }

  async function cvhVideo(fetchPage, videoId) {
    const data = await fetchPage(`${CVH_API}/video/${videoId}`, {
      headers: { Referer: ANIMEGO_REFERER, Accept: "application/json" },
    });
    const sources = (data && data.sources) || {};
    const streams = [];
    if (sources.hlsUrl) streams.push({ kind: "hls", quality: null, url: sources.hlsUrl });
    for (const [key, value] of Object.entries(sources)) {
      if (typeof value !== "string" || !value.startsWith("http")) continue;
      if (key === "hlsUrl" || key === "dashUrl" || key === "dashManifestUrl") continue;
      const quality = CVH_QUALITY[key] || null;
      if (quality) streams.push({ kind: "mp4", quality, url: value });
    }
    if (!streams.length) throw new Error(`CVH не отдал ссылок для видео ${videoId}`);
    streams.sort((a, b) => (b.quality || 0) - (a.quality || 0) || (a.kind === "mp4" ? -1 : 1));
    return streams;
  }

  /** Полный поток CVH: embed-ссылка (или cvh_id) + серия/озвучка -> список потоков. */
  async function cvhExtract(fetchPage, url, { season, episode, studio } = {}) {
    const parsed = typeof url === "object" ? url : parseCvhUrl(url);
    season = season ?? parsed.season;
    episode = episode ?? parsed.episode;
    studio = studio ?? parsed.studio;
    const items = await cvhPlaylist(fetchPage, parsed.cvhId);
    const chosen = cvhSelect(items, { season, episode, studio });
    const streams = await cvhVideo(fetchPage, chosen.videoId);
    return { player: "cvh", episodeItem: chosen, streams };
  }

  /* ================================ Kodik ================================ */
  /* embed -> urlParams+подписи -> эндпоинт из atob() в бандле -> POST ->
     base64+цезарь -> ссылки. Подписи одноразовые: страница и POST подряд. */

  async function kodikExtract(fetchPage, fetchText, postForm, url) {
    url = forceHttps(url);
    const page = await fetchText(url, { headers: { Referer: ANIMEGO_REFERER } });

    let raw = page.match(/urlParams\s*=\s*'(\{.*?\})'/s);
    if (!raw) raw = page.match(/urlParams\s*=\s*"(\{.*?\})"/s);
    if (!raw) throw new Error("На странице Kodik нет urlParams — разметка сменилась");
    const params = JSON.parse(raw[1]);

    const video = {};
    for (const m of page.matchAll(/\.(type|hash|id)\s*=\s*['"]([^'"]+)['"]/g))
      if (!(m[1] in video)) video[m[1]] = m[2];
    for (const key of ["type", "hash", "id"])
      if (!(key in video)) throw new Error(`На странице Kodik нет данных видео (${key})`);

    const playerScript = page.match(/["'](\/assets\/js\/app\.player[^"']+\.js)["']/);
    let scriptPath = playerScript && playerScript[1];
    if (!scriptPath) {
      const any = page.match(/<script[^>]+src=["'](\/assets\/js\/[^"']+\.js)["']/);
      if (!any) throw new Error("На странице Kodik не найден js-бандл плеера");
      scriptPath = any[1];
    }

    const origin = new URL(url).origin;
    const script = await fetchText(origin + scriptPath, { headers: { Referer: url } });
    const ajax = script.match(/url:\s*atob\(["']([^"']+)["']\)/);
    if (!ajax) throw new Error("В бандле Kodik нет atob() с адресом эндпоинта");
    const postPath = b64Decode(ajax[1]);
    if (!postPath.startsWith("/")) throw new Error("Адрес эндпоинта Kodik неожиданный: " + postPath);

    const form = new URLSearchParams({
      hash: video.hash,
      id: video.id,
      type: video.type,
      d: params.d,
      d_sign: params.d_sign,
      pd: params.pd,
      pd_sign: params.pd_sign,
      // ref обязателен и должен быть раскодирован — пустой даёт 500
      ref: decodeURIComponent(params.ref || ""),
      ref_sign: params.ref_sign,
      bad_user: "true",
      cdn_is_working: "true",
    });
    const data = await postForm(origin + postPath, form, {
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Referer: url,
        Origin: origin,
        "X-Requested-With": "XMLHttpRequest",
        Accept: "application/json, text/javascript, */*; q=0.01",
      },
    });
    if (data && data.error) throw new Error("Kodik вернул ошибку: " + data.error);
    const links = (data && data.links) || {};
    if (!Object.keys(links).length) throw new Error("Kodik не вернул ссылок");

    const streams = [];
    let shift = null;
    const qualities = Object.keys(links).sort((a, b) => (a | 0) - (b | 0));
    for (const q of qualities) {
      const variant = (links[q] || [])[0];
      if (!variant || !variant.src) continue;
      let link, used;
      if (variant.src.includes(":hls:manifest.m3u8") || /^https?:|^\/\//.test(variant.src)) {
        link = forceHttps(variant.src);
      } else {
        [link, used] = decodeKodikUrl(variant.src, shift);
        shift = used;
        link = forceHttps(link);
      }
      const quality = q | 0;
      streams.push({ kind: "hls", quality, url: link });
      if (link.endsWith(":hls:manifest.m3u8"))
        streams.push({ kind: "mp4", quality, url: link.slice(0, -":hls:manifest.m3u8".length) });
    }
    if (!streams.length) throw new Error("Kodik вернул пустой список ссылок");
    streams.sort((a, b) => (b.quality || 0) - (a.quality || 0) || (a.kind === "mp4" ? -1 : 1));
    return { player: "kodik", streams };
  }

  /* -------------------------------- экспорт -------------------------------- */

  return {
    BROWSER_UA,
    ANIMEGO_REFERER,
    // cvh
    parseCvhUrl,
    cvhPlaylist,
    cvhSelect,
    cvhVideo,
    cvhExtract,
    // kodik
    kodikExtract,
    decodeKodikUrl,
    // хелперы
    unescapeHtml,
    caesarShift,
    forceHttps,
  };
});
