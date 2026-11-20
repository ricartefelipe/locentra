export function initFlash(root) {
  root.querySelectorAll("[data-flash] [data-dismiss]").forEach((button) => {
    button.addEventListener("click", () => button.closest("[data-flash]").remove());
  });
}
