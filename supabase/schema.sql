-- Gravity Music — Supabase schema for optional cloud sync of liked songs + playlists.
--
-- Design notes:
--   • The app stays offline-first: Hive ('LibraryBox') remains the source of
--     truth on-device. These tables are a per-user MIRROR for backup + sync.
--   • Liked songs are stored in full (small, and the primary signal).
--   • Playlists store the resolved track snapshot (faithful restore, no
--     re-import) PLUS the original Spotify/Apple URL as metadata, so the app
--     can offer an opt-in "Refresh from source" without auto-re-importing.
--   • Row Level Security ties every row to auth.uid(), so the shipped anon key
--     is safe — a user can only ever read/write their own rows.
--
-- Run in the Supabase SQL editor (Dashboard → SQL Editor → New query). The whole
-- file is idempotent — re-running it is safe and is how you apply later additions.

-- ── Liked songs ─────────────────────────────────────────────────────────────
create table if not exists public.liked_songs (
  user_id    uuid not null references auth.users on delete cascade,
  video_id   text not null,
  title      text,
  artist     text,
  thumbnail  text,
  duration   text,
  liked_at   timestamptz not null default now(),
  primary key (user_id, video_id)
);

-- ── Playlists (tracks stored inline as jsonb to mirror LocalPlaylist) ────────
create table if not exists public.playlists (
  user_id      uuid not null references auth.users on delete cascade,
  id           text not null,                 -- reuse LocalPlaylist.id
  name         text not null,
  created_at   timestamptz,
  tracks       jsonb not null default '[]'::jsonb,  -- List<LibraryTrack.toMap()>
  source_url   text,                          -- original Spotify/Apple link (nullable)
  source_type  text,                          -- 'spotify' | 'apple' | null
  updated_at   timestamptz not null default now(),  -- last-write-wins key
  primary key (user_id, id)
);

-- ── Row Level Security ──────────────────────────────────────────────────────
alter table public.liked_songs enable row level security;
alter table public.playlists  enable row level security;

-- Dropped first so this file stays re-runnable: CREATE POLICY has no
-- "if not exists" form, and re-running without these raises 42710.
drop policy if exists "own_liked_songs" on public.liked_songs;
create policy "own_liked_songs"
  on public.liked_songs for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "own_playlists" on public.playlists;
create policy "own_playlists"
  on public.playlists for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ── Feedback (anonymous, no account required) ───────────────────────────────
--
-- Unlike liked_songs/playlists above, this table is NOT tied to auth.uid():
-- feedback must work for users who never sign in. That means the shipped anon
-- key can write here, so the table is deliberately locked down:
--
--   • INSERT only — anon cannot select/update/delete, so nobody can read (or
--     scrape) anyone else's feedback with the public key.
--   • Rate-limited per installation_id by a trigger, so the key can't be
--     extracted from the APK and used to flood the table.
--   • installation_id is the same anonymous UUID HeartbeatService uses. It is
--     NOT a user id — it identifies an install, so repeat feedback from one
--     person can be grouped and rate-limited, nothing more.
--
-- `name` is NULL when the user left it blank. Store NULL rather than the
-- literal 'Anonymous' so "chose not to say" stays distinguishable from someone
-- actually named Anonymous, and the display wording can change later.
-- Read it back with: coalesce(name, 'Anonymous').

create table if not exists public.feedback (
  id              uuid primary key default gen_random_uuid(),
  installation_id text not null,
  name            text,                                  -- NULL = anonymous
  message         text not null check (length(trim(message)) between 1 and 4000),
  app_version     text,
  platform        text,
  created_at      timestamptz not null default now()
);

create index if not exists feedback_created_at_idx
  on public.feedback (created_at desc);

alter table public.feedback enable row level security;

-- Anyone (signed in or not) may submit; nobody may read back through the API.
-- Read feedback in the Supabase dashboard / SQL editor, which bypasses RLS.
drop policy if exists "anon_can_submit_feedback" on public.feedback;
create policy "anon_can_submit_feedback"
  on public.feedback for insert
  to anon, authenticated
  with check (true);

-- REVOKE ALL, not just select/update/delete: Supabase grants ALL on public
-- tables to anon/authenticated by default, and that includes TRUNCATE — which
-- RLS does NOT restrict. Without this, anyone with the shipped anon key could
-- wipe the table. Grant back only INSERT.
revoke all on public.feedback from anon, authenticated;
grant insert on public.feedback to anon, authenticated;

-- Rate limit: max 5 submissions per install per hour. SECURITY DEFINER so the
-- count can run even though anon has no SELECT on the table.
create or replace function public.feedback_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recent integer;
begin
  select count(*) into recent
    from public.feedback
   where installation_id = new.installation_id
     and created_at > now() - interval '1 hour';

  if recent >= 5 then
    raise exception 'Feedback rate limit reached. Please try again later.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists feedback_rate_limit_trg on public.feedback;
create trigger feedback_rate_limit_trg
  before insert on public.feedback
  for each row execute function public.feedback_rate_limit();
