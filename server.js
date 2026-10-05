const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { Pool } = require("pg");

const port = Number(process.env.PORT || 8787);
const token = process.env.MONITOR_TOKEN || "";
const offlineMinutes = Number(process.env.OFFLINE_MINUTES || 15);
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
  if (!pool) return;
  await pool.query(`
    CREATE TABLE IF NOT EXISTS client_reports (
      client_id TEXT PRIMARY KEY,
      received_at TIMESTAMPTZ NOT NULL,
      report JSONB NOT NULL
    )
  `);
}

const server = http.createServer(async (request, response) => {
  try {
    const requestUrl = new URL(request.url, `http://${request.headers.host || "localhost"}`);
    const requestPath = requestUrl.pathname;

    if (requestPath === "/" && request.method === "GET") {
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
      sendJson(response, 200, await statusPayload());
      return;
    }

    if (requestPath.startsWith("/api/client/") && request.method === "GET") {
      const clientId = decodeURIComponent(requestPath.slice("/api/client/".length));
      const report = await getReport(clientId);
      if (!report) {
        sendJson(response, 404, { erro: "Cliente nao encontrado." });
        return;
      }
      sendJson(response, 200, report);
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
