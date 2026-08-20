import { raw } from "hono/html";
// Same import-the-master rule as wordmark.tsx: the header and the URL handed
// out for external brand use must not be able to drift.
import mark from "../../public/logo/antgrid-mark-full.svg" with { type: "text" };

// The four-agent mark, NOT antgrid-mark-transparent.svg, which carries the same
// art: that one adapts through `prefers-color-scheme`, which keys off the
// reader's OS rather than the page, and this app forces dark -- an inlined copy
// would flip the wrong way for a light-OS visitor.
//
// h-9 against the wordmark's h-7 is the kit's lockup proportion -- the mark box
// runs 4/3 of the type size -- and it is also the size the four agents need
// before they separate: measured against the two-chevron reduction on this
// header's own ground, 28px leaves them thin and crowding the target, 36px
// reads cleanly. The bar is h-14, so 36px still clears it by 10px a side.
//
// `hidden sm:block`, unlike the site's nav, which shows it at every width: the
// note in layout.tsx is measured -- four nav labels plus the wordmark and the
// avatar already do not fit a 414px viewport, and the nav is the only item in
// that row that gives up width. A mark that showed on phones would come
// straight out of the labels.
// aria-hidden because the wordmark beside it already names the link. The file
// carries role="img" aria-label="Antgrid" for standalone use; left as-is here it
// makes the home link announce "Antgrid Antgrid".
const SIZED = mark.replace(
  "<svg",
  '<svg aria-hidden="true" class="hidden h-9 w-auto sm:block"',
);

export function Mark() {
  return raw(SIZED);
}
