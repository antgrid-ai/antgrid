/**
 * Parse a Postgres connection string and return a libpq-style URI.
 *
 * Accepts:
 *   - URI form:      postgres://user:pass@host:port/db
 *   - ADO.NET form:  Host=h;Port=p;Database=d;Username=u;Password=x;...
 *
 * On Windows + local Postgres the admin connection string is often in ADO.NET
 * form (pgAdmin / .NET tooling defaults); most Unix hosts use URIs.
 */
export function toPostgresUri(input: string): string {
  const trimmed = input.trim();
  if (trimmed.startsWith("postgres://") || trimmed.startsWith("postgresql://")) {
    return trimmed;
  }
  if (!trimmed.includes("=")) {
    throw new Error("Unrecognized Postgres connection string format");
  }

  const kv: Record<string, string> = {};
  for (const part of trimmed.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const k = part.slice(0, eq).trim();
    const v = part.slice(eq + 1).trim();
    if (k) kv[k.toLowerCase()] = v;
  }

  let host = kv["host"] ?? kv["server"] ?? "localhost";
  let port = kv["port"];
  if (host.includes(":")) {
    const [h, p] = host.split(":");
    host = h;
    port = port ?? p;
  }
  port = port ?? "5432";

  const db = kv["database"] ?? kv["dbname"] ?? "postgres";
  const user = encodeURIComponent(kv["username"] ?? kv["user id"] ?? kv["user"] ?? "postgres");
  const pass = encodeURIComponent(kv["password"] ?? "");

  return `postgres://${user}:${pass}@${host}:${port}/${encodeURIComponent(db)}`;
}

/** Replace the database-name segment of a libpq URI. */
export function withDatabase(uri: string, dbName: string): string {
  const u = new URL(uri);
  u.pathname = "/" + encodeURIComponent(dbName);
  return u.toString();
}
