/** Client-side memory of how each address signed in last time.
 *
 *  This is what makes the email-first flow's step 2 land on the right method
 *  without the server ever answering "does this address have a password / which
 *  provider did it use". That question is the enumeration oracle the whole auth
 *  surface is built to avoid (see routes/ui.tsx and auth/better-auth.ts), so the
 *  routing hint is held in the BROWSER instead: a returning user gets their own
 *  method on their own device, and a fresh browser learns nothing.
 *
 *  The hint is advisory in both directions. A wrong or absent one costs the user
 *  one extra click, never a failed sign-in, and the server treats it as
 *  untrusted input — `/ui/login/continue` switches on a closed set and falls
 *  through to the magic link, which works for every address whether or not an
 *  account exists (cross-device approve is signup-on-approve).
 */

/** Methods step 1 may route to. Mirrored by the switch in `/ui/login/continue`;
 *  anything else there falls through to the magic link. */
export const AUTH_METHODS = ["password", "link", "github", "google"] as const;
export type AuthMethod = (typeof AUTH_METHODS)[number];

/** Seconds the resend buttons stay disabled. Comfortably above the server's
 *  own start bucket (5 burst, 1 per 5s) so the button is never enabled into a
 *  429, and long enough that a slow inbox is given a chance before a retry. */
export const RESEND_COOLDOWN_SECONDS = 45;

const STORAGE_KEY = "antgrid.auth.methods.v1";
/** Addresses remembered per browser. Small on purpose: this is a convenience
 *  for the people who use this machine, not a history. */
const MAX_REMEMBERED = 5;

/** Inline client script shared by every page in the sign-in flow.
 *
 *  Inline rather than a Vite entry so the auth pages stay one request with no
 *  bundle to load before the form is usable — same call the password
 *  disclosure's carry-over script made before this replaced it. Wiring is
 *  declarative so the markup stays the source of truth:
 *
 *  - `data-ab-prefill`   on an input  — fill with the most recently used address
 *  - `data-ab-recall`    on a form    — set its hidden `method` field from the
 *                                       typed address on submit
 *  - `data-ab-remember`  on a form, button or link — record `<method>` for the address,
 *                                       taken from `data-ab-email` when the
 *                                       server already knows it, else from the
 *                                       form's own email input
 *  - `data-ab-remember-now` on anything — record `<method>` on load, for a page
 *                                       that IS the confirmation the write
 *                                       happened. `data-ab-remember` records an
 *                                       INTENT and can outlive a submit the
 *                                       server rejected; where the server
 *                                       renders the outcome, hang the hint off
 *                                       that instead and it can never claim a
 *                                       method the account does not have
 *  - `data-ab-once="<busy label>"` on a submit button — disable it once its form
 *                                       has been submitted, wearing `<busy
 *                                       label>` if it was the button that did
 *                                       the submitting. Never on a form that
 *                                       also carries `data-ab-cooldown`: two
 *                                       owners of `disabled` fight over the
 *                                       re-enable.
 *  - `data-ab-cooldown="<kind>"` on a form — disable its submit button for
 *                                       RESEND_COOLDOWN_SECONDS after a submit,
 *                                       counting down in the label. Persisted by
 *                                       TIMESTAMP, because every resend here is
 *                                       a POST that redirects to a freshly
 *                                       rendered page — in-memory state would be
 *                                       destroyed by the very submit it is
 *                                       meant to rate-limit, re-enabling the
 *                                       button instantly.
 *
 *  Everything degrades: with JS off, step 1 posts no `method` and every user
 *  gets the magic link, which is the correct answer for an unknown address.
 */
export const AUTH_MEMORY_SCRIPT = `(function(){
  var KEY=${JSON.stringify(STORAGE_KEY)},MAX=${MAX_REMEMBERED},COOL=${RESEND_COOLDOWN_SECONDS};
  var OK=${JSON.stringify(AUTH_METHODS)};
  function norm(v){return String(v||"").trim().toLowerCase();}
  function load(){try{var v=JSON.parse(localStorage.getItem(KEY)||"[]");return Array.isArray(v)?v:[];}catch(e){return [];}}
  function save(v){try{localStorage.setItem(KEY,JSON.stringify(v.slice(0,MAX)));}catch(e){}}
  function recall(email){var e=norm(email);if(!e)return null;
    var hit=load().filter(function(r){return r&&norm(r.e)===e;})[0];
    return hit&&OK.indexOf(hit.m)>=0?hit.m:null;}
  function remember(email,method){var e=norm(email);
    if(!e||OK.indexOf(method)<0)return;
    save([{e:e,m:method}].concat(load().filter(function(r){return r&&norm(r.e)!==e;})));}
  function lastEmail(){var r=load()[0];return r&&r.e?r.e:"";}
  function emailFor(el){
    var fixed=el.getAttribute("data-ab-email");
    if(fixed)return fixed;
    var scope=el.form||el.closest("form")||document;
    var input=scope.querySelector('[name="email"]');
    return input?input.value:"";}

  var prefill=document.querySelector("[data-ab-prefill]");
  // Only into an empty field: the server prefills it when the user came back
  // from step 2 via "change", and that address is the deliberate one.
  if(prefill&&!prefill.value){prefill.value=lastEmail();}

  Array.prototype.forEach.call(document.querySelectorAll("[data-ab-recall]"),function(form){
    form.addEventListener("submit",function(){
      var field=form.querySelector('[name="method"]');
      var input=form.querySelector('[name="email"]');
      if(field&&input){field.value=recall(input.value)||"";}
    });
  });

  Array.prototype.forEach.call(document.querySelectorAll("[data-ab-remember]"),function(el){
    var method=el.getAttribute("data-ab-remember");
    var evt=el.tagName==="FORM"?"submit":"click";
    el.addEventListener(evt,function(){remember(emailFor(el),method);});
  });

  var settled=document.querySelector("[data-ab-remember-now]");
  if(settled)remember(emailFor(settled),settled.getAttribute("data-ab-remember-now"));

  Array.prototype.forEach.call(document.querySelectorAll("[data-ab-once]"),function(btn){
    var form=btn.form||btn.closest("form");
    if(!form)return;
    var busy=btn.getAttribute("data-ab-once"),idle=btn.textContent;
    form.addEventListener("submit",function(e){
      var mine=e&&e.submitter?e.submitter===btn:document.activeElement===btn;
      // Deferred out of the handler: in some browsers a submit button disabled
      // during its own submit event drops its name/value from the payload, and
      // step 1's escape hatch IS a submitter value. The send being guarded is
      // awaited server-side, so the window this closes is a mail round trip
      // wide — long enough to mint a second pending row, which the bind cookie
      // then follows, stranding the page on the mail the user did not open.
      setTimeout(function(){btn.disabled=true;if(mine&&busy)btn.textContent=busy;},0);
    });
    // Back from step 2 restores this page from bfcache with the disable intact,
    // and a disabled default button swallows Enter as well as clicks — the
    // guard would otherwise leave step 1 with no way to submit at all.
    window.addEventListener("pageshow",function(e){
      if(e.persisted){btn.disabled=false;btn.textContent=idle;}});
  });

  Array.prototype.forEach.call(document.querySelectorAll("[data-ab-cooldown]"),function(form){
    var btn=form.querySelector('button[type="submit"]');
    if(!btn)return;
    var slot="antgrid.auth.cooldown."+form.getAttribute("data-ab-cooldown")+"."+norm(emailFor(form));
    var label=btn.textContent,timer=null;
    function readAt(){var v=parseInt(sessionStorage.getItem(slot)||"",10);return isNaN(v)?0:v;}
    function tick(){
      var left=Math.ceil((readAt()+COOL*1000-Date.now())/1000);
      if(left<=0){if(timer){clearInterval(timer);timer=null;}btn.disabled=false;btn.textContent=label;return;}
      btn.disabled=true;btn.textContent=label+" ("+left+"s)";}
    function arm(){if(!timer)timer=setInterval(tick,1000);tick();}
    function stamp(){try{sessionStorage.setItem(slot,String(Date.now()));}catch(e){}}
    // A cooldown that outlives its own navigation: the stamp is written before
    // the POST, and read back by the page the redirect lands on.
    form.addEventListener("submit",function(){stamp();arm();});
    // \`arm\` on the container means the page itself is the landing after a send,
    // so the clock starts now — otherwise the very first resend is offered
    // immediately after the mail it would replace. Guarded on an unset stamp so
    // a refresh extends nothing.
    if(!readAt()&&form.hasAttribute("data-ab-cooldown-arm"))stamp();
    if(readAt())arm();
  });
})();`;
