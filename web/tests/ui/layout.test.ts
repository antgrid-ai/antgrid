import { describe, test, expect } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Layout } from "../../src/ui/layout.js";
import { setPublicOrigin } from "../../src/ui/origin.js";
import { BETA } from "../../src/billing/plans.js";

describe("Layout", () => {
  test("renders the wordmark in the header", () => {
    const html = Layout({ title: "Test", children: "x" }).toString();
    // The brand must be surfaced visibly in the header, not only as a
    // <link rel="icon"> in <head> — that's what brands the visible page.
    // Inline, not an <img>: an <img> sized `h-7 w-auto` reserves no width until
    // the file loads, and the nav is the only item in that row that gives up
    // width — so the lockup landing late scrolls Devices out of a phone header.
    expect(html).not.toContain("<img");
    // Byte-identical to the file public/logo/antgrid-wordmark.svg hands out for
    // external brand use — everything past the root tag, so the class the header
    // injects is the only permitted difference. Hand-copying the markup into
    // wordmark.tsx instead of importing it passes every other assertion here.
    const master = readFileSync(
      resolve(import.meta.dir, "../../public/logo/antgrid-wordmark.svg"),
      "utf8"
    );
    expect(html).toContain(master.slice(master.indexOf(">") + 1).trimEnd());
    // The label keeps the lockup readable to screen readers.
    expect(html).toContain('aria-label="Antgrid"');
  });

  test("marks the product as beta inside the header lockup", () => {
    // Skipped rather than inverted once BETA flips: after launch the badge's
    // absence is the intent, not a regression worth asserting against.
    if (!BETA) return;
    // Signed-out on purpose — this is the beta signal on the pages that have
    // no account to read `promotional` off (login, signup, invite, reset).
    const html = Layout({ title: "Test", children: "x" }).toString();
    const lockup = html.slice(html.indexOf('<a href="/"'), html.indexOf("</a>"));
    expect(lockup).toContain(">beta<");
    // A span, never an anchor: nested anchors are invalid, and the badge is a
    // status marker rather than somewhere to navigate to.
    expect(lockup.slice(1)).not.toContain("<a ");
  });

  test("signed-in users get an /account link so delete is discoverable", () => {
    // The whole delete-account flow is unreachable without this link — it's the
    // only entry point to /account, and its absence undercuts the App Store /
    // Play data-deletion compliance the page exists for.
    const html = Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();
    expect(html).toContain('href="/account"');
  });

  test("omits the account menu for signed-out visitors", () => {
    const html = Layout({ title: "Test", children: "x" }).toString();
    expect(html).not.toContain('href="/account"');
  });

  test("signed-in users get a /devices nav link", () => {
    const html = Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();
    expect(html).toContain('href="/devices"');
  });

  test("signed-in users get a /team nav link", () => {
    // Shown to members too, not only owners: it is the only place a member is
    // told whose account their plan and limits come from.
    const html = Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();
    expect(html).toContain('href="/team"');
  });
});

describe("Layout brand mark", () => {
  const html = () => Layout({ title: "Test", children: "x" }).toString();

  test("inlines the four-agent mark beside the wordmark", () => {
    // Byte-identical to the file /logo/* hands out, same rule as the wordmark.
    const master = readFileSync(
      resolve(import.meta.dir, "../../public/logo/antgrid-mark-full.svg"),
      "utf8"
    );
    expect(html()).toContain(master.slice(master.indexOf(">") + 1).trimEnd());
  });

  test("sets the mark at the size four agents need to separate", () => {
    // h-9 is both the kit's lockup proportion against an h-7 wordmark and the
    // measured floor for the full tier — the reduction cut exists for chrome
    // that cannot afford this, and a header that quietly shrank back to h-7
    // would put four thin chevrons on top of the target.
    const markup = html();
    const svg = markup.slice(markup.indexOf("<svg"));
    expect(svg.slice(0, svg.indexOf(">"))).toContain("h-9");
  });

  test("hides the mark on phones, where the nav has no width to give", () => {
    // Measured, not stylistic: four nav labels plus the wordmark and the avatar
    // already overflow a 414px header, and the nav is the only item in that row
    // that gives up width.
    const markup = html();
    const svg = markup.slice(markup.indexOf("<svg"));
    expect(svg.slice(0, svg.indexOf(">"))).toContain("hidden");
    expect(svg.slice(0, svg.indexOf(">"))).toContain("sm:block");
  });

  test("keeps the home link announcing the brand once", () => {
    // Both cuts ship role="img" aria-label="Antgrid" for standalone use, so the
    // decorative one must be hidden or the link reads as "Antgrid Antgrid".
    const markup = html();
    const link = markup.slice(markup.indexOf('<a href="/"'), markup.indexOf("</a>"));
    const labels = link.split('aria-label="Antgrid"').length - 1;
    const hidden = link.split('aria-hidden="true"').length - 1;
    expect(labels - hidden).toBe(1);
  });
});

describe("Layout social card", () => {
  const html = () => Layout({ title: "Test", children: "x" }).toString();

  test("carries an image a scraper can actually fetch", () => {
    // og:image is fetched out of band, with no page to resolve a relative path
    // against, so this one must come out absolute once the origin is known.
    setPublicOrigin("https://accounts.antgrid.ai/");
    try {
      const markup = html();
      expect(markup).toContain(
        'content="https://accounts.antgrid.ai/og/antgrid-card.png"'
      );
      expect(markup).toContain('name="twitter:card" content="summary_large_image"');
      // Declared dimensions let a client reserve the card before the PNG lands.
      expect(markup).toContain('property="og:image:width" content="1200"');
      expect(markup).toContain('property="og:image:height" content="630"');
    } finally {
      setPublicOrigin(undefined);
    }
  });

  test("drops a path the deploy URL happens to carry", () => {
    // BETTER_AUTH_URL is only validated as a URL, so a deploy behind a subpath
    // can legitimately set one. Prefixing that path onto a root-relative asset
    // points the scraper at a 404, and nothing in the page would show it.
    setPublicOrigin("https://accounts.antgrid.ai/auth/");
    try {
      expect(html()).toContain(
        'content="https://accounts.antgrid.ai/og/antgrid-card.png"'
      );
    } finally {
      setPublicOrigin(undefined);
    }
  });

  test("a value that is not a URL degrades instead of throwing", () => {
    // Parsing happens at app boot, one import away from every route — a throw
    // here would be a startup crash, not a bad card.
    setPublicOrigin("not a url");
    try {
      expect(html()).toContain('content="/og/antgrid-card.png"');
    } finally {
      setPublicOrigin(undefined);
    }
  });

  test("degrades to a usable path rather than throwing when unset", () => {
    // Components are rendered in unit tests without an app to push the origin
    // in; a missing social image must never be able to take a page down.
    expect(html()).toContain('content="/og/antgrid-card.png"');
  });

  test("the card the tags point at is actually shipped", () => {
    // flutter_svg-style late failure: the tag is valid markup either way, so
    // nothing catches a card that was never generated.
    expect(
      existsSync(resolve(import.meta.dir, "../../public/og/antgrid-card.png"))
    ).toBe(true);
  });
});

describe("Layout account menu", () => {
  const html = () =>
    Layout({
      title: "Test",
      user: { email: "gita@example.com" },
      children: "x",
    }).toString();

  test("prints the signed-in address exactly once", () => {
    // The trigger used to repeat the address the menu already shows, so the
    // same string appeared twice within ~40px of itself on desktop.
    const hits = html().split("gita@example.com").length - 1;
    expect(hits).toBe(1);
  });

  test("carries the address on phones, where the trigger is the avatar alone", () => {
    // Regression guard for moving identity into the menu: the address must not
    // be behind a `sm:` breakpoint, or a phone user cannot tell which account
    // they are about to sign out of.
    const markup = html();
    const block = markup.slice(markup.indexOf("Signed in as"));
    expect(block).toContain("gita@example.com");
    expect(block.slice(0, block.indexOf("gita@example.com"))).not.toContain("sm:");
  });

  test("opens as a disclosure rather than daisyUI's focus-within dropdown", () => {
    // `.dropdown` opens on :focus-within, so clicking an open trigger re-focuses
    // instead of closing it, and its `.menu` list centres a <button> child while
    // left-aligning an <a> — the sign-out row never lined up with Account.
    const markup = html();
    expect(markup).toContain("<details");
    expect(markup).toContain("<summary");
    expect(markup).not.toContain("dropdown");
  });

  test("does not ship the menu's dismiss script to signed-out pages", () => {
    expect(Layout({ title: "Test", children: "x" }).toString()).not.toContain(
      "data-account-menu"
    );
  });
});
