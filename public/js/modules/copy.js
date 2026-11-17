// Seleciona o conteúdo de elementos data-copy ao focar, facilitando copiar tokens exibidos uma vez.
export function initCopy(root) {
  root.querySelectorAll("[data-copy]").forEach((element) => {
    element.tabIndex = 0;
    element.addEventListener("focus", () => {
      const range = document.createRange();
      range.selectNodeContents(element);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    });
  });
}
