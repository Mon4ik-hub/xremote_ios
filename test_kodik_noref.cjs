// Kodik: работает ли цепочка БЕЗ Referer/Origin (как это сделает SW без DNR)
const { createRequire } = require("node:module");

async function main() {
  const require2 = createRequire(__filename);
  const X = require2("./chrome-extension/extractors.js");

  async function fetchText(url, opts = {}) {
    const clean = { ...opts };
    if (clean.headers) {
      const h = { ...clean.headers };
      delete h.Referer; delete h.Origin; // имитируем, что браузер их выкинул
      clean.headers = h;
    }
    const r = await fetch(url, clean);
    if (!r.ok) throw new Error(`GET ${url} -> HTTP ${r.status}`);
    return r.text();
  }
  async function postForm(url, form, opts = {}) {
    const h = { ...opts.headers };
    delete h.Referer; delete h.Origin;
    const r = await fetch(url, { method: "POST", body: form.toString(), headers: h });
    if (!r.ok) throw new Error(`POST ${url} -> HTTP ${r.status}`);
    return r.json();
  }

  try {
    const res = await X.kodikExtract(async () => ({}), fetchText, postForm,
      "https://kodikplayer.com/seria/1639959/ab226064af69d5695eddcc46ce63a18a/720p?translations=false&min_age=16");
    console.log("Kodik БЕЗ Referer/Origin: OK");
    for (const s of res.streams.slice(0, 2)) console.log("  ", s.kind, s.quality + "p", s.url.slice(0, 60));
  } catch (e) {
    console.log("Kodik БЕЗ Referer/Origin: FAIL —", e.message);
  }
}
main();
