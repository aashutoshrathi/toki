"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");
const css = fs.readFileSync(path.join(root, "styles.css"), "utf8");

assert.match(html, /<div id="t3open" data-testid="T3OpenButtons" hidden><\/div>/);
assert.match(html, /<div id="readonly" role="status">Read-only session[^<]*cannot send replies\.<\/div><div id="t3open"/);

assert.match(app, /api\("\/api\/open",\s*\{\s*method:\s*"POST",\s*body:\s*JSON\.stringify\(\{\s*pid\s*\}\)\s*\}\)/);
assert.match(app, /Opened on your Mac/);
assert.match(app, /Couldn\\u2019t open: "\s*\+\s*e\.message/);
assert.match(app, /Running in T3 Code\. Reply there:/);
assert.match(app, /<button type="button" id="t3mac"/);
assert.match(app, /T3_DESKTOP_ICON \+ "Open on Mac<\/button>/);
assert.match(app, /<a id="t3phone" href="/);
assert.match(app, /T3_PHONE_ICON \+ "Open in T3 Code<\/a>/);
assert.match(app, /esc\(agent\.t3\.link\)/);
assert.match(app, /renderT3Open\(agent\);/);
assert.match(app, /agent && agent\.t3\b/);
assert.match(css, /#t3open\{/);
assert.match(css, /\.locked>#t3open/);

function matcherFor(userAgent, maxTouchPoints) {
  const source = [
    app.match(/function deviceOS\(\) \{[\s\S]*?\n\}\n/)[0],
    app.match(/function isThisDevice\([\s\S]*?\n\}\n/)[0]
  ].join("\n");
  const context = { navigator: { userAgent, maxTouchPoints } };
  vm.createContext(context);
  vm.runInContext(source + "\nthis.isThisDevice = isThisDevice;", context);
  return context.isThisDevice;
}

const android = matcherFor("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/126 Mobile Safari/537.36", 5);
assert.ok(android("Android"));
assert.ok(android("android"));
assert.ok(!android("iOS"));
assert.ok(!android(""));

const iphone = matcherFor("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", 5);
assert.ok(iphone("iOS"));
assert.ok(iphone("iPadOS"));
assert.ok(!iphone("Android"));

const ipad = matcherFor("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15", 5);
assert.ok(ipad("iPadOS"));
assert.ok(ipad("iOS"));

const desktop = matcherFor("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15", 0);
assert.ok(!desktop("iOS"));
assert.ok(!desktop("Android"));
assert.ok(!desktop(""));

console.log("remote T3 open tests passed");
