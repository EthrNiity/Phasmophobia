// Annonces du Grimoire des Entités : événements du jeu et nouveautés à signaler dans l’appli.
// Chaque annonce s’affiche en haut de l’onglet Enquête de sa date « debut » à sa date « fin » incluses
// (format AAAA-MM-JJ), puis disparaît toute seule. Sans ce fichier, l’appli fonctionne sans annonce.
// Champs : id (unique), genre (petit titre), titre, debut, fin, texte (liste de paragraphes), lien (annonce officielle).
window.GRIMOIRE_ANNONCES = [
  {
    id: "crimson-eye-2026",
    genre: "Événement",
    titre: "Crimson Eye",
    debut: "2026-10-08",
    fin: "2026-11-01",
    texte: [
      "L’événement se joue sur 8 lieux : 6 Tanglewood Drive, 42 Edgefield Road, Grafton Farmhouse, 13 Willow Street, Bleasdale Farmhouse, Point Hope (pas la version Restricted), Camp Woodwind et Nell’s Diner.",
      "Sous une Lune de sang, les entités sont environ 15 % plus rapides en chasse et la santé mentale baisse plus vite. Active « Lune de sang » dans « Pendant les chasses » : les vitesses du Grimoire s’ajustent.",
      "Points d’événement : trouve les totems de la Lune de sang, termine les enquêtes et les objectifs facultatifs. XP et récompenses doublés du 15 au 22 octobre."
    ],
    lien: "https://www.kineticgames.co.uk/news/the-crimson-eye-approaches-once-more"
  }
];
