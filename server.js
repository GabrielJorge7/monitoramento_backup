const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { Pool } = require("pg");
const crypto = require("node:crypto");

const port = Number(process.env.PORT || 8787);
const token = process.env.MONITOR_TOKEN || "";
const offlineMinutes = Number(process.env.OFFLINE_MINUTES || 15);
const adminEmail = String(process.env.ADMIN_EMAIL || "").trim().toLowerCase();
const adminPassword = String(process.env.ADMIN_PASSWORD || "");
const dashboardPath = path.join(__dirname, "monitoramento-backup.html");
const localStoragePath = path.join(__dirname, "clientes");
const pool = process.env.DATABASE_URL
  ? new Pool({ connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } })
  : null;

function send(response, statusCode, contentType, body) {
  response.writeHead(statusCode, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
  });
  response.end(body);
}

function sendJson(response, statusCode, value) {
  send(response, statusCode, "application/json; charset=utf-8", JSON.stringify(value));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function parseCookies(request) {
  return Object.fromEntries((request.headers.cookie || "").split(";").filter(Boolean).map(item => {
    const separator = item.indexOf("=");
    return [item.slice(0, separator).trim(), decodeURIComponent(item.slice(separator + 1).trim())];
  }));
}

function hashPassword(password, salt = crypto.randomBytes(16).toString("hex")) {
  return new Promise((resolve, reject) => crypto.scrypt(password, salt, 64, (error, key) => {
    if (error) reject(error);
    else resolve(`${salt}:${key.toString("hex")}`);
  }));
}

async function verifyPassword(password, storedHash) {
  const [salt, expected] = String(storedHash).split(":");
  const actual = (await hashPassword(password, salt)).split(":")[1];
  return expected && actual && crypto.timingSafeEqual(Buffer.from(actual, "hex"), Buffer.from(expected, "hex"));
}

async function createSession(userId) {
  const rawToken = crypto.randomBytes(32).toString("base64url");
  const sessionHash = crypto.createHash("sha256").update(rawToken).digest("hex");
  await pool.query("INSERT INTO auth_sessions (token_hash, user_id, expires_at) VALUES ($1, $2, NOW() + INTERVAL '12 hours')", [sessionHash, userId]);
  return rawToken;
}

async function getSessionUser(request) {
  if (!pool) return null;
  const rawToken = parseCookies(request).monitor_session;
  if (!rawToken) return null;
  const sessionHash = crypto.createHash("sha256").update(rawToken).digest("hex");
  const result = await pool.query(`
    SELECT u.id, u.email, u.name, u.role
    FROM auth_sessions s JOIN users u ON u.id = s.user_id
    WHERE s.token_hash = $1 AND s.expires_at > NOW() AND u.active = TRUE
  `, [sessionHash]);
  return result.rows[0] || null;
}

async function requireUser(request, response) {
  const user = await getSessionUser(request);
  if (!user) {
    sendJson(response, 401, { erro: "Login necessario." });
    return null;
  }
  return user;
}

function sessionCookie(tokenValue, maxAge = 43200) {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  return `monitor_session=${encodeURIComponent(tokenValue)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${maxAge}${secure}`;
}

function safeClientId(value) {
  const safe = String(value || "").replace(/[^a-zA-Z0-9._-]/g, "_");
  if (!safe) throw new Error("ClienteId invalido.");
  return safe;
}

function isOffline(receivedAt) {
  return (Date.now() - new Date(receivedAt).getTime()) / 60000 > offlineMinutes;
}

function clientSummary(report, receivedAt) {
  const offline = isOffline(receivedAt);
  return {
    ClienteId: String(report.ClienteId),
    ClienteNome: String(report.ClienteNome || report.ClienteId),
    Cnpj: String(report.Cnpj || ""),
    NomeLoja: String(report.NomeLoja || report.ClienteNome || report.ClienteId),
    Responsavel: String(report.Responsavel || ""),
    Servidor: String(report.Servidor || ""),
    Status: offline ? "offline" : String(report.Status || "sem_backup"),
    StatusLocal: String(report.Status || "sem_backup"),
    UltimoContato: receivedAt,
    GeradoEm: report.GeradoEm || null,
    UltimoBackup: report.UltimoBackup || null,
    IdadeUltimoBackupHoras: report.IdadeUltimoBackupHoras ?? null,
    BackupsEncontrados: Number(report.BackupsEncontrados || 0),
  };
}

function localClientPath(clientId) {
  return path.join(localStoragePath, `${safeClientId(clientId)}.json`);
}

async function saveReport(report) {
  const receivedAt = new Date().toISOString();
  if (pool) {
    await pool.query(`
      INSERT INTO client_reports (client_id, received_at, report)
      VALUES ($1, $2, $3::jsonb)
      ON CONFLICT (client_id) DO UPDATE SET received_at = EXCLUDED.received_at, report = EXCLUDED.report
    `, [String(report.ClienteId), receivedAt, JSON.stringify(report)]);
    return;
  }

  fs.mkdirSync(localStoragePath, { recursive: true });
  fs.writeFileSync(localClientPath(report.ClienteId), JSON.stringify({ RecebidoEm: receivedAt, Relatorio: report }, null, 2));
}

async function getStoredReports() {
  if (pool) {
    const result = await pool.query("SELECT client_id, received_at, report FROM client_reports");
    return result.rows.map(row => ({ receivedAt: row.received_at, report: row.report }));
  }

  if (!fs.existsSync(localStoragePath)) return [];
  return fs.readdirSync(localStoragePath)
    .filter(file => file.endsWith(".json"))
    .map(file => {
      try {
        const envelope = JSON.parse(fs.readFileSync(path.join(localStoragePath, file), "utf8"));
        return { receivedAt: envelope.RecebidoEm, report: envelope.Relatorio };
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function getReport(clientId) {
  if (pool) {
    const result = await pool.query("SELECT report FROM client_reports WHERE client_id = $1", [clientId]);
    return result.rows[0]?.report || null;
  }

  const filePath = localClientPath(clientId);
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf8")).Relatorio;
}

async function statusPayload() {
  const storedReports = await getStoredReports();
  const clients = storedReports
    .map(item => clientSummary(item.report, item.receivedAt))
    .sort((left, right) => `${left.Status}-${left.ClienteNome}`.localeCompare(`${right.Status}-${right.ClienteNome}`));
  return {
    GeradoEm: new Date().toISOString(),
    Resumo: {
      Total: clients.length,
      Ok: clients.filter(client => client.Status === "ok").length,
      Atrasados: clients.filter(client => client.Status === "atrasado").length,
      Invalidos: clients.filter(client => client.Status === "invalido").length,
      SemBackup: clients.filter(client => client.Status === "sem_backup").length,
      Offline: clients.filter(client => client.Status === "offline").length,
    },
    Clientes: clients,
  };
}

async function initializeDatabase() {
  if (!pool) {
    console.warn("DATABASE_URL nao configurada; login exige PostgreSQL.");
    return;
  }
  await pool.query(`
    CREATE TABLE IF NOT EXISTS client_reports (
      client_id TEXT PRIMARY KEY,
      received_at TIMESTAMPTZ NOT NULL,
      report JSONB NOT NULL
    )
  `);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id BIGSERIAL PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('admin', 'collaborator')),
      active BOOLEAN NOT NULL DEFAULT TRUE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE TABLE IF NOT EXISTS auth_sessions (
      token_hash TEXT PRIMARY KEY,
      user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      expires_at TIMESTAMPTZ NOT NULL
    );
  `);
  if (adminEmail && adminPassword) {
    const existing = await pool.query("SELECT id FROM users WHERE email = $1", [adminEmail]);
    if (existing.rowCount === 0) {
      await pool.query("INSERT INTO users (email, name, password_hash, role) VALUES ($1, $2, $3, 'admin')", [adminEmail, "Administrador", await hashPassword(adminPassword)]);
      console.log(`Administrador inicial criado: ${adminEmail}`);
    }
  }
}

const server = http.createServer(async (request, response) => {
  try {
    const requestUrl = new URL(request.url, `http://${request.headers.host || "localhost"}`);
    const requestPath = requestUrl.pathname;

    if (requestPath === "/api/auth/me" && request.method === "GET") {
      if (!pool) { sendJson(response, 503, { erro: "Configure DATABASE_URL para habilitar o login." }); return; }
      sendJson(response, 200, { usuario: await getSessionUser(request) });
      return;
    }

    if (requestPath === "/api/auth/login" && request.method === "POST") {
      if (!pool) { sendJson(response, 503, { erro: "Configure DATABASE_URL para habilitar o login." }); return; }
      const body = JSON.parse(await readBody(request));
      const result = await pool.query("SELECT * FROM users WHERE email = $1 AND active = TRUE", [String(body.email || "").trim().toLowerCase()]);
      const user = result.rows[0];
      if (!user || !(await verifyPassword(String(body.password || ""), user.password_hash))) {
        sendJson(response, 401, { erro: "E-mail ou senha invalidos." });
        return;
      }
      const sessionToken = await createSession(user.id);
      response.setHeader("Set-Cookie", sessionCookie(sessionToken));
      sendJson(response, 200, { usuario: { id: user.id, email: user.email, name: user.name, role: user.role } });
      return;
    }

    if (requestPath === "/api/auth/logout" && request.method === "POST") {
      const rawToken = parseCookies(request).monitor_session;
      if (pool && rawToken) await pool.query("DELETE FROM auth_sessions WHERE token_hash = $1", [crypto.createHash("sha256").update(rawToken).digest("hex")]);
      response.setHeader("Set-Cookie", sessionCookie("", 0));
      sendJson(response, 200, { ok: true });
      return;
    }

    if (requestPath === "/" && request.method === "GET") {
      if (!pool) { send(response, 503, "text/plain; charset=utf-8", "Configure DATABASE_URL para habilitar o login."); return; }
      send(response, 200, "text/html; charset=utf-8", fs.readFileSync(dashboardPath));
      return;
    }

    if (requestPath === "/api/report" && request.method === "POST") {
      if (token && request.headers["x-monitor-token"] !== token) {
        sendJson(response, 401, { erro: "Token invalido." });
        return;
      }
      const report = JSON.parse(await readBody(request));
      if (!report.ClienteId) throw new Error("O relatorio precisa informar ClienteId.");
      await saveReport(report);
      sendJson(response, 200, { recebido: true });
      return;
    }

    if (requestPath === "/api/status" && request.method === "GET") {
      if (!await requireUser(request, response)) return;
      sendJson(response, 200, await statusPayload());
      return;
    }

    if (requestPath.startsWith("/api/client/") && request.method === "GET") {
      if (!await requireUser(request, response)) return;
      const clientId = decodeURIComponent(requestPath.slice("/api/client/".length));
      const report = await getReport(clientId);
      if (!report) {
        sendJson(response, 404, { erro: "Cliente nao encontrado." });
        return;
      }
      sendJson(response, 200, report);
      return;
    }

    if (requestPath === "/api/users" && request.method === "GET") {
      const user = await requireUser(request, response);
      if (!user) return;
      if (user.role !== "admin") { sendJson(response, 403, { erro: "Acesso restrito ao administrador." }); return; }
      const result = await pool.query("SELECT id, email, name, role, active, created_at FROM users ORDER BY name");
      sendJson(response, 200, { usuarios: result.rows });
      return;
    }

    if (requestPath === "/api/users" && request.method === "POST") {
      const user = await requireUser(request, response);
      if (!user) return;
      if (user.role !== "admin") { sendJson(response, 403, { erro: "Acesso restrito ao administrador." }); return; }
      const body = JSON.parse(await readBody(request));
      const email = String(body.email || "").trim().toLowerCase();
      const name = String(body.name || "").trim();
      const role = body.role === "admin" ? "admin" : "collaborator";
      if (!email || !name || String(body.password || "").length < 8) throw new Error("Informe nome, e-mail e senha com pelo menos 8 caracteres.");
      const passwordHash = await hashPassword(String(body.password));
      await pool.query("INSERT INTO users (email, name, password_hash, role) VALUES ($1, $2, $3, $4)", [email, name, passwordHash, role]);
      sendJson(response, 201, { criado: true });
      return;
    }

    if (requestPath.startsWith("/api/users/") && request.method === "PATCH") {
      const user = await requireUser(request, response);
      if (!user) return;
      if (user.role !== "admin") { sendJson(response, 403, { erro: "Acesso restrito ao administrador." }); return; }
      const userId = Number(requestPath.slice("/api/users/".length));
      if (userId === user.id) throw new Error("O administrador atual nao pode ser desativado.");
      await pool.query("UPDATE users SET active = NOT active WHERE id = $1", [userId]);
      sendJson(response, 200, { atualizado: true });
      return;
    }

    if (requestPath.startsWith("/api/users/") && request.method === "DELETE") {
      const user = await requireUser(request, response);
      if (!user) return;
      if (user.role !== "admin") { sendJson(response, 403, { erro: "Acesso restrito ao administrador." }); return; }
      const userId = Number(requestPath.slice("/api/users/".length));
      if (!Number.isInteger(userId)) throw new Error("Usuario invalido.");
      if (userId === user.id) throw new Error("O administrador atual nao pode excluir a propria conta.");
      await pool.query("DELETE FROM users WHERE id = $1", [userId]);
      sendJson(response, 200, { excluido: true });
      return;
    }

    send(response, 404, "text/plain; charset=utf-8", "Nao encontrado");
  } catch (error) {
    sendJson(response, 500, { erro: error.message });
  }
});

initializeDatabase()
  .then(() => server.listen(port, "0.0.0.0", () => console.log(`Central ouvindo na porta ${port}`)))
  .catch(error => {
    console.error("Falha ao inicializar o central:", error);
    process.exit(1);
  });
