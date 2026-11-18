-- ════════════════════════════════════════════════════════════════════
--  AgendaANS v2.38.0 — Comunicados, llamados de atención y expedientes
--  Ejecutar UNA vez en Supabase → SQL Editor. Es seguro re-ejecutarlo.
--  No modifica datos existentes.
--
--  Qué crea:
--   • comunicados               → cada comunicado general o llamado de atención
--   • comunicado_destinatarios  → a quién va dirigido y cuándo lo firmó
--   • bucket privado "expedientes" (Storage):
--       comunicados/<id_comunicado>/<archivo>.pdf   → el documento
--       <id_anestesiologo>/firmas/<...>.png          → la firma de cada uno
--     Así cada anestesiólogo tiene su carpeta, y la app arma su expediente
--     con todos sus comunicados, llamados de atención y firmas.
--   • firmar_comunicado(): la firma la registra el servidor con su propia
--     hora; nadie puede alterar la fecha ni firmar por otro.
-- ════════════════════════════════════════════════════════════════════

-- 1. Tablas ------------------------------------------------------------------
create table if not exists public.comunicados (
  id             uuid primary key default gen_random_uuid(),
  tipo           text not null default 'comunicado',
  titulo         text not null,
  fecha          date not null default ((now() at time zone 'America/Bogota')::date),
  descripcion    text,
  archivo_path   text,
  archivo_nombre text,
  requiere_firma boolean not null default true,
  grupos         text[] not null default '{}',
  anulado        boolean not null default false,
  creado_por     uuid default auth.uid() references public.perfiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
alter table public.comunicados drop constraint if exists comunicados_tipo_check;
alter table public.comunicados add constraint comunicados_tipo_check
  check (tipo in ('comunicado','llamado_atencion'));

create table if not exists public.comunicado_destinatarios (
  id             uuid primary key default gen_random_uuid(),
  comunicado_id  uuid not null references public.comunicados(id) on delete cascade,
  perfil_id      uuid not null references public.perfiles(id) on delete cascade,
  visto_at       timestamptz,
  firmado_at     timestamptz,
  firma_path     text,
  firma_nombre   text,
  firma_cedula   text,
  dispositivo    text,
  created_at     timestamptz not null default now(),
  unique (comunicado_id, perfil_id)
);
create index if not exists idx_comdest_perfil on public.comunicado_destinatarios(perfil_id);
create index if not exists idx_comdest_com    on public.comunicado_destinatarios(comunicado_id);

-- 2. Seguridad de filas (RLS) -------------------------------------------------
alter table public.comunicados              enable row level security;
alter table public.comunicado_destinatarios enable row level security;

-- comunicados: el administrador ve y gestiona todo; cada anestesiólogo solo ve
-- los comunicados que le fueron dirigidos.
drop policy if exists com_admin_todo on public.comunicados;
create policy com_admin_todo on public.comunicados
  for all to authenticated using (public.es_admin()) with check (public.es_admin());

drop policy if exists com_destinatario_lee on public.comunicados;
create policy com_destinatario_lee on public.comunicados
  for select to authenticated using (
    not anulado and exists (
      select 1 from public.comunicado_destinatarios d
      where d.comunicado_id = comunicados.id and d.perfil_id = auth.uid()
    )
  );

-- destinatarios: el administrador gestiona; cada uno solo ve sus propias filas.
-- Nadie (salvo el administrador) puede editar filas directamente: la firma se
-- registra únicamente con la función firmar_comunicado().
drop policy if exists comdest_admin_todo on public.comunicado_destinatarios;
create policy comdest_admin_todo on public.comunicado_destinatarios
  for all to authenticated using (public.es_admin()) with check (public.es_admin());

drop policy if exists comdest_propio_lee on public.comunicado_destinatarios;
create policy comdest_propio_lee on public.comunicado_destinatarios
  for select to authenticated using (perfil_id = auth.uid());

-- 3. Funciones ----------------------------------------------------------------
-- Marca la primera vez que el anestesiólogo abre el comunicado
create or replace function public.marcar_comunicado_visto(p_comunicado uuid)
returns void language sql security definer set search_path = public as $$
  update public.comunicado_destinatarios
     set visto_at = coalesce(visto_at, now())
   where comunicado_id = p_comunicado and perfil_id = auth.uid();
$$;
grant execute on function public.marcar_comunicado_visto(uuid) to authenticated;

-- Registra la firma (una sola vez, con la hora del servidor)
create or replace function public.firmar_comunicado(p_comunicado uuid, p_firma_path text, p_dispositivo text default null)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  v_fecha timestamptz;
  v_perfil record;
begin
  if auth.uid() is null then raise exception 'Sin sesión' using errcode = '42501'; end if;
  if p_firma_path is null or split_part(p_firma_path, '/', 1) <> auth.uid()::text then
    raise exception 'Firma inválida' using errcode = '42501';
  end if;
  select nombre, apellidos, cedula into v_perfil from public.perfiles where id = auth.uid();
  update public.comunicado_destinatarios
     set firmado_at   = now(),
         visto_at     = coalesce(visto_at, now()),
         firma_path   = p_firma_path,
         firma_nombre = trim(coalesce(v_perfil.nombre,'') || ' ' || coalesce(v_perfil.apellidos,'')),
         firma_cedula = v_perfil.cedula,
         dispositivo  = left(p_dispositivo, 300)
   where comunicado_id = p_comunicado and perfil_id = auth.uid() and firmado_at is null
   returning firmado_at into v_fecha;
  if v_fecha is null then
    raise exception 'Este comunicado no está pendiente de tu firma' using errcode = 'P0001';
  end if;
  return v_fecha;
end $$;
grant execute on function public.firmar_comunicado(uuid, text, text) to authenticated;

-- 4. Storage: bucket privado "expedientes" -----------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expedientes', 'expedientes', false, 15728640,
        array['application/pdf','image/png','image/jpeg'])
on conflict (id) do update set public = false;

drop policy if exists exp_admin_todo on storage.objects;
create policy exp_admin_todo on storage.objects
  for all to authenticated
  using (bucket_id = 'expedientes' and public.es_admin())
  with check (bucket_id = 'expedientes' and public.es_admin());

-- Cada anestesiólogo lee su propia carpeta y los documentos que le enviaron
drop policy if exists exp_usuario_lee on storage.objects;
create policy exp_usuario_lee on storage.objects
  for select to authenticated using (
    bucket_id = 'expedientes' and (
      split_part(name, '/', 1) = auth.uid()::text
      or (split_part(name, '/', 1) = 'comunicados' and exists (
            select 1 from public.comunicado_destinatarios d
            where d.comunicado_id::text = split_part(name, '/', 2) and d.perfil_id = auth.uid()))
    )
  );

-- Cada anestesiólogo solo puede subir su firma, dentro de su carpeta (sin sobrescribir)
drop policy if exists exp_usuario_sube_firma on storage.objects;
create policy exp_usuario_sube_firma on storage.objects
  for insert to authenticated with check (
    bucket_id = 'expedientes'
    and split_part(name, '/', 1) = auth.uid()::text
    and split_part(name, '/', 2) = 'firmas'
  );
