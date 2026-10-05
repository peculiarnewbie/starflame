//// Checks an API module against what can cross the wire, and describes it
//// for code generation.
////
//// Every public function in the API module is an RPC method. Its first
//// argument is the `starflame/server.Context`, and every other argument must
//// be labelled, so the generated client functions are labelled too. Records
//// whose fields are all functions are capabilities, passed by reference;
//// they can only be returned.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import starflame_rpc_kit/interface.{
  type Interface, type Type, type TypeDefinition, Fn, Named, Tuple, Variable,
}

pub type Ref {
  Ref(module: String, name: String)
}

/// A type that can cross the wire.
pub type Ty {
  IntT
  FloatT
  StringT
  BoolT
  NilT
  ListT(item: Ty)
  OptionT(some: Ty)
  DictT(value: Ty)
  ResultT(ok: Ty, error: Ty)
  TupleT(elements: List(Ty))
  DataT(ref: Ref)
  CapabilityT(ref: Ref)
}

pub type Param {
  /// Capability methods' arguments have no labels.
  Value(label: Option(String), ty: Ty)
  /// A function the server can call back, fire-and-forget.
  Callback(label: Option(String), arguments: List(Ty))
}

pub type Method {
  Method(
    name: String,
    params: List(Param),
    returns: Ty,
    promise: Bool,
    documentation: Option(String),
    deprecation: Option(String),
  )
}

pub type DataType {
  DataType(ref: Ref, variants: List(Variant))
}

pub type Variant {
  Variant(name: String, fields: List(Field))
}

pub type Field {
  /// `key` is the label, or the position for unlabelled fields.
  Field(label: Option(String), key: String, ty: Ty)
}

pub type Capability {
  Capability(ref: Ref, methods: List(Method))
}

pub type Api {
  Api(
    module: String,
    methods: List(Method),
    /// Each type comes after the types it refers to, except for the
    /// references in `lazy`.
    data: List(DataType),
    capabilities: List(Capability),
    /// References to types that come later in `data`, because they're
    /// recursive.
    lazy: Set(#(Ref, Ref)),
  )
}

/// Cap'n Web stubs handle these names themselves, so RPC methods can't use
/// them.
const reserved_methods = [
  "then",
  "catch",
  "finally",
  "constructor",
  "dup",
  "map",
]

pub fn analyse(interface: Interface, module: String) -> Result(Api, String) {
  use api_module <- result.try(
    dict.get(interface.modules, module)
    |> result.replace_error(
      "There's no public module " <> module <> " in " <> interface.name <> ".",
    ),
  )
  let checker = Checker(interface:, api: module)
  use methods <- result.try(
    api_module.functions
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.try_map(fn(entry) { api_method(checker, entry.0, entry.1) }),
  )
  case methods {
    [] -> Error(module <> " has no public functions to serve.")
    _ -> {
      let roots = list.flat_map(methods, method_refs)
      use #(seen, data, capabilities) <- result.try(
        collect(checker, roots, [], dict.new(), []),
      )
      let #(order, lazy) = dependency_order(seen, data)
      let api =
        Api(
          module:,
          methods:,
          data: list.filter_map(order, dict.get(data, _)),
          capabilities: list.reverse(capabilities),
          lazy:,
        )
      use Nil <- result.map(check_names(api))
      api
    }
  }
}

type Checker {
  Checker(interface: Interface, api: String)
}

// METHODS ---------------------------------------------------------------------

fn api_method(
  checker: Checker,
  name: String,
  function: interface.Function,
) -> Result(Method, String) {
  let where = checker.api <> "." <> name
  use Nil <- result.try(method_name(name, where))
  case function.parameters {
    [
      interface.Parameter(
        type_: Named("starflame", "starflame/server", "Context", []),
        ..,
      ),
      ..rest
    ] -> {
      use params <- result.try(
        rest
        |> list.index_map(fn(parameter, index) {
          case parameter.label {
            Some(label) ->
              param(
                checker,
                parameter.type_,
                Some(label),
                where <> ", argument `" <> label <> "`",
              )
            None ->
              Error(
                where
                <> ": argument "
                <> int.to_string(index + 2)
                <> " has no label. Label every argument after the Context, like `id id: Int`, so the client's functions are labelled too.",
              )
          }
        })
        |> result.all,
      )
      use #(returns, promise) <- result.map(reply(
        checker,
        function.return,
        where <> ", reply",
      ))
      Method(
        name:,
        params:,
        returns:,
        promise:,
        documentation: function.documentation,
        deprecation: function.deprecation,
      )
    }
    _ ->
      Error(
        where
        <> ": an RPC method's first argument must be a starflame/server.Context. Every public function in "
        <> checker.api
        <> " is served, so make helpers private.",
      )
  }
}

fn method_name(name: String, where: String) -> Result(Nil, String) {
  case list.contains(reserved_methods, name) {
    True ->
      Error(
        where
        <> ": Cap'n Web stubs reserve the name `"
        <> name
        <> "`, so an RPC method can't use it.",
      )
    False -> Ok(Nil)
  }
}

fn param(
  checker: Checker,
  type_: Type,
  label: Option(String),
  where: String,
) -> Result(Param, String) {
  case type_ {
    Fn(arguments, Named("", "gleam", "Nil", [])) -> {
      use arguments <- result.map(
        arguments
        |> list.index_map(fn(argument, index) {
          ty(
            checker,
            argument,
            where <> ", callback argument " <> int.to_string(index + 1),
            False,
          )
        })
        |> result.all,
      )
      Callback(label:, arguments:)
    }
    Fn(..) ->
      Error(
        where
        <> ": callbacks must return Nil. The server calls them fire-and-forget, so there's no reply.",
      )
    _ -> ty(checker, type_, where, False) |> result.map(Value(label, _))
  }
}

fn reply(
  checker: Checker,
  type_: Type,
  where: String,
) -> Result(#(Ty, Bool), String) {
  case type_ {
    Named(_, "gleam/javascript/promise", "Promise", [inner]) ->
      ty(checker, inner, where, True) |> result.map(fn(ty) { #(ty, True) })
    _ -> ty(checker, type_, where, True) |> result.map(fn(ty) { #(ty, False) })
  }
}

// TYPES -----------------------------------------------------------------------

fn ty(
  checker: Checker,
  type_: Type,
  where: String,
  capabilities: Bool,
) -> Result(Ty, String) {
  let inner = fn(type_) { ty(checker, type_, where, capabilities) }
  case type_ {
    Named("", "gleam", "Int", []) -> Ok(IntT)
    Named("", "gleam", "Float", []) -> Ok(FloatT)
    Named("", "gleam", "String", []) -> Ok(StringT)
    Named("", "gleam", "Bool", []) -> Ok(BoolT)
    Named("", "gleam", "Nil", []) -> Ok(NilT)
    Named("", "gleam", "List", [item]) -> result.map(inner(item), ListT)
    Named("", "gleam", "Result", [ok, error]) -> {
      use ok <- result.try(inner(ok))
      use error <- result.map(inner(error))
      ResultT(ok, error)
    }
    Named("gleam_stdlib", "gleam/option", "Option", [some]) ->
      case inner(some) {
        Ok(OptionT(_)) | Ok(NilT) ->
          Error(
            where
            <> ": "
            <> describe(type_)
            <> " can't cross the wire, because None and Some(None) or Some(Nil) would both be null.",
          )
        Ok(some) -> Ok(OptionT(some))
        Error(error) -> Error(error)
      }
    Named(
      "gleam_stdlib",
      "gleam/dict",
      "Dict",
      [Named("", "gleam", "String", []), value],
    ) -> result.map(inner(value), DictT)
    Named("gleam_stdlib", "gleam/dict", "Dict", _) ->
      Error(
        where
        <> ": "
        <> describe(type_)
        <> " can't cross the wire. Dicts are JavaScript objects, so their keys must be Strings.",
      )
    Named(_, "gleam/javascript/promise", "Promise", _) ->
      Error(where <> ": only a method's reply can be a Promise.")
    Named("starflame", "starflame/server", "Context", []) ->
      Error(where <> ": only a method's first argument can be the Context.")
    Named(package, module, name, parameters)
      if package == checker.interface.name
    -> custom(checker, module, name, parameters, where, capabilities)
    Named("", _, _, _) | Named("gleam_stdlib", _, _, _) ->
      Error(where <> ": " <> describe(type_) <> " can't cross the wire.")
    Named(package, _, _, _) ->
      Error(
        where
        <> ": "
        <> describe(type_)
        <> " is from the "
        <> package
        <> " package. Only "
        <> checker.interface.name
        <> "'s own types can cross the wire.",
      )
    Tuple(elements) -> list.try_map(elements, inner) |> result.map(TupleT)
    Fn(..) ->
      Error(
        where
        <> ": functions can only be callback arguments or capability fields.",
      )
    Variable(_) -> Error(where <> ": generic types can't cross the wire.")
  }
}

fn custom(
  checker: Checker,
  module: String,
  name: String,
  parameters: List(Type),
  where: String,
  capabilities: Bool,
) -> Result(Ty, String) {
  let ref = Ref(module, name)
  use definition <- result.try(definition(checker, ref))
  case parameters, definition.constructors {
    [_, ..], _ ->
      Error(where <> ": " <> show(ref) <> " is generic, which isn't supported.")
    _, [] ->
      Error(
        where
        <> ": "
        <> show(ref)
        <> " has no public constructors, so it can't cross the wire.",
      )
    _, _ ->
      case is_capability(definition), capabilities {
        True, True -> Ok(CapabilityT(ref))
        True, False ->
          Error(
            where
            <> ": "
            <> show(ref)
            <> " is a capability, so it can only be returned.",
          )
        False, _ if module == checker.api ->
          Error(
            where
            <> ": move "
            <> show(ref)
            <> " out of "
            <> checker.api
            <> ". The client imports every type that crosses the wire, and importing the API module would bring server code with it.",
          )
        False, _ -> Ok(DataT(ref))
      }
  }
}

fn definition(checker: Checker, ref: Ref) -> Result(TypeDefinition, String) {
  checker.interface.modules
  |> dict.get(ref.module)
  |> result.try(fn(module) { dict.get(module.types, ref.name) })
  |> result.replace_error("There's no public type " <> show(ref) <> ".")
}

/// A record whose fields are all functions.
fn is_capability(definition: TypeDefinition) -> Bool {
  case definition.constructors {
    [interface.Constructor(parameters: [_, ..] as fields, ..)] ->
      list.all(fields, fn(field) {
        case field.type_ {
          Fn(..) -> True
          _ -> False
        }
      })
    _ -> False
  }
}

// DEFINITIONS -----------------------------------------------------------------

/// Finds and checks every type reachable from `pending`. Returns the data
/// types in the order they were first referred to.
fn collect(
  checker: Checker,
  pending: List(Ty),
  data_order: List(Ref),
  data: Dict(Ref, DataType),
  capabilities: List(Capability),
) -> Result(#(List(Ref), Dict(Ref, DataType), List(Capability)), String) {
  case pending {
    [] -> Ok(#(list.reverse(data_order), data, capabilities))
    [DataT(ref), ..rest] ->
      case dict.has_key(data, ref) {
        True -> collect(checker, rest, data_order, data, capabilities)
        False -> {
          use data_type <- result.try(data_type(checker, ref))
          let refs = list.flat_map(data_type.variants, variant_refs)
          collect(
            checker,
            list.append(refs, rest),
            [ref, ..data_order],
            dict.insert(data, ref, data_type),
            capabilities,
          )
        }
      }
    [CapabilityT(ref), ..rest] ->
      case list.any(capabilities, fn(seen) { seen.ref == ref }) {
        True -> collect(checker, rest, data_order, data, capabilities)
        False -> {
          use capability <- result.try(capability(checker, ref))
          let refs = list.flat_map(capability.methods, method_refs)
          collect(checker, list.append(refs, rest), data_order, data, [
            capability,
            ..capabilities
          ])
        }
      }
    [_, ..rest] -> collect(checker, rest, data_order, data, capabilities)
  }
}

fn data_type(checker: Checker, ref: Ref) -> Result(DataType, String) {
  use definition <- result.try(definition(checker, ref))
  use variants <- result.map(
    definition.constructors
    |> list.try_map(fn(constructor) {
      use fields <- result.map(
        constructor.parameters
        |> list.index_map(fn(field, index) {
          let key = option.unwrap(field.label, int.to_string(index))
          let where = show(ref) <> "." <> constructor.name <> " field " <> key
          case field.label {
            Some("constructor") ->
              Error(
                where
                <> ": Cap'n Web drops object keys that Object.prototype has, so a field can't be called `constructor`.",
              )
            _ -> {
              use ty <- result.map(case field.type_ {
                Fn(..) ->
                  Error(
                    where
                    <> ": a record with functions is a capability, so all its fields must be functions.",
                  )
                type_ -> ty(checker, type_, where, False)
              })
              Field(label: field.label, key:, ty:)
            }
          }
        })
        |> result.all,
      )
      Variant(name: constructor.name, fields:)
    }),
  )
  DataType(ref:, variants:)
}

fn capability(checker: Checker, ref: Ref) -> Result(Capability, String) {
  use definition <- result.try(definition(checker, ref))
  let fields = case definition.constructors {
    [constructor] -> constructor.parameters
    _ -> []
  }
  use methods <- result.map(
    list.try_map(fields, fn(field) {
      let name = option.unwrap(field.label, "")
      let where = show(ref) <> "." <> name
      use Nil <- result.try(case field.label {
        Some(_) -> method_name(name, where)
        None ->
          Error(
            where
            <> ": label every field of a capability. The labels are its method names.",
          )
      })
      case field.type_ {
        Fn(parameters, return) -> {
          use params <- result.try(
            parameters
            |> list.index_map(fn(parameter, index) {
              param(
                checker,
                parameter,
                None,
                where <> ", argument " <> int.to_string(index + 1),
              )
            })
            |> result.all,
          )
          use #(returns, promise) <- result.map(reply(
            checker,
            return,
            where <> ", reply",
          ))
          Method(
            name:,
            params:,
            returns:,
            promise:,
            documentation: None,
            deprecation: None,
          )
        }
        _ -> Error(where <> ": a capability's fields must all be functions.")
      }
    }),
  )
  Capability(ref:, methods:)
}

// ORDER -----------------------------------------------------------------------

/// Orders data types so that each comes after the ones it refers to, except
/// where types are recursive: those references are returned as lazy.
fn dependency_order(
  seen: List(Ref),
  data: Dict(Ref, DataType),
) -> #(List(Ref), Set(#(Ref, Ref))) {
  let state =
    list.fold(seen, Order(set.new(), set.new(), [], set.new()), fn(state, ref) {
      visit(data, ref, state)
    })
  #(list.reverse(state.order), state.lazy)
}

type Order {
  Order(
    done: Set(Ref),
    visiting: Set(Ref),
    order: List(Ref),
    lazy: Set(#(Ref, Ref)),
  )
}

fn visit(data: Dict(Ref, DataType), ref: Ref, state: Order) -> Order {
  case set.contains(state.done, ref), dict.get(data, ref) {
    False, Ok(data_type) -> {
      let state = Order(..state, visiting: set.insert(state.visiting, ref))
      let state =
        data_type.variants
        |> list.flat_map(variant_refs)
        |> list.fold(state, fn(state, ty) {
          case ty {
            DataT(target) ->
              case
                set.contains(state.done, target),
                set.contains(state.visiting, target)
              {
                True, _ -> state
                False, True ->
                  Order(..state, lazy: set.insert(state.lazy, #(ref, target)))
                False, False -> visit(data, target, state)
              }
            _ -> state
          }
        })
      Order(
        ..state,
        done: set.insert(state.done, ref),
        visiting: set.delete(state.visiting, ref),
        order: [ref, ..state.order],
      )
    }
    _, _ -> state
  }
}

// REFERENCES ------------------------------------------------------------------

/// The data types and capabilities a method refers to directly.
fn method_refs(method: Method) -> List(Ty) {
  method.params
  |> list.flat_map(fn(param) {
    case param {
      Value(ty:, ..) -> refs(ty)
      Callback(arguments:, ..) -> list.flat_map(arguments, refs)
    }
  })
  |> list.append(refs(method.returns))
}

fn variant_refs(variant: Variant) -> List(Ty) {
  list.flat_map(variant.fields, fn(field) { refs(field.ty) })
}

/// The data types and capabilities in a type, in order.
pub fn refs(ty: Ty) -> List(Ty) {
  case ty {
    DataT(_) | CapabilityT(_) -> [ty]
    ListT(inner) | OptionT(inner) | DictT(inner) -> refs(inner)
    ResultT(ok, error) -> list.append(refs(ok), refs(error))
    TupleT(elements) -> list.flat_map(elements, refs)
    IntT | FloatT | StringT | BoolT | NilT -> []
  }
}

// NAMES -----------------------------------------------------------------------

/// Generated modules define functions named after methods and capabilities;
/// make sure none of them would be defined twice.
fn check_names(api: Api) -> Result(Nil, String) {
  let methods = list.map(api.methods, fn(method) { method.name })
  let capabilities =
    list.map(api.capabilities, fn(capability) {
      #(snake_case(capability.ref.name), capability)
    })
  let client =
    list.flatten([
      methods,
      ["connect", "from_stub", "on_broken", "dispose"],
      list.flat_map(capabilities, fn(entry) {
        let #(prefix, capability) = entry
        [
          prefix <> "_decoder",
          prefix <> "_dispose",
          ..list.map(capability.methods, fn(method) {
            prefix <> "_" <> method.name
          })
        ]
      }),
    ])
  let server =
    list.flatten([
      methods,
      list.flat_map(capabilities, fn(entry) {
        let #(prefix, capability) = entry
        [
          prefix <> "_to_plain",
          ..list.map(capability.methods, fn(method) {
            prefix <> "_" <> method.name
          })
        ]
      }),
    ])
  let types = list.map(api.capabilities, fn(capability) { capability.ref.name })
  use Nil <- result.try(unique(client, "client.gleam would define"))
  use Nil <- result.try(unique(server, "server.gleam would define"))
  use Nil <- result.try(unique(
    ["Api", ..types],
    "client.gleam would define the type",
  ))
  Ok(Nil)
}

fn unique(names: List(String), message: String) -> Result(Nil, String) {
  case names {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case list.contains(rest, name) {
        True ->
          Error(
            message
            <> " `"
            <> name
            <> "` twice. Rename the method or capability.",
          )
        False -> unique(rest, message)
      }
  }
}

pub fn show(ref: Ref) -> String {
  ref.module <> "." <> ref.name
}

fn describe(type_: Type) -> String {
  case type_ {
    Named(name:, parameters: [], ..) -> name
    Named(name:, parameters:, ..) ->
      name <> "(" <> string.join(list.map(parameters, describe), ", ") <> ")"
    Tuple(elements) ->
      "#(" <> string.join(list.map(elements, describe), ", ") <> ")"
    Fn(parameters, return) ->
      "fn("
      <> string.join(list.map(parameters, describe), ", ")
      <> ") -> "
      <> describe(return)
    Variable(_) -> "a"
  }
}

/// `ApiError` to `api_error`, and `HTTPError` to `http_error`.
pub fn snake_case(name: String) -> String {
  let letters = string.to_graphemes(name)
  let next = list.append(list.drop(letters, 1), [""])
  let previous = ["", ..letters]
  list.zip(list.zip(previous, letters), next)
  |> list.map(fn(entry) {
    let #(#(previous, letter), next) = entry
    case is_upper(letter) {
      False -> letter
      True -> {
        let lower = string.lowercase(letter)
        let boundary =
          previous != ""
          && { !is_upper(previous) || { next != "" && is_lower(next) } }
        case boundary {
          True -> "_" <> lower
          False -> lower
        }
      }
    }
  })
  |> string.concat
}

fn is_upper(letter: String) -> Bool {
  string.uppercase(letter) == letter && string.lowercase(letter) != letter
}

fn is_lower(letter: String) -> Bool {
  string.lowercase(letter) == letter && string.uppercase(letter) != letter
}
