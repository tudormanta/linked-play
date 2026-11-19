-- D35: THE VAULT — cosmetic items (8 tiers), VOLTS wallet (append-only ledger), inventory, equipment,
-- daily featured shop, server-verified earning, achievements with exclusive rewards, and season honours.
-- Cosmetic only: nothing here touches puzzle answers, answer tiers, points, timers, RP, TrueSkill or matchmaking.
-- Every write goes through SECURITY DEFINER functions; clients can't touch these tables directly.

-- ------------------------------------------------------------------ catalogue
create table public.cosmetic_items (
  slug        text primary key check (slug ~ '^[a-z0-9-]{2,40}$'),
  name        text not null,
  slot        text not null check (slot in ('base', 'bulb', 'filament', 'outfit', 'head', 'eyes', 'acc', 'fx', 'banner', 'bundle')),
  tier        text not null check (tier in ('COMMON', 'UNCOMMON', 'RARE', 'EPIC', 'LEGENDARY', 'ULTRARARE', 'SEASONAL', 'HEIRLOOM')),
  description text not null,
  unlock      text not null check (unlock in ('starter', 'shop', 'bundle', 'achievement')),   -- bundle = only inside a bundle
  price       int check (price > 0),
  achievement text,
  season      int,
  contents    text[],                       -- bundles only: the items it grants
  sort        int not null default 0,
  active      boolean not null default true,
  tradable    boolean not null default false check (not tradable),
  -- Exclusive tiers and achievement rewards never have a price; shop items always do.
  check ((unlock = 'shop') = (price is not null)),
  check (tier not in ('ULTRARARE', 'SEASONAL', 'HEIRLOOM') or unlock <> 'shop'),
  check ((unlock = 'achievement') = (achievement is not null)),
  check ((slot = 'bundle') = (contents is not null))
);

create table public.achievements (
  code         text primary key,
  name         text not null,
  description  text not null,
  metric       text not null,
  target       int  not null check (target > 0),
  season       int,                          -- seasonal: only completable with that season's play
  reward_volts int  not null default 0,
  reward_items text[] not null default '{}',
  sort         int  not null default 0
);

create table public.player_achievements (
  player_id    uuid not null references public.players(id) on delete cascade,
  code         text not null references public.achievements(code),
  completed_at timestamptz not null default clock_timestamp(),
  claimed_at   timestamptz,
  primary key (player_id, code)
);

-- ------------------------------------------------------------------ wallet, inventory, equipment
create table public.vault_wallets (
  player_id  uuid primary key references public.players(id) on delete cascade,
  balance    int  not null default 0 check (balance >= 0),
  updated_at timestamptz not null default clock_timestamp()
);

-- Immutable, idempotent ledger: one row per (player, reason, source). Balance = sum(delta).
create table public.vault_ledger (
  id         bigint generated always as identity primary key,
  player_id  uuid not null references public.players(id) on delete cascade,
  delta      int  not null check (delta <> 0),
  reason     text not null,
  source     text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (player_id, reason, source)
);
create index vault_ledger_by_player on public.vault_ledger (player_id, created_at desc);

create table public.vault_inventory (
  player_id   uuid not null references public.players(id) on delete cascade,
  item        text not null references public.cosmetic_items(slug),
  acquired_at timestamptz not null default clock_timestamp(),
  source      text not null check (source in ('shop', 'achievement', 'bundle', 'admin')),
  season      int,
  primary key (player_id, item)
);

create table public.vault_equipped (
  player_id uuid not null references public.players(id) on delete cascade,
  slot      text not null,
  item      text not null references public.cosmetic_items(slug),
  primary key (player_id, slot)
);

-- Frenzy match results (rooms are reused, so log each match as it ends).
create table public.frenzy_results (
  room_id     uuid not null,
  match_no    int  not null,
  winners     uuid[] not null,
  players     int  not null,
  finished_at timestamptz not null default clock_timestamp(),
  primary key (room_id, match_no)
);

-- Season-end titles (Scientist), recorded once when a season rolls over.
create table public.ranked_honours (
  season    int  not null,
  queue     text not null,
  player_id uuid not null references public.players(id) on delete cascade,
  honour    text not null,
  primary key (season, queue, player_id, honour)
);

alter table public.cosmetic_items      enable row level security;
alter table public.achievements        enable row level security;
alter table public.player_achievements enable row level security;
alter table public.vault_wallets       enable row level security;
alter table public.vault_ledger        enable row level security;
alter table public.vault_inventory     enable row level security;
alter table public.vault_equipped      enable row level security;
alter table public.frenzy_results      enable row level security;
alter table public.ranked_honours      enable row level security;
revoke all on public.cosmetic_items, public.achievements, public.player_achievements, public.vault_wallets,
  public.vault_ledger, public.vault_inventory, public.vault_equipped, public.frenzy_results, public.ranked_honours
  from anon, authenticated;

-- ------------------------------------------------------------------ config (override any key in app_settings as vault_<key>)
create or replace function public.vault_cfg(p_key text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select value::int from public.app_settings where key = 'vault_' || p_key),
    case p_key
      when 'daily' then 50 when 'ranked_win' then 25 when 'ranked_loss' then 10 when 'frenzy_win' then 15
      when 'login' then 10 when 'ranked_daily_cap' then 20 when 'frenzy_daily_cap' then 3 when 'frenzy_min_players' then 3
      when 'weekly_dailies' then 150 when 'weekly_ranked' then 200 when 'featured_count' then 3 when 'featured_discount' then 20
    end)
$$;

-- ------------------------------------------------------------------ verified activity
-- Daily sets the player actually finished: every prompt settled, with at least one real guess on each.
create or replace function public.vault_dailies(p_player uuid)
returns table (d date, pts int, n int)
language sql stable security definer set search_path = public as $$
  select dc.challenge_date, sum(a.points)::int, array_length(dc.puzzle_ids, 1)
    from public.daily_challenges dc
    join public.attempts a on a.player_id = p_player and a.mode = 'daily'
     and a.challenge_date = dc.challenge_date and a.puzzle_id = any(dc.puzzle_ids)
   where dc.challenge_date <= public.utc_today()
   group by dc.challenge_date, dc.puzzle_ids
  having count(distinct a.puzzle_id) = array_length(dc.puzzle_ids, 1)
     and bool_and(a.status <> 'open' or clock_timestamp() > a.deadline_at + public.deadline_grace())
     and bool_and(a.guess_count >= 1)
$$;

-- Finished ranked matches the player completed (didn't leave, answered at least once).
create or replace function public.vault_ranked(p_player uuid)
returns table (match_id uuid, finished_at timestamptz, won boolean, season int, queue text)
language sql stable security definer set search_path = public as $$
  select m.id, m.finished_at, m.winner_team = rp.team, m.season, m.queue
    from public.ranked_players rp join public.ranked_matches m on m.id = rp.match_id
   where rp.player_id = p_player and m.status = 'finished' and not rp.forfeited
     and exists (select 1 from public.ranked_subs s where s.match_id = m.id and s.player_id = p_player and s.submitted_at is not null)
$$;

create or replace function public.vault_metrics(p_player uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  today date := public.utc_today();
  dailies int; best int; cur int; perfect int; ultra int; placed int; s1_placed int; win_streak int;
  diamond int; sci int; fz int; s1_wins int;
begin
  select count(*), coalesce(sum((pts >= n * 100)::int), 0) into dailies, perfect from public.vault_dailies(p_player);
  -- streaks: islands of consecutive days
  with x as (select d, d - (row_number() over (order by d))::int as grp from public.vault_dailies(p_player)),
       isl as (select min(d) s, max(d) e, count(*) len from x group by grp)
  select coalesce(max(len), 0), coalesce(max(len) filter (where e >= today - 1), 0) into best, cur from isl;
  select count(*) into ultra from public.attempts a join public.accepted_answers aa on aa.id = a.accepted_answer_id
   where a.player_id = p_player and a.mode = 'daily' and aa.tier = 'ULTRALINK';
  select coalesce(max(placements), 0) into placed from public.ranked_ratings where player_id = p_player;
  select coalesce(max(placements), 0) into s1_placed from public.ranked_ratings where player_id = p_player and season = 1;
  with r as (select won, finished_at, (row_number() over (order by finished_at) - row_number() over (partition by won order by finished_at)) g
               from public.vault_ranked(p_player))
  select coalesce(max(c), 0) into win_streak from (select count(*) c from r where won group by g) t;
  select count(*) into diamond from (
    select m.season from public.ranked_players rp join public.ranked_matches m on m.id = rp.match_id
     where rp.player_id = p_player and rp.rp_after >= 1500
     group by m.season having count(distinct m.queue) = 2) t;
  select count(distinct season) into sci from public.ranked_honours where player_id = p_player and honour = 'scientist';
  select count(*) into fz from public.frenzy_results where p_player = any(winners) and players >= public.vault_cfg('frenzy_min_players');
  select count(*) into s1_wins from public.vault_ranked(p_player) where won and season = 1;
  return jsonb_build_object('dailies', dailies, 'streak', cur, 'best_streak', best, 'perfect', perfect, 'ultralinks', ultra,
    'placements', placed, 'win_streak', win_streak, 'diamond_both', diamond, 'scientist_seasons', sci,
    'frenzy_wins', fz, 's1_wins', s1_wins, 's1_placements', s1_placed);
end $$;

-- Credits everything the player has earned but not yet been paid for. Safe to call any number of times:
-- each reward has a unique (reason, source), so retries and double requests can't pay twice.
create or replace function public.vault_sync(p_player uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m jsonb; cur_season int := (select id from public.ranked_seasons where clock_timestamp() between starts_at and ends_at);
begin
  insert into public.vault_wallets (player_id) values (p_player) on conflict do nothing;

  insert into public.vault_ledger (player_id, delta, reason, source)
  select p_player, public.vault_cfg('daily'), 'daily', d::text from public.vault_dailies(p_player)
  on conflict do nothing;

  insert into public.vault_ledger (player_id, delta, reason, source)
  select p_player, case when won then public.vault_cfg('ranked_win') else public.vault_cfg('ranked_loss') end,
         case when won then 'ranked_win' else 'ranked_loss' end, match_id::text
    from (select *, row_number() over (partition by (finished_at at time zone 'utc')::date order by finished_at) rn
            from public.vault_ranked(p_player)) r
   where rn <= public.vault_cfg('ranked_daily_cap')
  on conflict do nothing;

  insert into public.vault_ledger (player_id, delta, reason, source)
  select p_player, public.vault_cfg('frenzy_win'), 'frenzy_win', room_id || ':' || match_no
    from (select *, row_number() over (partition by (finished_at at time zone 'utc')::date order by finished_at) rn
            from public.frenzy_results where p_player = any(winners) and players >= public.vault_cfg('frenzy_min_players')) f
   where rn <= public.vault_cfg('frenzy_daily_cap')
  on conflict do nothing;

  -- weekly challenges (ISO weeks, Monday start, UTC)
  insert into public.vault_ledger (player_id, delta, reason, source)
  select p_player, public.vault_cfg('weekly_dailies'), 'weekly_dailies', w::text
    from (select date_trunc('week', d)::date w from public.vault_dailies(p_player)) t group by w having count(*) >= 5
  on conflict do nothing;
  insert into public.vault_ledger (player_id, delta, reason, source)
  select p_player, public.vault_cfg('weekly_ranked'), 'weekly_ranked', w::text
    from (select date_trunc('week', finished_at at time zone 'utc')::date w from public.vault_ranked(p_player) where won) t
   group by w having count(*) >= 5
  on conflict do nothing;

  -- achievements (completion only; rewards are claimed by the player)
  m := public.vault_metrics(p_player);
  insert into public.player_achievements (player_id, code)
  select p_player, a.code from public.achievements a
   where coalesce((m ->> a.metric)::int, 0) >= a.target
  on conflict do nothing;

  update public.vault_wallets
     set balance = (select coalesce(sum(delta), 0) from public.vault_ledger where player_id = p_player), updated_at = clock_timestamp()
   where player_id = p_player;
end $$;

-- ------------------------------------------------------------------ ownership and looks
create or replace function public.vault_owns(p_player uuid, p_item text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.cosmetic_items where slug = p_item and unlock = 'starter')
      or exists (select 1 from public.vault_inventory where player_id = p_player and item = p_item)
$$;

create or replace function public.vault_default_look() returns jsonb
language sql immutable as $$
  select jsonb_build_object('v', 2, 'base', 'base-classic-spark', 'bulb', 'bulb-gold', 'filament', 'fil-classic',
    'outfit', 'out-navy-hoodie', 'head', null, 'eyes', null, 'acc', null, 'fx', null, 'banner', 'ban-classic')
$$;

-- Converts the old {color, hat, glasses} look to a full Vault look.
create or replace function public.vault_look_from_v1(a jsonb) returns jsonb
language sql immutable as $$
  select case when a is null then null when a ? 'v' then a else
    public.vault_default_look()
      || jsonb_build_object('bulb', 'bulb-' || (array['gold','teal','pink','blue','violet','green','orange','red','white','lilac','lime','cyan'])[coalesce((a->>'color')::int, 0) + 1])
      || jsonb_build_object('head', case when coalesce(a->>'hat', 'none') = 'none' then null else 'hat-' || (a->>'hat') end)
      || jsonb_build_object('eyes', case when coalesce(a->>'glasses', 'none') = 'none' then null else 'eyes-' || (a->>'glasses') end)
  end
$$;

create or replace function public.vault_look(p_player uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(public.vault_look_from_v1((select avatar from public.players where id = p_player)), public.vault_default_look())
$$;

create or replace function public.vault_equip(p_look jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.me(); slot_name text; it text; look jsonb := '{"v": 2}'::jsonb;
  required text[] := array['base', 'bulb', 'filament', 'outfit', 'banner'];
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into public.players (id) values (me) on conflict do nothing;
  foreach slot_name in array array['base', 'bulb', 'filament', 'outfit', 'head', 'eyes', 'acc', 'fx', 'banner'] loop
    it := nullif(p_look ->> slot_name, '');
    if it is null then
      if slot_name = any(required) then it := public.vault_default_look() ->> slot_name; end if;
    else
      if not exists (select 1 from public.cosmetic_items where slug = it and slot = slot_name) then
        raise exception 'item % does not go in %', it, slot_name using errcode = '22023';
      end if;
      if not public.vault_owns(me, it) then raise exception 'you do not own %', it using errcode = '42501'; end if;
    end if;
    look := look || jsonb_build_object(slot_name, it);
  end loop;
  delete from public.vault_equipped where player_id = me;
  insert into public.vault_equipped (player_id, slot, item)
  select me, k, v from jsonb_each_text(look) e(k, v) where k <> 'v' and v is not null;
  update public.players set avatar = look where id = me;
  return look;
end $$;

-- ------------------------------------------------------------------ shop
create or replace function public.vault_featured(p_day date) returns table (item text, price int, was int)
language sql stable security definer set search_path = public as $$
  select slug, (price * (100 - public.vault_cfg('featured_discount')) / 100 / 10 * 10)::int, price
    from public.cosmetic_items
   where unlock = 'shop' and active
   order by md5(p_day::text || slug)
   limit public.vault_cfg('featured_count')
$$;

create or replace function public.vault_buy(p_item text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.me(); it public.cosmetic_items; cost int; bal int; grants text[];
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into public.players (id) values (me) on conflict do nothing;
  select * into it from public.cosmetic_items where slug = p_item;
  if not found or not it.active then raise exception 'item not found' using errcode = 'P0002'; end if;
  if it.unlock <> 'shop' or it.price is null or it.tier in ('ULTRARARE', 'SEASONAL', 'HEIRLOOM') then
    raise exception 'this item can''t be bought' using errcode = '42501';
  end if;
  grants := case when it.slot = 'bundle' then it.contents else array[it.slug] end;
  if not exists (select 1 from unnest(grants) g where not public.vault_owns(me, g)) then
    raise exception 'you already own this' using errcode = '23505';
  end if;

  perform public.vault_sync(me);
  select balance into bal from public.vault_wallets where player_id = me for update;
  cost := coalesce((select f.price from public.vault_featured(public.utc_today()) f where f.item = it.slug), it.price);
  if bal < cost then raise exception 'not enough VOLTS' using errcode = '22023'; end if;

  insert into public.vault_ledger (player_id, delta, reason, source) values (me, -cost, 'purchase', it.slug);
  insert into public.vault_inventory (player_id, item, source)
  select me, g, case when it.slot = 'bundle' then 'bundle' else 'shop' end from unnest(grants) g
   where not public.vault_owns(me, g)
  on conflict do nothing;
  if it.slot = 'bundle' then
    insert into public.vault_inventory (player_id, item, source) values (me, it.slug, 'shop') on conflict do nothing;
  end if;
  update public.vault_wallets set balance = balance - cost, updated_at = clock_timestamp() where player_id = me;
  return public.vault_state();
exception when unique_violation then
  raise exception 'you already own this' using errcode = '23505';
end $$;

create or replace function public.vault_claim(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.me(); a public.achievements; pa public.player_achievements;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  perform public.vault_sync(me);
  select * into a from public.achievements where code = p_code;
  if not found then raise exception 'achievement not found' using errcode = 'P0002'; end if;
  select * into pa from public.player_achievements where player_id = me and code = p_code for update;
  if not found then raise exception 'not completed yet' using errcode = '42501'; end if;
  if pa.claimed_at is null then
    insert into public.vault_inventory (player_id, item, source, season)
    select me, i, 'achievement', a.season from unnest(a.reward_items) i on conflict do nothing;
    if a.reward_volts > 0 then
      insert into public.vault_ledger (player_id, delta, reason, source) values (me, a.reward_volts, 'achievement', a.code)
      on conflict do nothing;
    end if;
    update public.player_achievements set claimed_at = clock_timestamp() where player_id = me and code = p_code;
    perform public.vault_sync(me);
  end if;
  return public.vault_state();
end $$;

create or replace function public.vault_claim_login() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.me();
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into public.players (id) values (me) on conflict do nothing;
  insert into public.vault_ledger (player_id, delta, reason, source)
  values (me, public.vault_cfg('login'), 'login', public.utc_today()::text) on conflict do nothing;
  perform public.vault_sync(me);
  return public.vault_state();
end $$;

-- ------------------------------------------------------------------ reads
create or replace function public.vault_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'items', (select coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'name', name, 'slot', slot, 'tier', tier,
              'description', description, 'unlock', unlock, 'price', price, 'achievement', achievement, 'season', season,
              'contents', contents) order by sort, slug), '[]') from public.cosmetic_items where active),
    'achievements', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'description', description,
              'metric', metric, 'target', target, 'season', season, 'rewardVolts', reward_volts, 'rewardItems', reward_items)
              order by sort), '[]') from public.achievements),
    'seasons', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'startsAt', starts_at, 'endsAt', ends_at) order by id), '[]')
                  from public.ranked_seasons),
    'rewards', jsonb_build_object('daily', public.vault_cfg('daily'), 'rankedWin', public.vault_cfg('ranked_win'),
              'rankedLoss', public.vault_cfg('ranked_loss'), 'frenzyWin', public.vault_cfg('frenzy_win'), 'login', public.vault_cfg('login'),
              'weeklyDailies', public.vault_cfg('weekly_dailies'), 'weeklyRanked', public.vault_cfg('weekly_ranked'),
              'rankedDailyCap', public.vault_cfg('ranked_daily_cap'), 'frenzyDailyCap', public.vault_cfg('frenzy_daily_cap'),
              'frenzyMinPlayers', public.vault_cfg('frenzy_min_players')))
$$;

create or replace function public.vault_state() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.me(); m jsonb; wk date := date_trunc('week', public.utc_today())::date;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into public.players (id) values (me) on conflict do nothing;
  perform public.vault_sync(me);
  m := public.vault_metrics(me);
  return jsonb_build_object(
    'balance', (select balance from public.vault_wallets where player_id = me),
    'owned', (select coalesce(jsonb_agg(jsonb_build_object('item', item, 'acquiredAt', acquired_at, 'source', source, 'season', season)), '[]')
                from public.vault_inventory where player_id = me),
    'look', public.vault_look(me),
    'metrics', m,
    'achievements', (select coalesce(jsonb_agg(jsonb_build_object('code', a.code, 'value', least(coalesce((m ->> a.metric)::int, 0), a.target),
                     'completedAt', pa.completed_at, 'claimedAt', pa.claimed_at)), '[]')
                       from public.achievements a left join public.player_achievements pa on pa.player_id = me and pa.code = a.code),
    'weekly', jsonb_build_object('weekStart', wk,
              'dailies', (select count(*) from public.vault_dailies(me) where d >= wk),
              'rankedWins', (select count(*) from public.vault_ranked(me) where won and finished_at >= wk)),
    'loginClaimed', exists (select 1 from public.vault_ledger where player_id = me and reason = 'login' and source = public.utc_today()::text),
    'featured', (select coalesce(jsonb_agg(jsonb_build_object('item', item, 'price', price, 'was', was)), '[]') from public.vault_featured(public.utc_today())),
    'featuredEndsAt', (public.utc_today() + 1)::timestamp at time zone 'utc',
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('delta', delta, 'reason', reason, 'at', created_at) order by created_at desc), '[]')
                 from (select * from public.vault_ledger where player_id = me order by created_at desc limit 12) l));
end $$;

-- The old editor RPC now saves through the Vault (keeps old clients working until they reload).
create or replace function public.set_avatar(p_color int, p_hat text, p_glasses text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v1 jsonb := public.vault_look_from_v1(jsonb_build_object('color', p_color, 'hat', p_hat, 'glasses', p_glasses));
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if p_color is null or p_color not between 0 and 11 then raise exception 'unknown colour' using errcode = '22023'; end if;
  return public.vault_equip(public.vault_look(public.me())
    || jsonb_build_object('bulb', v1 -> 'bulb', 'head', v1 -> 'head', 'eyes', v1 -> 'eyes'));
end $$;

-- ------------------------------------------------------------------ hooks into existing modes
-- Log every Frenzy match result (rooms are reused, so winners would otherwise be overwritten).
create or replace function public.frenzy_finish(p_room uuid, p_winners uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.frenzy_results (room_id, match_no, winners, players)
  select p_room, r.match_no, coalesce(p_winners, '{}'),
         (select count(*) from public.frenzy_players fp where fp.room_id = p_room and fp.in_match)
    from public.frenzy_rooms r where r.id = p_room and r.status = 'playing'
  on conflict do nothing;
  update public.frenzy_rooms set status = 'finished', winners = coalesce(p_winners, '{}') where id = p_room;
  update public.frenzy_players set ready = false where room_id = p_room;
end $$;

-- Scientist is the top 0.1% of eligible Volt players at the moment a season ends.
create or replace function public.ranked_record_honours(p_season int) returns void
language plpgsql security definer set search_path = public as $$
declare s public.ranked_seasons; q text; pool int; top_n int;
begin
  select * into s from public.ranked_seasons where id = p_season;
  if not found then return; end if;
  foreach q in array array['solo', 'duo'] loop
    with eligible as (
      select rr.player_id, rr.rp from public.ranked_ratings rr
       where rr.queue = q and rr.season = p_season and rr.rp >= 2400 and rr.wins + rr.losses >= 50
         and (select count(*) from public.ranked_players p join public.ranked_matches m on m.id = p.match_id
               where p.player_id = rr.player_id and m.queue = q and m.status = 'finished'
                 and m.finished_at between s.ends_at - interval '14 days' and s.ends_at) >= 10)
    select count(*) into pool from eligible;
    if pool >= public.ranked_cfg('scientist_min_pool') then
      top_n := floor(pool * 0.001);
      insert into public.ranked_honours (season, queue, player_id, honour)
      select p_season, q, player_id, 'scientist' from public.ranked_ratings
       where queue = q and season = p_season and rp >= 2400 order by rp desc limit top_n
      on conflict do nothing;
    end if;
  end loop;
end $$;

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
    perform public.ranked_record_honours(s.id);
    insert into public.ranked_seasons values (s.id + 1, s.ends_at, s.ends_at + make_interval(days => public.ranked_cfg('season_days')::int))
    on conflict do nothing;
    select * into s from public.ranked_seasons where id = s.id + 1;
  end loop;
  return s.id;
end $$;

-- ------------------------------------------------------------------ grants
revoke execute on function public.vault_cfg(text), public.vault_dailies(uuid), public.vault_ranked(uuid), public.vault_metrics(uuid),
  public.vault_sync(uuid), public.vault_owns(uuid, text), public.vault_look(uuid), public.vault_featured(date),
  public.ranked_record_honours(int) from public, anon, authenticated;
revoke execute on function public.vault_equip(jsonb), public.vault_buy(text), public.vault_claim(text), public.vault_claim_login(),
  public.vault_catalog(), public.vault_state() from public, anon;
grant execute on function public.vault_equip(jsonb), public.vault_buy(text), public.vault_claim(text), public.vault_claim_login(),
  public.vault_catalog(), public.vault_state() to authenticated;

-- Existing looks carry over as Vault looks (their colours, hats and glasses are free starter items).
update public.players set avatar = public.vault_look_from_v1(avatar) where avatar is not null and not avatar ? 'v';
-- Generated by scripts/vault-catalog.py. Do not edit by hand.
insert into public.achievements (code, name, description, metric, target, season, reward_volts, reward_items, sort) values
  ('first-light', 'First Light', 'Finish your first daily puzzle set.', 'dailies', 1, null, 50, array['ban-first-light']::text[], 0),
  ('week-warrior', 'Week Warrior', 'Finish the daily on 7 days in a row.', 'best_streak', 7, null, 100, array['acc-torch']::text[], 1),
  ('devotee', 'Daily Devotee', 'Finish 30 daily puzzle sets.', 'dailies', 30, null, 200, array['eyes-starlight']::text[], 2),
  ('perfect-circuit', 'Perfect Circuit', 'Score a perfect 500/500 on a daily (ULTRALINK on all five prompts).', 'perfect', 1, null, 300, array['out-perfect-circuit']::text[], 3),
  ('ultralinker', 'Ultralinker', 'Find an ULTRALINK answer in a daily puzzle.', 'ultralinks', 1, null, 150, array['fil-ultralink']::text[], 4),
  ('eternal-flame', 'The Eternal Flame', 'Finish the daily on 100 days in a row.', 'best_streak', 100, null, 500, array['bulb-eternal-flame']::text[], 5),
  ('ranked-debut', 'Ranked Debut', 'Finish your 5 ranked placement matches.', 'placements', 5, null, 100, array['ban-ranked']::text[], 6),
  ('frenzy-champ', 'Frenzy Champion', 'Win 10 Link Frenzy matches with 3 or more players.', 'frenzy_wins', 10, null, 200, array['head-frenzy-crown']::text[], 7),
  ('unbreakable', 'Unbreakable', 'Win 25 ranked matches in a row.', 'win_streak', 25, null, 300, array['fx-unbreakable']::text[], 8),
  ('rainbow-lightning', 'Rainbow Lightning', 'Reach Diamond in both 1v1 and 2v2 in the same season.', 'diamond_both', 1, null, 500, array['fx-rainbow-lightning']::text[], 9),
  ('the-scientist', 'The Scientist', 'Finish a ranked season as a Scientist (top 0.1% of Volt players).', 'scientist_seasons', 1, null, 1000, array['base-scientist', 'ban-scientist']::text[], 10),
  ('s1-pioneer', 'Season 1 Pioneer', 'Finish your ranked placements during Season 1.', 's1_placements', 5, 1, 100, array['ban-s1']::text[], 11),
  ('s1-founder', 'Season 1 Founder', 'Win 10 ranked matches during Season 1.', 's1_wins', 10, 1, 300, array['out-s1-founder']::text[], 12),
  ('scientist-legacy', 'Scientist Legacy', 'Finish as a Scientist in three separate seasons.', 'scientist_seasons', 3, null, 2500, array['fx-scientist-legacy']::text[], 13),
  ('first-spark', 'The First Spark', 'Finish 1,000 daily puzzle sets.', 'dailies', 1000, null, 2500, array['base-first-spark']::text[], 14)
on conflict (code) do update set name = excluded.name, description = excluded.description, metric = excluded.metric, target = excluded.target,
  season = excluded.season, reward_volts = excluded.reward_volts, reward_items = excluded.reward_items, sort = excluded.sort;

insert into public.cosmetic_items (slug, name, slot, tier, description, unlock, price, achievement, season, contents, sort) values
  ('base-classic-spark', 'Classic Spark', 'base', 'COMMON', 'The original LINKUP bulb: warm, bright and always up for a puzzle.', 'starter', null, null, null, null, 0),
  ('bulb-gold', 'Sunbeam', 'bulb', 'COMMON', 'A sunbeam glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-teal', 'Lagoon', 'bulb', 'COMMON', 'A lagoon glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-pink', 'Bubblegum', 'bulb', 'COMMON', 'A bubblegum glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-blue', 'Skylight', 'bulb', 'COMMON', 'A skylight glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-violet', 'Twilight', 'bulb', 'COMMON', 'A twilight glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-green', 'Clover', 'bulb', 'COMMON', 'A clover glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-orange', 'Ember', 'bulb', 'COMMON', 'A ember glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-red', 'Cherry', 'bulb', 'COMMON', 'A cherry glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-white', 'Moonglow', 'bulb', 'COMMON', 'A moonglow glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-lilac', 'Lavender', 'bulb', 'COMMON', 'A lavender glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-lime', 'Zest', 'bulb', 'COMMON', 'A zest glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('bulb-cyan', 'Glacier', 'bulb', 'COMMON', 'A glacier glass tint. One of the twelve starter colours.', 'starter', null, null, null, null, 10),
  ('fil-classic', 'Classic Filament', 'filament', 'COMMON', 'The trusty zig-zag filament every bulb starts with.', 'starter', null, null, null, null, 20),
  ('out-navy-hoodie', 'Navy Hoodie', 'outfit', 'COMMON', 'Comfy, oversized and very LINKUP navy.', 'starter', null, null, null, null, 30),
  ('hat-cap', 'Cap', 'head', 'COMMON', 'A starter cap for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-beanie', 'Beanie', 'head', 'COMMON', 'A starter beanie for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-tophat', 'Top Hat', 'head', 'COMMON', 'A starter top hat for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-party', 'Party Hat', 'head', 'COMMON', 'A starter party hat for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-wizard', 'Wizard Hat', 'head', 'COMMON', 'A starter wizard hat for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-headphones', 'Headphones', 'head', 'COMMON', 'A starter headphones for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-sprout', 'Sprout', 'head', 'COMMON', 'A starter sprout for your bulb.', 'starter', null, null, null, null, 40),
  ('hat-halo', 'Halo', 'head', 'COMMON', 'A starter halo for your bulb.', 'starter', null, null, null, null, 40),
  ('eyes-round', 'Round Glasses', 'eyes', 'COMMON', 'Starter round glasses.', 'starter', null, null, null, null, 50),
  ('eyes-shades', 'Shades', 'eyes', 'COMMON', 'Starter shades.', 'starter', null, null, null, null, 50),
  ('eyes-star', 'Star Glasses', 'eyes', 'COMMON', 'Starter star glasses.', 'starter', null, null, null, null, 50),
  ('eyes-heart', 'Heart Glasses', 'eyes', 'COMMON', 'Starter heart glasses.', 'starter', null, null, null, null, 50),
  ('eyes-monocle', 'Monocle', 'eyes', 'COMMON', 'Starter monocle.', 'starter', null, null, null, null, 50),
  ('eyes-3d', '3D Glasses', 'eyes', 'COMMON', 'Starter 3d glasses.', 'starter', null, null, null, null, 50),
  ('ban-classic', 'LINKUP Navy', 'banner', 'COMMON', 'The classic midnight-navy nameplate.', 'starter', null, null, null, null, 80),
  ('base-grin', 'Big Grin', 'base', 'COMMON', 'All smiles, all the time.', 'shop', 150, null, null, null, 0),
  ('out-tee', 'White Tee', 'outfit', 'COMMON', 'A crisp white tee. Simple, clean, classic.', 'shop', 100, null, null, null, 30),
  ('out-stripe-tee', 'Striped Tee', 'outfit', 'COMMON', 'Bold stripes for a bold bulb.', 'shop', 150, null, null, null, 30),
  ('fil-spiral', 'Spiral Filament', 'filament', 'COMMON', 'A tight coil that glows a little warmer.', 'shop', 120, null, null, null, 20),
  ('head-bucket', 'Bucket Hat', 'head', 'COMMON', 'Laid-back and sun-ready.', 'shop', 180, null, null, null, 40),
  ('acc-pencil', 'Pencil', 'acc', 'COMMON', 'For jotting down links before the timer runs out.', 'shop', 80, null, null, null, 60),
  ('acc-coffee', 'Coffee Cup', 'acc', 'COMMON', 'Fuel for the daily puzzle.', 'shop', 120, null, null, null, 60),
  ('ban-sunset', 'Sunset', 'banner', 'COMMON', 'Warm orange fading into pink.', 'shop', 150, null, null, null, 80),
  ('ban-mint', 'Mint', 'banner', 'COMMON', 'Cool, fresh, minty green.', 'shop', 120, null, null, null, 80),
  ('bulb-neon-blue', 'Neon Blue', 'bulb', 'UNCOMMON', 'Electric blue glass that pops on any banner.', 'shop', 350, null, null, null, 1010),
  ('bulb-frost', 'Frosted Glass', 'bulb', 'UNCOMMON', 'Soft, frosted white glass with an icy edge.', 'shop', 400, null, null, null, 1010),
  ('base-dreamer', 'Daydreamer', 'base', 'UNCOMMON', 'Half-closed eyes and a content little smile.', 'shop', 300, null, null, null, 1000),
  ('fil-heart', 'Heart Filament', 'filament', 'UNCOMMON', 'Lights up with love for a good link.', 'shop', 300, null, null, null, 1020),
  ('out-blue-hoodie', 'Blue Hoodie', 'outfit', 'UNCOMMON', 'Bright blue, oversized, the Neon look.', 'shop', 300, null, null, null, 1030),
  ('out-puffer', 'Puffer Vest', 'outfit', 'UNCOMMON', 'Puffy, warm and very stylish.', 'shop', 450, null, null, null, 1030),
  ('head-propeller', 'Propeller Cap', 'head', 'UNCOMMON', 'Spins when you''re thinking hard.', 'shop', 300, null, null, null, 1040),
  ('eyes-goggles', 'Lab Goggles', 'eyes', 'UNCOMMON', 'Safety first when experimenting with answers.', 'shop', 300, null, null, null, 1050),
  ('acc-wrench', 'Wrench', 'acc', 'UNCOMMON', 'For tightening loose connections.', 'shop', 280, null, null, null, 1060),
  ('acc-book', 'Puzzle Book', 'acc', 'UNCOMMON', 'A well-thumbed book of word links.', 'shop', 350, null, null, null, 1060),
  ('fx-glow', 'Soft Glow', 'fx', 'UNCOMMON', 'A gentle halo of light around your bulb.', 'shop', 450, null, null, null, 1070),
  ('ban-forest', 'Forest', 'banner', 'UNCOMMON', 'Deep green pines at dusk.', 'shop', 300, null, null, null, 1080),
  ('ban-ocean', 'Deep Ocean', 'banner', 'UNCOMMON', 'Layers of blue going down and down.', 'shop', 300, null, null, null, 1080),
  ('bulb-emerald', 'Emerald', 'bulb', 'RARE', 'Rich emerald glass, the Circuit look.', 'shop', 800, null, null, null, 2010),
  ('bulb-midnight', 'Midnight Glass', 'bulb', 'RARE', 'Dark smoked glass with a bright core.', 'shop', 1000, null, null, null, 2010),
  ('fil-bolt', 'Lightning Filament', 'filament', 'RARE', 'A filament shaped like a bolt of lightning.', 'shop', 700, null, null, null, 2020),
  ('out-dark-tech', 'Circuit Techwear', 'outfit', 'RARE', 'Dark techwear with glowing seams.', 'shop', 850, null, null, null, 2030),
  ('out-midnight-hoodie', 'Midnight Hoodie', 'outfit', 'RARE', 'Near-black with a faint starfield print.', 'shop', 900, null, null, null, 2030),
  ('head-chef', 'Chef''s Hat', 'head', 'RARE', 'For cooking up perfect answers.', 'shop', 700, null, null, null, 2040),
  ('eyes-visor', 'Cyber Visor', 'eyes', 'RARE', 'A glowing visor straight from the future.', 'shop', 650, null, null, null, 2050),
  ('acc-flask', 'Bubbling Flask', 'acc', 'RARE', 'Something is definitely reacting in there.', 'shop', 750, null, null, null, 2060),
  ('fx-sparks', 'Electric Sparks', 'fx', 'RARE', 'Little sparks crackle around your bulb.', 'shop', 1100, null, null, null, 2070),
  ('ban-grid', 'Neon Grid', 'banner', 'RARE', 'A glowing synthwave grid.', 'shop', 800, null, null, null, 2080),
  ('bulb-rose-gold', 'Rose Gold', 'bulb', 'EPIC', 'Polished rose-gold glass.', 'shop', 2000, null, null, null, 3010),
  ('fil-infinity', 'Infinity Filament', 'filament', 'EPIC', 'An endless loop of light.', 'shop', 1600, null, null, null, 3020),
  ('out-varsity', 'Overload Varsity', 'outfit', 'EPIC', 'Red and black varsity jacket, the Overload look.', 'shop', 2200, null, null, null, 3030),
  ('out-tux', 'Midnight Tux', 'outfit', 'EPIC', 'Black tie, bright bulb.', 'shop', 2500, null, null, null, 3030),
  ('head-viking', 'Viking Helm', 'head', 'EPIC', 'Horns up for ranked.', 'shop', 1800, null, null, null, 3040),
  ('eyes-watt-specs', 'Gold-Rim Specs', 'eyes', 'EPIC', 'Professor Watt''s gold-rimmed glasses.', 'shop', 1500, null, null, null, 3050),
  ('acc-lightning-rod', 'Lightning Rod', 'acc', 'EPIC', 'Catches every bolt of inspiration.', 'shop', 2000, null, null, null, 3060),
  ('ban-voltage', 'Voltage', 'banner', 'EPIC', 'Crackling yellow lightning on deep blue.', 'shop', 1800, null, null, null, 3080),
  ('fil-golden', 'Golden Filament', 'filament', 'LEGENDARY', 'A shimmering filament of pure gold.', 'shop', 4500, null, null, null, 4020),
  ('out-lab-coat', 'Professor''s Lab Coat', 'outfit', 'LEGENDARY', 'White lab coat with gold trim.', 'shop', 4000, null, null, null, 4030),
  ('head-royal-crown', 'Royal Crown', 'head', 'LEGENDARY', 'Gold, jewels and absolutely no modesty.', 'shop', 5000, null, null, null, 4040),
  ('fx-golden-shimmer', 'Golden Shimmer', 'fx', 'LEGENDARY', 'Gold light shimmers all around you.', 'shop', 6000, null, null, null, 4070),
  ('ban-aurora', 'Aurora', 'banner', 'LEGENDARY', 'The northern lights, rippling across your nameplate.', 'shop', 5000, null, null, null, 4080),
  ('base-neon', 'Neon', 'base', 'UNCOMMON', 'Cool, confident and always plugged in.', 'bundle', null, null, null, null, 1000),
  ('base-circuit', 'Circuit', 'base', 'RARE', 'Focused, precise, quietly brilliant.', 'bundle', null, null, null, null, 2000),
  ('base-overload', 'Overload', 'base', 'EPIC', 'Cheeky grin, way too much energy.', 'bundle', null, null, null, null, 3000),
  ('base-professor-watt', 'Professor Watt', 'base', 'LEGENDARY', 'Wise, kind and very well read.', 'bundle', null, null, null, null, 4000),
  ('bundle-neon', 'Neon Bundle', 'bundle', 'UNCOMMON', 'The Neon character with the Blue Hoodie. Pair with Glacier glass and Headphones.', 'shop', 500, null, null, array['base-neon', 'out-blue-hoodie']::text[], 1090),
  ('bundle-circuit', 'Circuit Bundle', 'bundle', 'RARE', 'The Circuit character with Emerald glass and Circuit Techwear.', 'shop', 1200, null, null, array['base-circuit', 'bulb-emerald', 'out-dark-tech']::text[], 2090),
  ('bundle-overload', 'Overload Bundle', 'bundle', 'EPIC', 'The Overload character with the Overload Varsity jacket.', 'shop', 3000, null, null, array['base-overload', 'out-varsity']::text[], 3090),
  ('bundle-professor', 'Professor Watt Bundle', 'bundle', 'LEGENDARY', 'Professor Watt with the Lab Coat and Gold-Rim Specs.', 'shop', 7500, null, null, array['base-professor-watt', 'out-lab-coat', 'eyes-watt-specs']::text[], 4090),
  ('ban-first-light', 'First Light', 'banner', 'UNCOMMON', 'A soft dawn glow, for everyone''s first daily.', 'achievement', null, 'first-light', null, null, 1080),
  ('acc-torch', 'Streak Torch', 'acc', 'RARE', 'A little torch that never goes out.', 'achievement', null, 'week-warrior', null, null, 2060),
  ('eyes-starlight', 'Starlight Specs', 'eyes', 'RARE', 'Glasses that twinkle like the night sky.', 'achievement', null, 'devotee', null, null, 2050),
  ('out-perfect-circuit', 'Perfect Circuit Hoodie', 'outfit', 'EPIC', 'An animated green circuit-board hoodie. Only perfect players wear it.', 'achievement', null, 'perfect-circuit', null, null, 3030),
  ('fil-ultralink', 'Prism Filament', 'filament', 'EPIC', 'A rainbow filament for finding the rarest link.', 'achievement', null, 'ultralinker', null, null, 3020),
  ('bulb-eternal-flame', 'The Eternal Flame', 'bulb', 'LEGENDARY', 'An animated orange bulb that burns forever.', 'achievement', null, 'eternal-flame', null, null, 4010),
  ('ban-ranked', 'Ranked Debut', 'banner', 'RARE', 'Steel-blue chevrons for every ranked newcomer.', 'achievement', null, 'ranked-debut', null, null, 2080),
  ('head-frenzy-crown', 'Frenzy Crown', 'head', 'EPIC', 'A crackling crown for the last bulb standing.', 'achievement', null, 'frenzy-champ', null, null, 3040),
  ('fx-unbreakable', 'Unbreakable', 'fx', 'EPIC', 'A pink electrical aura that never breaks.', 'achievement', null, 'unbreakable', null, null, 3070),
  ('fx-rainbow-lightning', 'Rainbow Lightning Aura', 'fx', 'ULTRARARE', 'Prismatic lightning that shifts through every colour.', 'achievement', null, 'rainbow-lightning', null, null, 5070),
  ('base-scientist', 'The Scientist', 'base', 'ULTRARARE', 'A golden-rainbow atom bulb, worn only by Scientists.', 'achievement', null, 'the-scientist', null, null, 5000),
  ('ban-scientist', 'The Scientist', 'banner', 'ULTRARARE', 'Imperial red and white gold with the rainbow atom.', 'achievement', null, 'the-scientist', null, null, 5080),
  ('ban-s1', 'Season 1 Pioneer', 'banner', 'SEASONAL', 'Teal and silver, stamped Season 1.', 'achievement', null, 's1-pioneer', 1, null, 6080),
  ('out-s1-founder', 'Season 1 Founder Jacket', 'outfit', 'SEASONAL', 'A teal bomber jacket with the Season 1 founder patch.', 'achievement', null, 's1-founder', 1, null, 6030),
  ('fx-scientist-legacy', 'Scientist Legacy', 'fx', 'HEIRLOOM', 'A white-gold atomic glow. The rarest aura in LINKUP.', 'achievement', null, 'scientist-legacy', null, null, 7070),
  ('base-first-spark', 'The First Spark', 'base', 'HEIRLOOM', 'A radiant white-gold bulb for 1,000 dailies of devotion.', 'achievement', null, 'first-spark', null, null, 7000)
on conflict (slug) do update set name = excluded.name, slot = excluded.slot, tier = excluded.tier, description = excluded.description,
  unlock = excluded.unlock, price = excluded.price, achievement = excluded.achievement, season = excluded.season, contents = excluded.contents,
  sort = excluded.sort, active = true;

