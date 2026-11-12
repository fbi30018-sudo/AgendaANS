// AgendaANS — utilidades compartidas de las funciones del servidor (v2.37.0)
// La clave de servicio SOLO vive aqui, leida de las variables de entorno de Netlify.
// Nunca se envia al navegador.

export const SUPA_URL = Netlify.env.get("SUPABASE_URL") || "https://vhrsyhbflxyvvgaaahum.supabase.co"
// La clave anon es publica (ya esta en index.html); se usa para los flujos normales de Auth.
export const ANON =
  Netlify.env.get("SUPABASE_ANON_KEY") ||
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZocnN5aGJmbHh5dnZnYWFhaHVtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMzk0NjIsImV4cCI6MjA5NTkxNTQ2Mn0.XSxVjEkRDR7UZfg0YbY1hoDxwfT5RbKovjnz6ALiMPM"
export const APP_URL = Netlify.env.get("APP_URL") || "https://agendaans.netlify.app"
export const CORREO_FICTICIO = "@agendaans.local"

export function serviceKey(): string {
  const k = Netlify.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!k) throw new HttpError(503, "Falta configurar SUPABASE_SERVICE_ROLE_KEY en Netlify")
  return k
}

export class HttpError extends Error {
  status: number
  constructor(status: number, msg: string) {
    super(msg)
    this.status = status
  }
}

function hdrServicio(extra: Record<string, string> = {}) {
  const k = serviceKey()
  const h: Record<string, string> = { apikey: k, "Content-Type": "application/json", ...extra }
  // Claves heredadas (JWT) van tambien en Authorization; las nuevas sb_secret_ solo en apikey.
  if (k.startsWith("eyJ")) h.Authorization = "Bearer " + k
  return h
}

async function leer(r: Response) {
  const t = await r.text()
  try {
    return t ? JSON.parse(t) : null
  } catch {
    return t
  }
}

/** PostgREST con la clave de servicio (salta RLS: usar solo despues de autorizar). */
export async function rest(method: string, path: string, body?: unknown, prefer?: string) {
  const r = await fetch(SUPA_URL + "/rest/v1/" + path, {
    method,
    headers: hdrServicio(prefer ? { Prefer: prefer } : {}),
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const d = await leer(r)
  if (!r.ok) throw new HttpError(502, "BD: " + (d?.message || r.statusText))
  return d
}

/** API de administracion de Supabase Auth. */
export async function authAdmin(method: string, path: string, body?: unknown) {
  const r = await fetch(SUPA_URL + "/auth/v1/admin/" + path, {
    method,
    headers: hdrServicio(),
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const d = await leer(r)
  if (!r.ok) throw new HttpError(r.status === 422 ? 400 : 502, d?.msg || d?.message || d?.error_description || r.statusText)
  return d
}

/** Valida el token del usuario que llama y devuelve su id. */
export async function usuarioDelToken(req: Request): Promise<{ id: string; email?: string }> {
  const h = req.headers.get("authorization") || ""
  const token = h.replace(/^Bearer\s+/i, "")
  if (!token) throw new HttpError(401, "Sin sesion")
  const r = await fetch(SUPA_URL + "/auth/v1/user", { headers: { apikey: ANON, Authorization: "Bearer " + token } })
  if (!r.ok) throw new HttpError(401, "Sesion invalida o vencida")
  const u = await r.json()
  return { id: u.id, email: u.email }
}

export async function perfilPorId(id: string) {
  const d = await rest("GET", "perfiles?select=*&id=eq." + encodeURIComponent(id))
  return Array.isArray(d) ? d[0] || null : null
}

export async function exigirAdmin(uid: string) {
  const p = await perfilPorId(uid)
  if (!p || p.rol !== "admin" || !p.activo) throw new HttpError(403, "Solo el administrador puede hacer esto")
  return p
}

export function esCorreoReal(e?: string | null) {
  return !!e && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e) && !e.toLowerCase().endsWith(CORREO_FICTICIO)
}

/**
 * Si el usuario entra con cedula (correo ficticio cedula@agendaans.local) pero su perfil
 * tiene un correo real, se pasa ese correo a Auth para que el enlace de recuperacion le llegue.
 * El ingreso con cedula sigue funcionando gracias a /api/publico/login-cedula.
 */
export async function asegurarCorreoAuth(userId: string, correoPerfil?: string | null): Promise<string | null> {
  const u = await authAdmin("GET", "users/" + userId)
  const actual: string = u?.email || ""
  if (esCorreoReal(correoPerfil) && correoPerfil!.toLowerCase() !== actual.toLowerCase()) {
    await authAdmin("PUT", "users/" + userId, { email: correoPerfil, email_confirm: true })
    return correoPerfil!
  }
  return esCorreoReal(actual) ? actual : null
}

export async function enviarRecuperacion(email: string) {
  const r = await fetch(
    SUPA_URL + "/auth/v1/recover?redirect_to=" + encodeURIComponent(APP_URL + "/restablecer"),
    { method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email }) },
  )
  if (!r.ok) {
    const d = await leer(r)
    throw new HttpError(r.status === 429 ? 429 : 502, d?.msg || d?.message || "No se pudo enviar el correo")
  }
}

export async function auditar(actor: string | null, usuario: string, campo: string, nuevo: string) {
  try {
    await rest("POST", "auditoria_perfiles", { actor_id: actor, usuario_id: usuario, campo, valor_nuevo: nuevo })
  } catch (e) {
    console.error("auditoria:", (e as Error).message)
  }
}

export function json(data: unknown, status = 200) {
  return Response.json(data, { status })
}

export function errorResp(e: unknown) {
  if (e instanceof HttpError) return json({ error: e.message }, e.status)
  console.error(e)
  return json({ error: "Error interno" }, 500)
}
