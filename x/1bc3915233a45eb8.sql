-- D32: RANKED 1v1 and 2v2 (founder brief "LINKUP Ranked 1v1/2v2", 2026-11-19). Premium only.
-- Matches: 4 shared prompts, 40 s each, ONE locked answer per player per prompt, fixed tier points.
-- Winner: higher total (team total in 2v2); ties play shared 40 s sudden-death prompts (max 3, then void).
-- Hidden skill: TrueSkill (mu, sigma) per queue per season; visible Rank Points (RP) with divisions.
-- Everything is server-authoritative and resolved lazily under a row lock on each poll (like LINK FRENZY).

-- ------------------------------------------------------------------ constants
create or replace function public.ranked_cfg(p_key text) returns float8
language sql immutable as $$
  select case p_key
    when 'mu' then 25.0 when 'sigma' then 25.0 / 3 when 'beta' then 25.0 / 6 when 'tau' then 25.0 / 300
    when 'answer_s' then 40 when 'countdown_s' then 3 when 'reveal_s' then 6
    when 'placements' then 5 when 'max_sudden_death' then 3 when 'afk_s' then 60
    when 'season_days' then 56 when 'scientist_min_pool' then 1000 end
$$;

-- ------------------------------------------------------------------ tables
create table public.ranked_seasons (
  id        int primary key,
  starts_at timestamptz not null,
  ends_at   timestamptz not null
);

create table public.ranked_ratings (
  player_id      uuid not null references public.players(id) on delete cascade,
  queue          text not null check (queue in ('solo', 'duo')),
  season         int  not null references public.ranked_seasons(id),
  mu             float8 not null,
  sigma          float8 not null,
  rp             int not null default 0,
  placements     int not null default 0,     -- placement matches played this season (rank hidden until 5)
  wins           int not null default 0,
  losses         int not null default 0,
  last_match_at  timestamptz,
  primary key (player_id, queue, season)
);

create table public.ranked_queue (
  player_id    uuid primary key references public.players(id) on delete cascade,
  queue        text not null check (queue in ('solo', 'duo')),
  skill        float8 not null,                -- conservative skill mu - 3 sigma
  joined_at    timestamptz not null default clock_timestamp(),
  last_poll_at timestamptz not null default clock_timestamp()
);

create table public.ranked_matches (
  id            uuid primary key default gen_random_uuid(),
  queue         text not null check (queue in ('solo', 'duo')),
  season        int not null references public.ranked_seasons(id),
  status        text not null default 'playing' check (status in ('playing', 'finished', 'void')),
  puzzle_ids    uuid[] not null,                -- 4 main prompts + sudden-death spares
  winner_team   int,
  end_reason    text,                            -- 'score' | 'forfeit' | 'tie_limit' | 'abandoned'
  created_at    timestamptz not null default clock_timestamp(),
  finished_at   timestamptz,
  ratings_done  boolean not null default false
);

create table public.ranked_players (
  match_id      uuid not null references public.ranked_matches(id) on delete cascade,
  player_id     uuid not null references public.players(id) on delete cascade,
  team          int  not null check (team in (0, 1)),
  name          text not null,
  last_seen_at  timestamptz not null default clock_timestamp(),
  forfeited     boolean not null default false,
  mu_before     float8, sigma_before float8, mu_after float8, sigma_after float8,
  rp_before     int, rp_after int, placements_after int,
  primary key (match_id, player_id)
);

create table public.ranked_rounds (
  match_id    uuid not null references public.ranked_matches(id) on delete cascade,
  round_no    int  not null,
  puzzle_id   uuid not null references public.puzzles(id),
  starts_at   timestamptz not null,
  deadline_at timestamptz not null,
  resolved_at timestamptz,
  primary key (match_id, round_no)
);

create table public.ranked_subs (
  match_id           uuid not null references public.ranked_matches(id) on delete cascade,
  round_no           int  not null,
  player_id          uuid not null references public.players(id) on delete cascade,
  raw_answer         text,
  accepted_answer_id uuid references public.accepted_answers(id),
  points             int not null default 0,
  submitted_at       timestamptz,
  primary key (match_id, round_no, player_id)
);
create index ranked_players_by_player on public.ranked_players (player_id);

alter table public.ranked_seasons enable row level security;
alter table public.ranked_ratings enable row level security;
alter table public.ranked_queue   enable row level security;
alter table public.ranked_matches enable row level security;
alter table public.ranked_players enable row level security;
alter table public.ranked_rounds  enable row level security;
alter table public.ranked_subs    enable row level security;
revoke all on public.ranked_seasons, public.ranked_ratings, public.ranked_queue, public.ranked_matches,
  public.ranked_players, public.ranked_rounds, public.ranked_subs from anon, authenticated;

-- ------------------------------------------------------------------ seasons
-- The season covering now; seasons roll every 8 weeks without anyone having to start them.
create or replace function public.ranked_season() returns int
language plpgsql security definer set search_path = public as $$
declare s public.ranked_seasons; now_ts timestamptz := clock_timestamp();
begin
  select * into s from public.ranked_seasons where now_ts >= starts_at and now_ts < ends_at;
  if found then return s.id; end if;
  select * into s from public.ranked_seasons order by id desc limit 1;
  if not found then
    insert into public.ranked_seasons values (1, date_trunc('day', now_ts), date_trunc('day', now_ts) + make_interval(days => public.ranked_cfg('season_days')::int))
    on conflict do nothing;
    return 1;
  end if;
  while s.ends_at <= now_ts loop
    insert into public.ranked_seasons values (s.id + 1, s.ends_at, s.ends_at + make_interval(days => public.ranked_cfg('season_days')::int))
    on conflict do nothing;
    select * into s from public.ranked_seasons where id = s.id + 1;
  end loop;
  return s.id;
end $$;

-- ------------------------------------------------------------------ ranks
-- Visible RP is one number: 100 per division from Bronze III (0) to Diamond I (1799), then Master (1800+)
-- and Volt (2400+) as continuous elite RP. Scientist is a leaderboard title on top of Volt.
create or replace function public.ranked_division(p_rp int) returns jsonb
language sql immutable as $$
  select case
    when p_rp >= 2400 then jsonb_build_object('tier', 'VOLT', 'division', null, 'progress', p_rp - 2400, 'elite', true)
    when p_rp >= 1800 then jsonb_build_object('tier', 'MASTER', 'division', null, 'progress', p_rp - 1800, 'elite', true)
    else jsonb_build_object(
      'tier', (array['BRONZE','SILVER','GOLD','PLATINUM','EMERALD','DIAMOND'])[greatest(p_rp, 0) / 300 + 1],
      'division', (array['III','II','I'])[(greatest(p_rp, 0) % 300) / 100 + 1],
      'progress', greatest(p_rp, 0) % 100, 'elite', false)
  end
$$;

-- Where hidden skill says a player belongs on the RP ladder (used to seed after placements and to steer RP).
create or replace function public.ranked_hidden_rp(p_mu float8, p_sigma float8) returns int
language sql immutable as $$ select greatest(0, round((p_mu - 3 * p_sigma) * 50 + 400))::int $$;

-- A player's rating for this season, created on first use with a soft reset from their last season.
create or replace function public.ranked_rating(p_player uuid, p_queue text) returns public.ranked_ratings
language plpgsql security definer set search_path = public as $$
declare r public.ranked_ratings; prev public.ranked_ratings; v_season int := public.ranked_season();
begin
  select * into r from public.ranked_ratings where player_id = p_player and queue = p_queue and ranked_ratings.season = v_season;
  if found then return r; end if;
  select * into prev from public.ranked_ratings where player_id = p_player and queue = p_queue order by ranked_ratings.season desc limit 1;
  insert into public.ranked_ratings (player_id, queue, season, mu, sigma, rp)
  values (p_player, p_queue, v_season,
          case when prev.player_id is null then public.ranked_cfg('mu') else public.ranked_cfg('mu') + (prev.mu - public.ranked_cfg('mu')) * 0.75 end,
          case when prev.player_id is null then public.ranked_cfg('sigma') else least(public.ranked_cfg('sigma'), prev.sigma + 1.5) end,
          case when prev.player_id is null then 0 else (prev.rp * 0.6)::int end)
  on conflict do nothing;
  select * into r from public.ranked_ratings where player_id = p_player and queue = p_queue and ranked_ratings.season = v_season;
  return r;
end $$;

-- ------------------------------------------------------------------ TrueSkill (two teams, no draws)
create or replace function public.ts_pdf(x float8) returns float8 language sql immutable as $$ select exp(-x * x / 2) / sqrt(2 * pi()) $$;
create or replace function public.ts_cdf(x float8) returns float8 language sql immutable as $$ select 0.5 * (1 + erf(x / sqrt(2))) $$;

-- Applies the result of a finished match exactly once: TrueSkill for every player from the team result,
-- then visible RP (placements first). Puzzle-score margin never matters, only who won.
create or replace function public.ranked_apply_ratings(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  m public.ranked_matches; p record; r public.ranked_ratings;
  beta float8 := public.ranked_cfg('beta'); tau float8 := public.ranked_cfg('tau');
  mu_w float8 := 0; mu_l float8 := 0; var_sum float8 := 0; n int := 0; c float8; t float8; v float8; w float8;
  s2 float8; won boolean; mu2 float8; sig2 float8; p_win float8; base int; adj int; delta int; new_rp int; hidden int;
  placements_n int := public.ranked_cfg('placements')::int;
begin
  select * into m from public.ranked_matches where id = p_match for update;
  if m.ratings_done or m.status <> 'finished' or m.winner_team is null then return; end if;

  for p in select rp.*, rr.mu, rr.sigma from public.ranked_players rp
             join public.ranked_ratings rr on rr.player_id = rp.player_id and rr.queue = m.queue and rr.season = m.season
            where rp.match_id = p_match loop
    if p.team = m.winner_team then mu_w := mu_w + p.mu; else mu_l := mu_l + p.mu; end if;
    var_sum := var_sum + p.sigma ^ 2 + tau ^ 2; n := n + 1;
  end loop;
  c := sqrt(var_sum + n * beta ^ 2);
  t := (mu_w - mu_l) / c;
  v := public.ts_pdf(t) / greatest(public.ts_cdf(t), 1e-12);
  w := v * (v + t);

  for p in select rp.*, rr.mu, rr.sigma, rr.rp as cur_rp, rr.placements from public.ranked_players rp
             join public.ranked_ratings rr on rr.player_id = rp.player_id and rr.queue = m.queue and rr.season = m.season
            where rp.match_id = p_match loop
    won := p.team = m.winner_team;
    s2 := p.sigma ^ 2 + tau ^ 2;
    mu2 := p.mu + (case when won then 1 else -1 end) * s2 / c * v;
    sig2 := sqrt(s2 * greatest(1 - s2 / c ^ 2 * w, 1e-4));
    -- my chance of winning before the match, from both teams' skill
    p_win := public.ts_cdf((case when p.team = 0 then 1 else -1 end) *
             ((select coalesce(sum(rr.mu), 0) from public.ranked_players x join public.ranked_ratings rr on rr.player_id = x.player_id and rr.queue = m.queue and rr.season = m.season where x.match_id = p_match and x.team = 0)
            - (select coalesce(sum(rr.mu), 0) from public.ranked_players x join public.ranked_ratings rr on rr.player_id = x.player_id and rr.queue = m.queue and rr.season = m.season where x.match_id = p_match and x.team = 1)) / c);
    hidden := public.ranked_hidden_rp(mu2, sig2);
    if p.placements + 1 < placements_n then
      new_rp := p.cur_rp;                                 -- still placing: rank hidden
    elsif p.placements + 1 = placements_n then
      new_rp := hidden;                                   -- placements done: seed from hidden skill
    else
      if won then base := round(10 + 24 * (1 - p_win)); else base := -round(10 + 24 * p_win); end if;
      adj := greatest(-6, least(6, round((hidden - p.cur_rp) / 25.0)::int));  -- steer RP toward hidden skill
      delta := case when won then greatest(8, least(35, base + adj)) else least(-8, greatest(-35, base + adj)) end;
      new_rp := greatest(0, p.cur_rp + delta);
    end if;
    update public.ranked_ratings set mu = mu2, sigma = sig2, rp = new_rp, placements = placements + 1,
           wins = wins + case when won then 1 else 0 end, losses = losses + case when won then 0 else 1 end,
           last_match_at = clock_timestamp()
     where player_id = p.player_id and queue = m.queue and season = m.season;
    update public.ranked_players set mu_before = p.mu, sigma_before = p.sigma, mu_after = mu2, sigma_after = sig2,
           rp_before = p.cur_rp, rp_after = new_rp, placements_after = p.placements + 1
     where match_id = p_match and player_id = p.player_id;
  end loop;
  update public.ranked_matches set ratings_done = true where id = p_match;
end $$;

-- ------------------------------------------------------------------ prompts
-- 4 + sudden-death prompts: published puzzles except today's and upcoming dailies (no spoilers),
-- least recently seen in ranked by any of these players first.
create or replace function public.ranked_pick_puzzles(p_players uuid[], p_n int) returns uuid[]
language sql security definer set search_path = public as $$
  select array_agg(id) from (
    select pz.id from public.puzzles pz
     where pz.status = 'published'
       and not exists (select 1 from public.daily_challenges d where d.challenge_date >= public.utc_today() and pz.id = any(d.puzzle_ids))
     order by (select max(m.created_at) from public.ranked_rounds rd join public.ranked_matches m on m.id = rd.match_id
                 join public.ranked_players rp on rp.match_id = m.id
                where rd.puzzle_id = pz.id and rp.player_id = any(p_players)) asc nulls first,
              random()
     limit p_n) s
$$;

-- ------------------------------------------------------------------ match flow
create or replace function public.ranked_new_round(p_match uuid, p_round int, p_starts timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  select puzzle_ids into ids from public.ranked_matches where id = p_match;
  insert into public.ranked_rounds (match_id, round_no, puzzle_id, starts_at, deadline_at)
  values (p_match, p_round, ids[p_round], p_starts, p_starts + make_interval(secs => public.ranked_cfg('answer_s')))
  on conflict do nothing;
end $$;

create or replace function public.ranked_finish(p_match uuid, p_winner int, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.ranked_matches set status = case when p_winner is null then 'void' else 'finished' end,
         winner_team = p_winner, end_reason = p_reason, finished_at = clock_timestamp()
   where id = p_match and status = 'playing';
  perform public.ranked_apply_ratings(p_match);
end $$;

-- Advances a match to where the clock says it should be. Call with the match row locked.
create or replace function public.ranked_tick(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  m public.ranked_matches; rd public.ranked_rounds; now_ts timestamptz := clock_timestamp();
  active0 int; active1 int; waiting int; t0 int; t1 int; main int := 4;
begin
  select * into m from public.ranked_matches where id = p_match for update;
  if m.status <> 'playing' then return; end if;

  -- players silent for a minute have disconnected and forfeit
  update public.ranked_players set forfeited = true
   where match_id = p_match and not forfeited and last_seen_at < now_ts - make_interval(secs => public.ranked_cfg('afk_s'));
  select count(*) filter (where team = 0 and not forfeited), count(*) filter (where team = 1 and not forfeited)
    into active0, active1 from public.ranked_players where match_id = p_match;
  if active0 = 0 and active1 = 0 then perform public.ranked_finish(p_match, null, 'abandoned'); return; end if;
  if active0 = 0 then perform public.ranked_finish(p_match, 1, 'forfeit'); return; end if;
  if active1 = 0 then perform public.ranked_finish(p_match, 0, 'forfeit'); return; end if;

  loop
    select * into rd from public.ranked_rounds where match_id = p_match order by round_no desc limit 1;
    if rd.resolved_at is null then
      select count(*) into waiting from public.ranked_players p
       where p.match_id = p_match and not p.forfeited
         and not exists (select 1 from public.ranked_subs s where s.match_id = p_match and s.round_no = rd.round_no and s.player_id = p.player_id);
      if waiting = 0 or now_ts > rd.deadline_at + public.deadline_grace() then
        -- close the prompt for everyone; no answer scores zero
        insert into public.ranked_subs (match_id, round_no, player_id, points)
        select p_match, rd.round_no, p.player_id, 0 from public.ranked_players p where p.match_id = p_match
        on conflict do nothing;
        update public.ranked_rounds set resolved_at = least(now_ts, rd.deadline_at + public.deadline_grace())
         where match_id = p_match and round_no = rd.round_no;
        continue;
      end if;
      return;
    end if;
    if now_ts < rd.resolved_at + make_interval(secs => public.ranked_cfg('reveal_s')) then return; end if;

    if rd.round_no >= main then
      select coalesce(sum(s.points) filter (where p.team = 0), 0), coalesce(sum(s.points) filter (where p.team = 1), 0)
        into t0, t1 from public.ranked_subs s join public.ranked_players p on p.match_id = s.match_id and p.player_id = s.player_id
       where s.match_id = p_match;
      if t0 <> t1 then perform public.ranked_finish(p_match, case when t0 > t1 then 0 else 1 end, 'score'); return; end if;
      if rd.round_no >= main + public.ranked_cfg('max_sudden_death')::int
         or rd.round_no + 1 > coalesce(array_length(m.puzzle_ids, 1), 0) then
        perform public.ranked_finish(p_match, null, 'tie_limit'); return;   -- still tied: void, no rating change
      end if;
    end if;
    perform public.ranked_new_round(p_match, rd.round_no + 1,
      rd.resolved_at + make_interval(secs => public.ranked_cfg('reveal_s') + public.ranked_cfg('countdown_s')));
  end loop;
end $$;

-- ------------------------------------------------------------------ state for the client
create or replace function public.ranked_json(p_match uuid, p_me uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m public.ranked_matches; rd public.ranked_rounds; now_ts timestamptz := clock_timestamp(); my_team int; j jsonb;
begin
  select * into m from public.ranked_matches where id = p_match;
  select team into my_team from public.ranked_players where match_id = p_match and player_id = p_me;
  select * into rd from public.ranked_rounds where match_id = p_match order by round_no desc limit 1;
  j := jsonb_build_object(
    'id', m.id, 'queue', m.queue, 'status', m.status, 'winner_team', m.winner_team, 'end_reason', m.end_reason,
    'my_team', my_team, 'server_now', now_ts, 'main_rounds', 4,
    'round', case when rd.match_id is null then null else jsonb_build_object(
      'no', rd.round_no, 'sudden_death', rd.round_no > 4, 'starts_at', rd.starts_at, 'deadline_at', rd.deadline_at,
      'resolved', rd.resolved_at is not null,
      'next_at', case when rd.resolved_at is null then null else rd.resolved_at + make_interval(secs => public.ranked_cfg('reveal_s')) end,
      -- concepts only once the prompt has started
      'concept_a', case when now_ts >= rd.starts_at then pz.concept_a end, 'concept_b', case when now_ts >= rd.starts_at then pz.concept_b end,
      'icon_a', case when now_ts >= rd.starts_at then pz.icon_a end, 'icon_b', case when now_ts >= rd.starts_at then pz.icon_b end,
      'my_answer', (select raw_answer from public.ranked_subs s where s.match_id = p_match and s.round_no = rd.round_no and s.player_id = p_me and s.submitted_at is not null)
    ) end,
    'players', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.player_id, 'name', p.name, 'team', p.team, 'me', p.player_id = p_me, 'forfeited', p.forfeited,
        'avatar', (select pl.avatar from public.players pl where pl.id = p.player_id),
        -- totals only count prompts that have closed for everyone
        'total', (select coalesce(sum(s.points), 0) from public.ranked_subs s join public.ranked_rounds r2 on r2.match_id = s.match_id and r2.round_no = s.round_no
                   where s.match_id = p_match and s.player_id = p.player_id and r2.resolved_at is not null),
        'submitted', exists (select 1 from public.ranked_subs s where s.match_id = p_match and s.round_no = rd.round_no and s.player_id = p.player_id and s.submitted_at is not null),
        'rp_before', p.rp_before, 'rp_after', p.rp_after, 'placements', p.placements_after
      ) order by p.team, p.name), '[]') from public.ranked_players p where p.match_id = p_match),
    -- per-prompt results, revealed only after each prompt closes
    'results', (select coalesce(jsonb_agg(jsonb_build_object(
        'round', r2.round_no, 'concept_a', pz2.concept_a, 'concept_b', pz2.concept_b,
        'subs', (select coalesce(jsonb_agg(jsonb_build_object('player', s.player_id, 'typed', s.raw_answer, 'points', s.points,
                   'tier', aa.tier, 'answer', aa.canonical_answer)), '[]')
                 from public.ranked_subs s left join public.accepted_answers aa on aa.id = s.accepted_answer_id
                 where s.match_id = p_match and s.round_no = r2.round_no)) order by r2.round_no), '[]')
      from public.ranked_rounds r2 join public.puzzles pz2 on pz2.id = r2.puzzle_id
     where r2.match_id = p_match and r2.resolved_at is not null))
  from public.puzzles pz where pz.id = rd.puzzle_id;
  if j is null then  -- no round yet (should not happen)
    j := jsonb_build_object('id', m.id, 'status', m.status);
  end if;
  return j;
end $$;

-- ------------------------------------------------------------------ player-facing RPCs
create or replace function public.ranked_require() returns public.accounts
language plpgsql security definer set search_path = public as $$
declare a public.accounts := public.require_account();
begin
  if not coalesce((select unlimited_access from public.players where id = public.me()), false) then
    raise exception 'ranked is a premium mode' using errcode = '42501';
  end if;
  return a;
end $$;

-- Join (or stay in) the queue; returns a match as soon as one is made. Clients call this every ~1.5 s.
create or replace function public.ranked_queue_poll(p_queue text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a public.accounts := public.ranked_require(); me uuid := public.me(); now_ts timestamptz := clock_timestamp();
  q public.ranked_queue; r public.ranked_ratings; active uuid; waited float8; win float8;
  picks uuid[]; teams int[]; best_diff float8; d float8; i int; mid uuid; size int; v_season int := public.ranked_season();
  pl uuid[]; mus float8[]; pz uuid[];
begin
  if p_queue not in ('solo', 'duo') then raise exception 'unknown queue' using errcode = '22023'; end if;
  -- already in a live match? go back to it
  select m.id into active from public.ranked_matches m join public.ranked_players p on p.match_id = m.id
   where p.player_id = me and m.status = 'playing' and not p.forfeited order by m.created_at desc limit 1;
  if active is not null then
    delete from public.ranked_queue where player_id = me;
    return jsonb_build_object('status', 'matched', 'match_id', active);
  end if;

  r := public.ranked_rating(me, p_queue);
  insert into public.ranked_queue (player_id, queue, skill) values (me, p_queue, r.mu - 3 * r.sigma)
  on conflict (player_id) do update set last_poll_at = now_ts, skill = excluded.skill,
     queue = excluded.queue, joined_at = case when ranked_queue.queue = excluded.queue then ranked_queue.joined_at else now_ts end;
  select * into q from public.ranked_queue where player_id = me;

  perform pg_advisory_xact_lock(hashtext('ranked_queue_' || p_queue));
  waited := extract(epoch from now_ts - q.joined_at);
  win := 3 + waited * 1.5;                   -- skill window widens the longer either player has waited
  size := case when p_queue = 'solo' then 2 else 4 end;

  select array_agg(player_id order by dist), array_agg(skill order by dist) into pl, mus from (
    select player_id, skill, abs(skill - q.skill) as dist from public.ranked_queue
     where queue = p_queue and player_id <> me and last_poll_at > now_ts - interval '6 seconds'
       and abs(skill - q.skill) <= greatest(win, 3 + extract(epoch from now_ts - joined_at) * 1.5)
     order by abs(skill - q.skill) limit size - 1) c;

  if coalesce(array_length(pl, 1), 0) < size - 1 then
    return jsonb_build_object('status', 'queued', 'queue', p_queue, 'waited', round(waited),
      'searching', (select count(*) from public.ranked_queue where queue = p_queue and last_poll_at > now_ts - interval '6 seconds'));
  end if;

  picks := array[me] || pl;
  for i in 1..size loop perform public.ranked_rating(picks[i], p_queue); end loop;
  if size = 2 then
    teams := array[0, 1];
  else
    -- split four players into the two most even teams by skill (TrueSkill mu)
    select array_agg(rr.mu order by array_position(picks, rr.player_id)) into mus
      from public.ranked_ratings rr where rr.player_id = any(picks) and rr.queue = 'duo' and rr.season = v_season;
    best_diff := null;
    for i in 2..4 loop
      d := abs((mus[1] + mus[i]) - (mus[1] + mus[2] + mus[3] + mus[4] - mus[1] - mus[i]));
      if best_diff is null or d < best_diff then best_diff := d; teams := array[0, 1, 1, 1]; teams[i] := 0; end if;
    end loop;
  end if;
  pz := public.ranked_pick_puzzles(picks, 4 + public.ranked_cfg('max_sudden_death')::int);
  if coalesce(array_length(pz, 1), 0) < 4 then
    return jsonb_build_object('status', 'queued', 'queue', p_queue, 'waited', round(waited), 'error', 'not enough prompts');
  end if;
  insert into public.ranked_matches (queue, season, puzzle_ids) values (p_queue, v_season, pz) returning id into mid;
  insert into public.ranked_players (match_id, player_id, team, name)
  select mid, picks[gs.n], teams[gs.n],
         coalesce((select a2.display_name from public.accounts a2 where a2.primary_player = picks[gs.n]), 'Player')
    from generate_series(1, size) gs(n);
  delete from public.ranked_queue where player_id = any(picks);
  perform public.ranked_new_round(mid, 1, now_ts + make_interval(secs => public.ranked_cfg('countdown_s') + 2));
  return jsonb_build_object('status', 'matched', 'match_id', mid);
end $$;

create or replace function public.ranked_queue_leave() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  delete from public.ranked_queue where player_id = public.me();
end $$;

create or replace function public.ranked_state(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.me();
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.ranked_players where match_id = p_match and player_id = me) then
    raise exception 'not in this match' using errcode = '42501';
  end if;
  perform 1 from public.ranked_matches where id = p_match for update;
  update public.ranked_players set last_seen_at = clock_timestamp() where match_id = p_match and player_id = me and not forfeited;
  perform public.ranked_tick(p_match);
  return public.ranked_json(p_match, me);
end $$;

-- Leaving a live match forfeits it (a loss once the whole team has gone).
create or replace function public.ranked_forfeit(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.me();
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  perform 1 from public.ranked_matches where id = p_match for update;
  update public.ranked_players set forfeited = true where match_id = p_match and player_id = me;
  perform public.ranked_tick(p_match);
  return public.ranked_json(p_match, me);
end $$;

-- Badge info for both ladders (profile, lobby).
create or replace function public.ranked_profile() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.me(); s int := public.ranked_season(); q text; r public.ranked_ratings; out jsonb := '{}';
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  foreach q in array array['solo', 'duo'] loop
    select * into r from public.ranked_ratings where player_id = me and queue = q and season = s;
    out := out || jsonb_build_object(q, jsonb_build_object(
      'rp', coalesce(r.rp, 0), 'placements', coalesce(r.placements, 0), 'placements_needed', public.ranked_cfg('placements')::int,
      'wins', coalesce(r.wins, 0), 'losses', coalesce(r.losses, 0),
      'rank', case when coalesce(r.placements, 0) >= public.ranked_cfg('placements') then public.ranked_division(r.rp) end,
      'scientist', public.ranked_is_scientist(me, q)));
  end loop;
  return out || jsonb_build_object('season', s, 'season_ends_at', (select ends_at from public.ranked_seasons where id = s),
    'premium', coalesce((select unlimited_access from public.players where id = me), false));
end $$;

-- Scientist: Volt players with 50+ matches this season and 10+ in the last 14 days, in the top 0.1% of that
-- eligible pool. Locked until the pool reaches the published minimum (1,000), so 0.1% is at least one player.
create or replace function public.ranked_is_scientist(p_player uuid, p_queue text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare s int := (select id from public.ranked_seasons where clock_timestamp() between starts_at and ends_at); pool int; top_n int;
begin
  if s is null then return false; end if;
  with eligible as (
    select rr.player_id, rr.rp from public.ranked_ratings rr
     where rr.queue = p_queue and rr.season = s and rr.rp >= 2400 and rr.wins + rr.losses >= 50
       and (select count(*) from public.ranked_players p join public.ranked_matches m on m.id = p.match_id
             where p.player_id = rr.player_id and m.queue = p_queue and m.status = 'finished'
               and m.finished_at > clock_timestamp() - interval '14 days') >= 10)
  select count(*) into pool from eligible;
  if pool < public.ranked_cfg('scientist_min_pool') then return false; end if;
  top_n := floor(pool * 0.001);
  return exists (select 1 from (select player_id from public.ranked_ratings where queue = p_queue and season = s and rp >= 2400
                                order by rp desc limit top_n) t where t.player_id = p_player);
end $$;

create or replace function public.ranked_leaderboard(p_queue text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s int := public.ranked_season(); me uuid := public.me();
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  return jsonb_build_object('queue', p_queue, 'season', s, 'top', (select coalesce(jsonb_agg(x order by (x->>'rp')::int desc), '[]') from (
    select jsonb_build_object('name', coalesce(a.display_name, 'Player'), 'username', a.username, 'rp', rr.rp,
             'rank', public.ranked_division(rr.rp), 'me', rr.player_id = me,
             'avatar', (select pl.avatar from public.players pl where pl.id = rr.player_id)) x
      from public.ranked_ratings rr left join public.accounts a on a.primary_player = rr.player_id
     where rr.queue = p_queue and rr.season = s and rr.placements >= public.ranked_cfg('placements')
     order by rr.rp desc limit 50) t));
end $$;

-- ------------------------------------------------------------------ answers (via the ranked-guess Edge Function)
create or replace function public.ranked_guess_context(p_match uuid, p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.player_for(p_player); rd public.ranked_rounds; m public.ranked_matches; now_ts timestamptz := clock_timestamp();
begin
  select * into m from public.ranked_matches where id = p_match;
  if not found or not exists (select 1 from public.ranked_players where match_id = p_match and player_id = me and not forfeited) then return null; end if;
  select * into rd from public.ranked_rounds where match_id = p_match order by round_no desc limit 1;
  if m.status <> 'playing' or rd.resolved_at is not null or now_ts < rd.starts_at or now_ts > rd.deadline_at + public.deadline_grace()
     or exists (select 1 from public.ranked_subs where match_id = p_match and round_no = rd.round_no and player_id = me) then
    return jsonb_build_object('status', 'closed');
  end if;
  return jsonb_build_object('status', 'open',
    'blocked_inputs', (select to_jsonb(blocked_inputs) from public.puzzles where id = rd.puzzle_id),
    'answers', (select coalesce(jsonb_agg(jsonb_build_object('id', aa.id, 'canonical', aa.canonical_answer,
                  'aliases', (select coalesce(jsonb_agg(al.alias), '[]') from public.answer_aliases al where al.accepted_answer_id = aa.id))), '[]')
                from public.accepted_answers aa where aa.puzzle_id = rd.puzzle_id));
end $$;

-- Locks the player's one answer for this prompt. Points stay hidden until the prompt closes for everyone.
create or replace function public.ranked_submit(p_match uuid, p_player uuid, p_raw text, p_answer_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.player_for(p_player); rd public.ranked_rounds; m public.ranked_matches; aa public.accepted_answers;
        now_ts timestamptz := clock_timestamp(); ok boolean;
begin
  select * into m from public.ranked_matches where id = p_match for update;
  if not found or not exists (select 1 from public.ranked_players where match_id = p_match and player_id = me and not forfeited) then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  update public.ranked_players set last_seen_at = now_ts where match_id = p_match and player_id = me;
  select * into rd from public.ranked_rounds where match_id = p_match order by round_no desc limit 1;
  if m.status <> 'playing' or rd.resolved_at is not null or now_ts < rd.starts_at or now_ts > rd.deadline_at + public.deadline_grace() then
    return jsonb_build_object('outcome', 'closed');
  end if;
  if p_answer_id is not null then
    select * into aa from public.accepted_answers where id = p_answer_id and puzzle_id = rd.puzzle_id;
    if not found then p_answer_id := null; end if;
  end if;
  insert into public.ranked_subs (match_id, round_no, player_id, raw_answer, accepted_answer_id, points, submitted_at)
  values (p_match, rd.round_no, me, left(p_raw, 200), p_answer_id, case when p_answer_id is null then 0 else public.tier_points(aa.tier) end, now_ts)
  on conflict do nothing
  returning true into ok;
  if ok is null then return jsonb_build_object('outcome', 'already_locked'); end if;
  perform public.ranked_tick(p_match);   -- closes the prompt at once if everyone has answered
  return jsonb_build_object('outcome', 'locked');
end $$;

-- ------------------------------------------------------------------ grants
revoke execute on function public.ranked_cfg(text), public.ranked_season(), public.ranked_division(int), public.ranked_hidden_rp(float8, float8),
  public.ranked_rating(uuid, text), public.ts_pdf(float8), public.ts_cdf(float8), public.ranked_apply_ratings(uuid),
  public.ranked_pick_puzzles(uuid[], int), public.ranked_new_round(uuid, int, timestamptz), public.ranked_finish(uuid, int, text),
  public.ranked_tick(uuid), public.ranked_json(uuid, uuid), public.ranked_require(), public.ranked_is_scientist(uuid, text),
  public.ranked_guess_context(uuid, uuid), public.ranked_submit(uuid, uuid, text, uuid)
  from public, anon, authenticated;
grant execute on function public.ranked_guess_context(uuid, uuid), public.ranked_submit(uuid, uuid, text, uuid) to service_role;
revoke execute on function public.ranked_queue_poll(text), public.ranked_queue_leave(), public.ranked_state(uuid),
  public.ranked_forfeit(uuid), public.ranked_profile(), public.ranked_leaderboard(text) from public, anon;
grant execute on function public.ranked_queue_poll(text), public.ranked_queue_leave(), public.ranked_state(uuid),
  public.ranked_forfeit(uuid), public.ranked_profile(), public.ranked_leaderboard(text) to authenticated;
