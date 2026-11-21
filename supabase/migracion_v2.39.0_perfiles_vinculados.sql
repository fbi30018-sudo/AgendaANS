-- ════════════════════════════════════════════════════════════════════
--  AgendaANS v2.39.0 — Perfiles vinculados (misma persona: SEDAR + IME)
--  Ejecutar en Supabase → SQL Editor, por pasos.
-- ════════════════════════════════════════════════════════════════════

-- ── PASO 0 (SOLO LECTURA): ver los perfiles de Leonard y dónde está su disponibilidad
select p.id, p.nombre, p.apellidos, p.cedula, p.empresa, p.rol, p.activo,
       (select count(*) from auth.users u where u.id = p.id) as tiene_login,
       (select count(*) from public.disponibilidad d where d.user_id = p.id) as dias_disponibilidad
from public.perfiles p
where translate(lower(p.nombre || ' ' || p.apellidos), 'áéíóú', 'aeiou') like '%leon%'
order by p.empresa;
-- Esperado: una fila SEDAR con tiene_login = 1 (con la que él entra)
-- y una fila IME con tiene_login = 0 (slot IME). Anote ambos id.

-- ── PASO 1: columna de vínculo
alter table public.perfiles
  add column if not exists vinculado_a uuid references public.perfiles(id) on delete set null;

-- ── PASO 2: permiso para ver y escribir la disponibilidad de los perfiles vinculados a uno
drop policy if exists disp_perfil_vinculado on public.disponibilidad;
create policy disp_perfil_vinculado on public.disponibilidad
  for all to authenticated
  using (exists (select 1 from public.perfiles p
                 where p.id = disponibilidad.user_id and p.vinculado_a = auth.uid()))
  with check (exists (select 1 from public.perfiles p
                      where p.id = disponibilidad.user_id and p.vinculado_a = auth.uid()));

-- ── PASO 3: vincular el perfil IME de Leonard a su perfil SEDAR (reemplace los id del PASO 0)
-- update public.perfiles
--    set vinculado_a = 'ID_PERFIL_SEDAR'
--  where id = 'ID_PERFIL_IME';
