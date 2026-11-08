// Grimoire Overlay : le Grimoire des Entités dans une fenêtre posée au-dessus de Phasmophobia.
// La fenêtre affiche le site en ligne (mode compact) : chaque mise à jour du site y arrive toute seule.
// Le jeu doit être en « Fenêtré sans bordure » : en plein écran exclusif, Windows n'affiche rien par-dessus.

const { app, BrowserWindow, globalShortcut, Tray, Menu, screen, shell, nativeImage, ipcMain } = require("electron");
const path = require("node:path");
const fs = require("node:fs");

const SITE = process.env.GRIMOIRE_SITE || "https://ethrniity.github.io/Phasmophobia/";
const HOTE = new URL(SITE).host;
const OPACITES = [1, 0.85, 0.7, 0.55];
const TAILLES = { compact: { width: 380, height: 720 }, complet: { width: 1180, height: 820 } };

/* Préfixes possibles pour les raccourcis en jeu. Ctrl+Alt est évité : sur un clavier AZERTY c'est AltGr (€, #, @…). */
const PREFIXES = {
  "Ctrl+Shift": "Ctrl+Maj",
  "Alt+Shift": "Alt+Maj",
  "Ctrl+Alt": "Ctrl+Alt"
};
/* Touches envoyées à l'appli (même logique que le clavier dans le site). */
const TOUCHES_APPLI = ["1", "2", "3", "4", "5", "6", "7", "E", "F", "C", "P", "L", "D", "N"];

// ───────────── Réglages enregistrés ─────────────
const FICHIER = () => path.join(app.getPath("userData"), "reglages.json");
const DEFAUT = {
  vue: "compact",
  bornes: { compact: null, complet: null },
  opacite: 1,
  devant: true,
  raccourcis: true,
  pave: false,
  prefixe: "Ctrl+Shift",
  vuMasque: false
};
let R = structuredClone(DEFAUT);
function lire() {
  try { R = Object.assign(structuredClone(DEFAUT), JSON.parse(fs.readFileSync(FICHIER(), "utf8"))); } catch { /* premier lancement */ }
  if (!PREFIXES[R.prefixe]) R.prefixe = DEFAUT.prefixe;
  if (!OPACITES.includes(R.opacite)) R.opacite = 1;
}
let attente = null;
function ecrire() {
  clearTimeout(attente);
  attente = setTimeout(() => { try { fs.writeFileSync(FICHIER(), JSON.stringify(R, null, 2)); } catch { /* sans gravité */ } }, 300);
}

// ───────────── Fenêtre ─────────────
let win = null, tray = null, traversant = false;

/* Position par défaut : coin haut droit de l'écran principal, ou dernière position si elle est encore visible. */
function bornesPour(vue) {
  const b = R.bornes[vue];
  if (b && screen.getAllDisplays().some(d => intersecte(d.workArea, b))) return b;
  const zone = screen.getPrimaryDisplay().workArea, t = TAILLES[vue];
  const w = Math.min(t.width, zone.width - 40), h = Math.min(t.height, zone.height - 40);
  return vue === "compact"
    ? { x: zone.x + zone.width - w - 20, y: zone.y + 20, width: w, height: h }
    : { x: zone.x + Math.round((zone.width - w) / 2), y: zone.y + Math.round((zone.height - h) / 2), width: w, height: h };
}
function intersecte(a, b) {
  return a.x < b.x + b.width - 60 && b.x < a.x + a.width - 60 && a.y < b.y + b.height - 40 && b.y < a.y + a.height - 40;
}
function adresse(vue) { return SITE + "?vue=" + (vue === "compact" ? "compact" : "complet"); }

function creer() {
  win = new BrowserWindow({
    ...bornesPour(R.vue),
    minWidth: 320, minHeight: 360,
    frame: false,
    backgroundColor: "#0e0c18",
    alwaysOnTop: R.devant,
    show: false,
    title: "Grimoire Overlay",
    icon: path.join(__dirname, "icone.png"),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      additionalArguments: ["--grimoire-prefixe=" + PREFIXES[R.prefixe]]
    }
  });
  // « screen-saver » : au-dessus des jeux en fenêtré sans bordure.
  if (R.devant) win.setAlwaysOnTop(true, "screen-saver");
  win.setOpacity(R.opacite);
  win.setMenuBarVisibility(false);

  win.loadURL(adresse(R.vue));
  win.once("ready-to-show", () => win.show());

  // Glisser la fenêtre : la barre du haut en compact, le titre en vue complète.
  win.webContents.on("did-finish-load", () => {
    if (!win.webContents.getURL().startsWith(SITE)) return;
    win.webContents.insertCSS(`
      :root:not([data-compact]) .entete{-webkit-app-region:drag;user-select:none;cursor:move}
      :root:not([data-compact]) .entete::after{content:"Grimoire Overlay · ${PREFIXES[R.prefixe]}+G pour masquer ou rappeler";display:block;font:11px "IBM Plex Mono",monospace;color:var(--cendre);margin-top:6px}
      :root[data-traversant] body{outline:2px dashed var(--cierge);outline-offset:-2px}
      ::-webkit-scrollbar{width:8px}::-webkit-scrollbar-thumb{background:var(--trait);border-radius:8px}
    `);
  });

  // Site injoignable : page d'attente qui réessaie toute seule.
  win.webContents.on("did-fail-load", (_e, code, _desc, url, principal) => {
    if (!principal || code === -3) return; // -3 : chargement annulé, sans gravité
    if (url && url.startsWith("file:")) return;
    win.loadFile(path.join(__dirname, "hors-ligne.html"), { query: { cible: adresse(R.vue) } });
  });

  // Liens externes (aide, Steam, mails…) : dans le navigateur, pas dans l'overlay.
  win.webContents.setWindowOpenHandler(({ url }) => { ouvrirDehors(url); return { action: "deny" }; });
  win.webContents.on("will-navigate", (e, url) => {
    let hote = ""; try { hote = new URL(url).host; } catch { /* adresse invalide */ }
    if (url.startsWith("file:") || hote === HOTE || hote.endsWith(".supabase.co")) return;
    e.preventDefault(); ouvrirDehors(url);
  });

  const memoriser = () => { if (win && !win.isDestroyed() && !win.isMinimized()) { R.bornes[R.vue] = win.getBounds(); ecrire(); } };
  win.on("moved", memoriser);
  win.on("resized", memoriser);
  win.on("closed", () => { win = null; });
}
function ouvrirDehors(url) {
  try { const u = new URL(url); if (["https:", "http:", "mailto:"].includes(u.protocol)) shell.openExternal(url); } catch { /* ignoré */ }
}

/* Le site demande à changer de vue (bouton « Vue complète » ou « Compact »). */
function changerVue(vue) {
  if (!win || (vue !== "compact" && vue !== "complet") || vue === R.vue) return;
  R.bornes[R.vue] = win.getBounds();
  R.vue = vue; ecrire();
  win.setBounds(bornesPour(vue), true);
  majMenu();
}

// ───────────── Actions ─────────────
function message(t) {
  if (win && !win.isDestroyed()) win.webContents.send("grimoire:message", t);
}
function basculerVisible() {
  if (!win) { creer(); return; }
  if (win.isVisible() && !win.isMinimized()) win.hide();
  else { win.showInactive(); if (R.devant) win.setAlwaysOnTop(true, "screen-saver"); }
}
function basculerTraversant() {
  if (!win) return;
  traversant = !traversant;
  win.setIgnoreMouseEvents(traversant, { forward: true });
  win.webContents.send("grimoire:traversant", traversant);
  if (!traversant) win.focus();
  message(traversant ? "Clics traversants : la souris passe au jeu" : "Clics normaux : l’overlay répond à la souris");
  majMenu();
}
function opaciteSuivante() {
  const i = OPACITES.indexOf(R.opacite);
  R.opacite = OPACITES[(i + 1) % OPACITES.length];
  if (win) win.setOpacity(R.opacite);
  message("Opacité : " + Math.round(R.opacite * 100) + " %");
  ecrire(); majMenu();
}
function choisirOpacite(o) { R.opacite = o; if (win) win.setOpacity(o); ecrire(); majMenu(); }
function basculerDevant() {
  R.devant = !R.devant;
  if (win) win.setAlwaysOnTop(R.devant, "screen-saver");
  ecrire(); majMenu();
}
/* Passe la fenêtre sur l'écran suivant, au même endroit relatif (pratique avec deux écrans). */
function ecranSuivant() {
  if (!win) return;
  const ecrans = screen.getAllDisplays();
  if (ecrans.length < 2) { message("Un seul écran détecté"); return; }
  const b = win.getBounds(), ici = screen.getDisplayMatching(b);
  const i = ecrans.findIndex(d => d.id === ici.id), la = ecrans[(i + 1) % ecrans.length];
  const rx = (b.x - ici.workArea.x) / Math.max(1, ici.workArea.width - b.width);
  const ry = (b.y - ici.workArea.y) / Math.max(1, ici.workArea.height - b.height);
  const w = Math.min(b.width, la.workArea.width), h = Math.min(b.height, la.workArea.height);
  win.setBounds({
    x: Math.round(la.workArea.x + Math.min(1, Math.max(0, rx)) * (la.workArea.width - w)),
    y: Math.round(la.workArea.y + Math.min(1, Math.max(0, ry)) * (la.workArea.height - h)),
    width: w, height: h
  });
  R.bornes[R.vue] = win.getBounds(); ecrire();
}
function recentrer() {
  if (!win) return;
  R.bornes[R.vue] = null;
  win.setBounds(bornesPour(R.vue));
  win.showInactive();
}

// ───────────── Raccourcis en jeu ─────────────
function enregistrerRaccourcis() {
  globalShortcut.unregisterAll();
  const p = R.prefixe, rates = [];
  const lier = (touche, f) => { try { if (!globalShortcut.register(p + "+" + touche, f)) rates.push(touche); } catch { rates.push(touche); } };
  // Toujours actifs : afficher / masquer, clics traversants, opacité, écran suivant.
  lier("G", basculerVisible);
  lier("T", basculerTraversant);
  lier("O", opaciteSuivante);
  lier("M", ecranSuivant);
  if (R.raccourcis) {
    TOUCHES_APPLI.forEach(t => lier(t, () => { if (win && !win.isDestroyed()) win.webContents.send("grimoire:raccourci", t); }));
  }
  // Option : pavé numérique sans préfixe, Num1 à Num7 pour les preuves (Phasmophobia ne s'en sert pas).
  // Désactivé par défaut : tant que l'overlay tourne, ces touches ne tapent plus de chiffres ailleurs.
  if (R.raccourcis && R.pave) {
    for (let n = 1; n <= 7; n++) {
      try { globalShortcut.register("num" + n, () => { if (win && !win.isDestroyed()) win.webContents.send("grimoire:raccourci", String(n)); }); } catch { /* clavier sans pavé */ }
    }
  }
  if (rates.length) setTimeout(() => message("Raccourcis déjà pris par un autre programme : " + rates.map(t => PREFIXES[p] + "+" + t).join(", ")), 2500);
}

// ───────────── Icône de la barre des tâches (zone de notification) ─────────────
function majMenu() {
  if (!tray) return;
  const P = PREFIXES[R.prefixe];
  tray.setToolTip("Grimoire Overlay" + (traversant ? " · clics traversants" : ""));
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "Afficher / masquer", accelerator: P.replace("Maj", "Shift") + "+G", click: basculerVisible },
    { label: R.vue === "compact" ? "Passer en vue complète" : "Passer en mode compact", click: () => win && win.webContents.send("grimoire:raccourci", "V") },
    { type: "separator" },
    { label: "Toujours au premier plan", type: "checkbox", checked: R.devant, click: basculerDevant },
    { label: "Clics traversants (la souris passe au jeu)", type: "checkbox", checked: traversant, click: basculerTraversant },
    { label: "Opacité", submenu: OPACITES.map(o => ({ label: Math.round(o * 100) + " %", type: "radio", checked: R.opacite === o, click: () => choisirOpacite(o) })) },
    { label: "Écran suivant", click: ecranSuivant, enabled: screen.getAllDisplays().length > 1 },
    { label: "Remettre en place", click: recentrer },
    { type: "separator" },
    { label: "Raccourcis en jeu (preuves, minuteurs…)", type: "checkbox", checked: R.raccourcis, click: () => { R.raccourcis = !R.raccourcis; ecrire(); enregistrerRaccourcis(); majMenu(); } },
    { label: "Pavé numérique 1 à 7 pour les preuves", type: "checkbox", checked: R.pave, enabled: R.raccourcis, click: () => { R.pave = !R.pave; ecrire(); enregistrerRaccourcis(); majMenu(); } },
    { label: "Touche de préfixe", submenu: Object.entries(PREFIXES).map(([k, v]) => ({ label: v, type: "radio", checked: R.prefixe === k, click: () => {
      R.prefixe = k; ecrire(); enregistrerRaccourcis(); majMenu();
      message("Préfixe des raccourcis : " + v + ". Relance l’overlay pour mettre à jour l’aide affichée.");
    } })) },
    { label: "Recharger le Grimoire", click: () => win && win.loadURL(adresse(R.vue)) },
    { type: "separator" },
    { label: "Quitter", click: () => app.quit() }
  ]));
}

// ───────────── Démarrage ─────────────
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on("second-instance", () => { if (win) { win.show(); win.focus(); } else creer(); });
  app.whenReady().then(() => {
    app.setAppUserModelId("io.github.ethrniity.grimoire-overlay");
    lire();
    ipcMain.on("grimoire:vue", (_e, vue) => changerVue(vue));
    ipcMain.on("grimoire:masquer", () => {
      if (!win) return;
      win.hide();
      if (tray && !R.vuMasque) { R.vuMasque = true; ecrire(); tray.displayBalloon?.({ title: "Grimoire Overlay", content: "Masqué. " + PREFIXES[R.prefixe] + "+G ou l’icône près de l’horloge pour le rappeler." }); }
    });
    creer();
    const img = nativeImage.createFromPath(path.join(__dirname, "icone-plateau.png"));
    tray = new Tray(img.isEmpty() ? nativeImage.createFromPath(path.join(__dirname, "icone.png")).resize({ width: 16, height: 16 }) : img);
    tray.on("click", basculerVisible);
    majMenu();
    enregistrerRaccourcis();
    screen.on("display-added", majMenu);
    screen.on("display-removed", () => { majMenu(); if (win && !screen.getAllDisplays().some(d => intersecte(d.workArea, win.getBounds()))) recentrer(); });
  });
  app.on("will-quit", () => globalShortcut.unregisterAll());
  // Fermer la fenêtre ne quitte pas : l'overlay reste dans la zone de notification (Quitter dans son menu).
  app.on("window-all-closed", () => { /* rester actif */ });
}
