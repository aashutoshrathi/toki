(function(root, factory) {
  const renderMarkdown = factory();
  if (typeof module === "object" && module.exports) module.exports = renderMarkdown;
  root.renderMarkdown = renderMarkdown;
})(typeof globalThis !== "undefined" ? globalThis : this, function() {
  function escapeHTML(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function anchor(href, label) {
    return '<a href="' + href + '" target="_blank" rel="noopener noreferrer">' + label + "</a>";
  }

  function countChar(value, char) {
    let total = 0;
    for (let index = 0; index < value.length; index++) {
      if (value[index] === char) total++;
    }
    return total;
  }

  // Where a bare URL actually ends. What surrounds it is prose, so a trailing full stop or comma
  // belongs to the sentence, and a closing bracket belongs to the URL only if the URL opened it.
  // Escaping has already run by this point, so a delimiter that wrapped the URL arrives as an
  // entity -- &gt; from <url>, &quot; from "url" -- and has to come off whole, while the semicolon
  // ending an &amp; inside a query string has to stay on.
  function urlEnd(url) {
    let end = url.length;
    while (end > 0) {
      const head = url.slice(0, end);
      const wrapper = head.match(/&(?:gt|quot|#39);$/);
      if (wrapper) {
        end -= wrapper[0].length;
        continue;
      }
      const last = head[end - 1];
      if (last === ";" && /&(?:#\d+|[a-zA-Z]+);$/.test(head)) break;
      if (".,;:!?".indexOf(last) >= 0) {
        end--;
        continue;
      }
      if (last === ")" && countChar(head, "(") < countChar(head, ")")) {
        end--;
        continue;
      }
      break;
    }
    return end;
  }

  // A bare URL runs to whitespace, to a "<" (escaping has already run, so a raw one can only be
  // markup this renderer produced), or to a control character, which no URL contains and which is
  // what a stashed code span is left behind as.
  const BARE_URL = /https?:\/\/[^\s<\p{Cc}]+/gu;

  // A bare URL, linked from wherever it ends up: the prose an agent writes, a line of a table, the
  // question in an approval prompt. Only http(s) is matched, so no anchor this produces can carry
  // a javascript: or data: target, and the URL has already been escaped by the time it lands in
  // the href.
  function linkURL(match) {
    const url = match.slice(0, urlEnd(match));
    if (!/^https?:\/\/[^\s<]/.test(url)) return match;
    return anchor(url, url) + match.slice(url.length);
  }

  function inlineMarkdown(value) {
    const codes = [];
    let text = value.replace(/`([^`\n]+)`/g, function(_, code) {
      codes.push(code);
      return "\u0001C" + (codes.length - 1) + "\u0001";
    });
    text = text.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    text = text.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<i>$2</i>");
    // Written links and bare ones in a single pass, the written form first: matching them
    // separately would let the bare-URL pass find the href the written one had just produced and
    // nest a second anchor inside the first.
    text = text.replace(
      new RegExp("\\[([^\\]]+)\\]\\(([^)\\s]*)\\)|" + BARE_URL.source, "gu"),
      function(match, label, href) {
        // A written link is matched whatever its destination, but only followed when that
        // destination is one this renderer will open. The rest -- a relative path, an anchor, a
        // mailto -- stays the plain text it has always been. Matching only the http ones here
        // would drop the others through to the bare-URL branch, which would then find a URL in
        // the label and swallow the "](destination)" after it into the href.
        if (label !== undefined) return /^https?:/.test(href) ? anchor(href, label) : match;
        return linkURL(match);
      }
    );
    return text.replace(/\u0001C(\d+)\u0001/g, function(_, index) {
      return "<code>" + codes[Number(index)] + "</code>";
    });
  }

  function tableCells(line) {
    let value = line.trim();
    if (value.startsWith("|")) value = value.slice(1);
    if (value.endsWith("|")) value = value.slice(0, -1);
    const cells = [];
    let cell = "";
    for (let index = 0; index < value.length; index++) {
      if (value[index] === "\\" && value[index + 1] === "|") {
        cell += "|";
        index++;
      } else if (value[index] === "|") {
        cells.push(cell.trim());
        cell = "";
      } else {
        cell += value[index];
      }
    }
    cells.push(cell.trim());
    return cells;
  }

  function tableAlignment(cell) {
    const value = cell.trim();
    if (!/^:?-{3,}:?$/.test(value)) return null;
    if (value.startsWith(":") && value.endsWith(":")) return "center";
    if (value.endsWith(":")) return "right";
    return "left";
  }

  function renderTable(lines, start) {
    if (start + 1 >= lines.length || !lines[start].includes("|")) return null;
    const headers = tableCells(lines[start]);
    const delimiters = tableCells(lines[start + 1]);
    if (
      headers.length < 2 ||
      delimiters.length !== headers.length ||
      delimiters.some(function(cell) { return tableAlignment(cell) === null; })
    ) {
      return null;
    }

    const alignments = delimiters.map(tableAlignment);
    const rows = [];
    let next = start + 2;
    while (next < lines.length && lines[next].trim() && lines[next].includes("|")) {
      const cells = tableCells(lines[next]);
      if (cells.length !== headers.length) break;
      rows.push(cells);
      next++;
    }

    function cellHTML(tag, value, index) {
      return "<" + tag + ' style="text-align:' + alignments[index] + '">' +
        inlineMarkdown(value) + "</" + tag + ">";
    }

    const head = "<thead><tr>" + headers.map(function(value, index) {
      return cellHTML("th", value, index);
    }).join("") + "</tr></thead>";
    const body = rows.length ? "<tbody>" + rows.map(function(row) {
      return "<tr>" + row.map(function(value, index) {
        return cellHTML("td", value, index);
      }).join("") + "</tr>";
    }).join("") + "</tbody>" : "";
    return {
      html: '<div class="table-wrap"><table>' + head + body + "</table></div>",
      next: next
    };
  }

  function renderMarkdown(source) {
    let text = escapeHTML(source);
    const fences = [];
    text = text.replace(/```[a-zA-Z0-9_-]*\n([\s\S]*?)```/g, function(_, code) {
      fences.push(code);
      return "\u0000F" + (fences.length - 1) + "\u0000";
    });

    const lines = text.split("\n");
    const output = [];
    for (let index = 0; index < lines.length;) {
      const fence = lines[index].match(/^\u0000F(\d+)\u0000$/);
      if (fence) {
        output.push("<pre><code>" + fences[Number(fence[1])] + "</code></pre>");
        index++;
        continue;
      }

      const table = renderTable(lines, index);
      if (table) {
        output.push(table.html);
        index = table.next;
        continue;
      }

      const line = lines[index];
      if (/^#{1,4}\s/.test(line)) {
        output.push("<p><b>" + inlineMarkdown(line.replace(/^#{1,4}\s+/, "")) + "</b></p>");
      } else if (/^\s*[-*]\s+/.test(line)) {
        output.push("<p>&bull; " + inlineMarkdown(line.replace(/^\s*[-*]\s+/, "")) + "</p>");
      } else if (/^\s*\d+\.\s+/.test(line)) {
        output.push("<p>" + inlineMarkdown(line) + "</p>");
      } else if (line.length) {
        output.push("<p>" + inlineMarkdown(line) + "</p>");
      }
      index++;
    }
    return output.join("");
  }

  // The same links for text that is not Markdown: a message you typed, the target of a tool call.
  // Nothing else in the string is interpreted, so a reply of "**not bold**" still reads as it was
  // typed, and the escape runs first so this is safe on anything.
  renderMarkdown.linkify = function(source) {
    return escapeHTML(source == null ? "" : source).replace(BARE_URL, function(match) {
      return linkURL(match);
    });
  };

  return renderMarkdown;
});
