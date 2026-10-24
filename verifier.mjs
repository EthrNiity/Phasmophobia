// Vérification des données du Grimoire des Entités, à lancer avant chaque publication :
//   node verifier.mjs          contrôle des données et du calcul, sans dépendance
//   node verifier.mjs --page   en plus, ouvre l'appli dans Chromium et parcourt les onglets (Playwright) Code de sortie 0 : données valides ; 1 : au moins une erreur (ne pas publier).
// Les avertissements (valeurs « à compléter », combinaisons de preuves en double) n'empêchent pas la publication.
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dossier = new URL(".", import.meta.url);
const html = readFileSync(new URL("index.html", dossier), "utf8");
const erreurs = [], avertissements = [];
const erreur = m => erreurs.push(m), avert = m => avertissements.push(m);

/* 1. Chaque script intégré à index.html doit être du JavaScript valide. */
const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
scripts.forEach((code, i) => { try { new vm.Script(code); } catch (e) { erreur(`Script intégré n°${i + 1} invalide : ${e.message}`); } });

/* 2. Le moteur (entre ENGINE-START et ENGINE-END) doit s'exécuter seul. */
const debut = html.indexOf("/*ENGINE-START*/"), fin = html.indexOf("/*ENGINE-END*/");
if (debut < 0 || fin < debut) { console.error("Marqueurs ENGINE-START / ENGINE-END introuvables."); process.exit(1); }
const ctx = vm.createContext({});
try {
  vm.runInContext(html.slice(debut, fin) + "\n;globalThis.__m={EV,GHOSTS,NIVEAUX,VITESSES,etatVide,calculer,ensembles};", ctx);
} catch (e) { console.error("Le moteur ne s'exécute pas : " + e.message); process.exit(1); }
const { EV, GHOSTS, NIVEAUX, VITESSES, etatVide, calculer, ensembles } = ctx.__m;

/* Extrait un littéral { … } ou [ … ] qui suit `debutTexte`, en respectant les chaînes. */
function litteral(debutTexte) {
  const i0 = html.indexOf(debutTexte);
  if (i0 < 0) return null;
  let i = i0 + debutTexte.length;
  while (html[i] !== "{" && html[i] !== "[") i++;
  const ouvre = html[i], ferme = ouvre === "{" ? "}" : "]";
  let prof = 0, q = null;
  for (let j = i; j < html.length; j++) {
    const c = html[j];
    if (q) { if (c === "\\") j++; else if (c === q) q = null; continue; }
    if (c === '"' || c === "'" || c === "`") { q = c; continue; }
    if (c === ouvre) prof++;
    else if (c === ferme && --prof === 0) return vm.runInNewContext("(" + html.slice(i, j + 1) + ")");
  }
  return null;
}

/* 3. Preuves. */
const idsEV = new Set(EV.map(e => e.id));
if (idsEV.size !== EV.length) erreur("Deux preuves portent le même identifiant.");
EV.forEach(e => { if (!e.n || !e.c) erreur(`Preuve « ${e.id} » : nom ou nom court manquant.`); });

/* 4. Entités. */
const estAcompleter = v => typeof v === "string" && /à compléter/i.test(v);
const ids = new Set(), triplets = new Map();
for (const g of GHOSTS) {
  const qui = `Entité « ${g.id} »`;
  if (!/^[a-z0-9-]+$/.test(g.id || "")) erreur(`${qui} : identifiant invalide (minuscules, chiffres, tirets).`);
  if (ids.has(g.id)) erreur(`${qui} : identifiant en double.`);
  ids.add(g.id);
  if (!g.n) erreur(`${qui} : nom manquant.`);
  if (!Array.isArray(g.ev) || g.ev.length !== 3 || new Set(g.ev).size !== 3) erreur(`${qui} : il faut exactement 3 preuves différentes.`);
  else g.ev.forEach(e => { if (!idsEV.has(e)) erreur(`${qui} : preuve inconnue « ${e} ».`); });
  if (g.forced && !(g.ev || []).includes(g.forced)) erreur(`${qui} : la preuve forcée « ${g.forced} » n'est pas une de ses preuves.`);
  if (g.tMin == null || g.tMax == null) {
    if (!(g.tMin == null && g.tMax == null)) erreur(`${qui} : tMin et tMax doivent être tous deux connus, ou tous deux à null.`);
    else avert(`${qui} : seuil de chasse à compléter à la main.`);
  } else if (!(Number.isFinite(g.tMin) && Number.isFinite(g.tMax) && 0 <= g.tMin && g.tMin <= g.tMax && g.tMax <= 100))
    erreur(`${qui} : seuils de chasse incohérents (tMin ${g.tMin}, tMax ${g.tMax}).`);
  if (g.sp == null) avert(`${qui} : vitesse à compléter à la main.`);
  else if (!Array.isArray(g.sp) || !g.sp.length || !g.sp.every(r => Array.isArray(r) && r.length === 2 && r.every(Number.isFinite) && 0.2 <= r[0] && r[0] <= r[1] && r[1] <= 5))
    erreur(`${qui} : plages de vitesse invalides (attendu [[min,max], …] en m/s, entre 0,2 et 5).`);
  if (g.any != null && !(g.any >= 0 && g.any <= 1)) erreur(`${qui} : « any » doit être entre 0 et 1.`);
  for (const champ of ["signe", "test"]) {
    if (typeof g[champ] !== "string" || !g[champ].trim()) erreur(`${qui} : texte « ${champ} » manquant.`);
    else if (estAcompleter(g[champ])) avert(`${qui} : « ${champ} » à compléter à la main.`);
  }
  if (Array.isArray(g.ev)) {
    const cle = [...g.ev].sort().join("+");
    if (triplets.has(cle)) avert(`Mêmes trois preuves pour « ${triplets.get(cle)} » et « ${g.id} ».`);
    else triplets.set(cle, g.id);
  }
}
if (!GHOSTS.some(g => g.id === "mimic")) avert("Le Mimic n'est plus dans la liste.");
else if (GHOSTS.find(g => g.id === "mimic").ev.includes("orb")) erreur("Le Mimic ne doit pas avoir les orbes parmi ses trois preuves (elles s'ajoutent toujours).");

/* 5. Difficultés et vitesses de référence. */
const idsNiv = new Set();
for (const v of NIVEAUX) {
  if (idsNiv.has(v.id)) erreur(`Difficulté « ${v.id} » en double.`);
  idsNiv.add(v.id);
  if (!(Number.isInteger(v.n) && v.n >= 0 && v.n <= 3)) erreur(`Difficulté « ${v.id} » : nombre de preuves fournies hors de 0 à 3.`);
  if (!v.nom) erreur(`Difficulté « ${v.id} » : nom manquant.`);
}
VITESSES.forEach(v => { if (!(v.r[0] < v.r[1])) erreur(`Catégorie de vitesse « ${v.id} » : plage invalide.`); });

/* 6. Fiches détaillées : une par entité, aucune orpheline. */
const FICHES = litteral("const FICHES =");
if (!FICHES) erreur("Objet FICHES introuvable dans index.html.");
else {
  for (const g of GHOSTS) {
    const f = FICHES[g.id];
    if (!f) { erreur(`Entité « ${g.id} » : fiche détaillée manquante dans FICHES.`); continue; }
    for (const champ of ["f", "w"]) {
      if (typeof f[champ] !== "string" || !f[champ].trim()) erreur(`Fiche « ${g.id} » : champ « ${champ} » manquant.`);
      else if (estAcompleter(f[champ])) avert(`Fiche « ${g.id} » : « ${champ === "f" ? "force" : "faiblesse"} » à compléter à la main.`);
    }
    if (f.plus && !Array.isArray(f.plus)) erreur(`Fiche « ${g.id} » : « plus » doit être une liste.`);
  }
  Object.keys(FICHES).forEach(k => { if (!ids.has(k)) erreur(`Fiche « ${k} » sans entité correspondante.`); });
}

/* 7. Lieux. */
const LIEUX = litteral("const LIEUX=");
if (!LIEUX) erreur("Liste LIEUX introuvable dans index.html.");
else if (new Set(LIEUX).size !== LIEUX.length) erreur("Un lieu apparaît deux fois dans LIEUX.");

/* 8. Le calcul : état vide, et chaque entité reste possible avec n'importe quel jeu de preuves qu'elle peut montrer. */
try {
  const vide = calculer(etatVide());
  if (vide.liste.length !== GHOSTS.length) erreur("Le calcul ne renvoie pas toutes les entités.");
  if (!vide.liste.every(x => x.p > 0)) erreur("Sans aucun relevé, toutes les entités devraient être possibles.");
  if (Math.abs(vide.liste.reduce((a, x) => a + x.p, 0) - 1) > 1e-6) erreur("Les probabilités ne totalisent pas 100 %.");
  for (const g of GHOSTS) for (const n of [3, 2, 1]) for (const jeu of ensembles(g, n)) {
    const s = etatVide(); s.d = NIVEAUX.find(v => v.n === n)?.id || "normale"; s.n = n;
    jeu.forEach(e => { s.ev[e] = 1; });
    if (n === 3) EV.forEach(e => { if (!g.ev.includes(e.id) && !(g.id === "mimic" && e.id === "orb")) s.ev[e.id] = -1; });
    const x = calculer(s).liste.find(y => y.g.id === g.id);
    if (!(x && x.p > 0)) { erreur(`« ${g.id} » devient impossible avec ses propres preuves (${jeu.join(", ")}, ${n} preuve(s) fournie(s)).`); break; }
  }
} catch (e) { erreur("Le calcul plante : " + e.message); }

/* 9. Aucun nombre d'entités écrit en dur. */
const enDur = html.match(/(sur \d{2,}["'`]|Les \d+ entités|<h2>\d+ entités possibles|planchette\("[1-9]\d*"\))/g);
if (enDur) erreur(`Nombre d'entités écrit en dur : ${[...new Set(enDur)].join(" ; ")} (utiliser GHOSTS.length).`);

/* 9 bis. Version des données affichée en pied de page : la veille automatique la tient à jour. */
const version = html.match(/<span id="version-jeu">([^<]*)<\/span>/), mois = html.match(/<span id="date-donnees">([^<]*)<\/span>/);
if (!version || !/^\d+(\.\d+){1,3}$/.test(version[1].trim())) erreur('Pied de page : <span id="version-jeu"> absent ou version illisible (attendu par ex. 0.19.1).');
if (!mois || !mois[1].trim()) erreur('Pied de page : <span id="date-donnees"> absent ou vide.');

/* 10. Annonces (annonces.js), si le fichier existe. */
try {
  const code = readFileSync(new URL("annonces.js", dossier), "utf8");
  const w = { window: {} }; vm.runInNewContext(code, w);
  const A = w.window.GRIMOIRE_ANNONCES;
  if (!Array.isArray(A)) erreur("annonces.js : GRIMOIRE_ANNONCES doit être une liste.");
  else {
    const vus = new Set(), date = /^\d{4}-\d{2}-\d{2}$/;
    for (const a of A) {
      const qui = `Annonce « ${a.id} »`;
      if (!a.id || vus.has(a.id)) erreur(`${qui} : identifiant manquant ou en double.`);
      vus.add(a.id);
      if (!date.test(a.debut || "") || !date.test(a.fin || "") || a.debut > a.fin) erreur(`${qui} : dates début/fin invalides.`);
      if (!a.titre || !Array.isArray(a.texte) || !a.texte.length) erreur(`${qui} : titre ou texte manquant.`);
      if (a.lien && !/^https:\/\//.test(a.lien)) erreur(`${qui} : lien non https.`);
    }
  }
} catch (e) { if (e.code !== "ENOENT") erreur("annonces.js illisible : " + e.message); }

/* 11. Avec --page : ouvre l'appli dans Chromium (Playwright), parcourt chaque onglet et relève toute erreur JavaScript. */
if (process.argv.includes("--page")) {
  const { createRequire } = await import("node:module");
  const { createServer } = await import("node:http");
  const { extname } = await import("node:path");
  let pw;
  try { pw = createRequire(import.meta.url)("playwright"); }
  catch { erreur("--page demandé mais Playwright est introuvable (npm i playwright)."); }
  if (pw) {
    const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png" };
    const serveur = createServer((req, res) => {
      const chemin = decodeURIComponent(new URL(req.url, "http://x").pathname).replace(/^\/+/, "") || "index.html";
      try { const corps = readFileSync(new URL(chemin, dossier)); res.writeHead(200, { "content-type": types[extname(chemin)] || "application/octet-stream" }); res.end(corps); }
      catch { res.writeHead(404); res.end(); }
    });
    await new Promise(r => serveur.listen(0, "127.0.0.1", r));
    const adresse = `http://127.0.0.1:${serveur.address().port}/`;
    const nav = await pw.chromium.launch(process.env.PLAYWRIGHT_BROWSERS_PATH ? {} : { executablePath: "/opt/pw-browsers/chromium" }).catch(() => pw.chromium.launch());
    try {
      const page = await nav.newPage({ viewport: { width: 420, height: 900 } });
      const plantages = [];
      page.on("pageerror", e => plantages.push(e.message));
      await page.route("**/*", r => r.request().url().startsWith(adresse) ? r.continue() : r.abort());   // pas de réseau extérieur
      await page.goto(adresse, { waitUntil: "load" });
      await page.waitForTimeout(800);
      const texte = await page.textContent("body");
      if (!texte.includes(`${GHOSTS.length} entités possibles`)) erreur(`Page : « ${GHOSTS.length} entités possibles » n'apparaît pas à l'ouverture.`);
      for (const id of await page.$$eval("#onglets [data-tab]", b => b.filter(x => !x.hidden).map(x => x.dataset.tab))) {   // onglets visibles seulement
        await page.click(`#onglets [data-tab="${id}"]`);
        await page.waitForTimeout(1200);
      }
      plantages.forEach(m => erreur("Page : erreur JavaScript : " + m));
    } finally { await nav.close(); serveur.close(); }
  }
}

/* Bilan. */
console.log(`${GHOSTS.length} entités, ${EV.length} preuves, ${NIVEAUX.length} difficultés, ${LIEUX ? LIEUX.length : "?"} lieux, données v${version ? version[1] : "?"}.`);
avertissements.forEach(m => console.log("À SURVEILLER  " + m));
erreurs.forEach(m => console.log("ERREUR        " + m));
console.log(erreurs.length ? `${erreurs.length} erreur(s) : ne pas publier.` : "Données valides.");
process.exit(erreurs.length ? 1 : 0);
