create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  user_id text not null unique default ('CH' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  username text not null unique check (username = lower(username) and username ~ '^[a-z0-9_]{3,24}$'),
  full_name text not null check (char_length(full_name) between 1 and 80),
  bio text not null default '' check (char_length(bio) <= 160),
  avatar_url text,
  discoverable boolean not null default true,
  show_online_status boolean not null default true,
  show_last_seen boolean not null default true,
  is_online boolean not null default false,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.login_aliases (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  email text not null
);
alter table public.login_aliases enable row level security;

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(),
  unique (sender_id, receiver_id),
  check (sender_id <> receiver_id)
);

create table if not exists public.friendships (
  user_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

create table if not exists public.blocked_users (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  name text check (name is null or char_length(name) between 1 and 80),
  description text not null default '' check (char_length(description) <= 300),
  avatar_url text,
  is_group boolean not null default false,
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  joined_at timestamptz not null default now(),
  last_read_at timestamptz,
  primary key (conversation_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  content text not null check (char_length(content) between 1 and 10000),
  type text not null default 'text' check (type in ('text', 'image', 'video', 'audio', 'file')),
  attachment_url text,
  reply_to uuid references public.messages(id) on delete set null,
  forwarded_from uuid references public.messages(id) on delete set null,
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  check ((type = 'text' and attachment_url is null) or (type <> 'text' and attachment_url is not null))
);

create table if not exists public.message_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  unique (message_id, user_id)
);

create table if not exists public.message_receipts (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz,
  primary key (message_id, user_id)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  type text not null,
  title text not null,
  body text not null default '',
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists messages_conversation_created_idx on public.messages (conversation_id, created_at desc);
create index if not exists conversation_members_user_idx on public.conversation_members (user_id, conversation_id);
create index if not exists friend_requests_receiver_status_idx on public.friend_requests (receiver_id, status, created_at desc);
create index if not exists notifications_user_created_idx on public.notifications (user_id, created_at desc);

create or replace function public.is_conversation_member(conversation uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.conversation_members where conversation_id = $1 and user_id = auth.uid()) $$;

create or replace function public.is_conversation_admin(conversation uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.conversation_members where conversation_id = $1 and user_id = auth.uid() and role = 'admin') $$;

create or replace function public.is_conversation_creator(conversation uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.conversations where id = $1 and created_by = auth.uid()) $$;

create or replace function public.are_friends(other_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.friendships where user_id = auth.uid() and friend_id = $1) $$;

create or replace function public.shares_conversation_with(other_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.conversation_members mine
    join public.conversation_members theirs using (conversation_id)
    where mine.user_id = auth.uid() and theirs.user_id = $1
  )
$$;

create or replace function public.profiles_block_each_other(other_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp
as $$ select exists (select 1 from public.blocked_users where (blocker_id = auth.uid() and blocked_id = other_id) or (blocker_id = other_id and blocked_id = auth.uid())) $$;

create or replace function public.set_profile_defaults()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
declare candidate text;
begin
  candidate := lower(coalesce(new.raw_user_meta_data->>'username', ''));
  if candidate !~ '^[a-z0-9_]{3,24}$' then
    candidate := 'user_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  insert into public.profiles (id, username, full_name)
  values (new.id, candidate, coalesce(nullif(left(new.raw_user_meta_data->>'full_name', 80), ''), 'New Chatter'));
  insert into public.login_aliases (user_id, username, email) values (new.id, candidate, new.email);
  return new;
end;
$$;

create or replace function public.sync_login_alias()
returns trigger language plpgsql security definer set search_path = public, auth, pg_temp
as $$
begin
  insert into public.login_aliases (user_id, username, email)
  values (new.id, (select username from public.profiles where id = new.id), new.email)
  on conflict (user_id) do update set username = excluded.username, email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.set_profile_defaults();
drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated after update of email on auth.users
for each row when (old.email is distinct from new.email)
execute procedure public.sync_login_alias();

create or replace function public.sync_profile_login_alias()
returns trigger language plpgsql security definer set search_path = public, auth, pg_temp
as $$
begin
  update public.login_aliases set username = new.username where user_id = new.id;
  return new;
end;
$$;
drop trigger if exists profile_username_alias_update on public.profiles;
create trigger profile_username_alias_update after update of username on public.profiles
for each row when (old.username is distinct from new.username)
execute procedure public.sync_profile_login_alias();

insert into public.login_aliases (user_id, username, email)
select p.id, p.username, u.email from public.profiles p join auth.users u on u.id = p.id
on conflict (user_id) do update set username = excluded.username, email = excluded.email;

create or replace function public.search_profiles(search_term text)
returns table (id uuid, user_id text, username text, full_name text, avatar_url text, is_online boolean, last_seen_at timestamptz, bio text)
language sql stable security definer set search_path = public, pg_temp
as $$
  select p.id, p.user_id, p.username, p.full_name, p.avatar_url,
    (p.is_online and p.show_online_status and p.last_seen_at > now() - interval '2 minutes') as is_online,
    case when p.show_last_seen then p.last_seen_at else null end as last_seen_at,
    p.bio
  from public.profiles p
  where auth.uid() is not null
    and p.discoverable
    and (lower(p.username) = lower(trim(both '@' from search_term)) or upper(p.user_id) = upper(search_term))
    and p.id <> auth.uid()
    and not public.profiles_block_each_other(p.id)
  limit 1
$$;

create or replace function public.get_profile_status(other_user uuid)
returns table (is_online boolean, last_seen_at timestamptz)
language sql stable security definer set search_path = public, pg_temp
as $$
  select
    (p.is_online and p.show_online_status and p.last_seen_at > now() - interval '2 minutes'),
    case when p.show_last_seen then p.last_seen_at else null end
  from public.profiles p
  where auth.uid() is not null and p.id = other_user
    and not public.profiles_block_each_other(other_user)
    and (p.discoverable or public.are_friends(other_user) or public.shares_conversation_with(other_user))
$$;

create or replace function public.get_or_create_dm(other_user uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp
as $$
declare current_user_id uuid := auth.uid(); conversation uuid;
begin
  if current_user_id is null or other_user = current_user_id then raise exception 'Invalid conversation participants'; end if;
  if not exists (select 1 from public.profiles where id = other_user and (discoverable or public.are_friends(other_user))) then raise exception 'This account cannot be contacted'; end if;
  if public.profiles_block_each_other(other_user) then raise exception 'This conversation is not available'; end if;
  select c.id into conversation
  from public.conversations c
  where not c.is_group
    and exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = current_user_id)
    and exists (select 1 from public.conversation_members m where m.conversation_id = c.id and m.user_id = other_user)
    and (select count(*) from public.conversation_members m where m.conversation_id = c.id) = 2
  limit 1;
  if conversation is null then
    insert into public.conversations (created_by, is_group) values (current_user_id, false) returning id into conversation;
    insert into public.conversation_members (conversation_id, user_id, role)
    values (conversation, current_user_id, 'admin'), (conversation, other_user, 'member');
  end if;
  return conversation;
end;
$$;

create or replace function public.accept_friend_request(request_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare request_row public.friend_requests%rowtype;
begin
  select * into request_row from public.friend_requests
  where id = request_id and receiver_id = auth.uid() and status = 'pending'
  for update;
  if not found then raise exception 'This friend request is no longer available'; end if;
  if public.profiles_block_each_other(request_row.sender_id) then raise exception 'This friend request is no longer available'; end if;
  insert into public.friendships (user_id, friend_id)
  values (request_row.receiver_id, request_row.sender_id), (request_row.sender_id, request_row.receiver_id)
  on conflict do nothing;
  update public.friend_requests set status = 'accepted' where id = request_row.id;
end;
$$;

create or replace function public.remove_friend(other_user uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.friendships where user_id = auth.uid() and friend_id = other_user
  ) then raise exception 'Contact not found'; end if;
  delete from public.friendships
  where (user_id = auth.uid() and friend_id = other_user)
     or (user_id = other_user and friend_id = auth.uid());
end;
$$;

create or replace function public.leave_group(group_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare group_row public.conversations%rowtype; next_admin uuid;
begin
  select * into group_row from public.conversations
  where id = group_id and is_group
  for update;
  if not found or not exists (
    select 1 from public.conversation_members where conversation_id = group_id and user_id = auth.uid()
  ) then raise exception 'Group not found'; end if;

  select user_id into next_admin from public.conversation_members
  where conversation_id = group_id and user_id <> auth.uid()
  order by joined_at limit 1;
  if next_admin is null then
    delete from public.conversations where id = group_id;
    return;
  end if;

  if exists (
    select 1 from public.conversation_members where conversation_id = group_id and user_id = auth.uid() and role = 'admin'
  ) and not exists (
    select 1 from public.conversation_members where conversation_id = group_id and user_id <> auth.uid() and role = 'admin'
  ) then
    update public.conversation_members set role = 'admin'
    where conversation_id = group_id and user_id = next_admin;
  end if;
  if group_row.created_by = auth.uid() then
    update public.conversations set created_by = next_admin where id = group_id;
  end if;
  delete from public.conversation_members where conversation_id = group_id and user_id = auth.uid();
end;
$$;

create or replace function public.notify_friend_request()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.status = 'pending' then
    insert into public.notifications (user_id, actor_id, type, title, body, data)
    values (new.receiver_id, new.sender_id, 'friend_request', 'New friend request',
      (select full_name || ' sent you a friend request.' from public.profiles where id = new.sender_id),
      jsonb_build_object('request_id', new.id));
  end if;
  return new;
end;
$$;
drop trigger if exists friend_request_notification on public.friend_requests;
create trigger friend_request_notification after insert on public.friend_requests
for each row execute procedure public.notify_friend_request();

create or replace function public.notify_group_member_added()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
declare group_row public.conversations%rowtype;
begin
  select * into group_row from public.conversations where id = new.conversation_id;
  if group_row.is_group and new.user_id <> group_row.created_by then
    insert into public.notifications (user_id, actor_id, type, title, body, data)
    values (new.user_id, auth.uid(), 'group_invitation', 'Added to a group',
      'You were added to ' || coalesce(group_row.name, 'a group') || '.',
      jsonb_build_object('conversation_id', new.conversation_id));
  end if;
  return new;
end;
$$;
drop trigger if exists group_member_notification on public.conversation_members;
create trigger group_member_notification after insert on public.conversation_members
for each row execute procedure public.notify_group_member_added();

create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update public.conversations set updated_at = new.created_at where id = new.conversation_id;
  insert into public.notifications (user_id, actor_id, type, title, body, data)
  select cm.user_id, new.sender_id, 'message', 'New message',
    (select full_name from public.profiles where id = new.sender_id) || ' sent you a message.',
    jsonb_build_object('conversation_id', new.conversation_id, 'message_id', new.id)
  from public.conversation_members cm
  where cm.conversation_id = new.conversation_id and cm.user_id <> new.sender_id;
  return new;
end;
$$;
drop trigger if exists message_notification on public.messages;
create trigger message_notification after insert on public.messages
for each row execute procedure public.notify_new_message();

create or replace function public.add_message_receipts()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  insert into public.message_receipts (message_id, user_id, read_at)
  select new.id, cm.user_id, null from public.conversation_members cm
  where cm.conversation_id = new.conversation_id and cm.user_id <> new.sender_id;
  return new;
end;
$$;
drop trigger if exists message_receipt_insert on public.messages;
create trigger message_receipt_insert after insert on public.messages
for each row execute procedure public.add_message_receipts();

create or replace function public.blocked_user_cleanup()
returns trigger language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  delete from public.friendships where (user_id = new.blocker_id and friend_id = new.blocked_id) or (user_id = new.blocked_id and friend_id = new.blocker_id);
  update public.friend_requests set status = 'cancelled'
  where status = 'pending'
    and ((sender_id = new.blocker_id and receiver_id = new.blocked_id) or (sender_id = new.blocked_id and receiver_id = new.blocker_id));
  delete from public.conversation_members cm using public.conversations c
  where cm.conversation_id = c.id and not c.is_group
    and cm.user_id in (new.blocker_id, new.blocked_id)
    and exists (
      select 1 from public.conversation_members other
      where other.conversation_id = c.id
        and other.user_id = case when cm.user_id = new.blocker_id then new.blocked_id else new.blocker_id end
    );
  return new;
end;
$$;
drop trigger if exists blocked_user_cleanup_trigger on public.blocked_users;
create trigger blocked_user_cleanup_trigger after insert on public.blocked_users
for each row execute procedure public.blocked_user_cleanup();

alter table public.profiles enable row level security;
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.blocked_users enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reactions enable row level security;
alter table public.message_receipts enable row level security;
alter table public.notifications enable row level security;

create policy "Profiles are visible to the owner and discoverable users" on public.profiles
for select to authenticated using (id = auth.uid() or ((discoverable or public.are_friends(id) or public.shares_conversation_with(id)) and not public.profiles_block_each_other(id)));
create policy "Users create their own profile" on public.profiles
for insert to authenticated with check (id = auth.uid());
create policy "Users update their own profile" on public.profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "Participants can view requests" on public.friend_requests
for select to authenticated using (sender_id = auth.uid() or receiver_id = auth.uid());
create policy "Users send requests" on public.friend_requests
for insert to authenticated with check (
  sender_id = auth.uid()
  and exists (select 1 from public.profiles p where p.id = receiver_id and p.discoverable)
  and not public.profiles_block_each_other(receiver_id)
);
create policy "Request recipients can respond" on public.friend_requests
for update to authenticated
using ((receiver_id = auth.uid() or sender_id = auth.uid()) and status = 'pending')
with check ((receiver_id = auth.uid() and status in ('rejected')) or (sender_id = auth.uid() and status = 'cancelled'));
create policy "Request participants can remove requests" on public.friend_requests
for delete to authenticated using (sender_id = auth.uid() or receiver_id = auth.uid());

create policy "Users view their friendships" on public.friendships
for select to authenticated using (user_id = auth.uid() or friend_id = auth.uid());
create policy "Users add friendships for themselves" on public.friendships
for insert to authenticated with check (false);
create policy "Users remove their friendships" on public.friendships
for delete to authenticated using (user_id = auth.uid() or friend_id = auth.uid());

create policy "Users manage their blocks" on public.blocked_users
for all to authenticated using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

create policy "Members view conversations" on public.conversations
for select to authenticated using (public.is_conversation_member(id) or created_by = auth.uid());
create policy "Users create conversations" on public.conversations
for insert to authenticated with check (created_by = auth.uid() and is_group);
create policy "Group admins update conversations" on public.conversations
for update to authenticated using (public.is_conversation_admin(id)) with check (public.is_conversation_admin(id));
create policy "Group admins delete conversations" on public.conversations
for delete to authenticated using (is_group and public.is_conversation_admin(id));

create policy "Members see conversation membership" on public.conversation_members
for select to authenticated using (public.is_conversation_member(conversation_id));
create policy "Conversation admins or creators add members" on public.conversation_members
for insert to authenticated with check (
  (public.is_conversation_admin(conversation_id) or public.is_conversation_creator(conversation_id))
  and (user_id = auth.uid() or exists (
    select 1 from public.friendships where user_id = auth.uid() and friend_id = conversation_members.user_id
  ))
);
create policy "Members update own read state; admins update members" on public.conversation_members
for update to authenticated using (user_id = auth.uid() or public.is_conversation_admin(conversation_id))
with check ((user_id = auth.uid() and role = 'member') or public.is_conversation_admin(conversation_id));
create policy "Members leave or admins remove members" on public.conversation_members
for delete to authenticated using (user_id = auth.uid() or public.is_conversation_admin(conversation_id));

create policy "Members read conversation messages" on public.messages
for select to authenticated using (public.is_conversation_member(conversation_id));
create policy "Members send messages" on public.messages
for insert to authenticated with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id)
  and not exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = public.messages.conversation_id and cm.user_id <> auth.uid()
      and public.profiles_block_each_other(cm.user_id)
  )
  and (type = 'text' or attachment_url like auth.uid()::text || '/' || conversation_id::text || '/%')
);
create policy "Senders update their messages" on public.messages
for update to authenticated using (sender_id = auth.uid() and public.is_conversation_member(conversation_id))
with check (sender_id = auth.uid() and public.is_conversation_member(conversation_id)
  and (type = 'text' or attachment_url like auth.uid()::text || '/' || conversation_id::text || '/%'));
create policy "Senders delete their messages" on public.messages
for delete to authenticated using (sender_id = auth.uid() and public.is_conversation_member(conversation_id));

create policy "Members read reactions" on public.message_reactions
for select to authenticated using (exists (select 1 from public.messages m where m.id = message_id and public.is_conversation_member(m.conversation_id)));
create policy "Members add own reactions" on public.message_reactions
for insert to authenticated with check (user_id = auth.uid() and exists (select 1 from public.messages m where m.id = message_id and public.is_conversation_member(m.conversation_id)));
create policy "Users update own reactions" on public.message_reactions
for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Users remove own reactions" on public.message_reactions
for delete to authenticated using (user_id = auth.uid());

create policy "Members read message receipts" on public.message_receipts
for select to authenticated using (user_id = auth.uid() or exists (select 1 from public.messages m where m.id = message_id and m.sender_id = auth.uid()));
create policy "Recipients update own receipts" on public.message_receipts
for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "Users view own notifications" on public.notifications
for select to authenticated using (user_id = auth.uid());
create policy "Users update own notifications" on public.notifications
for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on function public.is_conversation_member(uuid) from public, anon;
revoke all on function public.is_conversation_admin(uuid) from public, anon;
revoke all on function public.is_conversation_creator(uuid) from public, anon;
revoke all on function public.are_friends(uuid) from public, anon;
revoke all on function public.shares_conversation_with(uuid) from public, anon;
revoke all on function public.profiles_block_each_other(uuid) from public, anon;
revoke all on function public.search_profiles(text) from public, anon;
revoke all on function public.get_profile_status(uuid) from public, anon;
revoke all on function public.get_or_create_dm(uuid) from public, anon;
revoke all on function public.accept_friend_request(uuid) from public, anon;
revoke all on function public.remove_friend(uuid) from public, anon;
revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid) to authenticated;
grant execute on function public.is_conversation_admin(uuid) to authenticated;
grant execute on function public.is_conversation_creator(uuid) to authenticated;
grant execute on function public.are_friends(uuid) to authenticated;
grant execute on function public.shares_conversation_with(uuid) to authenticated;
grant execute on function public.profiles_block_each_other(uuid) to authenticated;
grant execute on function public.search_profiles(text) to authenticated;
grant execute on function public.get_profile_status(uuid) to authenticated;
grant execute on function public.get_or_create_dm(uuid) to authenticated;
grant execute on function public.accept_friend_request(uuid) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
revoke insert, update on public.profiles from anon, authenticated;
grant insert (id, username, full_name) on public.profiles to authenticated;
grant update (username, full_name, bio, avatar_url, discoverable, show_online_status, show_last_seen, is_online, last_seen_at)
on public.profiles to authenticated;
revoke update on public.conversations from anon, authenticated;
grant update (name, description, avatar_url) on public.conversations to authenticated;
revoke update on public.message_receipts from anon, authenticated;
grant update (read_at) on public.message_receipts to authenticated;
revoke select on public.profiles from anon, authenticated;
grant select (id, user_id, username, full_name, bio, avatar_url, discoverable, show_online_status, show_last_seen, created_at)
on public.profiles to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-files', 'chat-files', false, 26214400, array['image/jpeg','image/png','image/gif','image/webp','video/mp4','video/webm','video/quicktime','audio/mpeg','audio/mp4','audio/ogg','audio/webm','audio/wav','application/pdf','text/plain','text/csv'])
on conflict (id) do update set public = false, file_size_limit = 26214400,
  allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp','video/mp4','video/webm','video/quicktime','audio/mpeg','audio/mp4','audio/ogg','audio/webm','audio/wav','application/pdf','text/plain','text/csv'];
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880;

create policy "Conversation members read chat files" on storage.objects
for select to authenticated using (
  bucket_id = 'chat-files'
  and (storage.foldername(name))[2] is not null
  and public.is_conversation_member(((storage.foldername(name))[2])::uuid)
);
create policy "Users upload their chat files" on storage.objects
for insert to authenticated with check (bucket_id = 'chat-files' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Users delete their uploaded files" on storage.objects
for delete to authenticated using (bucket_id = 'chat-files' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Anyone can view avatars" on storage.objects
for select to authenticated using (bucket_id = 'avatars');
create policy "Users upload their own avatar" on storage.objects
for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "Users delete their own avatar" on storage.objects
for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object or undefined_object then null;
end;
$$;
do $$
begin
  alter publication supabase_realtime add table public.friend_requests;
exception when duplicate_object or undefined_object then null;
end;
$$;
do $$
begin
  alter publication supabase_realtime add table public.notifications;
exception when duplicate_object or undefined_object then null;
end;
$$;
