"use strict";

const storageKey = "gdev-emacs-comandi-fissati";
const filter = document.querySelector("#comandi-filtro");
const onlyPinned = document.querySelector("#solo-fissati");
const filterStatus = document.querySelector("#esito-filtro");
const rows = Array.from(document.querySelectorAll("#lista-comandi li[data-id]"));
const ids = new Set(rows.map((row) => row.dataset.id));
const pinned = readPinned();
const normalize = (value) =>
  value.toLocaleLowerCase("it").normalize("NFD").replace(/\p{Diacritic}/gu, "");

function readPinned() {
  try {
    const stored = JSON.parse(localStorage.getItem(storageKey) ?? "[]");
    return new Set(Array.isArray(stored) ? stored.filter((id) => ids.has(id)) : []);
  } catch {
    return new Set();
  }
}

function savePinned() {
  try {
    localStorage.setItem(storageKey, JSON.stringify([...pinned]));
  } catch {
    // Mantiene i comandi fissati per la durata della pagina.
  }
}

function updateList() {
  const query = normalize(filter.value.trim());
  const showPinned = onlyPinned.getAttribute("aria-pressed") === "true";
  let visible = 0;

  for (const row of rows) {
    const isPinned = pinned.has(row.dataset.id);
    const pin = row.querySelector(".pin");
    pin.setAttribute("aria-pressed", String(isPinned));
    pin.textContent = isPinned ? "★" : "☆";
    row.hidden = (showPinned && !isPinned) || !row.dataset.search.includes(query);
    if (!row.hidden) visible += 1;
  }

  if (visible === 0) {
    filterStatus.textContent = showPinned && !query
      ? "Nessun comando fissato."
      : "Nessun comando corrisponde alla ricerca.";
  } else {
    filterStatus.textContent = query || showPinned
      ? (visible === 1 ? "Un comando" : visible + " comandi")
      : "";
  }
}

for (const row of rows) {
  const name = row.querySelector("strong").textContent;
  row.dataset.search = normalize(row.textContent);
  const pin = document.createElement("button");
  pin.type = "button";
  pin.className = "pin";
  pin.setAttribute("aria-label", "Fissa " + name);
  pin.addEventListener("click", () => {
    const id = row.dataset.id;
    if (pinned.has(id)) pinned.delete(id);
    else pinned.add(id);
    savePinned();
    updateList();
    if (row.hidden) onlyPinned.focus();
  });
  row.append(pin);
}
document.querySelector(".command-tools").hidden = false;
filter.addEventListener("input", updateList);
onlyPinned.addEventListener("click", () => {
  onlyPinned.setAttribute("aria-pressed", String(onlyPinned.getAttribute("aria-pressed") !== "true"));
  updateList();
});
updateList();

const copyButton = document.querySelector("#copia-installazione");
const installCommands = document.querySelector("#passi-installazione");
const copyStatus = document.querySelector("#esito-copia");
copyButton.hidden = false;
copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(installCommands.textContent);
    copyStatus.textContent = "Comandi copiati.";
  } catch {
    const selection = window.getSelection();
    if (selection) {
      const range = document.createRange();
      range.selectNodeContents(installCommands);
      selection.removeAllRanges();
      selection.addRange(range);
    }
    copyStatus.textContent = "Premi ⌘C per copiare i comandi selezionati.";
  }
});
