export function create() {
  return { subscriptions: new Set(), onCount: () => {} };
}

export function publish(topic, event) {
  for (const subscription of [...topic.subscriptions]) {
    subscription.callback?.(event);
  }
}

export function onCountChange(topic, callback) {
  topic.onCount = callback;
}

export function subscription(topic) {
  return { topic, callback: null, disposed: false };
}

export function listen(subscription, callback) {
  if (subscription.disposed) throw new Error("The subscription is disposed");
  const active = subscription.callback !== null;
  subscription.callback = callback;
  if (!active) {
    subscription.topic.subscriptions.add(subscription);
    subscription.topic.onCount(subscription.topic.subscriptions.size);
  }
}

export function dispose(subscription) {
  if (subscription.disposed) return;
  subscription.disposed = true;
  subscription.callback = null;
  if (subscription.topic.subscriptions.delete(subscription)) {
    subscription.topic.onCount(subscription.topic.subscriptions.size);
  }
}
