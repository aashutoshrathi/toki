"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");
const css = fs.readFileSync(path.join(root, "styles.css"), "utf8");

assert.match(html, /<textarea id="msg"/);
assert.match(html, /Return adds a line/);
assert.match(html, /Ctrl \+ Return sends/);
assert.match(html, /aria-keyshortcuts="Meta\+Enter Control\+Enter"/);
// The send button is a labelled pill rather than an icon: it is the one control in the
// composer that should pull the eye, and an unlabelled arrow made it a guess.
assert.match(html, /<button id="send"[^>]+>Send<\/button>/);
// The composer is two rows now, so the field gets the full width and the tools sit under it.
assert.match(html, /<div class="composer-top">/);
assert.match(html, /<div class="composer-actions">/);
assert.match(html, /<span class="composer-avatar" id="composeravatar"/);
assert.match(html, /<button id="expand"/);
// Every control that carried wiring has to survive the restructure.
for (const id of ["msg", "attach", "model", "screen", "clear", "send"]) {
  assert.match(html, new RegExp('id="' + id + '"'), id + " went missing from the composer");
}
assert.match(css, /\.composer\.expanded textarea/);
assert.match(html, /<small>Reject<\/small>/);
assert.match(app, /Approve<\/button>/);
assert.match(app, /Reject<\/button>/);
assert.match(app, /navigator\.vibrate/);
assert.match(app, /e\.preventDefault\(\)/);
assert.match(app, /e\.metaKey\s*\|\|\s*e\.ctrlKey/);
assert.match(app, /function resizeComposer/);
assert.match(app, /new ResizeObserver/);
assert.match(app, /if\s*\(!pid\s*\|\|\s*sending\s*\|\|\s*uploading\)\s*return/);
// An awaited send (image upload) is bound to the agent chosen at Send, not the live `current`.
assert.match(app, /async function send\(body, pid = current\)/);
assert.match(app, /await send\(\{ text: message \}, pid\)/);
assert.match(app, /Sent \\u2713 via/);
// Optimistic send: the message is echoed and the input cleared before the round trip resolves.
assert.match(app, /function sendText/);
assert.match(app, /function submitComposer/);
assert.match(app, /sendText\(caption\)/);
assert.match(app, /function addEcho/);
assert.match(app, /pendingEcho/);
// A typing indicator covers the wait for the reply, and is reconciled against the polled transcript.
assert.match(app, /function showTyping/);
assert.match(app, /awaitingReply/);
assert.match(css, /\.m\.typing/);
assert.match(css, /@keyframes tblink/);
// Tap-to-retry on a failed message, and the question/approval panel is dismissed on answer.
assert.match(app, /\.m\.user\.failed/);
assert.match(app, /f\.remove\(\);\s*feedback\("tap"\);\s*sendText\(text\)/);
assert.match(app, /\$\("#alert"\)\.style\.display\s*=\s*"none"/);
assert.match(css, /Tap to retry/);
// Privacy toggle masks agent names in the picker for recordings.
assert.match(html, /id="privacytoggle"/);
assert.match(app, /function dispTitle/);
assert.match(app, /privacyMode/);
assert.match(css, /body\.privacy/);
// The picker shows each agent's folder under its title, and the privacy toggle masks that too.
assert.match(app, /function agentRow/);
assert.match(app, /function dispPath/);
assert.match(app, /dispPath\(a\.path\)/);
assert.match(app, /class="tp"/);
assert.match(css, /#dd \.tp\{/);
// The picker is capped to the room left above the footer. The footer is painted over the header,
// so a list sized as a flat slice of the viewport ran its last rows behind the key pad, and the
// composer growing (or a mirrored screen) moved that edge without the list ever hearing about it.
assert.match(app, /function sizeAgentList/);
assert.match(app, /function setAgentListOpen/);
assert.match(app, /\$\("footer"\)\.getBoundingClientRect\(\)\.top/);
assert.match(app, /window\.visualViewport/);
assert.match(app, /setProperty\("--dd-max"/);
assert.match(app, /window\.addEventListener\("resize", sizeAgentList\)/);
assert.match(css, /max-height:var\(--dd-max,60vh\)/);
// While it is open the picker outranks the footer, so a list clamped to its floor stays readable.
assert.match(css, /header:has\(#dd\.open\)\{z-index:6\}/);
// Every open goes through the helper: a raw class toggle would leave the list unmeasured.
assert.ok(!/\$\("#dd"\)\.classList\.(toggle|add)\("open"\)/.test(app),
          "the picker is opened without sizing it against the footer");
// A Clear button sends /clear, behind a confirm tap: it sits beside Send and cannot be undone.
assert.match(html, /id="clear"/);
assert.match(app, /function clearContext/);
assert.match(app, /send\(\{\s*text:\s*"\/clear"\s*\}\)/);
assert.match(app, /setClearArmed\(true\)/);
assert.match(app, /if\s*\(!clearArmed\)/);
assert.match(css, /#clear\.armed\{/);
// Clearing drops the log itself rather than waiting for the server to notice the new session, and
// a poll already in flight against the old transcript is discarded instead of appended.
assert.match(app, /function resetTranscript/);
assert.match(app, /if\s*\(ok\)\s*resetTranscript\(\)/);
assert.match(app, /const epoch = logEpoch/);
assert.match(app, /if\s*\(epoch\s*!=\s*logEpoch\)\s*return/);
assert.match(app, /r\.session\s*!==\s*logSession/);
// Every kind of message links its URLs: the agent's reply through the Markdown renderer, your own
// messages and the tool rows through linkify, which escapes as it goes.
assert.match(app, /const linkify = renderMarkdown\.linkify/);
assert.match(app, /d\.innerHTML = linkify\(e\.text\)/);
assert.match(app, /d\.innerHTML = linkify\(text\)/);
assert.match(app, /function dispLinked/);
assert.match(app, /dispLinked\(e\.text \|\| ""\)/);
assert.match(app, /dispLinked\(e\.detail\)/);
// Tapping a link inside a message that failed to send opens the link instead of retrying the send.
assert.match(app, /if\s*\(e\.target\.closest\("a"\)\)\s*return/);
assert.match(css, /\.m a\{/);
assert.match(css, /\.user a\{/);
assert.match(css, /#alert \.qq a\{/);

// Restyled question banner (header label + badge/label option layout) and film grain.
assert.match(app, /class="ahead"/);
assert.match(app, /data-opt="\$\{qi\}:\$\{oi\}"/);
assert.match(app, /class="mark \$\{q\.multi \? "box" : "radio"\}"/);
assert.match(app, /<span class="olab">/);
assert.match(css, /feTurbulence/);
assert.match(css, /button:not\(:disabled\):active/);
assert.match(css, /\.decision\.reject/);
assert.match(css, /min-height:44px/);

// Multi-select / multi-question pickers: options toggle in place and a Submit button turns the
// accumulated choices into the keystrokes each TUI needs.
assert.match(app, /function buildKeySequence/);
assert.match(app, /function toggleOption/);
// Sarvam's picker submits on the option number itself: no Tab (that opens its notes field) and
// no trailing Enter (that would resubmit), so it rides Antigravity's digits-only branch.
assert.match(app, /provider == "antigravity" \|\| provider == "sarvam"/);
assert.match(app, /provider != "antigravity" && provider != "sarvam"/);
assert.match(app, /data-submit="1"/);
assert.match(app, /send\(\{ keys \}\)/);
// Submit is gated on every question being answered, and the pending answer is keyed by agent pid,
// so a partial answer is never delivered and one agent's picks never leak to another.
assert.match(app, /function answerComplete\(qs, sel\)/);
assert.match(app, /answerComplete\(answer\.questions, answer\.sel\)/);
assert.match(app, /questionSignature\(a\.pid,/);
// Signature is collision-proof (JSON), not delimiter-joined.
assert.match(app, /return JSON\.stringify\(\[pid, provider,/);
// Options expose their checked state to assistive tech, and a failed submit keeps the picks.
assert.match(app, /role="\$\{q\.multi \? "checkbox" : "radio"\}" aria-checked="\$\{on\}"/);
assert.match(app, /const ok = await send\(\{ keys \}\)/);

// The browser tab title is "<machine> - <chat>", the footer's numbered Choice keys still type into
// the terminal, and leaving an active session asks first.
assert.match(app, /function setDocTitle/);
assert.match(app, /agent\.machine \+ " - " \+ chat/);
assert.match(app, /await send\(\{ text: b\.dataset\.text, raw: true \}\)/);
assert.match(app, /function showDisconnectConfirm/);
assert.match(app, /\$\("#home"\)\.addEventListener\("click", showDisconnectConfirm\)/);
assert.match(html, /id="confirm"[^>]*role="dialog"[^>]*aria-modal="true"/);
assert.match(html, /id="confirmok"/);
assert.match(css, /#confirm\[hidden\]\{display:none\}/);
assert.match(css, /\.opt \.mark\.box/);
assert.match(css, /\.opt\.on \.mark/);
assert.match(css, /\.decision-row\.one/);

// Image input: an attachment can be picked, pasted, or shot, previewed, then uploaded to the Mac
// and referenced by path in the reply.
assert.match(app, /function uploadImage/);
assert.match(app, /"\/api\/upload"/);
// A caption-less image sends "Image: <path>", never a bare "/path" the TUI reads as a slash command.
assert.match(app, /"Image: " \+ path/);
assert.match(app, /function setPendingImage/);
assert.match(app, /addEventListener\("paste"/);
assert.match(html, /id="fileinput"[^>]*accept="image\/\*"/);
assert.match(html, /id="attach"/);
assert.match(html, /id="attachpreview"/);
assert.match(css, /#attachpreview img/);

// Every element app.js reaches for at load must exist in the page. A missing one throws on the
// first line that touches it and takes the whole script down with it, which looks from the phone
// like the app simply never started.
const RUNTIME_IDS = new Set(["typing"]); // created by showTyping, never in the served HTML
const pageIds = new Set([...html.matchAll(/id="([^"]+)"/g)].map(m => m[1]));
const wanted = new Set([
  ...[...app.matchAll(/\$\("#([a-zA-Z0-9_-]+)"\)/g)].map(m => m[1]),
  ...[...app.matchAll(/getElementById\("([a-zA-Z0-9_-]+)"\)/g)].map(m => m[1]),
]);
const missing = [...wanted].filter(id => !pageIds.has(id) && !RUNTIME_IDS.has(id));
assert.deepEqual(missing, [], "app.js selects ids that index.html does not define: " + missing);

console.log("remote mobile UX tests passed");

// Behavioral coverage of the browser boundary complements the markup contracts above.
{
const vm = require("node:vm");
const source = app;
// Exercise the page's event logic with the browser boundary replaced. Polling replaces option
// nodes, so a source assertion alone cannot establish that keyboard focus survives the update.
const document = { activeElement: null };
function node(id, dataset = {}) {
  const classes = new Set();
  return {
    id, dataset, hidden: false, disabled: false, attrs: {}, style: {}, children: [],
    classList: {
      contains: name => classes.has(name),
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name); },
    },
    setAttribute(name, value) { this.attrs[name] = String(value); },
    getAttribute(name) { return this.attrs[name]; },
    focus() { document.activeElement = this; },
    scrollIntoView() {},
    contains(other) { return this.children.includes(other); },
    querySelectorAll() { return this.children; },
    querySelector() { return this.children.find(child => child.attrs["aria-selected"] == "true"); },
  };
}
const ids = ["dd", "ddbtn", "ddlist", "terminalkeys", "terminaltoggle", "readonly", "attach",
  "model", "screen", "modelclose", "expand", "send", "clear", "fileinput", "msg", "composeravatar",
  "modelmirror", "modelscreen", "mmlabel", "paircode", "manualhost", "manualtoken", "pairstatus"];
const nodes = Object.fromEntries(ids.map(id => ["#" + id, node(id)]));
const key = node("key", { key: "enter" });
const inputIDs = ["attach", "model", "screen", "send", "clear", "fileinput", "msg"];
const navigationIDs = ["terminaltoggle", "expand", "modelclose"];
const footerControls = [...inputIDs, ...navigationIDs].map(id => nodes["#" + id]).concat(key);
document.querySelectorAll = () => footerControls;
Object.defineProperty(nodes["#ddlist"], "innerHTML", {
  set(value) {
    this.children = [...value.matchAll(/<button[^>]*aria-selected="([^"]+)"[^>]*data-pid="([^"]+)"/g)]
      .map(([, selected, pid]) => {
        const item = node("", { pid });
        item.attrs["aria-selected"] = selected;
        return item;
      });
  },
});

let resetCount = 0;
let attachmentClearCount = 0;
const context = vm.createContext({
  document, $: id => nodes[id],
  agents: [
    { pid: 11, title: "One", provider: "codex", writable: true, screen: true, uploads: true },
    { pid: 22, title: "Two", provider: "claude", writable: true },
    { pid: 33, title: "Read only", provider: "zed", writable: false },
  ],
  current: 11, sending: false, uploading: false, modelMirror: null,
  MODEL_COMMANDS: { codex: "/model" },
  agentRow: a => a.title, plainTitle: t => t,
  providerLogo: () => "logo", providerLabel: p => p,
  setDocTitle() {}, sizeAgentList() {}, refreshLog() {}, refreshModelMirror() {},
  resetTranscript() { resetCount++; }, clearPendingImage() { attachmentClearCount++; },
  setTimeout() { return 1; }, clearTimeout() {},
});
for (const name of ["setPairStatus", "setAgentListOpen", "handleAgentPickerKeydown", "renderAgents",
  "updateComposer", "setTerminalControlsOpen", "openMirror", "closeModelMirror"]) {
  const found = source.match(new RegExp("^function " + name + "\\([\\s\\S]*?^}", "m"));
  assert.ok(found, name + " must be a top-level function");
  vm.runInContext(found[0], context);
}
function run(code) { return vm.runInContext(code, context); }
function press(key, shiftKey = false) {
  const event = { key, shiftKey, prevented: false, preventDefault() { this.prevented = true; }, stopPropagation() {} };
  context.handleAgentPickerKeydown(event);
  return event;
}

run("renderAgents()");
nodes["#ddbtn"].focus();
press("ArrowDown");
assert.equal(nodes["#ddbtn"].attrs["aria-expanded"], "true");
assert.equal(document.activeElement.dataset.pid, "11");
press("ArrowDown");
assert.equal(document.activeElement.dataset.pid, "22");
run("renderAgents()");
assert.equal(document.activeElement.dataset.pid, "22", "polling must preserve the focused option");
press("End");
assert.equal(document.activeElement.dataset.pid, "33");
press("ArrowDown");
assert.equal(document.activeElement.dataset.pid, "11", "arrow navigation wraps");
press("Home");
assert.equal(document.activeElement.dataset.pid, "11");
press("ArrowUp");
assert.equal(document.activeElement.dataset.pid, "33");
document.activeElement.onclick({ stopPropagation() {} });
assert.equal(run("current"), 33);
assert.equal(resetCount, 1);
assert.equal(attachmentClearCount, 1, "switching sessions must drop the previous attachment");
assert.equal(document.activeElement, nodes["#ddbtn"]);
assert.equal(nodes["#ddbtn"].attrs["aria-expanded"], "false");

press("ArrowDown");
run("agents = agents.filter(a => a.pid != 33); current = 11; renderAgents()");
assert.equal(document.activeElement.dataset.pid, "11", "ended sessions fall back to the selected option");
press("Escape");
assert.equal(document.activeElement, nodes["#ddbtn"]);
assert.equal(nodes["#ddbtn"].attrs["aria-expanded"], "false");
press("ArrowDown");
assert.equal(press("Tab").prevented, false, "Tab must continue to the next page control");
assert.equal(document.activeElement, nodes["#ddbtn"]);
press("ArrowDown");
assert.equal(press("Tab", true).prevented, true, "Shift-Tab returns to the trigger");
press("ArrowDown");
run("agents = []; renderAgents()");
assert.equal(document.activeElement, nodes["#ddbtn"]);
assert.equal(nodes["#ddbtn"].attrs["aria-expanded"], "false");

// A send/upload blocks every terminal-input route, while layout and dismissal remain operable.
for (const state of ["sending = true; uploading = false", "sending = false; uploading = true"]) {
  run(state + "; updateComposer({pid:11, provider:'codex', writable:true, screen:true, uploads:true})");
  for (const id of inputIDs) assert.equal(nodes["#" + id].disabled, true, id + " must be gated");
  assert.equal(key.disabled, true);
  for (const id of navigationIDs) assert.equal(nodes["#" + id].disabled, false, id + " must remain operable");
}
run("sending = false; uploading = false; updateComposer({pid:11,provider:'codex',writable:true})");
assert.equal(nodes["#send"].disabled, false);
run("updateComposer({pid:33,provider:'zed',writable:false})");
for (const id of inputIDs) assert.equal(nodes["#" + id].disabled, true);
assert.equal(key.disabled, true);

assert.match(html, /id="terminalkeys"[^>]*hidden/);
run("setTerminalControlsOpen(false); openMirror({pid:11}, 'Live terminal', 'Reading', 250)");
assert.equal(nodes["#terminalkeys"].hidden, false, "mirroring must reveal the terminal keys");
assert.equal(nodes["#terminaltoggle"].attrs["aria-expanded"], "true");
run("setTerminalControlsOpen(false)");
assert.equal(nodes["#terminalkeys"].hidden, true);

assert.match(html, /id="pairstatus"[^>]*role="status"[^>]*aria-live="polite"/);
assert.match(html, /id="paircode"[\s\S]*?aria-describedby="pairinstructions pairstatus"/);
run("setPairStatus('Enter all six digits.', 'paircode')");
assert.equal(document.activeElement, nodes["#paircode"]);
assert.equal(nodes["#paircode"].attrs["aria-invalid"], "true");
assert.equal(nodes["#pairstatus"].textContent, "Enter all six digits.");
run("setPairStatus('Network unavailable')");
assert.equal(nodes["#paircode"].attrs["aria-invalid"], "false", "network failures are not invalid codes");

console.log("remote keyboard, disclosure, pairing accessibility and send-gate tests passed");

}
