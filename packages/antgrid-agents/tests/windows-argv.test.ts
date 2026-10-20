import { describe, expect, test } from "bun:test";
import { expandWindowsEnv, splitWindowsCommandLine, windowsRawArgv } from "../src/agents/windows-argv";

describe("splitWindowsCommandLine", () => {
  test("splits on whitespace and groups double-quoted runs", () => {
    expect(splitWindowsCommandLine("--chrome  --model\tsonnet")).toEqual(["--chrome", "--model", "sonnet"]);
    expect(splitWindowsCommandLine('--append-system-prompt "be brief" --add-dir "C:\\My Notes"'))
      .toEqual(["--append-system-prompt", "be brief", "--add-dir", "C:\\My Notes"]);
    expect(splitWindowsCommandLine('--x="a b"c')).toEqual(["--x=a bc"]);
    expect(splitWindowsCommandLine('""')).toEqual([""]);
  });

  test("keeps backslashes literal unless they precede a quote", () => {
    expect(splitWindowsCommandLine("C:\\a\\b\\ next")).toEqual(["C:\\a\\b\\", "next"]);
    expect(splitWindowsCommandLine('"C:\\dir\\\\" next')).toEqual(["C:\\dir\\", "next"]);
    expect(splitWindowsCommandLine('say \\"hi\\"')).toEqual(["say", '"hi"']);
    expect(splitWindowsCommandLine('"a ""quoted"" word"')).toEqual(['a "quoted" word']);
  });

  test("leaves cmd.exe operators as plain text", () => {
    expect(splitWindowsCommandLine("--a & --b")).toEqual(["--a", "&", "--b"]);
  });
});

describe("expandWindowsEnv", () => {
  const env = { USERPROFILE: "C:\\Users\\Me", Model: "opus" };

  test("expands defined names case-insensitively, as cmd.exe does", () => {
    expect(expandWindowsEnv("--add-dir %userprofile%\\notes --model %MODEL%", env))
      .toBe("--add-dir C:\\Users\\Me\\notes --model opus");
  });

  test("leaves undefined names and stray percents intact", () => {
    expect(expandWindowsEnv("%NOPE% 100% of %USERPROFILE%", env)).toBe("%NOPE% 100% of C:\\Users\\Me");
    expect(expandWindowsEnv("50%", env)).toBe("50%");
  });

  test("expands before splitting, so a spaced value stays one argument only when quoted", () => {
    expect(windowsRawArgv('--add-dir "%D%"', { D: "C:\\My Notes" })).toEqual(["--add-dir", "C:\\My Notes"]);
  });
});
