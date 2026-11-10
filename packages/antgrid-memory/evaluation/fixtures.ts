// SPDX-License-Identifier: MPL-2.0

export type EvaluationDocument = {
  id: string;
  content: string;
  applicability?: string;
  title?: string;
  description?: string;
};
export type EvaluationQuery = {
  id: string;
  category: "concise" | "long" | "ambiguous" | "legacy";
  query: string;
  relevant: string[];
  judgement: string;
};

// These labels describe the requested fact before either ranker is executed.
// Generated context makes document length explicit without borrowing user notes.
export const JUDGEMENT_VERSION = "synthetic-source-facts-v1";
function procedureContext(subject: string): string {
  return Array.from({ length: 18 }, (_, index) => `\n\n## Review checkpoint ${index + 1}\nThe ${subject} procedure records the observed input and the expected outcome separately. The operator keeps a copy of the original artifact, writes the reproduction steps, and checks the result before proceeding. A second reviewer checks that the evidence supports the stated conclusion. A successful example does not establish behavior for untested environments. If the result differs, stop this procedure, preserve the evidence, and record the unresolved question. A changed assumption requires a new reviewed revision rather than silently replacing the earlier account.`).join("");
}
const long = (id: string, title: string, description: string, fact: string, applicability: string): EvaluationDocument => ({
  id, title, description, content: fact + procedureContext("release verification"), applicability,
});

export const DOCUMENTS: EvaluationDocument[] = [
  { id: "oauth-port", title: "Loopback OAuth callback port", description: "Avoid local login collisions by using the actual bound address.", content: "The desktop browser sign-in callback binds an ephemeral loopback port. Read the bound port before opening the authorization URL; assuming a fixed port can send the browser to an unrelated process.", applicability: "Synthetic desktop authentication client." },
  { id: "sqlite-network", title: "SQLite WAL on network filesystems", description: "Keep the database on a local filesystem with shared-memory support.", content: "SQLite WAL uses shared-memory coordination. The fictional team keeps its mutable database on the local disk and copies a completed export to a network share instead of opening the live store there." },
  { id: "ime-submit", title: "IME Enter must finish composition", description: "Do not submit a form while its input method is composing text.", content: "The message editor checks isComposing before treating Enter as submission. Otherwise a Japanese input method can send a partially composed message." },
  { id: "tenant-cache", title: "Tenant cache keys prevent data leakage", description: "Partition cached responses by tenant and authorization context.", content: "The response cache key includes tenant identity and permission version. A cache entry keyed only by resource number can expose one tenant's data to another. Invalidate entries after a permission change." },
  { id: "webhook-retry", title: "Payment webhook retry idempotency", description: "A delivery identifier makes repeated webhook attempts safe.", content: "Persist the webhook delivery identifier with the payment update in one transaction. A retry with the same identifier returns the original outcome rather than applying the payment twice." },
  { id: "crlf-snapshot", title: "CRLF snapshot failures on Windows", description: "Compare normalized text when line-ending style is irrelevant.", content: "The text snapshot fixture normalizes CRLF to LF before comparison. Preserve line endings when the test is specifically checking byte identity. This fixes otherwise spurious Windows build failures." },
  { id: "windows-path", title: "Windows PATH configuration merge", description: "Preserve existing executable directories when extending child environments.", content: "Windows environment names are case-insensitive. Merge Path and PATH into one child environment entry; do not overwrite the search path with only the newly installed tool directory." },
  { id: "tls-hostname", title: "Certificate hostname mismatch", description: "A trusted certificate can still name the wrong host.", content: "Verify that the requested DNS name appears in the certificate subject alternative names. Adding a CA certificate does not fix a hostname mismatch." },
  { id: "nullable-backfill", title: "Nullable migration backfill and rollback", description: "Separate adding a nullable column from requiring values.", content: "Add the new nullable column, backfill existing rows, verify coverage, then require non-null values. Keep the old read path until rollback no longer needs it; a schema rollback cannot recover data discarded too early." },
  { id: "json-stdout", title: "JSON stdout cannot contain logs", description: "Send diagnostics to stderr in a machine-readable CLI.", content: "The CLI prints exactly one JSON result to stdout. Progress messages, startup warnings and debug logs go to stderr so the consumer can parse the response without stripping arbitrary lines." },

  long("archive-date", "Windows archive date locale", "ISO input avoids day/month inversion under the documented Windows locale.", "The fictional Lark archive fixture accepts yyyy-MM-dd on Windows when the regional format is dd/MM/yyyy. Its recorded example maps 2026-04-03 to April 3. The macOS 3.2 fixture rejects that input and needs --date-format yyyy-MM-dd. Dates are written in UTC; other versions were not executed.", "Windows dd/MM/yyyy; distinct macOS 3.2 condition."),
  long("android-jdk", "Android Java build environment", "The Android Gradle build needs the configured JDK, independently of the editor.", "In the synthetic Android build, Gradle uses the JDK selected by JAVA_HOME. Editing Java source in an IDE does not change the child build environment. On Windows, check the selected executable and its version before changing dependencies.", "Synthetic Android Gradle build on Windows."),
  long("worktree-cleanup", "Worktree merge cleanup", "Remove an isolated checkout only after preserving work and checking the destination.", "The checkout cleanup procedure verifies that the reviewed changes exist in the destination branch and no process owns the worktree directory. A finished agent turn alone does not establish that a merge happened. Preserve uncommitted files before removal.", "Local Git worktrees."),
  long("mobile-lease", "Mobile reconnect session lease", "A reconnect must renew authorization instead of reviving an expired transport.", "The mobile connection binds its session to an authorization lease. After expiry the old session must not resume delivering commands. Reconnect obtains a new valid lease and reopens the admitted project streams.", "Synthetic mobile remote-control client."),
  long("exif-rotation", "Image EXIF rotation", "Orient decoded pixels once before creating image thumbnails.", "The photo importer applies EXIF orientation to decoded pixels before thumbnail creation. Copying the orientation tag onto already rotated pixels rotates the displayed thumbnail twice.", "JPEG uploads with EXIF orientation."),
  long("unicode-filename", "Unicode filename normalization", "Normalize lookup keys without rewriting the displayed filename.", "The synchronizer compares filenames using a documented Unicode normalization form. Composed and decomposed accented text can name the same displayed file. Keep the original spelling for display and preserve filesystem-specific collision handling.", "Cross-platform filename synchronization."),
  long("postgres-lock", "Postgres advisory migration lock", "Serialize schema runners with a transaction-scoped advisory lock.", "The deployment runner acquires a Postgres transaction-scoped advisory lock before applying schema changes. The lock is released by transaction completion. This prevents two deployment processes from applying the same migration concurrently.", "Synthetic Postgres deployment pipeline."),
  long("esm-extension", "TypeScript ESM import extension", "Emitted JavaScript imports must resolve in the target runtime.", "The Node ESM build emits imports with the JavaScript extension expected at runtime. A TypeScript-only module resolver accepting an extensionless import does not prove that the emitted application can load it.", "Node ESM output; not a bundler-only application."),
  long("stream-cancel", "Stream cancellation cleanup", "Release readers and bounded buffers when a consumer cancels.", "When a stream consumer cancels, the producer stops writing, releases the reader and discards its bounded buffer. Cancellation must propagate through the pipe; merely hiding the progress indicator leaves the producer running.", "Synthetic asynchronous stream pipeline."),
  long("export-snapshot", "Export snapshot consistency and order", "A sequence watermark excludes later inserts while revision checks detect changes.", "The JSON export fixes a record sequence watermark and timestamp at its first page. Keyset ordering uses stable record identifiers. Later inserts are excluded; an update or deletion in the exported context invalidates the remaining pages.", "Multi-page local-store exports."),

  { id: "legacy-eresolve", content: "An npm ERESOLVE peer dependency error can mean that the selected package versions require incompatible peers. Compare the declared peer ranges before forcing installation; the synthetic fixture used matching major versions." },
  { id: "legacy-busy", content: "SQLITE_BUSY during a short transaction should use bounded asynchronous retries and a short busy timeout. A long synchronous wait blocks the application event loop. Reuse the same operation identity when retrying a write." },
  { id: "legacy-429", content: "On HTTP 429, honor a valid Retry-After response header. Retry only within the operation budget and only when the request can be repeated safely." },
  { id: "legacy-port", content: "EADDRINUSE on port 4317 means another process already owns the telemetry listener. Inspect the listener owner or choose another configured port before retrying startup." },
  { id: "legacy-ca", content: "The x509 unknown authority error means this client does not trust the issuing certificate authority. Install the intended development CA in the client's trust configuration; disabling verification hides the cause." },
  { id: "legacy-cmake", content: "The synthetic CMake install failed under Program Files because an earlier configure cached the wrong install prefix. Correct the prefix in a fresh build directory; repeatedly rebuilding leaves the cached value intact.", applicability: "Windows local build fixture." },
  { id: "legacy-tokyo", content: "東京の予定はタイムゾーン Asia/Tokyo を明示して保存する。表示端末のタイムゾーンだけに依存すると日付が変わる。", applicability: "Synthetic Japanese scheduling note." },
  { id: "legacy-korean", content: "설정 저장 실패 시 임시 파일을 먼저 기록한 뒤 원자적으로 교체한다. 저장 실패를 성공으로 표시하지 않는다.", applicability: "Synthetic Korean settings note." },
  { id: "legacy-token-path", content: "src/parser/token_stream.ts owns the token buffer for the fictional parser. Peek does not consume a token; advance updates the read position. Keep the end-of-input sentinel distinct from an empty string." },
  { id: "legacy-idle", content: "The synthetic proxy can reset connection after its idle timeout. Configure a suitable keepalive or reconnect the client; a successful initial connection does not establish an unlimited idle lifetime." },

  { id: "token-renewal", title: "OAuth token renewal", description: "Refresh access before expiration without losing the latest refresh credential.", content: "Persist a rotated refresh credential before replacing the previous value. If concurrent renewals race, serialize them per account. Never log either token." },
  { id: "browser-session", title: "Browser session expiry", description: "Expired login cookies require renewed user authentication.", content: "A browser session cookie carries an expiry. An expired login session must authenticate again even if its websocket connection is still open." },
  { id: "unicode-search", title: "Unicode search tokenization", description: "Index words in the original language and test punctuation separately.", content: "The search parser keeps Unicode letters and numbers as query tokens. Punctuation-only text has no searchable tokens. Do not strip non-Latin text when building the search expression." },
  { id: "oauth-copy", title: "Login page copy", description: "Wording for the authorization screen.", content: "The login page mentions OAuth and the browser callback. Its help text repeats callback port when describing support tickets. This note records wording, not the port allocation algorithm." },
  { id: "sqlite-backup", title: "Database backup checklist", content: "Archive a SQLite database after its WAL checkpoint finishes. The checklist mentions network storage as a destination for the completed backup, not for the mutable live database." },
  { id: "date-calendar", title: "Calendar date display", content: "A calendar shows date labels in the Windows locale. Date display and locale preferences do not determine which date syntax the archive exporter accepts." },
  { id: "java-editor", title: "Java editor syntax colors", content: "The Java editor highlights keywords and comments. Java source coloring is independent of the Android build environment and Gradle JDK selection." },
  { id: "worktree-label", title: "Worktree label in sidebar", content: "The sidebar presents the worktree branch and merge badge. A cleanup action has a separate confirmation. This is the display layout, not proof that any changes have merged." },
  { id: "image-layout", title: "Image thumbnail grid", content: "The image grid reserves an aspect-ratio box for each thumbnail. EXIF metadata is shown in a details panel; this layout note does not specify pixel rotation." },
  { id: "export-button", title: "Export button order", content: "The toolbar places Export after Filter. Button order is independent of record ordering or snapshot consistency in the downloaded file." },
  { id: "token-theme", title: "Token color theme", content: "The syntax theme colors a parser token according to its category. This has no relation to OAuth credential renewal or authorization expiry." },
  { id: "migration-ui", title: "Migration progress labels", content: "The schema migration screen labels backfill, verification and rollback stages. Progress wording does not implement a nullable-column migration or a transaction lock." },
];

export const QUERIES: EvaluationQuery[] = [
  { id: "c01", category: "concise", query: "loopback OAuth callback port", relevant: ["oauth-port"], judgement: "Requests callback allocation behavior, not login-page wording." },
  { id: "c02", category: "concise", query: "SQLite WAL network filesystem", relevant: ["sqlite-network"], judgement: "Requests where the live database may run; completed backup placement is not an answer." },
  { id: "c03", category: "concise", query: "IME Enter submit", relevant: ["ime-submit"], judgement: "Requests composition-aware message submission." },
  { id: "c04", category: "concise", query: "tenant cache key leakage", relevant: ["tenant-cache"], judgement: "Requests tenant isolation in cached responses." },
  { id: "c05", category: "concise", query: "payment webhook retry idempotency", relevant: ["webhook-retry"], judgement: "Requests protection against duplicate payment delivery." },
  { id: "c06", category: "concise", query: "CRLF snapshot Windows", relevant: ["crlf-snapshot"], judgement: "Requests the line-ending snapshot fix." },
  { id: "c07", category: "concise", query: "PATH child environment Windows", relevant: ["windows-path"], judgement: "Requests child executable search-path merging." },
  { id: "c08", category: "concise", query: "certificate hostname mismatch", relevant: ["tls-hostname"], judgement: "Wrong host naming differs from an untrusted issuing CA." },
  { id: "c09", category: "concise", query: "nullable column backfill", relevant: ["nullable-backfill"], judgement: "Requests migration ordering, not progress-label copy." },
  { id: "c10", category: "concise", query: "JSON stdout logs", relevant: ["json-stdout"], judgement: "Requests machine-readable CLI output separation." },

  { id: "l01", category: "long", query: "archive Windows date locale", relevant: ["archive-date"], judgement: "Requests documented exporter input conditions, not calendar labels." },
  { id: "l02", category: "long", query: "Android Java build JDK", relevant: ["android-jdk"], judgement: "Requests Gradle runtime selection, not editor syntax colors." },
  { id: "l03", category: "long", query: "worktree merge cleanup", relevant: ["worktree-cleanup"], judgement: "Requests safe checkout removal conditions, not a sidebar badge." },
  { id: "l04", category: "long", query: "mobile reconnect lease", relevant: ["mobile-lease"], judgement: "Requests transport authorization renewal." },
  { id: "l05", category: "long", query: "image EXIF rotation", relevant: ["exif-rotation"], judgement: "Requests pixel orientation, not thumbnail layout." },
  { id: "l06", category: "long", query: "Unicode filename normalization", relevant: ["unicode-filename"], judgement: "Requests normalization for filename identity, not query tokenization." },
  { id: "l07", category: "long", query: "Postgres advisory migration lock", relevant: ["postgres-lock"], judgement: "Requests cross-process deployment serialization." },
  { id: "l08", category: "long", query: "TypeScript ESM import extension", relevant: ["esm-extension"], judgement: "Requests emitted module-path compatibility." },
  { id: "l09", category: "long", query: "stream cancellation cleanup", relevant: ["stream-cancel"], judgement: "Requests cancellation propagation and resource release." },
  { id: "l10", category: "long", query: "export snapshot consistency", relevant: ["export-snapshot"], judgement: "Requests a coherent multi-page data export, not a toolbar layout." },

  { id: "a01", category: "ambiguous", query: "date formatting", relevant: ["archive-date", "date-calendar"], judgement: "Without input-versus-display context, both documented date syntax and display formatting are relevant." },
  { id: "a02", category: "ambiguous", query: "token renewal", relevant: ["token-renewal"], judgement: "Renewal selects authorization tokens; parser tokens are not renewed." },
  { id: "a03", category: "ambiguous", query: "session expiry", relevant: ["mobile-lease", "browser-session"], judgement: "Both transport authorization and browser login explain a session expiring." },
  { id: "a04", category: "ambiguous", query: "port collision", relevant: ["oauth-port", "legacy-port"], judgement: "Both dynamic allocation and diagnosing a listener owner address local port collisions." },
  { id: "a05", category: "ambiguous", query: "Java configuration", relevant: ["android-jdk"], judgement: "The corpus's Java runtime configuration is the JDK selection; syntax colors do not configure it." },
  { id: "a06", category: "ambiguous", query: "schema rollback", relevant: ["nullable-backfill"], judgement: "Requests preserving rollback compatibility; progress labels and serialization alone do not supply it." },
  { id: "a07", category: "ambiguous", query: "stream buffer", relevant: ["stream-cancel", "legacy-token-path"], judgement: "Both producer buffers and the parser's token stream buffer are relevant without further context." },
  { id: "a08", category: "ambiguous", query: "export order", relevant: ["export-snapshot", "export-button"], judgement: "The query does not distinguish data order from command placement." },
  { id: "a09", category: "ambiguous", query: "Windows build", relevant: ["android-jdk", "legacy-cmake", "crlf-snapshot"], judgement: "All three describe concrete failures or configuration in Windows builds." },
  { id: "a10", category: "ambiguous", query: "Unicode search", relevant: ["unicode-search", "unicode-filename"], judgement: "Both query tokenization and normalized filename lookup can answer this underspecified search request." },

  { id: "g01", category: "legacy", query: "npm ERESOLVE peer", relevant: ["legacy-eresolve"], judgement: "The legacy note directly diagnoses incompatible package peer ranges." },
  { id: "g02", category: "legacy", query: "SQLITE_BUSY timeout", relevant: ["legacy-busy"], judgement: "Requests lock-wait retry behavior, not network filesystem placement." },
  { id: "g03", category: "legacy", query: "HTTP 429 Retry-After", relevant: ["legacy-429"], judgement: "Requests handling the specific response code and retry header." },
  { id: "g04", category: "legacy", query: "EADDRINUSE 4317", relevant: ["legacy-port"], judgement: "The exact listener error and port are documented in the legacy note." },
  { id: "g05", category: "legacy", query: "x509 unknown authority", relevant: ["legacy-ca"], judgement: "Requests issuing-CA trust, not hostname matching." },
  { id: "g06", category: "legacy", query: "CMake Program Files install", relevant: ["legacy-cmake"], judgement: "Requests the cached install-prefix failure." },
  { id: "g07", category: "legacy", query: "東京 タイムゾーン", relevant: ["legacy-tokyo"], judgement: "Original-language terms ask for the Tokyo timezone scheduling note." },
  { id: "g08", category: "legacy", query: "설정 저장 실패", relevant: ["legacy-korean"], judgement: "Original-language terms ask for the settings-save failure note." },
  { id: "g09", category: "legacy", query: "src/parser/token_stream.ts", relevant: ["legacy-token-path"], judgement: "The exact source path identifies the token-buffer ownership note." },
  { id: "g10", category: "legacy", query: '"reset connection" "idle timeout"', relevant: ["legacy-idle"], judgement: "Quoted phrases request the idle proxy reset behavior." },
];

const backgroundTopics = [
  ["Inventory dashboard", "The inventory dashboard groups stock observations by warehouse. A monthly report records item counts and shipping delays."],
  ["Windows screenshot review", "The Windows screenshot review checks panel alignment, accessible labels and contrast. Product screenshots are reviewed before publication."],
  ["Session dashboard layout", "A session dashboard arranges recent activities by workspace. The design review changes spacing and labels without modifying runtime behavior."],
  ["Cache metrics chart", "The cache metrics chart displays hit counts and chart legends. The analytics review concerns the visual presentation of measurements."],
  ["Export icon artwork", "The export icon artwork uses the product's existing line weight. The design record tracks approved shapes and toolbar spacing."],
  ["Build newsletter", "The build newsletter summarizes the team's weekly milestones. Editorial review checks spelling and publication dates."],
  ["Image caption review", "An image caption identifies the illustrated workflow. Reviewers check terminology, alt text and translation consistency."],
  ["Migration documentation index", "The documentation index links release notes and team meeting summaries. It tracks section names and ownership assignments."],
];
export function corpus(size: number): EvaluationDocument[] {
  if (size < DOCUMENTS.length) throw new Error(`Corpus must include all ${DOCUMENTS.length} judged documents`);
  return [...DOCUMENTS, ...Array.from({ length: size - DOCUMENTS.length }, (_, index) => {
    const topic = backgroundTopics[index % backgroundTopics.length]!;
    return { id: `background-${String(index).padStart(6, "0")}`, title: `${topic[0]} ${index + 1}`, description: `Synthetic supporting record in collection ${index % 37}.`, content: `${topic[1]} Review item ${index + 1} belongs to collection ${index % 37}. Its acceptance status concerns this artifact only.` };
  })];
}
