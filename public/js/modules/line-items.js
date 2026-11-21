// Inclusão e remoção de linhas repetidas (itens, tarifas), mantendo labels associados por id único.
// Cada [data-line-group] dentro de [data-line-items] tem as próprias linhas ([data-lines]) e o próprio
// botão ([data-add-line]); sem grupos, o formulário inteiro é um grupo só.
function resetFields(line, renumber) {
  line.querySelectorAll("select, input, textarea").forEach((field) => {
    if (renumber && field.id) {
      const label = line.querySelector(`label[for="${field.id}"]`);
      field.id = renumber(field.id);
      if (label) label.htmlFor = field.id;
    }
    field.value = field.dataset.resetValue || "";
  });
}

function initGroup(group) {
  const container = group.querySelector("[data-lines]");
  const addButton = group.querySelector("[data-add-line]");
  if (!container || !addButton) return;
  let counter = container.querySelectorAll("[data-line]").length;

  addButton.addEventListener("click", () => {
    const template = container.querySelector("[data-line]");
    if (!template) return;
    const clone = template.cloneNode(true);
    counter += 1;
    resetFields(clone, (id) => `${id.replace(/-\d+$/, "")}-${counter}`);
    container.appendChild(clone);
    const first = clone.querySelector("select, input:not([type=hidden])");
    if (first) first.focus();
  });

  // A última linha serve de modelo para as próximas: em vez de removida, volta ao estado inicial.
  container.addEventListener("click", (event) => {
    const button = event.target.closest("[data-remove-line]");
    if (!button) return;
    const line = button.closest("[data-line]");
    if (container.querySelectorAll("[data-line]").length > 1) line.remove();
    else resetFields(line);
    addButton.focus();
  });
}

export function initLineItems(root) {
  root.querySelectorAll("[data-line-items]").forEach((form) => {
    const groups = form.querySelectorAll("[data-line-group]");
    (groups.length ? groups : [form]).forEach(initGroup);

    // Linhas mantidas como texto (com campos ocultos) são removidas por inteiro.
    form.addEventListener("click", (event) => {
      const button = event.target.closest("[data-remove-kept]");
      if (!button) return;
      const group = button.closest("[data-line-group]") || form;
      button.closest("[data-kept-line]").remove();
      const next = group.querySelector("[data-remove-kept], [data-add-line], select, input:not([type=hidden])");
      if (next) next.focus();
    });
  });
}
