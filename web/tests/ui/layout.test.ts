import { describe, test, expect } from "bun:test";
import { Layout } from "../../src/ui/layout.js";
import { BETA } from "../../src/billing/plans.js";

describe("Layout", () => {
  test("renders the wordmark in the header", () => {
    const html = Layout({ title: "Test", children: "x" }).toString();
    // The brand must be surfaced as a visible <img> in the header, not only as
    // a <link rel="icon"> in <head> — that's what brands the visible page.
    expect(html).toContain('<img src="/logo/antgrid-wordmark.svg"');
    // alt text keeps the lockup readable to screen readers / broken loads.
    expect(html).toContain('alt="antgrid"');
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
