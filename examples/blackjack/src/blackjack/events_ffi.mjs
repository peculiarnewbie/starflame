const rooms = new WeakMap();
const subscriptions = new WeakMap();

function cached(values, key, create) {
  if (!values.has(key)) values.set(key, create());
  return values.get(key);
}

export function roomEvents(execution, create) {
  return cached(rooms, execution, create);
}

export function subscription(context, create) {
  return cached(subscriptions, context, create);
}
