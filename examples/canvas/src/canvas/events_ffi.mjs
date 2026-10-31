const rooms = new WeakMap();

export function roomEvents(execution, create) {
  let events = rooms.get(execution);
  if (!events) {
    events = create();
    rooms.set(execution, events);
  }
  return events;
}
