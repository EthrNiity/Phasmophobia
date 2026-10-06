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
  preuves    text[] not null default '{}'
);
create index if not exists investigations_user_date on public.investigations (user_id, created_at desc);

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
create or replace function public.classement()
returns table (user_id uuid, pseudo text, enquetes bigint, trouvees bigint, survies bigint, serie int, derniere timestamptz)
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
         max(i.created_at)
    from cercle c
    join public.profiles p on p.id = c.id
    left join public.investigations i on i.user_id = p.id
   group by p.id, p.pseudo;
$$;

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
