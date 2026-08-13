/** Cross-tab notice that this browser now holds a session.
 *
 *  The waiting page cannot see the session cookie — it is httpOnly — so it only
 *  learns that a sign-in landed on its next poll, up to a tick late. That is
 *  invisible when the link is approved on a phone and the tab is the thing you
 *  are watching, but glaring when the link is opened in THIS browser: the
 *  approving tab signs in server-side and lands on the dashboard, leaving the
 *  tab beside it still saying "waiting" for a sign-in that already happened.
 *
 *  BroadcastChannel is origin-scoped, so nothing here crosses to another site,
 *  and the payload is an address the receiving page already renders.
 */
export const AUTH_CHANNEL = "antgrid.auth";
export const SIGNED_IN_EVENT = "signed-in";

/** Inline listener for a page waiting on a sign-in to complete elsewhere.
 *
 *  Wiring is declarative, like auth-memory.ts: `data-ab-wake="<address>"` on any
 *  element marks the page as waiting for that address. The address is what
 *  keeps this from firing on the wrong flow — a browser that signs in as
 *  somebody else says nothing about the sign-in this page is waiting for, and
 *  yanking a half-finished flow to another account's dashboard would be worse
 *  than the wait it saves.
 *
 *  `replace`, not `assign`: the page being left is a dead end once the session
 *  exists, and Back must not return to it.
 */
export const AUTH_WAKE_SCRIPT = `(function(){
  var el=document.querySelector("[data-ab-wake]");
  if(!el||!window.BroadcastChannel)return;
  var mine=String(el.getAttribute("data-ab-wake")||"").trim().toLowerCase();
  if(!mine)return;
  var ch=new BroadcastChannel(${JSON.stringify(AUTH_CHANNEL)});
  ch.addEventListener("message",function(e){
    var d=e.data;
    if(!d||d.t!==${JSON.stringify(SIGNED_IN_EVENT)})return;
    if(String(d.email||"").trim().toLowerCase()!==mine)return;
    location.replace("/dashboard");
  });
})();`;
