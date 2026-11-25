# animego downloader

Работа с видео с [animego.me](https://animego.me) — три инструмента:

- **Chrome-расширение** ([chrome-extension/](chrome-extension/)) — кнопка на странице
  аниме, панель с выбором плеера/озвучки/серий, скачивание средствами браузера.
  Без серверной части.
- **CLI-скрипт** ([animego_downloader.py](animego_downloader.py)) — то же самое
  из командной строки.
- **Приложение для iPhone** ([ios-app/](ios-app/README.md)) — AnimeGO Cast: Share
  Extension для Safari отправляет серию в приложение AniLabX на телевизоре
  (протокол XRemote).

Оба построены по гайду [«Разбор плееров аниме-сайтов» (Habr)](https://habr.com/ru/articles/1079156/)
и его библиотеке [anime-dl-core](https://github.com/ialakey/anime-dl-core) — её логика
для CVH и Kodik портирована в `chrome-extension/extractors.js`.

Инструменты читают только то, что отдаёт обычный браузерный плеер: DRM и платные
ограничения не обходятся. Для личного использования.

---

## Chrome-расширение

### Установка

1. `chrome://extensions` → включите «Режим разработчика» (переключатель справа сверху)
2. «Загрузить распакованное расширение» → выберите папку `chrome-extension` проекта
3. Папку `chrome-extension` после установки не перемещать и не удалять —
   Chrome грузит код расширения из неё

### Использование

1. Откройте страницу любого аниме на animego.me — справа внизу появится
   фиолетовая кнопка со стрелкой.
2. Кликните — раскроется панель:
   - **Плеер** — CVH (mp4 144p–1080p, рекомендуется) или Kodik (mp4 360p–720p).
     Озвучки на разных плеерах различаются: если нужной нет в одном —
     переключите другой, список озвучек перестроится.
   - **Озвучка** — доступна для выбранного плеера.
   - **Качество ≤** — скачается ближайшее доступное не выше выбранного.
   - **Серии** — чипы, кнопка «все».
3. «Скачать выбранные» — серии уйдут в загрузки браузера
   (`Загрузки/<подпапка>/Название - эпизод N [Озвучка][720p].mp4`).

Значения по умолчанию (плеер, качество, подпапка) задаются в настройках:
иконка расширения в тулбаре или `chrome://extensions` → AnimeGO Downloader → «Настройки».

### Как оно работает (без сервера)

```
страница аниме (content script)
  └─ background service worker:
       GET animego.me/player/{id}/episodes        → список эпизодов
       GET animego.me/player/videos/{episodeId}   → embed-ссылки CVH/Kodik по озвучкам
       CVH:  plapi.cdnvideohub.com playlist/video → прямые mp4
       Kodik: страница + POST /ftor → base64+цезарь → прямые mp4
       chrome.downloads.download()                → загрузка браузером
```

- Cross-origin запросы разрешает `host_permissions`, CORS не мешает.
- Прямые mp4 CDN работают с обычным UA браузера (CVH проверяет именно его).
- Referer для API CVH ставит session-rule `declarativeNetRequest` —
  service worker не может указать Referer в fetch сам.
- Kodik работает вовсе без Referer/Origin (проверено), подписи одноразовые,
  поэтому между сериями пауза 1.5 с.

## CLI-скрипт

```bash
pip install -r requirements.txt

python animego_downloader.py URL --list                          # озвучки и серии
python animego_downloader.py URL --episode 1-3,7 --dub "Dream Cast" --quality 1080
python animego_downloader.py URL --episode all                   # всё
python animego_downloader.py URL --episode 1 --show-streams      # только ссылки
```

Активный плеер задаётся множеством `ENABLED_PROVIDERS` в начале скрипта
(сейчас только `cvh`; kodik/aniboom за заглушкой, код сохранён).
ffmpeg нужен только для HLS; если его нет в PATH, используется бинарник
из пакета `imageio-ffmpeg`.

## Тесты

```bash
node test_extractors.mjs                    # живые сети: цепочка animego + CVH + Kodik
node test_background_sim.cjs                # реальный background.js с заглушками chrome.*
```

UI-панель можно проверять без установки расширения: `python -m http.server 8791`
в корне проекта и открыть `http://127.0.0.1:8791/ui-test/test.html` — страница
подключает реальные `content.js`/`content.css` со стабами `chrome.*`.

## Заметки

- Прямые ссылки подписанные и живут минуты, кэшировать бессмысленно —
  они получаются заново перед каждым скачиванием (и могут быть привязаны к IP).
- Разметка `data-*` на animego периодически меняется; при поломке первым делом
  проверяйте регулярки (`fetchEpisodes`/`fetchProviders` в background.js и класс
  `AnimeGo` в python-скрипте).
