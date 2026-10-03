export function onFocus(callback) {
  window.addEventListener("focus", () => callback());
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") callback();
  });
}

export function identity(value) { return value; }
