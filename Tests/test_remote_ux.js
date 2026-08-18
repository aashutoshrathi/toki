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
assert.match(html, /<button id="send"[^>]+><svg/);
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
