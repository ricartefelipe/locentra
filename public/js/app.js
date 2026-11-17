// Ponto de entrada: inicializa módulos pequenos e independentes. Sem dados inline: leituras
// ocorrem apenas por atributos data-* e por <script type="application/json">.
import { initFlash } from "./modules/flash.js";
import { initConfirm } from "./modules/confirm.js";
import { initLineItems } from "./modules/line-items.js";
import { initFocus } from "./modules/focus.js";
import { initCopy } from "./modules/copy.js";

document.addEventListener("DOMContentLoaded", () => {
  initFlash(document);
  initConfirm(document);
  initLineItems(document);
  initFocus(document);
  initCopy(document);
});
