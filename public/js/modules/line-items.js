// Inclusão e remoção de linhas repetidas (itens, tarifas, faixas), mantendo labels associados por id único.
// Cada [data-line-group] dentro de [data-line-items] tem as próprias linhas ([data-lines]) e o próprio
// botão ([data-add-line]); sem grupos, o formulário inteiro é um grupo só. A linha marcada com
// [data-line-template] (por exemplo, a linha vazia de uma lista numerada) é o modelo das novas linhas; sem
// ela, o modelo é a primeira linha.

// Campo limpo não carrega o erro de outra linha: sai o aria-invalid e as referências às mensagens de erro.
function clearErrorState(field) {
  field.removeAttribute("aria-invalid");
  const described = (field.getAttribute("aria-describedby") || "").split(/\s+/).filter((id) => id && !id.startsWith("erro-"));
  if (described.length) field.setAttribute("aria-describedby", described.join(" "));
  else field.removeAttribute("aria-describedby");
}

function resetFields(line, renumber) {
  line.querySelectorAll("select, input, textarea").forEach((field) => {
    if (renumber && field.id) {
      const label = line.querySelector(`label[for="${field.id}"]`);
      field.id = renumber(field.id);
      if (label) label.htmlFor = field.id;
    }
    field.value = field.dataset.resetValue || "";
    clearErrorState(field);
  });
  line.querySelectorAll(".field-error").forEach((message) => message.remove());
}

function initGroup(group) {
  const container = group.querySelector("[data-lines]");
  const addButton = group.querySelector("[data-add-line]");
  if (!container || !addButton) return;
  let counter = container.querySelectorAll("[data-line]").length;

  addButton.addEventListener("click", () => {
    const template = container.querySelector("[data-line][data-line-template]") || container.querySelector("[data-line]");
    if (!template) return;
    const clone = template.cloneNode(true);
    clone.removeAttribute("data-line-template");
    counter += 1;
    resetFields(clone, (id) => `${id.replace(/-\d+$/, "")}-${counter}`);
    container.appendChild(clone);
    const first = clone.querySelector("select, input:not([type=hidden])");
    if (first) first.focus();
  });

  // A última linha restante e a linha modelo servem de modelo para as próximas: em vez de removidas,
  // voltam ao estado inicial.
  container.addEventListener("click", (event) => {
    const button = event.target.closest("[data-remove-line]");
    if (!button) return;
    const line = button.closest("[data-line]");
    if (container.querySelectorAll("[data-line]").length > 1 && !line.hasAttribute("data-line-template")) line.remove();
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
