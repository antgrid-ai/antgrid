type LogLevel = "debug" | "info" | "warn" | "error";

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

let currentLevel: LogLevel = "info";
let jsonMode = false;

export function setLogLevel(level: LogLevel): void {
  currentLevel = level;
}

export function setJsonMode(enabled: boolean): void {
  jsonMode = enabled;
}

function formatTime(): string {
  const now = new Date();
  const h = String(now.getHours()).padStart(2, "0");
  const m = String(now.getMinutes()).padStart(2, "0");
  const s = String(now.getSeconds()).padStart(2, "0");
  const ms = String(now.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

function log(level: LogLevel, message: string, ...args: unknown[]): void {
  if (LEVEL_ORDER[level] < LEVEL_ORDER[currentLevel]) return;

  if (jsonMode) {
    const msg = args.length > 0 ? message.replace(/%s/g, () => String(args.shift())) : message;
    const fn = level === "error" ? console.error : console.log;
    fn(JSON.stringify({ time: new Date().toISOString(), level, msg }));
    return;
  }

  const tag = level.toUpperCase().padEnd(5);
  const prefix = `${formatTime()} [${tag}]`;
  const fn = level === "error" ? console.error : level === "warn" ? console.warn : console.log;
  fn(prefix, message, ...args);
}

export const logger = {
  debug: (msg: string, ...args: unknown[]) => log("debug", msg, ...args),
  info: (msg: string, ...args: unknown[]) => log("info", msg, ...args),
  warn: (msg: string, ...args: unknown[]) => log("warn", msg, ...args),
  error: (msg: string, ...args: unknown[]) => log("error", msg, ...args),
};
