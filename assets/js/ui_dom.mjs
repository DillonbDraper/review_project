// DOM access only; interaction policy and event bindings live in Hologram.
export default {
  focus(id) {
    document.getElementById(id)?.focus();
  },

  focusWithin(id) {
    return document.getElementById(id)?.contains(document.activeElement) || false;
  },
};
