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
assert.match(app, /if\s*\(!current\s*\|\|\s*sending\)\s*return/);
assert.match(app, /Sent \\u2713 via/);
// Optimistic send: the message is echoed and the input cleared before the round trip resolves.
assert.match(app, /function sendText/);
assert.match(app, /sendText\(v\)/);
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
// Restyled question banner (header label + badge/label option layout) and film grain.
assert.match(app, /class="ahead"/);
assert.match(app, /<b>\$\{i\s*\+\s*1\}<\/b><span>\$\{esc\(o\)\}<\/span>/);
assert.match(css, /feTurbulence/);
assert.match(css, /button:not\(:disabled\):active/);
assert.match(css, /\.decision\.reject/);
assert.match(css, /min-height:44px/);

console.log("remote mobile UX tests passed");
