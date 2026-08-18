import { raw } from "hono/html";
// The master file itself, not a copy of its path data — hand-copying the markup
// into this file is how the header and the URL handed out for external brand
// use drift apart silently. Same reason site/src/components/ui/Wordmark.astro
// imports it out of public/ rather than inlining it. Bun's text import resolves
// at load, so a rename fails at boot instead of rendering a blank header.
import wordmark from "../../public/logo/antgrid-wordmark.svg" with { type: "text" };

// Inlined rather than <img src="/logo/...">: the header sizes the lockup
// `h-7 w-auto`, and an <img> has no aspect ratio to derive a width from until
// the file arrives — so the browser reserves nothing and the beta badge and nav
// slide right once it lands. Inline, the viewBox is in the HTML the shift would
// have happened during, and it costs one fewer request on the critical path.
//
// Sizing lives here rather than at the call site because there is one call
// site; the substitution runs once at module load, not per render.
const SIZED = wordmark.replace("<svg", '<svg class="h-7 w-auto"');

export function Wordmark() {
  return raw(SIZED);
}
