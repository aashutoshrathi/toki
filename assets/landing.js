const tabs = [...document.querySelectorAll('[role="tab"]')];

function selectTab(tab) {
  for (const item of tabs) {
    const selected = item === tab;
    item.setAttribute("aria-selected", String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute("aria-controls")).hidden =
      !selected;
  }
}

for (const tab of tabs) {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    let index = tabs.indexOf(tab);
    if (event.key === "ArrowRight") {
      index = (index + 1) % tabs.length;
    } else if (event.key === "ArrowLeft") {
      index = (index - 1 + tabs.length) % tabs.length;
    } else if (event.key === "Home") {
      index = 0;
    } else if (event.key === "End") {
      index = tabs.length - 1;
    } else {
      return;
    }
    event.preventDefault();
    selectTab(tabs[index]);
    tabs[index].focus();
  });
}

for (const button of document.querySelectorAll("[data-copy]")) {
  button.hidden = false;
  button.addEventListener("click", async () => {
    const code = document.getElementById(button.dataset.copy);
    const status = document.querySelector(".copy-status");
    try {
      await navigator.clipboard.writeText(code.textContent);
      status.textContent = "Command copied. Paste it into Terminal.";
      button.textContent = "Copied!";
      window.setTimeout(() => {
        button.textContent = "Copy";
      }, 2000);
    } catch {
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(code);
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent =
        "Command selected. Press ⌘C on Mac or Ctrl+C to copy.";
    }
  });
}
