-- ════════════════════════════════════════════════════════════════════
--  AgendaANS — Informe de conciliación de datos personales (SOLO LECTURA)
--  Ejecutar en Supabase → SQL Editor. No modifica, fusiona ni borra nada.
--  Fabián revisa el resultado y decide persona por persona qué valor es el correcto.
-- ════════════════════════════════════════════════════════════════════
with p as (
  select id, nombre, apellidos, cedula, telefono, email, empresa, rol, activo,
         regexp_replace(lower(translate(trim(coalesce(nombre,'') || ' ' || coalesce(apellidos,'')),
           'ÁÉÍÓÚÜÑÀÈÌÒÙáéíóúüñàèìòù', 'AEIOUUNAEIOUaeiouunaeiou')), '\s+', ' ', 'g') as clave_nombre,
         regexp_replace(coalesce(cedula,''), '[^0-9A-Za-z]', '', 'g') as clave_cedula
  from public.perfiles
),
ficha as (
  select id, nombre || ' ' || apellidos || ' [' || coalesce(empresa,'-') || ' · ' || rol ||
         case when activo then '' else ' · INACTIVO' end || ' · CC ' || coalesce(cedula,'-') ||
         ' · id ' || left(id::text, 8) || ']' as txt, clave_nombre, clave_cedula
  from p
)
-- A. Misma persona con dos o más perfiles (nombre igual sin tildes/mayúsculas)
select 'A. Nombre duplicado' as tipo, f.clave_nombre as clave, string_agg(f.txt, '  |  ' order by f.txt) as detalle
from ficha f group by f.clave_nombre having count(*) > 1
union all
-- B. Misma cédula en dos o más perfiles
select 'B. Cédula duplicada', f.clave_cedula, string_agg(f.txt, '  |  ' order by f.txt)
from ficha f where f.clave_cedula <> '' group by f.clave_cedula having count(*) > 1
union all
-- C. Correo del perfil distinto del correo de ingreso (Auth)
select 'C. Correo perfil ≠ correo de ingreso', p.nombre || ' ' || p.apellidos,
       'perfil: ' || coalesce(p.email,'(vacío)') || '  ·  ingreso: ' || coalesce(u.email,'(vacío)')
from p join auth.users u on u.id = p.id
where lower(coalesce(p.email,'')) <> lower(coalesce(u.email,''))
union all
-- D. Datos del registro inicial (metadatos de Auth) distintos de los del perfil
select 'D. Dato del registro ≠ perfil (' || c.campo || ')', p.nombre || ' ' || p.apellidos,
       'perfil: ' || coalesce(c.v_perfil,'(vacío)') || '  ·  registro: ' || coalesce(c.v_meta,'(vacío)')
from p join auth.users u on u.id = p.id
cross join lateral (values
  ('nombre',    p.nombre,    u.raw_user_meta_data ->> 'nombre'),
  ('apellidos', p.apellidos, u.raw_user_meta_data ->> 'apellidos'),
  ('cedula',    p.cedula,    u.raw_user_meta_data ->> 'cedula'),
  ('telefono',  p.telefono,  u.raw_user_meta_data ->> 'telefono')
) as c(campo, v_perfil, v_meta)
where c.v_meta is not null and coalesce(c.v_perfil,'') <> c.v_meta
union all
-- E. Perfil sin usuario de ingreso, o usuario de ingreso sin perfil
select 'E. Perfil sin usuario de ingreso', p.nombre || ' ' || p.apellidos, 'id ' || p.id
from p where not exists (select 1 from auth.users u where u.id = p.id)
union all
select 'E. Usuario de ingreso sin perfil', coalesce(u.email,'-'), 'id ' || u.id
from auth.users u where not exists (select 1 from public.perfiles p where p.id = u.id)
order by 1, 2;
