import { describe, test, expect } from "bun:test";
import { ApproveSignInPage } from "../../src/ui/approve-sign-in.js";

function render() {
  return ApproveSignInPage({
    email: "alice@example.com",
    requesterUa: "browserA/1",
    requesterIp: "1.1.1.1",
    requestedAt: new Date("2026-07-15T07:11:06Z"),
    pendingId: "487391eb-1073-4f6c-be85-4f1379f09904",
    token: "A398-RHpPXNrPbX8tPl2tXaaIKI23mH0",
  }).toString();
}

describe("ApproveSignInPage", () => {
  test("disables the approve button on submit so a double-click cannot re-POST", () => {
    // A double-clicked approve sends the second POST into an already-approved
    // row, which the approver used to see as "Could not approve" for work that
    // had in fact succeeded. The sibling start form in login.tsx already guards
    // this way; keep the two consistent.
    const html = render();
    expect(html).toContain("onsubmit=");
    expect(html).toContain("disabled=true");
  });

  test("keeps the approve button submitting the form", () => {
    // The guard must fire on submit, not replace it — a disabled-by-default
    // button would make the page unusable.
    const html = render();
    expect(html).toContain('<form method="post" action="/ui/login/approve"');
    expect(html).toContain('type="submit"');
    expect(html).not.toContain("<button disabled");
  });
});
