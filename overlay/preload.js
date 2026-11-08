// Pont entre l'overlay et le site du Grimoire. Le site reste une page web normale :
// il voit seulement window.grimoireOverlay et reçoit des événements DOM.
const { contextBridge, ipcRenderer } = require("electron");

const arg = process.argv.find(a => a.startsWith("--grimoire-prefixe="));
const prefixe = arg ? arg.split("=")[1] : "Ctrl+Maj";

contextBridge.exposeInMainWorld("grimoireOverlay", {
  prefixe,
  vue: v => ipcRenderer.send("grimoire:vue", v === "compact" ? "compact" : "complet"),
  masquer: () => ipcRenderer.send("grimoire:masquer")
});

const envoyer = (nom, detail) => window.dispatchEvent(new CustomEvent(nom, { detail }));
ipcRenderer.on("grimoire:raccourci", (_e, k) => envoyer("grimoire:raccourci", String(k)));
ipcRenderer.on("grimoire:message", (_e, t) => envoyer("grimoire:message", String(t)));
ipcRenderer.on("grimoire:traversant", (_e, oui) => {
  if (oui) document.documentElement.setAttribute("data-traversant", "");
  else document.documentElement.removeAttribute("data-traversant");
});

/* Bouton « masquer » ajouté à côté des boutons du site, puisque la fenêtre n'a pas de barre de titre. */
window.addEventListener("DOMContentLoaded", () => {
  if (location.protocol === "file:") return;
  const croix = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.700" stroke-linecap="round" aria-hidden="true"><path d="M4 8h8"/></svg>`;
  const titre = `Masquer (${prefixe}+G pour la rappeler)`;
  const compact = document.querySelector(".ct-actions");
  if (compact) {
    const b = document.createElement("button");
    b.className = "ct-btn"; b.type = "button"; b.title = titre; b.setAttribute("aria-label", "Masquer l’overlay"); b.innerHTML = croix;
    b.addEventListener("click", () => ipcRenderer.send("grimoire:masquer"));
    compact.appendChild(b);
  }
  const nav = document.querySelector(".nav-droite");
  if (nav) {
    const b = document.createElement("button");
    b.className = "btn discret"; b.type = "button"; b.title = titre; b.setAttribute("aria-label", "Masquer l’overlay"); b.innerHTML = croix;
    b.style.cssText = "display:grid;place-items:center;padding:6px 8px";
    b.querySelector("svg").style.cssText = "width:15px;height:15px";
    b.addEventListener("click", () => ipcRenderer.send("grimoire:masquer"));
    nav.appendChild(b);
  }
});
