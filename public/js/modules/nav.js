// Menu lateral em telas estreitas: o botão [data-nav-toggle] abre e fecha a navegação (atributo
// data-nav-open no <body>); o fundo [data-nav-close] e a tecla Esc fecham. Em telas largas o botão
// fica oculto e a navegação está sempre visível.
export function initNav(root) {
  const toggle = root.querySelector("[data-nav-toggle]");
  if (!toggle) return;
  const state = root.body.dataset;
  const isOpen = () => "navOpen" in state;
  const setOpen = (open) => {
    if (open) state.navOpen = "";
    else delete state.navOpen;
    toggle.setAttribute("aria-expanded", String(open));
    toggle.setAttribute("aria-label", open ? "Fechar menu" : "Abrir menu");
  };
  toggle.addEventListener("click", () => setOpen(!isOpen()));
  root.querySelectorAll("[data-nav-close]").forEach((el) => el.addEventListener("click", () => setOpen(false)));
  root.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && isOpen()) {
      setOpen(false);
      toggle.focus();
    }
  });
}
