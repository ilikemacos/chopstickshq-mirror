-- Schema for the rNitro download counter (/api/dl-count).
-- Run once in the Supabase SQL editor:
--   https://supabase.com/dashboard/project/bohvvkpvnnqigfdcuhnp/sql/new
--
-- Design note: the anon role gets SELECT and EXECUTE only — never INSERT,
-- UPDATE or DELETE. All writes go through bump_download(), which is
-- SECURITY DEFINER and can only ever add exactly 1 to one of five known
-- rows. So even if the anon key leaks, the worst anyone can do is inflate a
-- counter one click at a time; they cannot set it, reset it, or write
-- anything else.

create table if not exists public.download_counts (
  kind  text primary key,
  count bigint not null default 0
);

insert into public.download_counts (kind, count) values
  ('zip', 0), ('pkg', 0), ('dmg', 0), ('sh', 0), ('copy', 0)
on conflict (kind) do nothing;

alter table public.download_counts enable row level security;

drop policy if exists "counts are publicly readable" on public.download_counts;
create policy "counts are publicly readable"
  on public.download_counts
  for select
  to anon, authenticated
  using (true);

-- Increment-by-one, with the kind validated server-side.
create or replace function public.bump_download(p_kind text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  new_count bigint;
begin
  if p_kind not in ('zip', 'pkg', 'dmg', 'sh', 'copy') then
    raise exception 'invalid kind: %', p_kind;
  end if;

  update public.download_counts
     set count = count + 1
   where kind = p_kind
  returning count into new_count;

  return new_count;
end;
$$;

revoke all on function public.bump_download(text) from public;
grant execute on function public.bump_download(text) to anon, authenticated;
