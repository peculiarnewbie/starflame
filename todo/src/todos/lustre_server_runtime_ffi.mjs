/*
Copyright 2022 Hayleigh Thompson

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in the
Software without restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
// Vendored from lustre 5.7.1 (MIT), lustre-labs/lustre.
// Compatibility fixes: startup arity, shadowed message variables, batched events,
// and messages arriving after shutdown. Imports point to compiled Lustre modules.
import {
  Result$Ok,
  Result$Ok$0,
  Result$isOk,
  List$NonEmpty$rest,
  List$NonEmpty$first,
} from "../../lustre/gleam.mjs";
import * as Decode from "../../gleam_stdlib/gleam/dynamic/decode.mjs";
import * as Dict from "../../gleam_stdlib/gleam/dict.mjs";
import * as Option from "../../gleam_stdlib/gleam/option.mjs";
import * as Diff from "../../lustre/lustre/vdom/diff.mjs";
import * as Cache from "../../lustre/lustre/vdom/cache.mjs";
import { isEqual } from "../../lustre/lustre/internals/equals.ffi.mjs";
import {
  Message$isClientDispatchedMessage,
  Message$isClientRegisteredCallback,
  Message$isClientDeregisteredCallback,
  //
  Message$EffectDispatchedMessage,
  Message$isEffectDispatchedMessage,
  Message$EffectEmitEvent,
  Message$isEffectEmitEvent,
  Message$EffectProvidedValue,
  Message$isEffectProvidedValue,
  Message$EffectRequestedContextSubscription,
  Message$isEffectRequestedContextSubscription,
  Message$EffectRemovedContextSubscription,
  Message$isEffectRemovedContextSubscription,
  //
  Message$isSystemRequestedShutdown,
} from "../../lustre/lustre/runtime/server/runtime.mjs";
import * as App from "../../lustre/lustre/runtime/app.mjs";
import * as Effect from "../../lustre/lustre/effect.mjs";
import * as Transport from "../../lustre/lustre/runtime/transport.mjs";
import {
  ServerMessage$isBatch,
  ServerMessage$isAttributeChanged,
  ServerMessage$isPropertyChanged,
  ServerMessage$isEventFired,
  ServerMessage$isContextProvided,
} from "../../lustre/lustre/runtime/transport.mjs";
import { toList } from "../../lustre/lustre/internals/list.ffi.mjs";

//

export class Runtime {
  #model;
  #update;
  #view;
  #config;

  #vdom;
  #cache;
  #providers = Dict.new$();

  #callbacks = /* @__PURE__ */ new Set();

  constructor(_, init, update, view, config, start_arguments) {
    const [model, effects] = init(start_arguments);
    this.#model = model;
    this.#update = update;
    this.#view = view;
    this.#config = config;

    this.#vdom = this.#view(this.#model);
    this.#cache = Cache.from_node(this.#vdom);

    this.#handle_effect(effects);
  }

  send(message) {
    if (!this.#update) return;
    if (Message$isClientDispatchedMessage(message)) {
      const { message: payload } = message;
      const next = this.#handle_client_message(payload);
      const diff = Diff.diff(this.#cache, this.#vdom, next);

      this.#vdom = next;
      this.#cache = diff.cache;

      this.broadcast(Transport.reconcile(diff.patch, Cache.memos(diff.cache)));
    } else if (Message$isClientRegisteredCallback(message)) {
      const { callback } = message;
      this.#callbacks.add(callback);

      callback(
        Transport.mount(
          this.#config.open_shadow_root,
          this.#config.adopt_styles,
          Dict.keys(this.#config.attributes),
          Dict.keys(this.#config.properties),
          Dict.keys(this.#config.contexts),
          this.#providers,
          this.#vdom,
          Cache.memos(this.#cache),
        ),
      );

      if (Option.Option$isSome(this.#config.on_connect)) {
        this.#dispatch(Option.Option$Some$0(this.#config.on_connect));
      }
    } else if (Message$isClientDeregisteredCallback(message)) {
      const { callback } = message;
      this.#callbacks.delete(callback);

      if (Option.Option$isSome(this.#config.on_disconnect)) {
        this.#dispatch(Option.Option$Some$0(this.#config.on_disconnect));
      }
    } else if (Message$isEffectDispatchedMessage(message)) {
      const { message: payload } = message;
      const [model, effect] = this.#update(this.#model, payload);
      const next = this.#view(model);
      const diff = Diff.diff(this.#cache, this.#vdom, next);

      this.#handle_effect(effect);

      this.#model = model;
      this.#vdom = next;
      this.#cache = diff.cache;

      this.broadcast(Transport.reconcile(diff.patch, Cache.memos(diff.cache)));
    } else if (Message$isEffectEmitEvent(message)) {
      const { name, data } = message;
      this.broadcast(Transport.emit(name, data));
    } else if (Message$isEffectProvidedValue(message)) {
      const { key, value } = message;
      const existing = Dict.get(this.#providers, key);
      // we do not need to broadcast an update if the provided value is the same.
      if (Result$isOk(existing) && isEqual(Result$Ok$0(existing), value)) {
        return;
      }

      this.#providers = Dict.insert(this.#providers, key, value);
      this.broadcast(Transport.provide(key, value));
    } else if (Message$isEffectRequestedContextSubscription(message)) {
      const { key, decoder } = message;

      this.broadcast(Transport.subscribe(key));
      this.#config.contexts = Dict.insert(this.#config.contexts, key, decoder);
    } else if (Message$isEffectRemovedContextSubscription(message)) {
      const { key } = message;

      this.broadcast(Transport.unsubscribe(key));
      this.#config.contexts = Dict.delete$(this.#config.contexts, key);
    } else if (Message$isSystemRequestedShutdown(message)) {
      this.#model = null;
      this.#update = null;
      this.#view = null;
      this.#config = null;
      this.#vdom = null;
      this.#cache = null;
      this.#providers = null;
      this.#callbacks.clear();
    }
  }

  broadcast(message) {
    for (const callback of this.#callbacks) {
      callback(message);
    }
  }

  #handle_client_message(message) {
    if (ServerMessage$isBatch(message)) {
      for (const item of message.messages.toArray()) {
        this.#handle_client_message(item);
      }
      return this.#view(this.#model);
    } else if (ServerMessage$isAttributeChanged(message)) {
      const { name, value } = message;
      const result = this.#handle_attribute_change(name, value);
      if (!Result$isOk(result)) {
        return this.#vdom;
      }

      return this.#dispatch(Result$Ok$0(result));
    } else if (ServerMessage$isPropertyChanged(message)) {
      const { name, value } = message;
      const result = this.#handle_property_change(name, value);
      if (!Result$isOk(result)) {
        return this.#vdom;
      }

      return this.#dispatch(Result$Ok$0(result));
    } else if (ServerMessage$isEventFired(message)) {
      const { path, name, event } = message;
      const [cache, result] = Cache.handle(this.#cache, path, name, event);

      this.#cache = cache;
      if (!Result$isOk(result)) {
        return this.#vdom;
      }

      const { message: payload } = Result$Ok$0(result);
      return this.#dispatch(payload);
    } else if (ServerMessage$isContextProvided(message)) {
      const { key, value } = message;
      let result = Dict.get(this.#config.contexts, key);
      if (!Result$isOk(result)) {
        return this.#vdom;
      }

      result = Decode.run(value, Result$Ok$0(result));
      if (!Result$isOk(result)) {
        return this.#vdom;
      }

      return this.#dispatch(Result$Ok$0(result));
    }
  }

  #dispatch(message) {
    const [model, effects] = this.#update(this.#model, message);
    this.#handle_effect(effects);
    this.#model = model;

    return this.#view(this.#model);
  }

  #handle_attribute_change(name, value) {
    const result = Dict.get(this.#config.attributes, name);
    if (!Result$isOk(result)) {
      return result;
    }

    return Result$Ok$0(result)(value);
  }

  #handle_property_change(name, value) {
    const result = Dict.get(this.#config.properties, name);
    if (!Result$isOk(result)) {
      return result;
    }

    return Result$Ok$0(result)(value);
  }

  #handle_effect(effect) {
    const dispatch = (message) =>
      this.send(Message$EffectDispatchedMessage(message));
    const emit = (name, data) => this.send(Message$EffectEmitEvent(name, data));
    const select = () => undefined;
    const internals = () => undefined;
    const provide = (key, value) =>
      this.send(Message$EffectProvidedValue(key, value));
    const subscribe = (key, decoder) =>
      this.send(Message$EffectRequestedContextSubscription(key, decoder));
    const unsubscribe = (key) =>
      this.send(Message$EffectRemovedContextSubscription(key));

    globalThis.queueMicrotask(() => {
      Effect.perform(effect,
        dispatch,
        emit,
        select,
        internals,
        provide,
        subscribe,
        unsubscribe
      );
    });
  }
}

export const start = (app, start_arguments) => {
  const config = App.configure_server_component(app.config);

  return Result$Ok(
    new Runtime(app.name, app.init, app.update, app.view, config, start_arguments),
  );
};

export const send = (runtime, message) => {
  runtime.send(message);
};
