// Code-unit predicates for the terminal-links scanners. Detection reads every
// line a program prints, so it is written as explicit walks whose cost is
// linear by construction rather than as patterns that each need auditing for
// backtracking.

export function isAsciiLetter(code: number): boolean {
  return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
}

export function isAsciiLower(code: number): boolean {
  return code >= 0x61 && code <= 0x7a;
}

export function isAsciiUpper(code: number): boolean {
  return code >= 0x41 && code <= 0x5a;
}

export function isAsciiDigit(code: number): boolean {
  return code >= 0x30 && code <= 0x39;
}

export function isAsciiAlnum(code: number): boolean {
  return isAsciiLetter(code) || isAsciiDigit(code);
}

/** ASCII letters, digits and `_`: the word characters a word boundary is
 *  judged by. */
export function isWordChar(code: number): boolean {
  return isAsciiAlnum(code) || code === 0x5f;
}

/** ECMAScript white space plus line terminators. */
export function isWhitespace(code: number): boolean {
  if (code <= 0x20) return code === 0x20 || (code >= 0x09 && code <= 0x0d);
  if (code < 0xa0) return false;
  return (
    code === 0xa0 ||
    code === 0x1680 ||
    (code >= 0x2000 && code <= 0x200a) ||
    code === 0x2028 ||
    code === 0x2029 ||
    code === 0x202f ||
    code === 0x205f ||
    code === 0x3000 ||
    code === 0xfeff
  );
}

export function isLineTerminator(code: number): boolean {
  return code === 0x0a || code === 0x0d || code === 0x2028 || code === 0x2029;
}

export function hasLineTerminator(text: string, from = 0): boolean {
  for (let i = from; i < text.length; i++) if (isLineTerminator(text.charCodeAt(i))) return true;
  return false;
}

export function isSeparator(ch: string | undefined): boolean {
  return ch === "/" || ch === "\\";
}

/** `//` or `\\`, in any mix: a UNC or network root where a separator may open a
 *  path. */
export function startsWithDoubleSeparator(path: string): boolean {
  return isSeparator(path[0]) && isSeparator(path[1]);
}

/** `X:` at `at`. */
export function hasDriveLetterAt(text: string, at = 0): boolean {
  return isAsciiLetter(text.charCodeAt(at)) && text.charCodeAt(at + 1) === 0x3a;
}

/** `X:\` or `X:/`. */
export function isDriveAbsolute(path: string): boolean {
  return hasDriveLetterAt(path) && isSeparator(path[2]);
}

/** Drive-qualified on Windows: a bare `\x` or `/x` is rooted on the current
 *  drive, which is not a place a printed path can name. */
export function isAbsoluteFor(path: string, platform: NodeJS.Platform): boolean {
  return platform === "win32" ? isDriveAbsolute(path) : path.startsWith("/");
}

/**
 * The comparison form of a Windows path. It must never merge two names NTFS
 * keeps apart, because a merged pair lets a sibling folder stand in for the
 * checkout's own, so it only ever errs towards "different". A unit folds to its
 * upper case only when that is a single unit that lower-cases back to the same
 * thing the unit itself does, which is a plain case pair. Everything
 * `toUpperCase` does beyond that is refused: U+0131 and U+017F upper-case to
 * ASCII `I` and `S`, and U+00B5 to a Greek capital, none of which NTFS treats as
 * the same name; U+212A KELVIN SIGN is already upper case, so it stays apart
 * from `k`; and `ß` would change the length of the name (`SS`).
 */
export function foldPathCase(path: string): string {
  let ascii = true;
  for (let i = 0; i < path.length; i++) {
    if (path.charCodeAt(i) > 0x7f) {
      ascii = false;
      break;
    }
  }
  if (ascii) return path.toUpperCase();
  let out = "";
  for (let i = 0; i < path.length; i++) {
    const unit = path[i]!;
    const upper = unit.toUpperCase();
    out += upper.length === 1 && upper.toLowerCase() === unit.toLowerCase() ? upper : unit;
  }
  return out;
}

/** Upper-cases ASCII letters and leaves every other code unit exactly as it is,
 *  for names whose non-ASCII characters must compare by identity. */
export function foldAsciiCase(text: string): string {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    out += isAsciiLower(code) ? String.fromCharCode(code - 0x20) : text[i];
  }
  return out;
}

/** `prefix` must be lowercase ASCII; only ASCII letters fold, so no non-ASCII
 *  character can stand in for one of its letters. */
export function startsWithIgnoreCase(text: string, prefix: string, at = 0): boolean {
  if (at + prefix.length > text.length) return false;
  for (let i = 0; i < prefix.length; i++) {
    let code = text.charCodeAt(at + i);
    if (isAsciiUpper(code)) code += 0x20;
    if (code !== prefix.charCodeAt(i)) return false;
  }
  return true;
}
