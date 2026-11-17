// Formulários com data-confirm pedem confirmação antes do envio.
export function initConfirm(root) {
  root.querySelectorAll("form[data-confirm]").forEach((form) => {
    form.addEventListener("submit", (event) => {
      if (!window.confirm(form.dataset.confirm)) event.preventDefault();
    });
  });
}
