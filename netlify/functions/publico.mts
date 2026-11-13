// AgendaANS — acciones sin sesión (v2.37.0)
// POST /api/publico/login-cedula   { cedula, password }  → sesión de Supabase
// POST /api/publico/recuperar      { identificador }     → envía enlace si hay correo real
//
// login-cedula existe porque el usuario de ingreso por cédula era un correo ficticio
// (cedula@agendaans.local). Cuando el correo de Auth pasa a ser el real (para poder
// recuperar la contraseña), la cédula sigue sirviendo para entrar.
// Nunca revela si una cédula existe: responde igual en todos los casos.
import type { Config, Context } from "@netlify/functions"
import {
  SUPA_URL, ANON, rest, authAdmin, asegurarCorreoAuth, enviarRecuperacion, json, errorResp, HttpError,
} from "../lib/supa.mts"

const soloDigitos = (s: string) => s.replace(/[^0-9A-Za-z]/g, "")

async function perfilesPorCedula(ced: string) {
  const d = await rest("GET", "perfiles?select=id,email,activo&cedula=eq." + encodeURIComponent(ced))
  return Array.isArray(d) ? d : []
}

export default async (req: Request, context: Context) => {
  try {
    if (req.method !== "POST") throw new HttpError(405, "Método no permitido")
    const accion = context.params?.accion || new URL(req.url).pathname.split("/").pop()
    const b = await req.json().catch(() => ({}))

    if (accion === "login-cedula") {
      const ced = soloDigitos(String(b.cedula || ""))
      const password = String(b.password || "")
      if (!ced || !password) throw new HttpError(400, "Datos incompletos")
      for (const p of await perfilesPorCedula(ced)) {
        const u = await authAdmin("GET", "users/" + p.id).catch(() => null)
        if (!u?.email) continue
        const r = await fetch(SUPA_URL + "/auth/v1/token?grant_type=password", {
          method: "POST",
          headers: { apikey: ANON, "Content-Type": "application/json" },
          body: JSON.stringify({ email: u.email, password }),
        })
        if (r.ok) return json(await r.json())
      }
      return json({ error: "Correo/cédula o contraseña incorrectos" }, 400)
    }

    if (accion === "recuperar") {
      const ident = String(b.identificador || "").trim()
      if (!ident) throw new HttpError(400, "Escribe tu cédula o correo")
      let perfiles: any[] = []
      if (ident.includes("@")) {
        const d = await rest("GET", "perfiles?select=id,email&email=ilike." + encodeURIComponent(ident))
        perfiles = Array.isArray(d) ? d : []
        // Usuarios cuyo correo de Auth es el real pero no está en perfiles: Supabase lo resuelve
        if (!perfiles.length) {
          await enviarRecuperacion(ident).catch(() => {})
          return json({ ok: true })
        }
      } else {
        perfiles = await perfilesPorCedula(soloDigitos(ident))
      }
      for (const p of perfiles) {
        try {
          const correo = await asegurarCorreoAuth(p.id, p.email)
          if (correo) await enviarRecuperacion(correo)
        } catch (e) {
          console.error("recuperar:", (e as Error).message)
        }
      }
      return json({ ok: true })
    }

    throw new HttpError(404, "No encontrado")
  } catch (e) {
    return errorResp(e)
  }
}

export const config: Config = {
  path: "/api/publico/:accion",
  method: ["POST"],
  rateLimit: { windowLimit: 15, windowSize: 60, aggregateBy: ["ip", "domain"] },
}
