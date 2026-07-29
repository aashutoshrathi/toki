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

  function inlineMarkdown(value) {
    const codes = [];
    let text = value.replace(/`([^`\n]+)`/g, function(_, code) {
      codes.push(code);
      return "\u0001C" + (codes.length - 1) + "\u0001";
    });
    text = text.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    text = text.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<i>$2</i>");
    text = text.replace(
      /\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
      '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
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

  return function renderMarkdown(source) {
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
  };
});
