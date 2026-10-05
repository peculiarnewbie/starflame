export function undefined_() {
  return undefined;
}

/// An array of `length` holes.
export function sparse(length) {
  return new Array(length);
}

/// An object that isn't plain.
export function instance() {
  return new (class Point {
    x = 1;
  })();
}

export function identity(value) {
  return value;
}
