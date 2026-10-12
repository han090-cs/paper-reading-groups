-- Paper Reading Groups: Supabase schema + row-level access policies.
-- Run this file in the Supabase SQL Editor, or apply it with the Supabase CLI.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text not null default 'Member',
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now()
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  member_role text not null default 'member' check (member_role in ('member', 'manager')),
  added_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table if not exists public.papers (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  title text not null,
  author text,
  doi text,
  source_url text,
  topic text,
  published_year integer check (published_year is null or published_year between 1500 and 2200),
  deadline date,
  pdf_path text,
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.reading_progress (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'not_started' check (status in ('not_started', 'reading', 'completed')),
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (paper_id, user_id)
);

create table if not exists public.research_notes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  paper_id uuid references public.papers(id) on delete set null,
  author_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  content text not null,
  visibility text not null default 'private' check (visibility in ('private', 'group_shared')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.discussions (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  paper_id uuid references public.papers(id) on delete cascade,
  note_id uuid references public.research_notes(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  content text not null,
  created_at timestamptz not null default now(),
  constraint discussion_parent_required check (paper_id is not null or note_id is not null)
);

-- Keeps names from the pre-Supabase app. These are archival rows until a real login is linked.
create table if not exists public.legacy_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid references public.groups(id) on delete set null,
  legacy_student_id text,
  display_name text not null,
  assigned_user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.legacy_members alter column group_id drop not null;
alter table public.legacy_members drop constraint if exists legacy_members_group_id_fkey;
alter table public.legacy_members add constraint legacy_members_group_id_fkey foreign key (group_id) references public.groups(id) on delete set null;

create table if not exists public.backup_runs (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  storage_path text not null,
  backup_bytes bigint not null default 0,
  details jsonb not null default '{}'::jsonb,
  restored_at timestamptz
);

create index if not exists idx_group_members_user on public.group_members(user_id);
create index if not exists idx_papers_group_deadline on public.papers(group_id, deadline);
create index if not exists idx_progress_user_status on public.reading_progress(user_id, status);
create index if not exists idx_notes_group_visibility on public.research_notes(group_id, visibility);
create index if not exists idx_discussions_group_created on public.discussions(group_id, created_at);
create index if not exists idx_legacy_members_group on public.legacy_members(group_id);

-- Keep update timestamps consistent.
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists groups_touch_updated_at on public.groups;
create trigger groups_touch_updated_at before update on public.groups
for each row execute function public.touch_updated_at();
drop trigger if exists papers_touch_updated_at on public.papers;
create trigger papers_touch_updated_at before update on public.papers
for each row execute function public.touch_updated_at();
drop trigger if exists progress_touch_updated_at on public.reading_progress;
create trigger progress_touch_updated_at before update on public.reading_progress
for each row execute function public.touch_updated_at();
drop trigger if exists notes_touch_updated_at on public.research_notes;
create trigger notes_touch_updated_at before update on public.research_notes
for each row execute function public.touch_updated_at();

-- Newly registered users are members by default. No browser client can self-assign admin.
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name, role)
  values (
    new.id,
    new.email,
    coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), split_part(coalesce(new.email, 'member'), '@', 1)),
    'member'
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
for each row execute function public.handle_new_auth_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;

create or replace function public.is_group_member(target_group uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (
    select 1 from public.group_members gm where gm.group_id = target_group and gm.user_id = auth.uid()
  );
$$;

create or replace function public.is_group_manager(target_group uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_admin()
    or exists (select 1 from public.groups g where g.id = target_group and g.created_by = auth.uid())
    or exists (select 1 from public.group_members gm where gm.group_id = target_group and gm.user_id = auth.uid() and gm.member_role = 'manager');
$$;

create or replace function public.can_manage_paper(target_paper uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.papers p where p.id = target_paper and public.is_group_manager(p.group_id));
$$;

-- Invalid object paths must fail closed rather than raising a UUID cast error in Storage RLS.
create or replace function public.try_uuid(value text)
returns uuid language plpgsql immutable set search_path = public as $$
begin
  return value::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

-- Prevent self-promotion even if a user manually calls the Data API.
create or replace function public.protect_profile_role()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.role is distinct from old.role
     and current_user not in ('postgres', 'supabase_admin', 'service_role')
     and not public.is_admin() then
    raise exception 'Only an administrator can change profile roles';
  end if;
  if new.email is distinct from old.email
     and current_user not in ('postgres', 'supabase_admin', 'service_role')
     and not public.is_admin() then
    raise exception 'Only an administrator can change profile email metadata';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_profile_role_trigger on public.profiles;
create trigger protect_profile_role_trigger before update on public.profiles
for each row execute function public.protect_profile_role();

-- Enable RLS on every application table.
alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.papers enable row level security;
alter table public.reading_progress enable row level security;
alter table public.research_notes enable row level security;
alter table public.discussions enable row level security;
alter table public.legacy_members enable row level security;
alter table public.backup_runs enable row level security;

-- Drop policy names first so this migration can be safely re-applied.
do $$ declare r record; begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname='public' and tablename in ('profiles','groups','group_members','papers','reading_progress','research_notes','discussions','legacy_members','backup_runs')
  loop execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename); end loop;
end $$;

create policy profiles_select_self_or_admin on public.profiles for select to authenticated
using (id = auth.uid() or public.is_admin());
create policy profiles_update_self_or_admin on public.profiles for update to authenticated
using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());
create policy profiles_insert_admin on public.profiles for insert to authenticated
with check (public.is_admin());
create policy profiles_delete_admin on public.profiles for delete to authenticated
using (public.is_admin());

create policy groups_select_member_or_admin on public.groups for select to authenticated
using (public.is_group_member(id) or created_by = auth.uid());
create policy groups_insert_admin on public.groups for insert to authenticated
with check (public.is_admin());
create policy groups_update_admin on public.groups for update to authenticated
using (public.is_admin()) with check (public.is_admin());
create policy groups_delete_admin on public.groups for delete to authenticated
using (public.is_admin());

create policy group_members_select_scope on public.group_members for select to authenticated
using (user_id = auth.uid() or public.is_admin() or public.is_group_manager(group_id));
create policy group_members_insert_manager on public.group_members for insert to authenticated
with check ((public.is_admin() or public.is_group_manager(group_id)) and (added_by = auth.uid() or public.is_admin()));
create policy group_members_update_manager on public.group_members for update to authenticated
using (public.is_admin() or public.is_group_manager(group_id))
with check (public.is_admin() or public.is_group_manager(group_id));
create policy group_members_delete_manager_or_self on public.group_members for delete to authenticated
using (user_id = auth.uid() or public.is_admin() or public.is_group_manager(group_id));

create policy papers_select_group_members on public.papers for select to authenticated
using (public.is_group_member(group_id));
create policy papers_insert_group_managers on public.papers for insert to authenticated
with check (public.is_admin() or (public.is_group_manager(group_id) and created_by = auth.uid()));
create policy papers_update_group_managers on public.papers for update to authenticated
using (public.is_group_manager(group_id)) with check (public.is_group_manager(group_id));
create policy papers_delete_group_managers on public.papers for delete to authenticated
using (public.is_group_manager(group_id));

create policy progress_select_owner_manager on public.reading_progress for select to authenticated
using (user_id = auth.uid() or public.is_admin() or public.can_manage_paper(paper_id));
create policy progress_insert_owner on public.reading_progress for insert to authenticated
with check ((user_id = auth.uid() or public.is_admin()) and exists (select 1 from public.papers p where p.id = paper_id and public.is_group_member(p.group_id)));
create policy progress_update_owner_or_admin on public.reading_progress for update to authenticated
using (user_id = auth.uid() or public.is_admin())
with check ((user_id = auth.uid() or public.is_admin()) and exists (select 1 from public.papers p where p.id = paper_id and public.is_group_member(p.group_id)));
create policy progress_delete_owner_or_admin on public.reading_progress for delete to authenticated
using (user_id = auth.uid() or public.is_admin());

create policy notes_select_visibility on public.research_notes for select to authenticated
using (
  public.is_admin()
  or author_id = auth.uid()
  or (visibility = 'group_shared' and public.is_group_member(group_id))
);
create policy notes_insert_member on public.research_notes for insert to authenticated
with check ((author_id = auth.uid() or public.is_admin()) and public.is_group_member(group_id)
  and (paper_id is null or exists (select 1 from public.papers p where p.id=paper_id and p.group_id=research_notes.group_id)));
create policy notes_update_author_or_admin on public.research_notes for update to authenticated
using (author_id = auth.uid() or public.is_admin())
with check ((author_id = auth.uid() or public.is_admin()) and public.is_group_member(group_id));
create policy notes_delete_author_or_admin on public.research_notes for delete to authenticated
using (author_id = auth.uid() or public.is_admin());

create policy discussions_select_group_members on public.discussions for select to authenticated
using (public.is_group_member(group_id) and (paper_id is null or exists (select 1 from public.papers p where p.id = discussions.paper_id and p.group_id = discussions.group_id))
  and (note_id is null or exists (
  select 1 from public.research_notes n where n.id = discussions.note_id and n.group_id = discussions.group_id
    and (n.visibility = 'group_shared' or n.author_id = auth.uid() or public.is_admin())
)));
create policy discussions_insert_group_members on public.discussions for insert to authenticated
with check ((author_id = auth.uid() or public.is_admin()) and public.is_group_member(group_id) and (paper_id is null or exists (select 1 from public.papers p where p.id = discussions.paper_id and p.group_id = discussions.group_id))
  and (note_id is null or exists (
  select 1 from public.research_notes n where n.id = discussions.note_id and n.group_id = discussions.group_id
    and (n.visibility = 'group_shared' or n.author_id = auth.uid() or public.is_admin())
)));
create policy discussions_delete_author_or_admin on public.discussions for delete to authenticated
using (author_id = auth.uid() or public.is_admin() or (public.is_group_manager(group_id) and (note_id is null or exists (
  select 1 from public.research_notes n where n.id = discussions.note_id and n.group_id = discussions.group_id and n.visibility = 'group_shared'
))));

create policy legacy_members_select_admin_or_manager on public.legacy_members for select to authenticated
using (public.is_admin() or public.is_group_manager(group_id));
create policy legacy_members_insert_admin on public.legacy_members for insert to authenticated
with check (public.is_admin());
create policy legacy_members_update_admin on public.legacy_members for update to authenticated
using (public.is_admin()) with check (public.is_admin());
create policy legacy_members_delete_admin on public.legacy_members for delete to authenticated
using (public.is_admin());

create policy backup_runs_select_admin on public.backup_runs for select to authenticated using (public.is_admin());
create policy backup_runs_insert_admin on public.backup_runs for insert to authenticated with check (public.is_admin() and created_by = auth.uid());
create policy backup_runs_update_admin on public.backup_runs for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy backup_runs_delete_admin on public.backup_runs for delete to authenticated using (public.is_admin());

-- Private buckets. Nothing is publicly readable.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('papers-private', 'papers-private', false, 52428800, array['application/pdf']),
       ('backups-private', 'backups-private', false, 52428800, array['application/json','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Storage object paths for papers must be: <group-uuid>/<paper-uuid>/<filename>.pdf
-- Admins/managers can add or replace PDFs; group members can read them.
do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'paper_groups_%' or schemaname='storage' and tablename='objects' and policyname like 'private_backup_admin_%'
  loop execute format('drop policy if exists %I on storage.objects', r.policyname); end loop;
end $$;
create policy paper_groups_read_member on storage.objects for select to authenticated
using (bucket_id = 'papers-private' and public.is_group_member(public.try_uuid((storage.foldername(name))[1])));
create policy paper_groups_insert_manager on storage.objects for insert to authenticated
with check (bucket_id = 'papers-private' and public.is_group_manager(public.try_uuid((storage.foldername(name))[1])));
create policy paper_groups_update_manager on storage.objects for update to authenticated
using (bucket_id = 'papers-private' and public.is_group_manager(public.try_uuid((storage.foldername(name))[1])))
with check (bucket_id = 'papers-private' and public.is_group_manager(public.try_uuid((storage.foldername(name))[1])));
create policy paper_groups_delete_manager on storage.objects for delete to authenticated
using (bucket_id = 'papers-private' and public.is_group_manager(public.try_uuid((storage.foldername(name))[1])));

create policy private_backup_admin_read on storage.objects for select to authenticated
using (bucket_id = 'backups-private' and public.is_admin());
create policy private_backup_admin_insert on storage.objects for insert to authenticated
with check (bucket_id = 'backups-private' and public.is_admin());
create policy private_backup_admin_update on storage.objects for update to authenticated
using (bucket_id = 'backups-private' and public.is_admin())
with check (bucket_id = 'backups-private' and public.is_admin());
create policy private_backup_admin_delete on storage.objects for delete to authenticated
using (bucket_id = 'backups-private' and public.is_admin());

-- Explicit API grants; RLS policies above remain the row-level authorization layer.
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles, public.groups, public.group_members,
  public.papers, public.reading_progress, public.research_notes, public.discussions,
  public.legacy_members, public.backup_runs to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.is_group_member(uuid) to authenticated;
grant execute on function public.is_group_manager(uuid) to authenticated;
grant execute on function public.can_manage_paper(uuid) to authenticated;
grant execute on function public.try_uuid(text) to authenticated;

-- After the first user signs up, promote that account in the SQL Editor:
-- update public.profiles set role = 'admin' where email = 'you@example.com';
