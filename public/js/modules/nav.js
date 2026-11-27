// Menu lateral em telas estreitas: o botão [data-nav-toggle] abre e fecha a navegação (atributo
// data-nav-open no <body>); o fundo [data-nav-close] e a tecla Esc fecham. Em telas largas o botão
// fica oculto e a navegação está sempre visível.
export function initNav(root) {
  const toggle = root.querySelector("[data-nav-toggle]");
  if (!toggle) return;
  const body = root.body;
  const setOpen = (open) => {
    if (open) body.setAttribute("data-nav-open", "");
    else body.removeAttribute("data-nav-open");
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Fechar menu" : "Abrir menu");
  };
  toggle.addEventListener("click", () => setOpen(!body.hasAttribute("data-nav-open")));
  root.querySelectorAll("[data-nav-close]").forEach((el) => el.addEventListener("click", () => setOpen(false)));
  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && body.hasAttribute("data-nav-open")) {
      setOpen(false);
      toggle.focus();
    }
  });
}
