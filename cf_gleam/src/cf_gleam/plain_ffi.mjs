export function identity(value) {
  return value;
}

export function null_() {
  return null;
}

export function array(items) {
  return items.toArray();
}

export function object(entries) {
  const result = {};
  for (const [key, value] of entries) result[key] = value;
  return result;
}
