# Grimoire des Entités

Carnet d'enquête non officiel pour Phasmophobia : preuves, entités possibles classées par probabilité, minuteurs, aide-mémoire, carnet d'enquêtes, comptes par mail, amis et classement.

Appli en un seul fichier (HTML, CSS et JavaScript sans framework), hébergée sur GitHub Pages, avec Supabase pour les comptes et les données.

## Fichiers

| Fichier | Rôle |
|---|---|
| `index.html` | Toute l'appli, dont les données du jeu (preuves, entités, fiches, lieux) |
| `annonces.js` | Événements du jeu affichés en haut de l'onglet Enquête, avec dates de début et de fin |
| `config.js` | Adresse et clé publique du projet Supabase (à remplir) |
| `supabase.js` | Bibliothèque supabase-js 2.117.2, embarquée pour ne dépendre d'aucun CDN |
| `schema.sql` | Tables, règles d'accès et fonctions à exécuter une fois dans Supabase |
| `verifier.mjs` | Contrôle des données avant publication (`node verifier.mjs`, ou `--page` pour ouvrir l'appli dans Chromium) |

Tant que `config.js` est vide, l'appli tourne en **mode local** : tout fonctionne sauf les comptes, les amis et le classement, et le carnet reste sur l'appareil.

## Mise en ligne

### 1. Supabase

1. Crée un nouveau projet sur supabase.com.
2. Ouvre **SQL Editor > New query**, colle tout le contenu de `schema.sql`, puis **Run**. Le script peut être relancé sans danger.
3. Ouvre **Project Settings > API** et copie l'adresse du projet (`https://xxxx.supabase.co`) et la clé publique (`anon`, ou `publishable` sur les projets récents).
4. Colle ces deux valeurs dans `config.js`. Ne mets jamais la clé `service_role` dans ce fichier.

### 2. GitHub Pages

1. Crée un dépôt et pousse-y tous les fichiers du projet, à la racine.
2. Dans **Settings > Pages**, choisis **Deploy from a branch**, branche `main`, dossier `/ (root)`.
3. Note l'adresse obtenue, par exemple `https://ton-compte.github.io/grimoire/`.

### 3. Relier les deux

Dans Supabase, **Authentication > URL Configuration** :

- **Site URL** : l'adresse GitHub Pages ci-dessus.
- **Redirect URLs** : ajoute la même adresse. Les liens de confirmation et de mot de passe oublié y renvoient.

### 4. Mails de confirmation

Le service de mail intégré à Supabase est limité à quelques envois par heure : assez pour tester, pas pour un groupe d'amis qui s'inscrit le même soir. Deux options dans **Authentication** :

- brancher un SMTP personnalisé (Resend, par exemple) ;
- ou désactiver **Confirm email** dans le fournisseur Email, le temps des essais. Les comptes sont alors actifs dès l'inscription.

## Essayer en local

```
python3 -m http.server 8000
```

puis ouvre `http://localhost:8000`. Si tu testes les comptes en local, ajoute aussi `http://localhost:8000` aux Redirect URLs.

## Mise à jour des données du jeu

Une tâche planifiée surveille chaque matin les versions de Phasmophobia. Quand une mise à jour importante change les entités, les preuves, les cartes ou les règles, elle modifie les données dans `index.html` (et `annonces.js` pour un événement), lance `node verifier.mjs --page`, puis publie sur `main` si tout est valide.

- Les valeurs viennent uniquement des notes de version officielles.
- Une valeur absente des notes est écrite « À compléter à la main » (textes) ou `null` (seuil `tMin`/`tMax`, vitesse `sp`) : elle s'affiche « à compléter » et ne pèse pas dans le calcul.
- Le nombre d'entités n'est jamais écrit en dur : l'appli utilise `GHOSTS.length`.

## Données

- `profiles` : pseudo et code ami (6 caractères), créés automatiquement à l'inscription.
- `investigations` : une ligne par enquête clôturée (lieu, difficulté, entité annoncée, vraie entité, survie, preuves trouvées).
- `friendships` : une ligne par paire de joueurs, en attente ou acceptée.

Qui voit quoi :

- chacun lit et modifie uniquement ses propres enquêtes ;
- un ami **confirmé** peut lire tes enquêtes et te voit dans son classement ;
- une demande en attente ne montre que ton pseudo ;
- personne ne peut lire les adresses mail des autres, ni modifier un code ami.

Les enquêtes clôturées sans être connecté restent sur l'appareil et sont ajoutées au compte à la connexion suivante.

## Sauvegarde

Avant toute manipulation de la base (nouvelle migration, nettoyage de tables, changement de projet), exporte les données :

- dans l'appli, onglet **Carnet > Exporter en JSON**, pour ton propre carnet ;
- dans Supabase, **Table Editor > investigations > Export to CSV**, pour l'ensemble des joueurs.

## Limites connues

- Le jeu n'expose pas ses résultats : chaque enquête se clôture à la main, en trois appuis.
- Le classement se met à jour à l'ouverture de l'onglet et après chaque action, pas en temps réel.
- Pas encore d'installation en appli (manifeste et mode hors ligne) ni de notifications.

Outil de fan, sans lien avec Kinetic Games.
