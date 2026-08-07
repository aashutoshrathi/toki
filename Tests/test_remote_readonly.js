"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");
const css = fs.readFileSync(path.join(root, "styles.css"), "utf8");

assert.match(html, /Read-only session/);
assert.match(html, /cannot send replies/);
assert.match(app, /agent\s*&&\s*agent\.writable/);
assert.match(app, /enabled\s*=\s*writable\s*&&\s*!sending/);
assert.match(app, /el\.disabled\s*=\s*!enabled/);
assert.match(app, /footer textarea/);
assert.match(app, /Read-only session/);

// Read-only sessions sit below the ones you can reply to, under one group label rather than a
// badge on every row. The label is emitted only where the read-only run begins.
assert.match(app, /class="ddgroup">Read-only</);
assert.match(app, /!a\.writable\s*&&\s*\(i\s*==\s*0\s*\|\|\s*agents\[i\s*-\s*1\]\.writable\)/);
assert.match(css, /\.ddgroup\{/);

// Clear lives inside <footer>, so the same rule that disables the composer on a read-only session
// disables it too -- there is no route to /clear on a session you cannot type into.
assert.match(html, /<footer>[\s\S]*id="clear"[\s\S]*<\/footer>/);

console.log("remote read-only session tests passed");
