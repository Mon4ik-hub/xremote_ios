/**
 * Симуляция расширения в Node: исполняется РЕАЛЬНЫЙ background.js
 * с заглушками chrome.* и браузерным UA на fetch. Проверяются
 * agdl-get-info и agdl-download (CVH + Kodik) целиком.
 */
const fs = require("node:fs");
const path = require("node:path");

const BROWSER_UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

async function main() {
  // --- глобалы, которые ждёт background.js ---
  const downloadsLog = [];
  const progressLog = [];
  let messageHandler = null;
  const waitFor = (predicate, timeoutMs = 30000) =>
    new Promise((resolve, reject) => {
      const t0 = Date.now();
      const tick = () => {
        try {
          if (predicate()) return resolve();
        } catch (e) {
          return reject(e);
        }
        if (Date.now() - t0 > timeoutMs) return reject(new Error("timeout ожидания прогресса"));
        setTimeout(tick, 200);
      };
      tick();
    });
  const finishedCount = () => progressLog.filter((p) => p.status === "finished").length;
  global.self = global;
  global.importScripts = (...files) => {
    for (const f of files) {
      const code = fs.readFileSync(path.join(__dirname, "chrome-extension", f), "utf-8");
      // new Function — чтобы в области видимости не было module (как в SW),
      // иначе UMD-обёртка уходит в CommonJS-ветку
      new Function("self", code)(global);
    }
  };
  global.chrome = {
    runtime: {
      id: "test-extension-id",
      lastError: null,
      onMessage: { addListener: (fn) => (messageHandler = fn) },
    },
    storage: { sync: { get: async () => ({}) } },
    downloads: {
      download: async (opts) => {
        // валидируем что ссылка вообще живая (HEAD/Range)
        const r = await fetch(opts.url, { headers: { "User-Agent": BROWSER_UA, Range: "bytes=0-0" } });
        downloadsLog.push({ filename: opts.filename, status: r.status, url: opts.url.slice(0, 70) });
        return downloadsLog.length;
      },
      // события загрузки (нужны startChromeDownload)
      onChanged: { addListener() {}, removeListener() {} },
      onErased: { addListener() {}, removeListener() {} },
      search: async () => [{ state: "in_progress" }],
    },
    tabs: {
      sendMessage: async (tabId, msg) => {
        if (msg.type === "agdl-progress") {
          progressLog.push(msg);
          console.log(`  [progress] ${msg.status || ""} ${msg.text || ""}`);
        }
      },
    },
    declarativeNetRequest: { updateSessionRules: async () => {} },
    action: { onClicked: { addListener() {} } },
  };

  // fetch с браузерным UA (SW в Chrome шлёт свой UA всегда)
  const realFetch = global.fetch;
  global.fetch = (url, opts = {}) =>
    realFetch(url, { ...opts, headers: { "User-Agent": BROWSER_UA, ...(opts.headers || {}) } });

  // исполняем реальный background.js (eval — как importScripts в SW)
  eval(fs.readFileSync(path.join(__dirname, "chrome-extension", "background.js"), "utf-8"));
  if (!messageHandler) throw new Error("background.js не зарегистрировал onMessage");

  const call = (msg) =>
    new Promise((resolve) => messageHandler(msg, { tab: { id: 7 } }, resolve));

  // --- 1. get-info ---
  const ANIME_URL = "https://animego.me/anime/tainaya-bitva-za-prestol-sil-neishego-printsa-duraleya-3592";
  const info = await call({ type: "agdl-get-info", url: ANIME_URL });
  if (!info.ok) throw new Error("get-info: " + info.error);
  console.log(`get-info OK: «${info.data.title}», серий: ${info.data.episodes.length}`);
  console.log("  dubs:", JSON.stringify(info.data.dubs));

  // --- 2. download CVH ---
  const ep1 = info.data.episodes[0];
  await call({
    type: "agdl-download", url: ANIME_URL, title: info.data.title,
    episodes: [ep1], player: "cvh", dub: info.data.dubs.cvh[0],
    quality: "480", folder: "animego-test",
  });
  await waitFor(() => finishedCount() >= 1);

  // --- 3. download Kodik ---
  const kodikDub = info.data.dubs.kodik[0];
  await call({
    type: "agdl-download", url: ANIME_URL, title: info.data.title,
    episodes: [ep1], player: "kodik", dub: kodikDub,
    quality: "360", folder: "animego-test",
  });
  await waitFor(() => finishedCount() >= 2);

  for (const d of downloadsLog)
    console.log(`download -> HTTP ${d.status} | ${d.filename} | ${d.url}...`);
  if (downloadsLog.length !== 2 || downloadsLog.some((d) => d.status >= 400))
    throw new Error("загрузки не прошли проверку");
  console.log("\nСИМУЛЯЦИЯ РАСШИРЕНИЯ ПРОШЛА");
}

main().catch((e) => {
  console.error("FAIL:", e.message);
  process.exit(1);
});
