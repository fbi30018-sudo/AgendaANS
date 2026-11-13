// AgendaANS — acciones de cuenta que requieren la clave de servicio (v2.37.0)
// POST /api/cuenta  { accion, id, ... }   con  Authorization: Bearer <token del usuario>
//
//  set_password      (admin)        asigna contraseña temporal y obliga a cambiarla
//  send_recovery     (admin)        envía al correo del usuario el enlace de restablecimiento
//  sync_email        (admin o el mismo usuario)  pasa el correo del perfil a Auth
//
// Toda acción valida en el servidor quién llama; ocultar botones no basta.
import type { Config } from "@netlify/functions"
import {
  usuarioDelToken, exigirAdmin, perfilPorId, authAdmin, rest, asegurarCorreoAuth,
  enviarRecuperacion, auditar, esCorreoReal, json, errorResp, HttpError,
} from "../lib/supa.mts"

export default async (req: Request) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "Método no permitido")
    const yo = await usuarioDelToken(req)
    const b = await req.json().catch(() => ({}))
    const accion = String(b.accion || "")
    const id = String(b.id || "")
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new HttpError(400, "Usuario inválido")

    if (accion === "set_password") {
      await exigirAdmin(yo.id)
      const pwd = String(b.password || "")
      if (pwd.length < 8) throw new HttpError(400, "La contraseña debe tener mínimo 8 caracteres")
      await authAdmin("PUT", "users/" + id, { password: pwd })
      await rest("PATCH", "perfiles?id=eq." + id, { must_change_password: true })
      // Cierra las sesiones abiertas del usuario (sus refresh tokens dejan de servir)
      await rest("POST", "rpc/admin_cerrar_sesion", { p_user: id, p_sesion: null }).catch(() => {})
      await auditar(yo.id, id, "contraseña", "restablecida por el administrador (temporal)")
      return json({ ok: true })
    }

    if (accion === "send_recovery") {
      await exigirAdmin(yo.id)
      const p = await perfilPorId(id)
      if (!p) throw new HttpError(404, "Usuario no encontrado")
      const correo = await asegurarCorreoAuth(id, p.email)
      if (!correo) throw new HttpError(400, "El usuario no tiene un correo real registrado. Agrégalo en su perfil.")
      await enviarRecuperacion(correo)
      await auditar(yo.id, id, "contraseña", "enlace de recuperación enviado")
      return json({ ok: true, correo })
    }

    if (accion === "sync_email") {
      if (yo.id !== id) await exigirAdmin(yo.id)
      const p = await perfilPorId(id)
      if (!p) throw new HttpError(404, "Usuario no encontrado")
      if (!esCorreoReal(p.email)) return json({ ok: true, sincronizado: false })
      const correo = await asegurarCorreoAuth(id, p.email)
      return json({ ok: true, sincronizado: !!correo })
    }

    throw new HttpError(400, "Acción desconocida")
  } catch (e) {
    return errorResp(e)
  }
}

export const config: Config = { path: "/api/cuenta", method: ["POST"] }
