/**
 * Живой тест extractors.js в Node: та же сеть, тот же код, что пойдёт в
 * service worker расширения. Запуск: node test_extractors.mjs
 */
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const X = require("./chrome-extension/extractors.js");

const UA = X.BROWSER_UA;

// аналог fetch-хелперов из background.js
async function fetchPage(url, opts = {}) {
  const r = await fetch(url, { headers: { "User-Agent": UA, ...opts.headers } });
  if (!r.ok) throw new Error(`${url} -> HTTP ${r.status}`);
  return r.json();
}
async function fetchText(url, opts = {}) {
  const r = await fetch(url, { headers: { "User-Agent": UA, ...opts.headers } });
  if (!r.ok) throw new Error(`${url} -> HTTP ${r.status}`);
  return r.text();
}
async function postForm(url, form, opts = {}) {
  const r = await fetch(url, {
    method: "POST",
    body: form.toString(),
    headers: { "User-Agent": UA, ...opts.headers },
  });
  if (!r.ok) throw new Error(`POST ${url} -> HTTP ${r.status}`);
  return r.json();
}

const ANIME_URL =
  "https://animego.me/anime/tainaya-bitva-za-prestol-sil-neishego-printsa-duraleya-3592";

// 1. цепочка animego (те же эндпоинты, что в python-скрипте)
const page = await fetchText(ANIME_URL, { headers: { "Accept-Language": "ru-RU,ru;q=0.9" } });
const animeId = page.match(/data-anime-player-loader-url-value="\/player\/(\d+)"/)[1];
const title = page.match(/<h1[^>]*>(.*?)<\/h1>/s)[1].replace(/<[^>]+>/g, "").trim();
console.log(`anime: ${title} (id=${animeId})`);

const epsJson = await fetchPage(
  `https://animego.me/player/${animeId}/episodes?page=0`,
  { headers: { "X-Requested-With": "XMLHttpRequest", Accept: "application/json", Referer: ANIME_URL } }
);
const epMatch = [...epsJson.data.content.matchAll(
  /data-episode-number="([^"]+)"[^>]*data-episode-type="\d+"[^>]*data-episode-watched="\w+"[^>]*data-episode="(\d+)"/g
)];
const episodes = epMatch.map((m) => ({ number: m[1], id: m[2] }));
console.log(`episodes: ${episodes.map((e) => e.number).join(",")}`);

const vidsJson = await fetchPage(
  `https://animego.me/player/videos/${episodes[0].id}`,
  { headers: { "X-Requested-With": "XMLHttpRequest", Accept: "application/json", Referer: ANIME_URL } }
);
const providers = [...vidsJson.data.content.matchAll(
  /data-player="([^"]+)"[^>]*data-provider-title="([^"]+)"[^>]*data-translation-title="([^"]+)"/g
)].map((m) => ({ url: "https:" + X.unescapeHtml(m[1]), player: m[2], dub: m[3] }));
console.log(`providers ep1: ${providers.map((p) => `${p.player}/${p.dub}`).join(" | ")}`);

// 2. CVH
{
  const cvh = providers.find((p) => p.player === "CVH");
  const res = await X.cvhExtract(fetchPage, cvh.url, {});
  console.log(`\nCVH ok: studio=${res.episodeItem.studio} ep=${res.episodeItem.episode}`);
  for (const s of res.streams.filter((s) => s.kind === "mp4").slice(0, 3))
    console.log(`  ${s.kind} ${s.quality}p ${s.url.slice(0, 70)}`);
  // серия 2 + нечёткая озвучка
  const res2 = await X.cvhExtract(fetchPage, cvh.url, { episode: 2, studio: "aniLiberty" });
  console.log(`CVH ep2 fuzzy 'aniLiberty' -> studio=${res2.episodeItem.studio}, top=${res2.streams[0].quality}p`);
}

// 3. Kodik
{
  const kod = providers.find((p) => p.player === "Kodik");
  const res = await X.kodikExtract(fetchPage, fetchText, postForm, kod.url);
  console.log(`\nKodik ok:`);
  for (const s of res.streams.slice(0, 4))
    console.log(`  ${s.kind} ${s.quality}p ${s.url.slice(0, 70)}`);
}

// 4. AniBoom удалён из расширения по решению пользователя

console.log("\nВСЕ ТЕСТЫ ПРОЙДЕНЫ");
