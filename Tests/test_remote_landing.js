"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");

assert.match(html, /Private by design/);
assert.match(html, /static interface that runs in your browser/);
assert.match(html, /does not receive or store your agent data/);
assert.match(html, /rel="icon" href="favicon\.svg" type="image\/svg\+xml"/);
assert.ok(fs.existsSync(path.join(root, "favicon.svg")));
assert.match(app, /This Remote Control link is invalid or expired/);
assert.match(app, /That code is incorrect or has rotated/);
assert.match(app, /This page needs a private link from Toki/);

console.log("remote locked landing tests passed");
