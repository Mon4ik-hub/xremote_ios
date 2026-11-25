/* Настройки расширения: плеер по умолчанию, качество, подпапка загрузок. */

const DEFAULTS = { player: "cvh", quality: "best", folder: "animego" };

const els = {
  player: document.getElementById("player"),
  quality: document.getElementById("quality"),
  folder: document.getElementById("folder"),
  save: document.getElementById("save"),
  saved: document.getElementById("saved"),
};

chrome.storage.sync.get(DEFAULTS).then((s) => {
  els.player.value = s.player;
  els.quality.value = s.quality;
  els.folder.value = s.folder;
});

els.save.addEventListener("click", async () => {
  await chrome.storage.sync.set({
    player: els.player.value,
    quality: els.quality.value,
    folder: els.folder.value.trim(),
  });
  els.saved.classList.add("show");
  setTimeout(() => els.saved.classList.remove("show"), 1500);
});
