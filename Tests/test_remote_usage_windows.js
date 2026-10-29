"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.join(__dirname, "..", "Sources", "Toki", "Resources", "webui");
const app = fs.readFileSync(path.join(root, "app.js"), "utf8");
const css = fs.readFileSync(path.join(root, "styles.css"), "utf8");

// Each quota window is its own block, drawn from the windows the Mac sends.
assert.match(app, /Array\.isArray\(a\.windows\)\s*&&\s*a\.windows\.length/);
assert.match(app, /a\.windows\.map\(usageWindow\)/);
assert.match(app, /data-testid="UsageWindows"/);

// The fill is the used share, tinted the way the Mac card tints it.
assert.match(app, /const used = \(100 - left\) \/ 100/);
assert.match(app, /style="width:' \+ \(100 - left\) \+ '%"/);
assert.match(app, /used >= 0\.58[\s\S]*?"hot"[\s\S]*?used >= 0\.25[\s\S]*?"warm"[\s\S]*?"ok"/);
assert.match(css, /\.u-w-fill\.ok\{/);
assert.match(css, /\.u-w-fill\.warm\{/);
assert.match(css, /\.u-w-fill\.hot\{/);

// Pace and auto-reset markers sit on the track at the ratio the Mac computed.
assert.match(app, /typeof w\.pace == "number"/);
assert.match(app, /class="u-w-pace"/);
assert.match(app, /usageMarkerAt\(ratio\)[\s\S]*?ratio \* 100/);
assert.match(app, /Auto-resets at or below " \+ percent \+ "% left, more than " \+ w\.autoResetMinHoursRemaining \+ "h before the natural weekly reset, if a banked reset is available\./);
assert.match(app, /Auto-resets at " \+ percent \+ "% left if a banked reset is available\./);
assert.match(app, /title="' \+ escAttr\(help\)/);
assert.match(app, /aria-label="' \+ escAttr\(help\)/);
assert.match(app, /title="' \+ escAttr\(detail\)/);
assert.match(app, /aria-label="' \+ escAttr\(detail\)/);
assert.match(css, /\.u-w-auto::before\{[^}]*linear-gradient\(#7359f2,#d95aa6\)/);
assert.match(css, /\.u-w-pace\{/);

// Dynamic values inside quoted attributes go through escAttr, which also escapes the double quote.
assert.match(app, /function escAttr\(s\) \{\s*return esc\(s\)\.replace\(\/"\/g, "&quot;"\);\s*\}/);
assert.match(app, /data-account="' \+\s*escAttr\(a\.id\)/);
assert.match(app, /aria-label="' \+ escAttr\(label\)/);
assert.match(app, /title="' \+ escAttr\(label\)/);

// Accounts that send no windows keep the single bar.
assert.match(app, /class="u-row' \+ \(a\.error/);
assert.match(app, /class="u-fill ' \+ usageClass\(a\.remaining\)/);

const start = app.indexOf("function usageWindowTint");
const end = app.indexOf("function renderUsage");
assert.ok(start > 0 && end > start, "usage window helpers went missing");
const sandbox = vm.createContext({
  esc: s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"),
});
vm.runInContext([
  app.match(/function escAttr\([\s\S]*?\n\}\n/)[0],
  app.match(/function resetExpiryLabel\([\s\S]*?\n\}\n/)[0],
  app.match(/function resetRow\([\s\S]*?\n\}\n/)[0],
  app.slice(start, end),
].join("\n"), sandbox);
const draw = w => vm.runInContext("usageWindow", sandbox)(w);

const weekly = draw({ label: "Fable 5 7d", left: 30, reset: "in 3d", pace: 0.5, deviation: 20, autoReset: 0.99, autoResetMinHoursRemaining: 12 });
assert.match(weekly, /u-w-label">Fable 5 7d<\/span><span class="u-w-value">30% left/);
assert.match(weekly, /u-w-fill hot" style="width:70%"/);
assert.match(weekly, /u-w-pace" style="--at:50%"/);
assert.match(weekly, /u-w-auto" style="--at:99%"/);
assert.match(weekly, /title="Auto-resets at or below 1% left, more than 12h before the natural weekly reset, if a banked reset is available\."/);
assert.match(weekly, /aria-label="Auto-resets at or below 1% left, more than 12h before the natural weekly reset, if a banked reset is available\."/);
assert.match(weekly, /Using quota too fast · 20% overutilized/);
assert.match(weekly, /title="Fable 5 7d · 30% left · Using quota too fast · 20% overutilized · in 3d"/);

const calm = draw({ label: "5h", left: 90, deviation: -12 });
assert.match(calm, /u-w-fill ok" style="width:10%"/);
assert.doesNotMatch(calm, /u-w-pace"|u-w-auto"/);
assert.match(calm, /Room to use more · 12% underutilized/);
assert.match(draw({ label: "5h", left: 70, deviation: 0 }), /On track/);
assert.match(draw({ label: "5h", left: 70 }), /u-w-fill warm" style="width:30%"/);
assert.match(draw({ label: "<b>", left: 50 }), /&lt;b&gt;/);
const legacyWeekly = draw({ label: "7d", left: 30, autoReset: 0.99 });
assert.match(legacyWeekly, /title="Auto-resets at 1% left if a banked reset is available\."/);
assert.match(legacyWeekly, /aria-label="Auto-resets at 1% left if a banked reset is available\."/);
assert.doesNotMatch(legacyWeekly, /natural weekly reset/);

const quoted = draw({ label: 'Fable "Preview" 7d', left: 30, reset: "in 3d", autoReset: 0.99 });
const quotedDetail = "Fable &quot;Preview&quot; 7d · 30% left · in 3d";
const autoHelp = "Auto-resets at 1% left if a banked reset is available.";
assert.match(quoted, /u-w-label">Fable "Preview" 7d<\/span>/);
assert.deepStrictEqual(
  [...quoted.matchAll(/ (title|aria-label)="([^"]*)"/g)].map(m => [m[1], m[2]]),
  [["title", quotedDetail], ["aria-label", quotedDetail], ["title", autoHelp], ["aria-label", autoHelp]],
);
assert.match(quoted, new RegExp(' title="' + quotedDetail + '" aria-label="' + quotedDetail + '">'));
const mixed = draw({ label: 'A&B <i> "x"', left: 30 });
assert.match(mixed, / title="A&amp;B &lt;i&gt; &quot;x&quot; · 30% left"/);
assert.match(mixed, /u-w-label">A&amp;B &lt;i&gt; "x"<\/span>/);

const redeem = vm.runInContext("resetRow", sandbox)({ id: 'acct"onclick="x', resets: 2 });
assert.match(redeem, /data-account="acct&quot;onclick=&quot;x"/);
assert.ok(!redeem.includes('"onclick='), "a raw quote from the account id reached the markup");
assert.match(redeem, /aria-label="Redeem reset \(2 available\)" title="Redeem reset \(2 available\)"/);

const drawReset = resets => vm.runInContext("resetRow", sandbox)({ id: "acct", resets });
assert.equal(drawReset("<img src=x onerror=alert(1)>"), "", "a hostile reset count must not reach the markup");
assert.equal(drawReset("2<img src=x onerror=alert(1)>"), "");
assert.match(drawReset("3"), /Redeem reset \(3 available\)[\s\S]*<span aria-hidden="true">3<\/span>/);

// Several accounts with three bars each outgrow the screen; the panel scrolls instead of clipping.
assert.match(css, /#usage\{[^}]*max-height:45dvh;overflow-y:auto/);

console.log("remote usage window tests passed");
