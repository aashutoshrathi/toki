"use strict";

const assert = require("node:assert");
const renderMarkdown = require("../Sources/Toki/Resources/webui/markdown.js");

const table = renderMarkdown([
  "| Name | Status | Total |",
  "| :--- | :---: | ---: |",
  "| **Alpha** | `ready` | 42 |",
  "| Beta | waiting | 7 |"
].join("\n"));

assert.match(table, /class="table-wrap"/);
assert.match(table, /<table>/);
assert.match(table, /<th style="text-align:left">Name<\/th>/);
assert.match(table, /<th style="text-align:center">Status<\/th>/);
assert.match(table, /<th style="text-align:right">Total<\/th>/);
assert.match(table, /<td style="text-align:left"><b>Alpha<\/b><\/td>/);
assert.match(table, /<td style="text-align:center"><code>ready<\/code><\/td>/);

const escaped = renderMarkdown("| Value | Note |\n| --- | --- |\n| a \\| b | <script>alert(1)</script> |");
assert.match(escaped, /<td style="text-align:left">a \| b<\/td>/);
assert.doesNotMatch(escaped, /<script>/);
assert.match(escaped, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);

// A bare URL is linked, and the sentence it sits in keeps its punctuation.
const bare = renderMarkdown("See https://github.com/aashutoshrathi/toki for the source.");
assert.match(
  bare,
  /<a href="https:\/\/github\.com\/aashutoshrathi\/toki" target="_blank" rel="noopener noreferrer">https:\/\/github\.com\/aashutoshrathi\/toki<\/a> for the source\./
);

const trailing = renderMarkdown("Open https://toki.aashutosh.dev/docs, then https://example.com.");
assert.match(trailing, /<a href="https:\/\/toki\.aashutosh\.dev\/docs"[^>]*>https:\/\/toki\.aashutosh\.dev\/docs<\/a>, then/);
assert.match(trailing, /<a href="https:\/\/example\.com"[^>]*>https:\/\/example\.com<\/a>\.<\/p>/);

// A bracket closes the URL only when the URL opened it.
const brackets = renderMarkdown("(see https://example.com/a) and https://en.wikipedia.org/wiki/Foo_(bar)");
assert.match(brackets, /href="https:\/\/example\.com\/a"/);
assert.match(brackets, /<\/a>\) and/);
assert.match(brackets, /href="https:\/\/en\.wikipedia\.org\/wiki\/Foo_\(bar\)"/);

// A written link is left alone rather than linked twice, and its text is not a URL to hunt for.
const written = renderMarkdown("[the repo](https://github.com/aashutoshrathi/toki) and nothing else");
assert.equal(written.match(/<a /g).length, 1);
assert.match(written, /<a href="https:\/\/github\.com\/aashutoshrathi\/toki"[^>]*>the repo<\/a>/);
assert.doesNotMatch(renderMarkdown("[https://a.example](https://b.example)"), /<a[^>]*><a /);

// Escaping runs first, so an "&" in a query string survives into the href, while the "<>" or
// quotes that wrapped a URL are not swallowed by it.
const query = renderMarkdown("https://example.com/s?a=1&b=2 done");
assert.match(query, /href="https:\/\/example\.com\/s\?a=1&amp;b=2"/);
assert.match(query, /<\/a> done<\/p>/);
const wrapped = renderMarkdown("<https://example.com/x> and \"https://example.com/y\"");
assert.match(wrapped, /href="https:\/\/example\.com\/x"/);
assert.match(wrapped, /<\/a>&gt; and/);
assert.match(wrapped, /href="https:\/\/example\.com\/y"/);
assert.match(wrapped, /<\/a>&quot;<\/p>/);

// Code keeps its URLs as text: a fenced block and an inline span are both left unlinked.
assert.doesNotMatch(renderMarkdown("```\ncurl https://example.com\n```"), /<a /);
assert.doesNotMatch(renderMarkdown("run `curl https://example.com` now"), /<a /);

// Nothing but http(s) is linked, so a scheme that would run script cannot become a target.
assert.doesNotMatch(renderMarkdown("javascript:alert(1) and data:text/html,x"), /<a /);
assert.doesNotMatch(renderMarkdown("[x](javascript:alert(1))"), /<a /);

// Links inside a table cell work the same way.
const cellLink = renderMarkdown([
  "| Name | Where |",
  "| --- | --- |",
  "| Toki | https://toki.aashutosh.dev |"
].join("\n"));
assert.match(cellLink, /<td style="text-align:left"><a href="https:\/\/toki\.aashutosh\.dev"/);

// linkify: plain text, links only, with everything else left exactly as typed.
assert.equal(
  renderMarkdown.linkify("ship https://example.com/a?x=1&y=2 now"),
  'ship <a href="https://example.com/a?x=1&amp;y=2" target="_blank" rel="noopener noreferrer">' +
    "https://example.com/a?x=1&amp;y=2</a> now"
);
assert.equal(renderMarkdown.linkify("**not bold** and `not code`"), "**not bold** and `not code`");
assert.equal(renderMarkdown.linkify(""), "");
assert.doesNotMatch(renderMarkdown.linkify("<script>alert(1)</script>"), /<script>/);
assert.doesNotMatch(renderMarkdown.linkify("javascript:alert(1)"), /<a /);

console.log("markdown table and link tests passed");
