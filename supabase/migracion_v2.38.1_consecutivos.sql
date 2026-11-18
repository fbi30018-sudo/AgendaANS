-- ════════════════════════════════════════════════════════════════════
--  AgendaANS v2.38.1 — Consecutivos de comunicados y llamados de atención
--  Ejecutar UNA vez en Supabase → SQL Editor (después de v2.38.0).
--  Es seguro re-ejecutarlo.
--
--   • Comunicados generales: consecutivo por año  → N.º 001-2026, 002-2026…
--   • Llamados de atención: consecutivo por anestesiólogo → 1.º, 2.º, 3.º…
--   Los asigna la base de datos al crear el documento; no se pueden editar
--   ni reutilizar (un comunicado anulado conserva su número).
-- ════════════════════════════════════════════════════════════════════

-- (se recrea al final; se quita primero para poder numerar lo existente)
drop trigger if exists trg_comunicados_consecutivo on public.comunicados;

alter table public.comunicados
  add column if not exists consecutivo   integer,
  add column if not exists anio          integer,
  add column if not exists perfil_llamado uuid references public.perfiles(id) on delete set null;

-- Llamados ya creados: tomar el anestesiólogo de su destinatario
update public.comunicados c
   set perfil_llamado = d.perfil_id
  from public.comunicado_destinatarios d
 where d.comunicado_id = c.id and c.tipo = 'llamado_atencion' and c.perfil_llamado is null;

update public.comunicados set anio = extract(year from fecha)::int where anio is null;

-- Numerar lo que ya exista, en orden de creación
with n as (
  select id, row_number() over (partition by anio order by created_at, id) as k
  from public.comunicados where tipo = 'comunicado' and consecutivo is null
)
update public.comunicados c set consecutivo = n.k
  + coalesce((select max(consecutivo) from public.comunicados x where x.tipo='comunicado' and x.anio=c.anio and x.consecutivo is not null),0)
  from n where c.id = n.id;

with n as (
  select id, row_number() over (partition by perfil_llamado order by created_at, id) as k
  from public.comunicados where tipo = 'llamado_atencion' and consecutivo is null and perfil_llamado is not null
)
update public.comunicados c set consecutivo = n.k
  + coalesce((select max(consecutivo) from public.comunicados x where x.tipo='llamado_atencion' and x.perfil_llamado=c.perfil_llamado and x.consecutivo is not null),0)
  from n where c.id = n.id;

-- Sin repetidos
create unique index if not exists ux_com_consec_general
  on public.comunicados (anio, consecutivo) where tipo = 'comunicado';
create unique index if not exists ux_com_consec_llamado
  on public.comunicados (perfil_llamado, consecutivo) where tipo = 'llamado_atencion';

-- Asignación automática y protección
create or replace function public.comunicados_consecutivo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    -- El número, el año, el tipo y el destinatario del llamado no se cambian
    new.consecutivo    := old.consecutivo;
    new.anio           := old.anio;
    new.tipo           := old.tipo;
    new.perfil_llamado := old.perfil_llamado;
    return new;
  end if;
  new.anio := extract(year from coalesce(new.fecha, (now() at time zone 'America/Bogota')::date))::int;
  if new.tipo = 'llamado_atencion' then
    if new.perfil_llamado is null then
      raise exception 'El llamado de atención debe indicar el anestesiólogo';
    end if;
    perform pg_advisory_xact_lock(hashtext('llamado:' || new.perfil_llamado::text));
    select coalesce(max(consecutivo),0) + 1 into new.consecutivo
      from public.comunicados where tipo = 'llamado_atencion' and perfil_llamado = new.perfil_llamado;
  else
    perform pg_advisory_xact_lock(hashtext('comunicado:' || new.anio::text));
    select coalesce(max(consecutivo),0) + 1 into new.consecutivo
      from public.comunicados where tipo = 'comunicado' and anio = new.anio;
  end if;
  return new;
end $$;

drop trigger if exists trg_comunicados_consecutivo on public.comunicados;
create trigger trg_comunicados_consecutivo
  before insert or update on public.comunicados
  for each row execute function public.comunicados_consecutivo();
