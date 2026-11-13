-- ════════════════════════════════════════════════════════════════════
--  AgendaANS v2.37.0 — perfiles, sesiones, auditoría y seguridad
--  Ejecutar UNA vez en Supabase → SQL Editor. Es seguro re-ejecutarlo.
--  No modifica ni fusiona datos existentes de nadie.
-- ════════════════════════════════════════════════════════════════════

-- 1. Campos nuevos del perfil ------------------------------------------------
alter table public.perfiles
  add column if not exists seccion text,
  add column if not exists grupo text,
  add column if not exists must_change_password boolean not null default false;

alter table public.perfiles drop constraint if exists perfiles_seccion_check;
alter table public.perfiles add constraint perfiles_seccion_check
  check (seccion is null or seccion in ('anestesiologo','administrativo','hospitalario'));

alter table public.perfiles drop constraint if exists perfiles_grupo_check;
alter table public.perfiles add constraint perfiles_grupo_check
  check (grupo is null or grupo in ('SEDAR','Colsubsidio','IME','Consulta externa'));

-- 2. ¿Quien llama es administrador activo? ----------------------------------
create or replace function public.es_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and rol = 'admin' and activo)
$$;
grant execute on function public.es_admin() to authenticated;

-- 3. Un usuario normal no puede cambiarse rol, estado, empresa, sección ni grupo
--    (aunque la política RLS le permita editar su propia fila).
--    El SQL Editor y la clave de servicio (funciones de Netlify) quedan permitidos.
create or replace function public.perfiles_proteger_campos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'anon' then return new; end if;
  if coalesce(auth.role(), '') = 'service_role' or public.es_admin() then return new; end if;
  if new.id is distinct from old.id
     or new.rol is distinct from old.rol
     or new.activo is distinct from old.activo
     or new.empresa is distinct from old.empresa
     or new.seccion is distinct from old.seccion
     or new.grupo is distinct from old.grupo then
    raise exception 'Solo el administrador puede cambiar rol, estado, empresa, sección o grupo'
      using errcode = '42501';
  end if;
  -- El usuario puede quitarse la obligación de cambiar contraseña (tras cambiarla), no ponérsela a otro
  if new.must_change_password and not old.must_change_password then
    raise exception 'No permitido' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_perfiles_proteger on public.perfiles;
create trigger trg_perfiles_proteger before update on public.perfiles
  for each row execute function public.perfiles_proteger_campos();

-- 4. Auditoría de cambios en perfiles ---------------------------------------
create table if not exists public.auditoria_perfiles (
  id bigserial primary key,
  fecha timestamptz not null default now(),
  actor_id uuid,            -- quién hizo el cambio (null = SQL Editor / sistema)
  usuario_id uuid not null, -- a quién
  campo text not null,
  valor_anterior text,
  valor_nuevo text
);
create index if not exists auditoria_perfiles_usuario_idx on public.auditoria_perfiles (usuario_id, fecha desc);
alter table public.auditoria_perfiles enable row level security;
drop policy if exists auditoria_admin_lee on public.auditoria_perfiles;
create policy auditoria_admin_lee on public.auditoria_perfiles for select to authenticated using (public.es_admin());
-- Nadie inserta desde el navegador: lo hacen el disparador y las funciones del servidor.

create or replace function public.perfiles_auditar()
returns trigger language plpgsql security definer set search_path = public as $$
declare k text; o jsonb := to_jsonb(old); n jsonb := to_jsonb(new);
begin
  for k in select jsonb_object_keys(n) loop
    if k in ('updated_at') then continue; end if;
    if (o -> k) is distinct from (n -> k) then
      insert into public.auditoria_perfiles (actor_id, usuario_id, campo, valor_anterior, valor_nuevo)
      values (auth.uid(), new.id, k, o ->> k, n ->> k);
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists trg_perfiles_auditar on public.perfiles;
create trigger trg_perfiles_auditar after update on public.perfiles
  for each row execute function public.perfiles_auditar();

-- 5. Sesiones activas: ver y cerrar (admin, o el propio usuario) -------------
create or replace function public.admin_sesiones(p_user uuid)
returns table (id uuid, creada timestamptz, ultima_actividad timestamptz, dispositivo text, ip text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not (public.es_admin() or p_user = auth.uid() or coalesce(auth.role(), '') = 'service_role') then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  return query
    select s.id, s.created_at,
           coalesce(s.refreshed_at at time zone 'UTC', s.updated_at, s.created_at),
           s.user_agent, host(s.ip)
    from auth.sessions s
    where s.user_id = p_user
    order by 3 desc nulls last;
end $$;
grant execute on function public.admin_sesiones(uuid) to authenticated;

-- p_sesion null = cerrar todas las sesiones del usuario
create or replace function public.admin_cerrar_sesion(p_user uuid, p_sesion uuid default null)
returns integer language plpgsql security definer set search_path = public, auth as $$
declare n integer;
begin
  if not (public.es_admin() or p_user = auth.uid() or coalesce(auth.role(), '') = 'service_role') then
    raise exception 'No autorizado' using errcode = '42501';
  end if;
  delete from auth.sessions where user_id = p_user and (p_sesion is null or id = p_sesion);
  get diagnostics n = row_count;  -- los refresh tokens se borran en cascada
  if n > 0 and auth.uid() is distinct from p_user then
    insert into public.auditoria_perfiles (actor_id, usuario_id, campo, valor_nuevo)
    values (auth.uid(), p_user, 'sesiones', n || ' sesión(es) cerrada(s) por el administrador');
  end if;
  return n;
end $$;
grant execute on function public.admin_cerrar_sesion(uuid, uuid) to authenticated;
