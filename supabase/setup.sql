-- BOAT DRAFT: shared-room backend
-- Run this entire file once in Supabase SQL Editor.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.draft_rooms (
  id uuid primary key default gen_random_uuid(),
  room_code text not null unique,
  status text not null default 'active' check (status in ('active', 'finished')),
  current_round integer not null default 1,
  attempt_no integer not null default 1,
  last_resolved_round integer,
  last_resolved_attempt integer,
  created_at timestamptz not null default now()
);

-- Compatibility with an older draft_rooms schema that required room_name.
-- The current room flow identifies rooms by room_code and does not use room_name.
alter table public.draft_rooms add column if not exists room_name text;
alter table public.draft_rooms alter column room_name drop not null;
-- Legacy column not used by the current app; allow inserts that omit it.
alter table public.draft_rooms alter column max_members drop not null;

create table if not exists public.draft_room_members (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.draft_rooms(id) on delete cascade,
  seat_no integer not null,
  member_name text not null,
  access_token_hash text not null,
  created_at timestamptz not null default now(),
  unique (room_id, seat_no),
  unique (room_id, member_name),
  unique (room_id, access_token_hash)
);

create table if not exists public.draft_picks (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.draft_rooms(id) on delete cascade,
  round_no integer not null,
  attempt_no integer not null,
  member_id uuid not null references public.draft_room_members(id) on delete cascade,
  player_name text not null,
  submitted_at timestamptz not null default now(),
  unique (room_id, round_no, attempt_no, member_id)
);

create table if not exists public.draft_awards (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.draft_rooms(id) on delete cascade,
  round_no integer not null,
  member_id uuid not null references public.draft_room_members(id) on delete cascade,
  player_name text not null,
  awarded_at timestamptz not null default now(),
  unique (room_id, round_no, member_id),
  unique (room_id, player_name)
);

alter table public.draft_rooms enable row level security;
alter table public.draft_room_members enable row level security;
alter table public.draft_picks enable row level security;
alter table public.draft_awards enable row level security;

-- Browser clients must use the RPCs below; direct table access stays closed.
revoke all on public.draft_rooms from anon, authenticated;
revoke all on public.draft_room_members from anon, authenticated;
revoke all on public.draft_picks from anon, authenticated;
revoke all on public.draft_awards from anon, authenticated;

create or replace function public.create_draft_room(p_member_names text[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room_id uuid;
  v_room_code text;
  v_name text;
  v_token text;
  v_seat integer := 0;
  v_members jsonb := '[]'::jsonb;
begin
  if p_member_names is null or cardinality(p_member_names) not in (3, 6) then
    raise exception '参加者は3人または6人にしてください';
  end if;

  if exists (
    select 1 from unnest(p_member_names) as u(n)
    where n is null or btrim(n) = ''
  ) then
    raise exception '参加者名に空欄があります';
  end if;

  if (select count(distinct lower(btrim(n))) from unnest(p_member_names) as u(n))
     <> cardinality(p_member_names) then
    raise exception '参加者名が重複しています';
  end if;

  v_room_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into public.draft_rooms(room_code) values (v_room_code)
  returning id into v_room_id;

  foreach v_name in array p_member_names loop
    v_seat := v_seat + 1;
    v_token := replace(gen_random_uuid()::text, '-', '') ||
               replace(gen_random_uuid()::text, '-', '');
    insert into public.draft_room_members
      (room_id, seat_no, member_name, access_token_hash)
    values
      (v_room_id, v_seat, btrim(v_name),
       encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'));

    v_members := v_members || jsonb_build_array(jsonb_build_object(
      'seat_no', v_seat,
      'member_name', btrim(v_name),
      'access_token', v_token
    ));
  end loop;

  return jsonb_build_object(
    'room_code', v_room_code,
    'participant_count', cardinality(p_member_names),
    'members', v_members
  );
end;
$$;

create or replace function public.get_draft_state(
  p_room_code text,
  p_access_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.draft_rooms%rowtype;
  v_me public.draft_room_members%rowtype;
  v_active_count integer;
  v_submitted_count integer;
  v_my_submitted boolean;
  v_my_award text;
  v_acquired jsonb;
  v_revealed jsonb;
begin
  select * into v_room
  from public.draft_rooms
  where room_code = upper(btrim(p_room_code));

  if not found then raise exception 'ルームが見つかりません'; end if;

  select * into v_me
  from public.draft_room_members
  where room_id = v_room.id
    and access_token_hash = encode(extensions.digest(convert_to(p_access_token, 'UTF8'), 'sha256'), 'hex');

  if not found then raise exception '参加コードが正しくありません'; end if;

  select count(*) into v_active_count
  from public.draft_room_members m
  where m.room_id = v_room.id
    and not exists (
      select 1 from public.draft_awards a
      where a.room_id = v_room.id
        and a.round_no = v_room.current_round
        and a.member_id = m.id
    );

  select count(*) into v_submitted_count
  from public.draft_picks p
  join public.draft_room_members m on m.id = p.member_id
  where p.room_id = v_room.id
    and p.round_no = v_room.current_round
    and p.attempt_no = v_room.attempt_no
    and not exists (
      select 1 from public.draft_awards a
      where a.room_id = v_room.id
        and a.round_no = v_room.current_round
        and a.member_id = m.id
    );

  select exists (
    select 1 from public.draft_picks
    where room_id = v_room.id
      and round_no = v_room.current_round
      and attempt_no = v_room.attempt_no
      and member_id = v_me.id
  ) into v_my_submitted;

  select a.player_name into v_my_award
  from public.draft_awards a
  where a.room_id = v_room.id
    and a.round_no = v_room.current_round
    and a.member_id = v_me.id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'player_name', a.player_name,
    'member_name', m.member_name,
    'round_no', a.round_no
  ) order by a.round_no, m.seat_no), '[]'::jsonb)
  into v_acquired
  from public.draft_awards a
  join public.draft_room_members m on m.id = a.member_id
  where a.room_id = v_room.id;

  if v_room.last_resolved_round is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'member_name', m.member_name,
      'player_name', p.player_name,
      'won', exists (
        select 1 from public.draft_awards a
        where a.room_id = p.room_id
          and a.round_no = p.round_no
          and a.member_id = p.member_id
          and a.player_name = p.player_name
      )
    ) order by m.seat_no), '[]'::jsonb)
    into v_revealed
    from public.draft_picks p
    join public.draft_room_members m on m.id = p.member_id
    where p.room_id = v_room.id
      and p.round_no = v_room.last_resolved_round
      and p.attempt_no = v_room.last_resolved_attempt;
  else
    v_revealed := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'room_code', v_room.room_code,
    'status', v_room.status,
    'my_name', v_me.member_name,
    'current_round', v_room.current_round,
    'attempt_no', v_room.attempt_no,
    'active_count', v_active_count,
    'submitted_count', v_submitted_count,
    'my_submitted', v_my_submitted,
    'my_awarded', v_my_award is not null,
    'my_awarded_player', v_my_award,
    'acquired_players', v_acquired,
    'last_reveal', v_revealed
  );
end;
$$;

create or replace function public.submit_draft_pick(
  p_room_code text,
  p_access_token text,
  p_player_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.draft_rooms%rowtype;
  v_me public.draft_room_members%rowtype;
  v_active_count integer;
  v_submitted_count integer;
  v_candidate text;
  v_winner uuid;
  v_loser_count integer;
begin
  select * into v_room
  from public.draft_rooms
  where room_code = upper(btrim(p_room_code))
  for update;

  if not found then raise exception 'ルームが見つかりません'; end if;
  if v_room.status <> 'active' then raise exception 'このルームは終了しています'; end if;

  select * into v_me
  from public.draft_room_members
  where room_id = v_room.id
    and access_token_hash = encode(extensions.digest(convert_to(p_access_token, 'UTF8'), 'sha256'), 'hex');

  if not found then raise exception '参加コードが正しくありません'; end if;

  if exists (
    select 1 from public.draft_awards
    where room_id = v_room.id
      and round_no = v_room.current_round
      and member_id = v_me.id
  ) then
    raise exception 'このラウンドの指名はすでに確定しています';
  end if;

  if exists (
    select 1 from public.draft_picks
    where room_id = v_room.id
      and round_no = v_room.current_round
      and attempt_no = v_room.attempt_no
      and member_id = v_me.id
  ) then
    raise exception 'この回の指名は送信済みです';
  end if;

  if p_player_name is null or btrim(p_player_name) = '' then
    raise exception '選手を選択してください';
  end if;

  if not exists (
    select 1 from public.players
    where name = btrim(p_player_name)
      and is_active = true
  ) then
    raise exception '選択した選手は候補一覧に存在しないか、現在選択できません';
  end if;

  if exists (
    select 1 from public.draft_awards
    where room_id = v_room.id
      and player_name = btrim(p_player_name)
  ) then
    raise exception 'その選手はすでに獲得されています';
  end if;

  insert into public.draft_picks
    (room_id, round_no, attempt_no, member_id, player_name)
  values
    (v_room.id, v_room.current_round, v_room.attempt_no, v_me.id, btrim(p_player_name));

  select count(*) into v_active_count
  from public.draft_room_members m
  where m.room_id = v_room.id
    and not exists (
      select 1 from public.draft_awards a
      where a.room_id = v_room.id
        and a.round_no = v_room.current_round
        and a.member_id = m.id
    );

  select count(*) into v_submitted_count
  from public.draft_picks
  where room_id = v_room.id
    and round_no = v_room.current_round
    and attempt_no = v_room.attempt_no;

  if v_submitted_count = v_active_count then
    -- Reveal and resolve all picks together. A random member wins each collision.
    for v_candidate in
      select player_name
      from public.draft_picks
      where room_id = v_room.id
        and round_no = v_room.current_round
        and attempt_no = v_room.attempt_no
      group by player_name
    loop
      select p.member_id into v_winner
      from public.draft_picks p
      where p.room_id = v_room.id
        and p.round_no = v_room.current_round
        and p.attempt_no = v_room.attempt_no
        and p.player_name = v_candidate
      order by random()
      limit 1;

      insert into public.draft_awards(room_id, round_no, member_id, player_name)
      values (v_room.id, v_room.current_round, v_winner, v_candidate)
      on conflict do nothing;
    end loop;

    select count(*) into v_loser_count
    from public.draft_room_members m
    where m.room_id = v_room.id
      and not exists (
        select 1 from public.draft_awards a
        where a.room_id = v_room.id
          and a.round_no = v_room.current_round
          and a.member_id = m.id
      );

    update public.draft_rooms
    set last_resolved_round = v_room.current_round,
        last_resolved_attempt = v_room.attempt_no,
        current_round = case when v_loser_count = 0 then v_room.current_round + 1 else v_room.current_round end,
        attempt_no = case when v_loser_count = 0 then 1 else v_room.attempt_no + 1 end
    where id = v_room.id;
  end if;

  return public.get_draft_state(v_room.room_code, p_access_token);
end;
$$;

grant execute on function public.create_draft_room(text[]) to anon, authenticated;
grant execute on function public.get_draft_state(text, text) to anon, authenticated;
grant execute on function public.submit_draft_pick(text, text, text) to anon, authenticated;
