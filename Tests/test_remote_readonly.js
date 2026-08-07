"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");

assert.match(html, /Read-only session/);
assert.match(html, /cannot send replies/);
assert.match(app, /agent\s*&&\s*agent\.writable/);
assert.match(app, /enabled\s*=\s*writable\s*&&\s*!sending/);
assert.match(app, /el\.disabled\s*=\s*!enabled/);
assert.match(app, /footer textarea/);
assert.match(app, /Read-only session/);

console.log("remote read-only session tests passed");
