insert into public.download_counts (kind, count) values
  ('arena_zip', 0), ('arena_sh', 0), ('arena_copy', 0)
on conflict (kind) do nothing;

create or replace function public.bump_download(p_kind text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  new_count bigint;
begin
  if p_kind not in (
    'zip', 'pkg', 'dmg', 'sh', 'copy',
    'arena_zip', 'arena_sh', 'arena_copy'
  ) then
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
