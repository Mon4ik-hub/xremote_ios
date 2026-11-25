#!/usr/bin/env python3
"""
Парсер-загрузчик видео с animego.me.

Цепочка (реверс-инжиниринг официального плеера сайта):
  1. GET {страница аниме}        -> data-anime-player-loader-url-value="/player/{anime_id}"
  2. GET /player/{anime_id}      -> список озвучек + данные о страницах эпизодов
  3. GET /player/{anime_id}/episodes?page=N -> список эпизодов (data-episode="{id}")
  4. GET /player/videos/{episode_id}        -> HTML с плеерами (data-player="//...") по озвучкам
  5. anime_dl_core.extract(embed_url)       -> прямые ссылки (mp4 / hls / dash) + заголовки

Идея шага 5 и работа с плеерами (AniBoom, Kodik, CVH, ...) взяты из гайда
https://habr.com/ru/articles/1079156/ (библиотека anime-dl-core).

Только то, что отдаёт обычный браузерный плеер; DRM и платные ограничения не обходятся.

Зависимости: pip install requests anime-dl-core imageio-ffmpeg
(ffmpeg нужен для HLS и склейки видео+озвучка; если ffmpeg нет в PATH,
используется бинарник из пакета imageio-ffmpeg)
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import requests

try:
    import anime_dl_core as adc
except ImportError:
    sys.exit("Не установлена библиотека anime-dl-core: pip install anime-dl-core")

BASE = "https://animego.me"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

# порядок предпочтения плееров, когда пользователь не указал конкретный
PROVIDER_ORDER = ["aniboom", "kodik", "cvh"]

# Активен только CVH: отдаёт прямые mp4 (144p–1080p) без HLS-склейки.
# Код остальных плееров (AniBoom, Kodik, ...) оставлен и рабочий,
# но по решению пользователя закрыт заглушкой. Чтобы вернуть -
# добавьте имя плеера в это множество (в нижнем регистре).
ENABLED_PROVIDERS = {"cvh"}


@dataclass
class Episode:
    number: str
    episode_id: str
    kind: str = ""  # data-episode-type (1 = обычная серия)


@dataclass
class PlayerItem:
    provider: str    # "Kodik", "AniBoom", "CVH", ...
    dub: str         # название озвучки, напр. "Dream Cast"
    dub_id: str
    url: str         # embed-ссылка плеера


class AnimeGo:
    def __init__(self, url: str):
        self.url = url
        self.sess = requests.Session()
        self.sess.headers.update({"User-Agent": UA, "Accept-Language": "ru-RU,ru;q=0.9"})
        self.anime_id: str = ""
        self.title: str = ""

    # ---------- шаги цепочки ----------

    def load(self):
        r = self._get(self.url)
        m = re.search(r'data-anime-player-loader-url-value="/player/(\d+)"', r)
        if not m:
            sys.exit("Не удалось найти плеер на странице: проверьте URL (нужна страница аниме на animego.me)")
        self.anime_id = m.group(1)
        t = re.search(r'<h1[^>]*>(.*?)</h1>', r, re.S)
        self.title = re.sub(r"<[^>]+>", "", t.group(1)).strip() if t else f"anime_{self.anime_id}"
        return self

    def episodes(self) -> list[Episode]:
        """Список эпизодов (с пагинацией по ?page=N, как это делает сам сайт)."""
        episodes: dict[str, Episode] = {}
        page = 0
        while page <= 50:  # защита от зацикливания
            d = self._json(f"/player/{self.anime_id}/episodes", params={"page": page})
            content = d["data"]["content"]
            found = 0
            for m in re.finditer(
                r'data-episode-number="([^"]+)"[^>]*data-episode-page="\d+"[^>]*'
                r'data-episode-index="\d+"[^>]*data-episode-type="(\d+)"[^>]*'
                r'data-episode="(\d+)"', content):
                found += 1
                num, kind, epid = m.groups()
                episodes.setdefault(num, Episode(num, epid, kind))
            returned = d["data"].get("page")
            if found == 0 or (returned is not None and int(returned) != page):
                break  # сервер зажал страницу — дальше эпизодов нет
            page += 1
        out = sorted(episodes.values(), key=lambda e: (0, int(e.number)) if e.number.isdigit() else (1, 0))
        return out

    def players(self, episode: Episode) -> list[PlayerItem]:
        """Плееры (озвучки) конкретного эпизода."""
        d = self._json(f"/player/videos/{episode.episode_id}")
        content = d["data"]["content"]
        items = []
        for m in re.finditer(
                r'data-player="([^"]+)"[^>]*data-provider="\d+"[^>]*data-ptranslation="(\d+)"'
                r'[^>]*data-provider-title="([^"]*)"[^>]*data-translation-title="([^"]*)"', content):
            url, dub_id, provider, dub = m.groups()
            items.append(PlayerItem(provider, html.unescape(dub), dub_id, "https:" + html.unescape(url)))
        return items

    # ---------- служебные ----------

    def _get(self, url: str, **kw) -> str:
        r = self.sess.get(url, timeout=30, **kw)
        r.raise_for_status()
        return r.text

    def _json(self, path: str, params: dict | None = None) -> dict:
        r = self.sess.get(BASE + path, params=params, timeout=30, headers={
            "X-Requested-With": "XMLHttpRequest", "Accept": "application/json",
            "Referer": self.url,
        })
        r.raise_for_status()
        d = r.json()
        if d.get("status") != "success":
            raise RuntimeError(f"API animego вернул ошибку для {path}: {d.get('message')}")
        return d


# ---------- выбор потока и скачивание ----------

def normalize_url(u: str) -> str:
    return "https:" + u if u.startswith("//") else u


def pick_stream(result, want_quality: str | None):
    """Выбирает поток: сначала прямые mp4, затем hls; качество <= запрошенного."""
    streams = [s for s in result.streams if not s.is_master]
    if not streams:
        return None
    want = int(want_quality) if want_quality and want_quality.isdigit() else None
    key = lambda s: (s.kind != "mp4", -(s.quality or 0))  # mp4 первее, качество выше лучше
    if want is not None:
        fitting = [s for s in streams if s.quality and s.quality <= want]
        if fitting:
            return sorted(fitting, key=key)[0]
        # нет подходящих по качеству — берём минимальное выше запрошенного
        return sorted(streams, key=lambda s: (s.kind != "mp4", (s.quality or 10**9)))[0]
    return sorted(streams, key=key)[0]


def ffmpeg_exe() -> str:
    ff = shutil.which("ffmpeg")
    if ff:
        return ff
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        sys.exit("ffmpeg не найден. Установите его в PATH или pip install imageio-ffmpeg")


def download_direct(stream, out: Path):
    """Прямой mp4 без отдельной аудиодорожки — качаем requests-ом."""
    tmp = out.with_suffix(".part")
    with requests.get(stream.url, headers=stream.headers or {}, stream=True, timeout=60) as r:
        r.raise_for_status()
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        with open(tmp, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):
                f.write(chunk)
                done += len(chunk)
                if total:
                    pct = done * 100 // total
                    print(f"\r    {done / 1e6:7.1f} / {total / 1e6:.1f} МБ ({pct}%)", end="", flush=True)
    print()
    tmp.replace(out)


def download_ffmpeg(stream, out: Path):
    """HLS и/или видео+отдельная дорожка озвучки (AniBoom) — склейка через ffmpeg."""
    exe = ffmpeg_exe()
    hdr = stream.headers or {}
    hdr_text = "".join(f"{k}: {v}\r\n" for k, v in hdr.items())
    cmd = [exe, "-y", "-loglevel", "error", "-stats", "-headers", hdr_text, "-i", stream.url]
    if stream.audio_url:  # видео и озвучка приходят разными потоками
        cmd += ["-headers", hdr_text, "-i", stream.audio_url,
                "-map", "0:v:0", "-map", "1:a:0"]
    cmd += ["-c", "copy", str(out)]
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        out.unlink(missing_ok=True)
        raise RuntimeError(f"ffmpeg завершился с кодом {proc.returncode}")


def safe_name(s: str) -> str:
    return re.sub(r'[<>:"/\\|?*]+', "_", s).strip()


# ---------- CLI ----------

def parse_episodes_arg(arg: str, available: list[Episode]) -> list[Episode]:
    """'5' | '1-5,7' | 'all' -> список эпизодов."""
    if arg.lower() in ("all", "все"):
        return available
    by_num = {e.number: e for e in available}
    chosen: list[Episode] = []
    for part in arg.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            if not (a.strip().isdigit() and b.strip().isdigit()):
                sys.exit(f"Непонятный диапазон эпизодов: {part}")
            for n in range(int(a), int(b) + 1):
                if str(n) in by_num:
                    chosen.append(by_num[str(n)])
        elif part in by_num:
            chosen.append(by_num[part])
        else:
            sys.exit(f"Эпизод {part!r} не найден. Доступны: {', '.join(e.number for e in available)}")
    # уникальные с сохранением порядка
    seen, uniq = set(), []
    for e in chosen:
        if e.number not in seen:
            seen.add(e.number)
            uniq.append(e)
    return uniq


def main():
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    p = argparse.ArgumentParser(
        description="Загрузка видео с animego.me (по гайду habr.com/ru/articles/1079156)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""примеры:
  python animego_downloader.py URL --list
  python animego_downloader.py URL --episode 1 --dub "Dream Cast"
  python animego_downloader.py URL --episode 1-3 --dub AniLiberty --quality 1080
  python animego_downloader.py URL --episode all --quality 720 --out downloads/
  python animego_downloader.py URL --episode 1 --show-streams   # только показать ссылки

плеер: работает только CVH (прямое mp4); AniBoom/Kodik закрыты заглушкой
(код оставлен, включаются через ENABLED_PROVIDERS в начале файла)""")
    p.add_argument("url", help="URL страницы аниме на animego.me")
    p.add_argument("--list", action="store_true", help="показать озвучки и эпизоды, ничего не скачивая")
    p.add_argument("--episode", default="1", help="номер: '5', '1-5,7' или 'all' (по умолчанию 1)")
    p.add_argument("--dub", default=None, help="название озвучки (по умолчанию — первая с наилучшим плеером)")
    p.add_argument("--provider", default=None,
                   help="плеер: активен только cvh (прямое mp4); остальные закрыты заглушкой")
    p.add_argument("--quality", default=None, help="максимальное качество, напр. 1080 (по умолчанию наилучшее)")
    p.add_argument("--out", default="downloads", help="каталог для файлов (по умолчанию ./downloads)")
    p.add_argument("--show-streams", action="store_true", help="вывести прямые ссылки и выйти")
    args = p.parse_args()

    anime = AnimeGo(args.url).load()
    episodes = anime.episodes()
    print(f"{anime.title} — {len(episodes)} эпизод(ов)")

    if not episodes:
        sys.exit("У тайтла нет эпизодов для скачивания")

    target_eps = parse_episodes_arg(args.episode, episodes)
    first_players = anime.players(target_eps[0])

    if args.list:
        dubs: dict[str, set[str]] = {}
        for it in first_players:
            dubs.setdefault(it.dub, set()).add(it.provider)
        print("\nОзвучки (доступные плееры):")
        for dub, provs in dubs.items():
            print(f"  {dub}  [{', '.join(sorted(provs))}]")
        print("\nЭпизоды:", ", ".join(e.number for e in episodes))
        return

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    for ep in target_eps:
        players = first_players if ep is target_eps[0] else anime.players(ep)
        if not players:
            print(f"  [эпизод {ep.number}] нет доступных плееров, пропуск")
            continue

        candidates = players
        if args.dub:
            candidates = [it for it in players if it.dub.lower() == args.dub.lower()]
            if not candidates:
                sys.exit(f"Озвучка {args.dub!r} не найдена. Есть: {', '.join(sorted({i.dub for i in players}))}")
        if args.provider:
            candidates = [it for it in candidates if it.provider.lower() == args.provider.lower()]
            if not candidates:
                sys.exit(f"Плеер {args.provider!r} не найден для этой озвучки. "
                         f"Есть: {', '.join(sorted({i.provider for i in players}))}")

        # заглушка: пропускаем отключённые плееры (см. ENABLED_PROVIDERS)
        disabled = [it for it in candidates if it.provider.lower() not in ENABLED_PROVIDERS]
        if disabled and args.provider:
            sys.exit(f"Плеер {args.provider!r} отключён заглушкой. "
                     f"Активен только: {', '.join(sorted(ENABLED_PROVIDERS))}.")
        candidates = [it for it in candidates if it.provider.lower() in ENABLED_PROVIDERS]
        if not candidates:
            print("  у этой озвучки нет активных плееров (только отключённые: "
                  f"{', '.join(sorted({i.provider for i in disabled})) or 'нет'}), пропуск")
            continue

        # авто-выбор: prefer dub with richest providers, then PROVIDER_ORDER
        def rank(it: PlayerItem):
            try:
                pref = PROVIDER_ORDER.index(it.provider.lower())
            except ValueError:
                pref = len(PROVIDER_ORDER)
            return pref

        candidates = sorted(candidates, key=rank)

        print(f"\n=== Эпизод {ep.number} ===")
        stream, chosen = None, None
        errors = []
        for it in candidates:
            try:
                res = adc.extract(it.url)
                stream = pick_stream(res, args.quality)
                if stream:
                    chosen = it
                    break
            except Exception as e:
                errors.append(f"{it.provider}/{it.dub}: {e}")
                continue
        if errors and not stream:
            for e in errors:
                print("  !", e)
        if not stream:
            print(f"  не удалось получить ссылку ни с одного плеера, пропуск")
            continue

        print(f"  плеер: {chosen.provider} | озвучка: {chosen.dub} | {stream.kind} {stream.quality or '?'}p"
              + (" + отдельная дорожка звука" if stream.audio_url else ""))
        print(f"  ссылка: {stream.url[:100]}...")

        if args.show_streams:
            continue

        fname = safe_name(f"{anime.title} - эпизод {ep.number} [{chosen.dub}]"
                          f"[{stream.quality or ''}p].mp4")
        out = out_dir / fname
        print(f"  -> {out}")
        try:
            if stream.kind == "mp4" and not stream.audio_url:
                download_direct(stream, out)
            else:
                download_ffmpeg(stream, out)
            print(f"  готово: {out} ({out.stat().st_size / 1e6:.1f} МБ)")
        except Exception as e:
            print(f"  ОШИБКА скачивания: {e}")


if __name__ == "__main__":
    main()
