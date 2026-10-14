export const CLIPBOARD_VERSION = 1;
export const CLIPBOARD_MAX_BYTES = 100_000;
export const CLIPBOARD_MAX_BASE64 = 133_336;
export const CLIPBOARD_MAX_WIRE_BYTES = 140 * 1024;
export const CLIPBOARD_LIFETIME_MS = 5_000;

export function decodeClipboardText(encoded: string): string | undefined {
  if (!encoded.length || encoded.length > CLIPBOARD_MAX_BASE64 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) return;
  const bytes = Buffer.from(encoded, "base64");
  if (!bytes.length || bytes.length > CLIPBOARD_MAX_BYTES || bytes.toString("base64") !== encoded) return;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return text.includes("\0") ? undefined : text;
  } catch { return; }
}
