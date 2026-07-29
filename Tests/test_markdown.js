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

console.log("markdown table tests passed");
