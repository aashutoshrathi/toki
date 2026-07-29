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
assert.match(app, /e\.metaKey\|\|e\.ctrlKey/);
assert.match(app, /function resizeComposer/);
assert.match(app, /new ResizeObserver/);
assert.match(app, /if\(!current\|\|sending\)return/);
assert.match(app, /await send\(\{text:v\}\)/);
assert.match(app, /Sent \\u2713 via/);
assert.match(css, /button:not\(:disabled\):active/);
assert.match(css, /\.decision\.reject/);
assert.match(css, /min-height:44px/);

console.log("remote mobile UX tests passed");
