import { expect, test } from "bun:test";
import { isClipboardUserInput } from "./interaction";

test("guest presses and releases participate without hover, drag motion, or wheel-only activity", () => {
  for (const button of [0, 1, 2, 3, 4, 8, 16, 20]) {
    for (const data of [`\x1b[<${button};10;20M`, `\x1b[<${button};10;20m`, `\x1b[${button + 32};10;20M`, `\x1b[M${String.fromCharCode(button + 32)}!!`]) {
      expect(isClipboardUserInput(data)).toBe(true);
    }
  }
  for (const button of [32, 35, 48, 64, 65, 66, 67, 80]) {
    for (const data of [`\x1b[<${button};10;20M`, `\x1b[${button + 32};10;20M`, `\x1b[M${String.fromCharCode(button + 32)}!!`]) {
      expect(isClipboardUserInput(data)).toBe(false);
    }
  }
});

test("keyboard, IME, paste, and Send count while engine-generated responses do not", () => {
  for (const data of ["hello", "\u4e16\u754c", "\r", "\x03", "\x1b", "\x1b[A", "\x1b[99;6u", "\x1b[200~pasted\x1b[201~"]) {
    expect(isClipboardUserInput(data)).toBe(true);
  }
  for (const data of ["", "\x1b[I", "\x1b[O", "\x1b[?1;2c", "\x1b[>0;136;0c", "\x1b[12;40R", "\x1b[0n", "\x1b[?1;2$y", "\x1b]52;c;?\x07"]) {
    expect(isClipboardUserInput(data)).toBe(false);
  }
});
