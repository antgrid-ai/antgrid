// A suite launched from an Antgrid terminal inherits that terminal's identity,
// which hooks and the MCP server stamp onto every payload a test asserts on.
// Only the terminal-stamped set: ANTGRID_DIR and debug knobs are set on purpose.
for (const key of ["ANTGRID_RUN_ID", "ANTGRID_TERMINAL_ID", "ANTGRID_API_PORT"]) {
  delete process.env[key];
}
