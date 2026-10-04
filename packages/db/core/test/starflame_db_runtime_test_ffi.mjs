export function is_integer_value(value, expected) {
  return value?.constructor?.name === "Integer" && value[0] === expected;
}

export function unsafe_integer() {
  return Number.MAX_SAFE_INTEGER + 1;
}
