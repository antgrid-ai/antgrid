// A deterministic PTY workload: a log burst, followed by small fullscreen edits.
export {};
for (let i = 0; i < 1000; i++) process.stdout.write(`history row ${i}\r\n`);
process.stdout.write("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[?1000h\x1b[?1006h");
process.stdout.write("Terminal frame prototype\r\n");
process.stdout.write("\x1b]8;;https://example.com/report\x1b\\\x1b[38;2;30;180;220mOpen report\x1b]8;;\x1b\\\x1b[0m");
for (let i = 0; i < 120; i++) {
  process.stdout.write(`\x1b[?2026h\x1b[4;1HUpdate ${String(i).padStart(3)} ${"|/-\\"[i % 4]}\x1b[K`);
  await Bun.sleep(2);
  process.stdout.write("\x1b[?2026l");
  await Bun.sleep(14);
}
process.stdout.write("\x1b[5;1HComplete\x1b[?25h");
