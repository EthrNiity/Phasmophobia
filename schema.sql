-- Grimoire des Entités — schéma Supabase
-- À coller tel quel dans Supabase > SQL Editor > New query, puis « Run ».
-- Le script peut être relancé sans danger : il ne supprime aucune donnée.

-- ───────────────────────────── Tables ─────────────────────────────

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  pseudo     text not null check (char_length(pseudo) between 2 and 24),
  code       text not null unique,                       -- code ami, 6 caractères
  created_at timestamptz not null default now()
);
-- Sceau « Créateur » affiché à côté du pseudo. Il se règle uniquement à la main dans Supabase (SQL Editor) :
-- aucun joueur ne peut se l'attribuer depuis l'appli, seul le pseudo est modifiable.
alter table public.profiles add column if not exists createur boolean not null default false;

create table if not exists public.investigations (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  lieu       text,
  difficulte smallint not null default 3 check (difficulte between 0 and 3),  -- nombre de preuves fournies
  annoncee   text not null,                              -- entité annoncée dans le journal
  reelle     text not null,                              -- entité révélée en fin de contrat
  correct    boolean generated always as (annoncee = reelle) stored,
  survecu    boolean not null default true,
  preuves    text[] not null default '{}',
  niveau     text check (niveau is null or char_length(niveau) between 1 and 20),  -- difficulté choisie : normale, pro, cauchemar, demence, zero
  joueurs    smallint check (joueurs is null or joueurs between 1 and 4),        -- nombre de joueurs, si précisé
  objectifs  smallint check (objectifs is null or objectifs between 0 and 3),    -- objectifs facultatifs remplis, si précisé
  os         boolean not null default false,                                     -- os trouvé
  parfaite   boolean not null default false                                      -- enquête parfaite
);
create index if not exists investigations_user_date on public.investigations (user_id, created_at desc);

-- Bases créées avant ces colonnes : elles sont ajoutées sans toucher aux enquêtes existantes.
alter table public.investigations
  add column if not exists niveau    text check (niveau is null or char_length(niveau) between 1 and 20),
  add column if not exists joueurs   smallint check (joueurs is null or joueurs between 1 and 4),
  add column if not exists objectifs smallint check (objectifs is null or objectifs between 0 and 3),
  add column if not exists os        boolean not null default false,
  add column if not exists parfaite  boolean not null default false;

create table if not exists public.friendships (
  id         uuid primary key default gen_random_uuid(),
  demandeur  uuid not null references public.profiles(id) on delete cascade,
  receveur   uuid not null references public.profiles(id) on delete cascade,
  statut     text not null default 'attente' check (statut in ('attente','accepte')),
  created_at timestamptz not null default now(),
  check (demandeur <> receveur)
);
-- Une seule ligne par paire de joueurs, quel que soit le sens de la demande (pas de doublon d'ami).
create unique index if not exists friendships_paire
  on public.friendships (least(demandeur, receveur), greatest(demandeur, receveur));

-- ───────────────────────── Profil automatique ─────────────────────────

-- Code ami : 6 caractères sans lettres ambiguës (pas de 0/O, 1/I/L).
create or replace function public.code_ami() returns text
language plpgsql set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  c text;
begin
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where code = c);
  end loop;
  return c;
end $$;

-- À chaque inscription, crée le profil avec le pseudo choisi et un code ami unique.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p text;
begin
  p := left(coalesce(nullif(trim(new.raw_user_meta_data->>'pseudo'), ''), split_part(new.email, '@', 1)), 24);
  if p is null or char_length(p) < 2 then p := 'Chasseur'; end if;
  for essai in 1..5 loop
    begin
      insert into public.profiles (id, pseudo, code) values (new.id, p, public.code_ami());
      return new;
    exception when unique_violation then
      if exists (select 1 from public.profiles where id = new.id) then return new; end if;
      -- sinon : collision de code, on retente avec un nouveau code
    end;
  end loop;
  raise exception 'Impossible de créer le profil';
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ───────────────────────── Fonctions d'aide ─────────────────────────

-- Amis confirmés.
create or replace function public.sont_amis(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships f
    where f.statut = 'accepte'
      and auth.uid() in (a, b)                           -- on ne peut interroger que ses propres liens
      and ((f.demandeur = a and f.receveur = b) or (f.demandeur = b and f.receveur = a))
  );
$$;

-- Liés par une demande, acceptée ou en attente (pour afficher le pseudo de l'autre).
create or replace function public.sont_lies(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships f
    where auth.uid() in (a, b)
      and ((f.demandeur = a and f.receveur = b) or (f.demandeur = b and f.receveur = a))
  );
$$;

-- Série en cours : nombre d'enquêtes réussies d'affilée en partant de la plus récente.
create or replace function public.serie_en_cours(uid uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from (
    select sum(case when correct then 0 else 1 end) over (order by created_at desc, id desc) as rates
    from public.investigations where user_id = uid
  ) t where rates = 0;
$$;

-- ───────────────────────── Règles d'accès (RLS) ─────────────────────────

alter table public.profiles       enable row level security;
alter table public.investigations enable row level security;
alter table public.friendships    enable row level security;

-- Profils : je vois le mien et ceux des joueurs liés à moi. Je ne modifie que mon pseudo.
drop policy if exists profiles_lecture on public.profiles;
create policy profiles_lecture on public.profiles for select to authenticated
  using (id = auth.uid() or public.sont_lies(auth.uid(), id));

drop policy if exists profiles_maj on public.profiles;
create policy profiles_maj on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (pseudo) on public.profiles to authenticated;

-- Enquêtes : j'écris les miennes ; mes amis confirmés peuvent les lire.
drop policy if exists enquetes_lecture on public.investigations;
create policy enquetes_lecture on public.investigations for select to authenticated
  using (user_id = auth.uid() or public.sont_amis(auth.uid(), user_id));

drop policy if exists enquetes_ajout on public.investigations;
create policy enquetes_ajout on public.investigations for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists enquetes_maj on public.investigations;
create policy enquetes_maj on public.investigations for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists enquetes_suppression on public.investigations;
create policy enquetes_suppression on public.investigations for delete to authenticated
  using (user_id = auth.uid());

-- Amitiés : je vois et je supprime celles qui me concernent. Création et acceptation passent par les fonctions ci-dessous.
drop policy if exists amities_lecture on public.friendships;
create policy amities_lecture on public.friendships for select to authenticated
  using (auth.uid() in (demandeur, receveur));

drop policy if exists amities_suppression on public.friendships;
create policy amities_suppression on public.friendships for delete to authenticated
  using (auth.uid() in (demandeur, receveur));

revoke insert, update on public.friendships from anon, authenticated;

-- ───────────────────── Fonctions appelées par l'appli ─────────────────────

-- Demande d'ami par code. Renvoie : envoyee, accepte, deja-amis, deja-demande, introuvable, soi-meme.
create or replace function public.demander_ami(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  moi   uuid := auth.uid();
  cible uuid;
  f     public.friendships;
begin
  if moi is null then raise exception 'Connexion requise'; end if;
  select id into cible from public.profiles where code = upper(trim(p_code));
  if cible is null then return 'introuvable'; end if;
  if cible = moi then return 'soi-meme'; end if;

  select * into f from public.friendships
   where (demandeur = moi and receveur = cible) or (demandeur = cible and receveur = moi);
  if found then
    if f.statut = 'accepte' then return 'deja-amis'; end if;
    if f.demandeur = cible then                       -- l'autre m'avait déjà invité : on accepte
      update public.friendships set statut = 'accepte' where id = f.id;
      return 'accepte';
    end if;
    return 'deja-demande';
  end if;

  insert into public.friendships (demandeur, receveur) values (moi, cible);
  return 'envoyee';
end $$;

-- Réponse à une demande reçue. Seul le destinataire peut répondre.
create or replace function public.repondre_ami(p_id uuid, p_accepter boolean) returns text
language plpgsql security definer set search_path = public as $$
declare
  moi uuid := auth.uid();
begin
  if moi is null then raise exception 'Connexion requise'; end if;
  if p_accepter then
    update public.friendships set statut = 'accepte'
     where id = p_id and receveur = moi and statut = 'attente';
    if not found then return 'introuvable'; end if;
    return 'accepte';
  end if;
  delete from public.friendships where id = p_id and receveur = moi and statut = 'attente';
  if not found then return 'introuvable'; end if;
  return 'refusee';
end $$;

-- Classement : moi et mes amis confirmés, avec les compteurs.
-- La liste des colonnes renvoyées a changé (enquêtes parfaites, sceau Créateur) : l'ancienne version est retirée avant d'être recréée.
drop function if exists public.classement();
create or replace function public.classement()
returns table (user_id uuid, pseudo text, enquetes bigint, trouvees bigint, survies bigint, serie int, derniere timestamptz, parfaites bigint, createur boolean)
language sql stable security definer set search_path = public as $$
  with cercle as (
    select auth.uid() as id
    union
    select case when f.demandeur = auth.uid() then f.receveur else f.demandeur end
      from public.friendships f
     where f.statut = 'accepte' and auth.uid() in (f.demandeur, f.receveur)
  )
  select p.id, p.pseudo,
         count(i.id),
         count(i.id) filter (where i.correct),
         count(i.id) filter (where i.survecu),
         public.serie_en_cours(p.id),
         max(i.created_at),
         count(i.id) filter (where i.parfaite),
         p.createur
    from cercle c
    join public.profiles p on p.id = c.id
    left join public.investigations i on i.user_id = p.id
   group by p.id, p.pseudo, p.createur;
$$;

-- ───────────────────────── Espace créateur ─────────────────────────
-- Tout ce qui suit est réservé au compte qui porte le sceau « Créateur » (profiles.createur),
-- et vérifié ici, dans la base : l'appli ne fait qu'afficher.

-- Vrai si le joueur connecté est le créateur.
create or replace function public.est_createur() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select createur from public.profiles where id = auth.uid()), false);
$$;

-- Annonces écrites depuis l'appli, en plus du fichier annonces.js. Tout le monde les lit, même sans compte ;
-- seul le créateur les écrit, les modifie ou les retire.
create table if not exists public.annonces (
  id         text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  genre      text not null default 'Annonce' check (char_length(genre) between 1 and 30),
  titre      text not null check (char_length(titre) between 1 and 80),
  debut      date,
  fin        date,
  texte      text[] not null default '{}' check (cardinality(texte) <= 6),
  lien       text check (lien is null or lien ~ '^https://'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (debut is null or fin is null or debut <= fin)
);
alter table public.annonces enable row level security;
drop policy if exists annonces_lecture on public.annonces;
create policy annonces_lecture on public.annonces for select to anon, authenticated using (true);
drop policy if exists annonces_ecriture on public.annonces;
create policy annonces_ecriture on public.annonces for all to authenticated
  using (public.est_createur()) with check (public.est_createur());
revoke all on public.annonces from anon, authenticated;
grant select on public.annonces to anon, authenticated;
grant insert, update, delete on public.annonces to authenticated;

-- Tableau de bord : chiffres de toute l'appli (jamais les adresses mail).
create or replace function public.tableau_createur() returns json
language plpgsql stable security definer set search_path = public as $$
declare
  auj date := (now() at time zone 'Europe/Paris')::date;
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  return json_build_object(
    'joueurs',     (select count(*) from public.profiles),
    'nouveaux_7j', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'actifs_7j',   (select count(distinct user_id) from public.investigations where created_at > now() - interval '7 days'),
    'enquetes',    (select count(*) from public.investigations),
    'enquetes_7j', (select count(*) from public.investigations where created_at > now() - interval '7 days'),
    'trouvees',    (select count(*) from public.investigations where correct),
    'survies',     (select count(*) from public.investigations where survecu),
    'parfaites',   (select count(*) from public.investigations where parfaite),
    'entites', (select coalesce(json_agg(e order by e.n desc, e.reelle), '[]'::json) from (
                  select reelle, count(*) as n, count(*) filter (where correct) as ok
                    from public.investigations group by reelle) e),
    'lieux',   (select coalesce(json_agg(l order by l.n desc, l.lieu), '[]'::json) from (
                  select lieu, count(*) as n from public.investigations
                   where lieu is not null group by lieu order by count(*) desc limit 8) l),
    'niveaux', (select coalesce(json_agg(v order by v.n desc), '[]'::json) from (
                  select coalesce(niveau, 'preuves-' || difficulte) as niveau, count(*) as n,
                         count(*) filter (where correct) as ok
                    from public.investigations group by 1) v),
    'par_jour', (select json_agg(d order by d.jour) from (
                  select g::date as jour,
                         (select count(*) from public.investigations
                           where (created_at at time zone 'Europe/Paris')::date = g::date) as n
                    from generate_series(auj - 13, auj, interval '1 day') g) d),
    'liste', (select coalesce(json_agg(j order by j.derniere desc nulls last, j.pseudo), '[]'::json) from (
                  select p.id, p.pseudo, p.code, p.createur, p.created_at,
                         count(i.id) as enquetes, count(i.id) filter (where i.correct) as trouvees,
                         max(i.created_at) as derniere
                    from public.profiles p left join public.investigations i on i.user_id = p.id
                   group by p.id) j)
  );
end $$;

-- Modération : enquêtes d'un joueur, pseudo, enquête ou compte.
create or replace function public.enquetes_joueur(p_id uuid) returns setof public.investigations
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  return query select * from public.investigations where user_id = p_id order by created_at desc limit 200;
end $$;

create or replace function public.moderer_pseudo(p_id uuid, p_pseudo text) returns text
language plpgsql security definer set search_path = public as $$
declare
  p text := trim(coalesce(p_pseudo, ''));
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  if char_length(p) not between 2 and 24 then return 'invalide'; end if;
  update public.profiles set pseudo = p where id = p_id;
  if not found then return 'introuvable'; end if;
  return 'ok';
end $$;

create or replace function public.moderer_enquete(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  delete from public.investigations where id = p_id;
  if not found then return 'introuvable'; end if;
  return 'supprimee';
end $$;

-- Supprime un compte et tout ce qui en dépend (profil, enquêtes, amitiés). Jamais le sien, ni celui d'un créateur.
create or replace function public.moderer_compte(p_id uuid) returns text
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  if p_id = auth.uid() then return 'soi-meme'; end if;
  if coalesce((select createur from public.profiles where id = p_id), false) then return 'createur'; end if;
  delete from auth.users where id = p_id;
  if not found then return 'introuvable'; end if;
  return 'supprime';
end $$;

-- ─────────────── Espace créateur : signalements, fiabilité, défis, sauvegarde ───────────────

-- Entité que le Grimoire classait première au moment de la clôture : sert à mesurer sa fiabilité.
alter table public.investigations
  add column if not exists prediction text check (prediction is null or char_length(prediction) between 1 and 40);

-- Signalements des joueurs (« cette fiche est fausse »). Un joueur écrit les siens ; seul le créateur les lit tous,
-- les marque traités ou les supprime. Vingt par joueur et par jour au plus.
create table if not exists public.signalements (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  entite     text check (entite is null or char_length(entite) between 1 and 40),
  message    text not null check (char_length(message) between 3 and 1000),
  version    text check (version is null or char_length(version) <= 20),
  traite     boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists signalements_date on public.signalements (created_at desc);
alter table public.signalements enable row level security;
drop policy if exists signalements_ajout on public.signalements;
create policy signalements_ajout on public.signalements for insert to authenticated
  with check (user_id = auth.uid()
    and (select count(*) from public.signalements s
          where s.user_id = auth.uid() and s.created_at > now() - interval '1 day') < 20);
drop policy if exists signalements_lecture on public.signalements;
create policy signalements_lecture on public.signalements for select to authenticated
  using (user_id = auth.uid() or public.est_createur());
drop policy if exists signalements_traitement on public.signalements;
create policy signalements_traitement on public.signalements for update to authenticated
  using (public.est_createur()) with check (public.est_createur());
drop policy if exists signalements_suppression on public.signalements;
create policy signalements_suppression on public.signalements for delete to authenticated
  using (public.est_createur());
revoke all on public.signalements from anon, authenticated;
grant select, delete on public.signalements to authenticated;
grant insert (entite, message, version) on public.signalements to authenticated;   -- auteur, date et statut : jamais fournis par l'appli
grant update (traite) on public.signalements to authenticated;

-- Boîte de réception du créateur, avec le pseudo de l'auteur (qui n'est pas forcément son ami).
create or replace function public.signalements_createur()
returns table (id uuid, pseudo text, entite text, message text, version text, traite boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  return query
    select s.id, p.pseudo, s.entite, s.message, s.version, s.traite, s.created_at
      from public.signalements s join public.profiles p on p.id = s.user_id
     order by s.traite, s.created_at desc
     limit 300;
end $$;

-- Fiabilité du Grimoire : sa première proposition était-elle la bonne entité ?
create or replace function public.fiabilite_createur() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  return json_build_object(
    'mesurees',       (select count(*) from public.investigations where prediction is not null),
    'justes',         (select count(*) from public.investigations where prediction is not null and prediction = reelle),
    'joueurs_justes', (select count(*) from public.investigations where prediction is not null and correct),
    'niveaux', (select coalesce(json_agg(v order by v.n desc), '[]'::json) from (
                  select coalesce(niveau, 'preuves-' || difficulte) as niveau, count(*) as n,
                         count(*) filter (where prediction = reelle) as ok
                    from public.investigations where prediction is not null group by 1) v),
    'erreurs', (select coalesce(json_agg(x order by x.n desc, x.reelle), '[]'::json) from (
                  select reelle, prediction, count(*) as n
                    from public.investigations
                   where prediction is not null and prediction <> reelle
                   group by reelle, prediction order by count(*) desc limit 10) x)
  );
end $$;

-- Défis : créés par le créateur, visibles par tous ; chacun voit sa progression et celle de ses amis.
create table if not exists public.defis (
  id          uuid primary key default gen_random_uuid(),
  titre       text not null check (char_length(titre) between 1 and 80),
  description text check (description is null or char_length(description) <= 300),
  critere     text not null default 'enquetes' check (critere in ('enquetes','trouvees','survies','parfaites')),
  objectif    int  not null default 10 check (objectif between 1 and 1000),
  niveau      text check (niveau is null or char_length(niveau) between 1 and 20),
  debut       date not null,
  fin         date not null,
  created_at  timestamptz not null default now(),
  check (debut <= fin)
);
alter table public.defis enable row level security;
drop policy if exists defis_lecture on public.defis;
create policy defis_lecture on public.defis for select to anon, authenticated using (true);
drop policy if exists defis_ecriture on public.defis;
create policy defis_ecriture on public.defis for all to authenticated
  using (public.est_createur()) with check (public.est_createur());
revoke all on public.defis from anon, authenticated;
grant select on public.defis to anon, authenticated;
grant insert, update, delete on public.defis to authenticated;

-- Défis en cours (et terminés depuis moins de 7 jours), avec la progression de moi et de mes amis confirmés.
create or replace function public.defis_en_cours() returns json
language sql stable security definer set search_path = public as $$
  with auj as (select (now() at time zone 'Europe/Paris')::date as j),
  cercle as (
    select auth.uid() as id
    union
    select case when f.demandeur = auth.uid() then f.receveur else f.demandeur end
      from public.friendships f
     where f.statut = 'accepte' and auth.uid() in (f.demandeur, f.receveur)
  )
  select coalesce(json_agg(json_build_object(
           'id', d.id, 'titre', d.titre, 'description', d.description, 'critere', d.critere,
           'objectif', d.objectif, 'niveau', d.niveau, 'debut', d.debut, 'fin', d.fin,
           'joueurs', (select coalesce(json_agg(r order by r.valeur desc, r.pseudo), '[]'::json) from (
               select p.id, p.pseudo, p.createur,
                      count(i.id) filter (where case d.critere when 'trouvees' then i.correct
                                                               when 'survies'  then i.survecu
                                                               when 'parfaites' then i.parfaite
                                                               else true end) as valeur
                 from cercle c
                 join public.profiles p on p.id = c.id
                 left join public.investigations i
                        on i.user_id = p.id
                       and (i.created_at at time zone 'Europe/Paris')::date between d.debut and d.fin
                       and (d.niveau is null or i.niveau = d.niveau)
                group by p.id, p.pseudo, p.createur) r)
         ) order by d.fin, d.debut), '[]'::json)
    from public.defis d, auj
   where auth.uid() is not null and d.debut <= auj.j and d.fin >= auj.j - 7;
$$;

-- Sauvegarde complète en un clic (sans les adresses mail, qui restent dans Supabase).
create or replace function public.sauvegarde_complete() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.est_createur() then raise exception 'Réservé au créateur' using errcode = '42501'; end if;
  return json_build_object(
    'application',    'Grimoire des Entités',
    'exporte_le',     now(),
    'profiles',       (select coalesce(json_agg(x order by x.created_at), '[]'::json) from public.profiles x),
    'investigations', (select coalesce(json_agg(x order by x.created_at), '[]'::json) from public.investigations x),
    'friendships',    (select coalesce(json_agg(x order by x.created_at), '[]'::json) from public.friendships x),
    'annonces',       (select coalesce(json_agg(x order by x.created_at), '[]'::json) from public.annonces x),
    'signalements',   (select coalesce(json_agg(x order by x.created_at), '[]'::json) from public.signalements x),
    'defis',          (select coalesce(json_agg(x order by x.created_at), '[]'::json) from public.defis x)
  );
end $$;

-- Droits d'exécution : uniquement les joueurs connectés, et jamais les fonctions internes.
revoke all on function public.code_ami()                 from public, anon, authenticated;
revoke all on function public.handle_new_user()          from public, anon, authenticated;
revoke all on function public.serie_en_cours(uuid)       from public, anon, authenticated;
revoke all on function public.sont_amis(uuid, uuid)      from public, anon;
revoke all on function public.sont_lies(uuid, uuid)      from public, anon;
revoke all on function public.demander_ami(text)         from public, anon;
revoke all on function public.repondre_ami(uuid, boolean) from public, anon;
revoke all on function public.classement()               from public, anon;
grant execute on function public.sont_amis(uuid, uuid)       to authenticated;
grant execute on function public.sont_lies(uuid, uuid)       to authenticated;
grant execute on function public.demander_ami(text)          to authenticated;
grant execute on function public.repondre_ami(uuid, boolean) to authenticated;
grant execute on function public.classement()                to authenticated;
revoke all on function public.est_createur()              from public, anon;
revoke all on function public.tableau_createur()          from public, anon;
revoke all on function public.enquetes_joueur(uuid)       from public, anon;
revoke all on function public.moderer_pseudo(uuid, text)  from public, anon;
revoke all on function public.moderer_enquete(uuid)       from public, anon;
revoke all on function public.moderer_compte(uuid)        from public, anon;
grant execute on function public.est_createur()             to authenticated;
grant execute on function public.tableau_createur()         to authenticated;
grant execute on function public.enquetes_joueur(uuid)      to authenticated;
grant execute on function public.moderer_pseudo(uuid, text) to authenticated;
grant execute on function public.moderer_enquete(uuid)      to authenticated;
grant execute on function public.moderer_compte(uuid)       to authenticated;
revoke all on function public.signalements_createur()     from public, anon;
revoke all on function public.fiabilite_createur()        from public, anon;
revoke all on function public.defis_en_cours()            from public, anon;
revoke all on function public.sauvegarde_complete()       from public, anon;
grant execute on function public.signalements_createur()    to authenticated;
grant execute on function public.fiabilite_createur()       to authenticated;
grant execute on function public.defis_en_cours()           to authenticated;
grant execute on function public.sauvegarde_complete()      to authenticated;

-- Fait relire le schéma à l'API tout de suite, pour que l'appli voie les nouvelles colonnes.
notify pgrst, 'reload schema';
