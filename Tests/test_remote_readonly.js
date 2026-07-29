"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");

assert.match(html, /Read-only session/);
assert.match(html, /cannot send replies/);
assert.match(app, /agent&&agent\.writable/);
assert.match(app, /el\.disabled=!writable/);
assert.match(app, /Read-only session/);

console.log("remote read-only session tests passed");
