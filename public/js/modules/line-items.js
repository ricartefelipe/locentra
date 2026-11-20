// Inclusão e remoção de linhas de itens, mantendo labels associados por id único.
export function initLineItems(root) {
  root.querySelectorAll("[data-line-items]").forEach((form) => {
    const container = form.querySelector("[data-lines]");
    const addButton = form.querySelector("[data-add-line]");
    if (!container || !addButton) return;
    let counter = container.querySelectorAll("[data-line]").length;

    addButton.addEventListener("click", () => {
      const template = container.querySelector("[data-line]");
      const clone = template.cloneNode(true);
      counter += 1;
      clone.querySelectorAll("select, input").forEach((field) => {
        const base = field.id.replace(/-\d+$/, "");
        const label = clone.querySelector(`label[for="${field.id}"]`);
        field.id = `${base}-${counter}`;
        if (label) label.htmlFor = field.id;
        field.value = field.tagName === "INPUT" ? "1" : "";
      });
      container.appendChild(clone);
      clone.querySelector("select").focus();
    });

    container.addEventListener("click", (event) => {
      const button = event.target.closest("[data-remove-line]");
      if (!button) return;
      const lines = container.querySelectorAll("[data-line]");
      if (lines.length > 1) {
        button.closest("[data-line]").remove();
        addButton.focus();
      }
    });
  });
}
