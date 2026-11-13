-- ════════════════════════════════════════════════════════════════════
--  AgendaANS v2.37.0 (b) — Datos del registro inicial que no llegaban al perfil
--  Ejecutar en Supabase → SQL Editor, DESPUÉS de migracion_v2.37.0_perfiles_sesiones.sql.
--
--  Problema (verificado 13/11/2026): al registrarse, cédula, teléfono, registro médico,
--  especialidad y correo se guardan en los metadatos de Supabase Auth. La función
--  handle_new_user solo copia nombre, apellidos y empresa a `perfiles`, y la tabla no
--  tenía columna de correo; por eso el administrador ve el perfil sin esos datos.
-- ════════════════════════════════════════════════════════════════════

-- 0. (Diagnóstico, opcional) ver qué hace hoy la función que crea el perfil:
-- select p.proname, pg_get_functiondef(p.oid)
-- from pg_trigger t join pg_proc p on p.oid = t.tgfoid
-- where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal;

-- 1. Al crearse un perfil, completar los campos VACÍOS con los datos del registro.
--    Funciona junto con la función existente (no la reemplaza) y nunca sobrescribe
--    un valor que ya tenga el perfil.
create or replace function public.perfiles_completar_desde_registro()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare m jsonb; correo text;
begin
  select u.raw_user_meta_data into m from auth.users u where u.id = new.id;
  if m is null then return new; end if;
  new.nombre       := coalesce(nullif(new.nombre,''),       nullif(m->>'nombre',''),       new.nombre);
  new.apellidos    := coalesce(nullif(new.apellidos,''),    nullif(m->>'apellidos',''),    new.apellidos);
  new.cedula       := coalesce(nullif(new.cedula,''),       nullif(m->>'cedula',''),       new.cedula);
  new.telefono     := coalesce(nullif(new.telefono,''),     nullif(m->>'telefono',''),     new.telefono);
  new.registro_med := coalesce(nullif(new.registro_med,''), nullif(m->>'registro_med',''), new.registro_med);
  new.especialidad := coalesce(nullif(new.especialidad,''), nullif(m->>'especialidad',''), new.especialidad);
  -- Correo real: el campo "correo" del formulario nuevo, o el de acceso si no es el ficticio
  correo := coalesce(nullif(m->>'correo',''),
                     case when (m->>'email') !~* '@agendaans\.local$' then nullif(m->>'email','') end);
  -- Tipo de usuario elegido en el registro (handle_new_user siempre ponía 'anestesiologo').
  -- Solo los dos tipos no privilegiados del formulario; la cuenta sigue inactiva hasta que el admin la apruebe.
  if new.rol = 'anestesiologo' and (m->>'rol') in ('interconsulta','hospitalario') then
    new.rol := m->>'rol';
  end if;
  if correo is not null and (new.email is null or new.email = '' or new.email ~* '@agendaans\.local$') then
    new.email := correo;
  end if;
  return new;
end $$;

drop trigger if exists trg_perfiles_completar_registro on public.perfiles;
create trigger trg_perfiles_completar_registro before insert on public.perfiles
  for each row execute function public.perfiles_completar_desde_registro();

-- 2. Recuperar los datos de los usuarios YA registrados.
--    Solo llena campos vacíos (o el correo ficticio); no cambia nada que ya tenga valor.
--    Cada cambio queda en auditoria_perfiles (actor = Sistema).
update public.perfiles p set
  cedula       = coalesce(nullif(p.cedula,''),       nullif(u.raw_user_meta_data->>'cedula',''),       p.cedula),
  telefono     = coalesce(nullif(p.telefono,''),     nullif(u.raw_user_meta_data->>'telefono',''),     p.telefono),
  registro_med = coalesce(nullif(p.registro_med,''), nullif(u.raw_user_meta_data->>'registro_med',''), p.registro_med),
  especialidad = coalesce(nullif(p.especialidad,''), nullif(u.raw_user_meta_data->>'especialidad',''), p.especialidad),
  email = case
    when (p.email is null or p.email = '' or p.email ~* '@agendaans\.local$')
     and coalesce(nullif(u.raw_user_meta_data->>'correo',''),
                  case when u.email !~* '@agendaans\.local$' then u.email end) is not null
    then coalesce(nullif(u.raw_user_meta_data->>'correo',''), u.email)
    else p.email end
from auth.users u
where u.id = p.id
  and (   (coalesce(p.cedula,'')       = '' and coalesce(u.raw_user_meta_data->>'cedula','')       <> '')
       or (coalesce(p.telefono,'')     = '' and coalesce(u.raw_user_meta_data->>'telefono','')     <> '')
       or (coalesce(p.registro_med,'') = '' and coalesce(u.raw_user_meta_data->>'registro_med','') <> '')
       or (coalesce(p.especialidad,'') = '' and coalesce(u.raw_user_meta_data->>'especialidad','') <> '')
       or ((p.email is null or p.email = '' or p.email ~* '@agendaans\.local$')
           and coalesce(nullif(u.raw_user_meta_data->>'correo',''),
                        case when u.email !~* '@agendaans\.local$' then u.email end) is not null));

-- 3. Quienes siguen sin correo real o sin registro médico (pedírselos o que lo completen en Mi perfil)
select nombre || ' ' || apellidos as usuario, cedula,
       case when email is null or email = '' or email ~* '@agendaans\.local$' then 'FALTA' else email end as correo,
       coalesce(nullif(registro_med,''), 'FALTA') as registro_medico
from public.perfiles
where activo and (email is null or email = '' or email ~* '@agendaans\.local$' or coalesce(registro_med,'') = '')
order by apellidos;
