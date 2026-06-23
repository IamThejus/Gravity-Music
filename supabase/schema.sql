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
-- Run this once in the Supabase SQL editor (Dashboard → SQL Editor → New query).

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

create policy "own_liked_songs"
  on public.liked_songs for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "own_playlists"
  on public.playlists for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
