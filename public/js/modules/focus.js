// Leva o foco para a primeira mensagem de erro, para leitores de tela e navegação por teclado.
export function initFocus(root) {
  const target = root.querySelector("[data-autofocus]");
  if (target) target.focus();
}
