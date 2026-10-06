//// Writes the generated modules for an analysed API:
////
//// - `wire.gleam`: encoders and decoders for every data type that crosses
////   the wire, shared by client and server.
//// - `server.gleam`: a dispatcher per method, which decodes the arguments,
////   calls the API and encodes the reply.
//// - `targets.ts`: Cap'n Web `RpcTarget` classes forwarding to the
////   dispatchers, since Gleam can't define JavaScript classes.
//// - `client.gleam`: typed client functions. It only imports `wire.gleam`
////   and the data types, so browser bundles don't pull in server code.
////
//// The Gleam modules come out unformatted; the caller runs `gleam format`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import starflame_rpc_kit/model.{
  type Api, type DataType, type Field, type Method, type Param, type Ref,
  type Ty, type Variant, BoolT, Callback, CapabilityT, DataT, DictT, FloatT,
  IntT, ListT, NilT, OptionT, ResultT, StringT, TupleT, Value,
}

pub type Output {
  Output(wire: String, server: String, client: String, targets: String)
}

/// `prefix` is the generated modules' directory as a module path, like
/// `todos/generated`.
pub fn generate(api: Api, prefix: String) -> Result(Output, String) {
  let scope = scope(api, prefix)
  use wire <- result.map(wire_module(Scope(..scope, wire: "")))
  Output(
    wire:,
    server: server_module(scope),
    client: client_module(scope),
    targets: targets_module(scope),
  )
}

// SCOPE -----------------------------------------------------------------------

type Scope {
  Scope(
    api: Api,
    prefix: String,
    /// Import aliases of the app's modules.
    aliases: Dict(String, String),
    /// The name each data type's functions start with, like `api_error`.
    names: Dict(Ref, String),
    /// How code refers to wire.gleam: `"wire."`, or `""` inside it.
    wire: String,
  )
}

/// Aliases the generated modules use for libraries.
const library_aliases = [
  "api", "client", "decode", "dict", "dynamic", "fast_decode", "gleam", "option",
  "plain", "promise", "server", "wire",
]

fn scope(api: Api, prefix: String) -> Scope {
  let modules =
    list.flatten([
      list.map(api.data, fn(data) { data.ref.module }),
      list.map(api.capabilities, fn(capability) { capability.ref.module }),
    ])
    |> list.unique
    |> list.filter(fn(module) { module != api.module })
    |> list.sort(string.compare)
  let aliases =
    list.fold(
      modules,
      dict.from_list([#(api.module, "api")]),
      fn(aliases, module) {
        dict.insert(aliases, module, alias(module, dict.values(aliases)))
      },
    )
  let names =
    list.map(api.data, fn(data) {
      let name = model.snake_case(data.ref.name)
      let shared =
        list.any(api.data, fn(other) {
          other.ref != data.ref && other.ref.name == data.ref.name
        })
      case shared {
        False -> #(data.ref, name)
        True -> {
          let assert Ok(alias) = dict.get(aliases, data.ref.module)
          #(data.ref, alias <> "_" <> name)
        }
      }
    })
    |> dict.from_list
  Scope(api:, prefix:, aliases:, names:, wire: "wire.")
}

fn alias(module: String, taken: List(String)) -> String {
  let last = case list.last(string.split(module, "/")) {
    Ok(last) -> last
    Error(Nil) -> module
  }
  let candidates = [last, string.replace(module, "/", "_")]
  let free = fn(name) {
    !list.contains(taken, name) && !list.contains(library_aliases, name)
  }
  case list.find(candidates, free) {
    Ok(name) -> name
    Error(Nil) -> numbered(string.replace(module, "/", "_"), 2, free)
  }
}

fn numbered(base: String, n: Int, free: fn(String) -> Bool) -> String {
  let name = base <> "_" <> int.to_string(n)
  case free(name) {
    True -> name
    False -> numbered(base, n + 1, free)
  }
}

/// A variable name that doesn't shadow a module or a generated variable.
fn variable(scope: Scope, name: String) -> String {
  let taken =
    list.flatten([
      library_aliases,
      dict.values(scope.aliases),
      ["value", "context", "values", "tuple"],
    ])
  case list.contains(taken, name) {
    True -> name <> "_"
    False -> name
  }
}

fn name(scope: Scope, ref: Ref) -> String {
  case dict.get(scope.names, ref) {
    Ok(name) -> name
    Error(Nil) -> model.snake_case(ref.name)
  }
}

fn qualified(scope: Scope, ref: Ref) -> String {
  case dict.get(scope.aliases, ref.module) {
    Ok(alias) -> alias <> "." <> ref.name
    Error(Nil) -> ref.name
  }
}

fn capability_prefix(ref: Ref) -> String {
  model.snake_case(ref.name)
}

/// A Gleam type annotation. Capabilities are the client's own opaque types
/// on the client.
fn annotation(scope: Scope, ty: Ty, client: Bool) -> String {
  let inner = fn(ty) { annotation(scope, ty, client) }
  case ty {
    IntT -> "Int"
    FloatT -> "Float"
    StringT -> "String"
    BoolT -> "Bool"
    NilT -> "Nil"
    ListT(item) -> "List(" <> inner(item) <> ")"
    OptionT(some) -> "option.Option(" <> inner(some) <> ")"
    DictT(value) -> "dict.Dict(String, " <> inner(value) <> ")"
    ResultT(ok, error) -> "Result(" <> inner(ok) <> ", " <> inner(error) <> ")"
    TupleT(elements) -> "#(" <> join(list.map(elements, inner)) <> ")"
    DataT(ref) -> qualified(scope, ref)
    CapabilityT(ref) if client -> ref.name
    CapabilityT(ref) -> qualified(scope, ref)
  }
}

// EXPRESSIONS -----------------------------------------------------------------

/// Encodes `value` as a `Plain`.
fn encode(scope: Scope, ty: Ty, value: String) -> String {
  case ty {
    ListT(item) -> "plain.list(" <> value <> ", " <> encoder(scope, item) <> ")"
    OptionT(some) ->
      "plain.option(" <> value <> ", " <> encoder(scope, some) <> ")"
    DictT(item) -> "plain.dict(" <> value <> ", " <> encoder(scope, item) <> ")"
    ResultT(ok, error) ->
      "plain.result("
      <> value
      <> ", "
      <> encoder(scope, ok)
      <> ", "
      <> encoder(scope, error)
      <> ")"
    TupleT(elements) ->
      case is_name(value) {
        True ->
          "plain.array(["
          <> join(
            list.index_map(elements, fn(element, index) {
              encode(scope, element, value <> "." <> int.to_string(index))
            }),
          )
          <> "])"
        // Bind it first: `pair.0.1` doesn't parse.
        False ->
          "{ let tuple = " <> value <> " " <> encode(scope, ty, "tuple") <> " }"
      }
    _ -> encoder(scope, ty) <> "(" <> value <> ")"
  }
}

/// A function that encodes a value as a `Plain`.
fn encoder(scope: Scope, ty: Ty) -> String {
  case ty {
    IntT -> "plain.int"
    FloatT -> "plain.float"
    StringT -> "plain.string"
    BoolT -> "plain.bool"
    NilT -> "plain.nil"
    DataT(ref) -> scope.wire <> name(scope, ref) <> "_to_plain"
    CapabilityT(ref) -> capability_prefix(ref) <> "_to_plain"
    ListT(item) -> "plain.list(_, " <> encoder(scope, item) <> ")"
    OptionT(some) -> "plain.option(_, " <> encoder(scope, some) <> ")"
    DictT(item) -> "plain.dict(_, " <> encoder(scope, item) <> ")"
    ResultT(ok, error) ->
      "plain.result(_, "
      <> encoder(scope, ok)
      <> ", "
      <> encoder(scope, error)
      <> ")"
    TupleT(_) -> "fn(tuple) { " <> encode(scope, ty, "tuple") <> " }"
  }
}

/// The fast path's description of `ty`. `owner` is the data type it's in,
/// if any, to find references that must be lazy.
fn kind(scope: Scope, ty: Ty, owner: Option(Ref)) -> String {
  let inner = fn(ty) { kind(scope, ty, owner) }
  case ty {
    IntT -> "fast_decode.IntKind"
    FloatT -> "fast_decode.FloatKind"
    StringT -> "fast_decode.StringKind"
    BoolT -> "fast_decode.BoolKind"
    NilT -> "fast_decode.NilKind"
    ListT(item) -> "fast_decode.ListKind(" <> inner(item) <> ")"
    OptionT(some) -> "fast_decode.OptionKind(" <> inner(some) <> ")"
    DictT(item) -> "fast_decode.DictKind(" <> inner(item) <> ")"
    ResultT(ok, error) ->
      "fast_decode.ResultKind(" <> inner(ok) <> ", " <> inner(error) <> ")"
    TupleT(elements) ->
      "fast_decode.TupleKind([" <> join(list.map(elements, inner)) <> "])"
    DataT(ref) -> {
      let lazy = case owner {
        Some(owner) -> set.contains(scope.api.lazy, #(owner, ref))
        None -> False
      }
      case lazy {
        True -> "fast_decode.LazyKind(" <> name(scope, ref) <> "_kind_ref)"
        False -> scope.wire <> name(scope, ref) <> "_kind"
      }
    }
    CapabilityT(_) -> panic as "capabilities aren't data"
  }
}

type Source {
  /// A field of a JavaScript object, or an element of an array.
  Key(object: String, key: String)
  Expression(String)
}

fn dynamic(source: Source) -> String {
  case source {
    Key(object, key) -> "fast_decode.get(" <> object <> ", \"" <> key <> "\")"
    Expression(expression) -> expression
  }
}

/// Builds a Gleam value from a JavaScript value that matched its kind.
fn build(scope: Scope, ty: Ty, source: Source) -> String {
  case ty, source {
    IntT, Key(..) | FloatT, Key(..) | StringT, Key(..) | BoolT, Key(..) ->
      dynamic(source)
    IntT, _ | FloatT, _ | StringT, _ | BoolT, _ ->
      "fast_decode.coerce(" <> dynamic(source) <> ")"
    NilT, _ -> "Nil"
    DataT(ref), _ ->
      scope.wire <> name(scope, ref) <> "_from_plain(" <> dynamic(source) <> ")"
    ListT(item), _ ->
      "fast_decode.list("
      <> dynamic(source)
      <> ", "
      <> builder(scope, item)
      <> ")"
    OptionT(some), _ ->
      "fast_decode.option("
      <> dynamic(source)
      <> ", "
      <> builder(scope, some)
      <> ")"
    DictT(item), _ ->
      "fast_decode.dict("
      <> dynamic(source)
      <> ", "
      <> builder(scope, item)
      <> ")"
    ResultT(ok, error), _ ->
      "fast_decode.result("
      <> dynamic(source)
      <> ", "
      <> builder(scope, ok)
      <> ", "
      <> builder(scope, error)
      <> ")"
    TupleT(elements), _ ->
      "{ let tuple = "
      <> dynamic(source)
      <> " #("
      <> join(
        list.index_map(elements, fn(element, index) {
          build(scope, element, Key("tuple", int.to_string(index)))
        }),
      )
      <> ") }"
    CapabilityT(_), _ -> panic as "capabilities aren't data"
  }
}

/// A function that builds a Gleam value from a JavaScript value that
/// matched its kind.
fn builder(scope: Scope, ty: Ty) -> String {
  case ty {
    IntT | FloatT | StringT | BoolT -> "fast_decode.coerce"
    NilT -> "fn(_) { Nil }"
    DataT(ref) -> scope.wire <> name(scope, ref) <> "_from_plain"
    ListT(item) -> "fast_decode.list(_, " <> builder(scope, item) <> ")"
    OptionT(some) -> "fast_decode.option(_, " <> builder(scope, some) <> ")"
    DictT(item) -> "fast_decode.dict(_, " <> builder(scope, item) <> ")"
    ResultT(ok, error) ->
      "fast_decode.result(_, "
      <> builder(scope, ok)
      <> ", "
      <> builder(scope, error)
      <> ")"
    TupleT(_) -> "fn(tuple) { " <> build(scope, ty, Expression("tuple")) <> " }"
    CapabilityT(_) -> panic as "capabilities aren't data"
  }
}

/// A `gleam/dynamic/decode` decoder, with the exact errors.
fn full_decoder(scope: Scope, ty: Ty) -> String {
  case ty {
    IntT -> "decode.int"
    FloatT -> "decode.float"
    StringT -> "decode.string"
    BoolT -> "decode.bool"
    NilT -> "plain.nil_decoder()"
    DataT(ref) -> scope.wire <> name(scope, ref) <> "_decoder()"
    CapabilityT(ref) -> capability_prefix(ref) <> "_decoder()"
    ListT(item) -> "decode.list(" <> full_decoder(scope, item) <> ")"
    OptionT(some) -> "decode.optional(" <> full_decoder(scope, some) <> ")"
    DictT(item) ->
      "decode.dict(decode.string, " <> full_decoder(scope, item) <> ")"
    ResultT(ok, error) ->
      "plain.result_decoder("
      <> full_decoder(scope, ok)
      <> ", "
      <> full_decoder(scope, error)
      <> ")"
    TupleT(elements) ->
      "{ "
      <> string.join(
        list.index_map(elements, fn(element, index) {
          "use element_"
          <> int.to_string(index)
          <> " <- decode.field("
          <> int.to_string(index)
          <> ", "
          <> full_decoder(scope, element)
          <> ")"
        }),
        " ",
      )
      <> " decode.success(#("
      <> join(
        list.index_map(elements, fn(_, index) {
          "element_" <> int.to_string(index)
        }),
      )
      <> ")) }"
  }
}

/// The decoder for an argument or reply: the fast path where it helps.
fn decoder(scope: Scope, ty: Ty) -> String {
  case ty {
    IntT | FloatT | StringT | BoolT | NilT | DataT(_) | CapabilityT(_) ->
      full_decoder(scope, ty)
    _ ->
      case has_capability(ty) {
        True -> full_decoder(scope, ty)
        False ->
          "fast_decode.kind_decoder("
          <> kind(scope, ty, None)
          <> ", "
          <> builder(scope, ty)
          <> ", fn() { "
          <> full_decoder(scope, ty)
          <> " })"
      }
  }
}

fn has_capability(ty: Ty) -> Bool {
  list.any(model.refs(ty), fn(ty) {
    case ty {
      CapabilityT(_) -> True
      _ -> False
    }
  })
}

/// Some value of `ty`, for `decode.failure`. `Error(Nil)` if `ty` can't be
/// built without itself.
fn zero(scope: Scope, ty: Ty, visiting: List(Ref)) -> Result(String, Nil) {
  case ty {
    IntT -> Ok("0")
    FloatT -> Ok("0.0")
    StringT -> Ok("\"\"")
    BoolT -> Ok("False")
    NilT -> Ok("Nil")
    ListT(_) -> Ok("[]")
    OptionT(_) -> Ok("option.None")
    DictT(_) -> Ok("dict.new()")
    ResultT(ok, error) ->
      case zero(scope, ok, visiting) {
        Ok(ok) -> Ok("Ok(" <> ok <> ")")
        Error(Nil) ->
          zero(scope, error, visiting)
          |> result.map(fn(error) { "Error(" <> error <> ")" })
      }
    TupleT(elements) ->
      list.try_map(elements, zero(scope, _, visiting))
      |> result.map(fn(elements) { "#(" <> join(elements) <> ")" })
    DataT(ref) ->
      case list.contains(visiting, ref), data_type(scope, ref) {
        False, Ok(data) ->
          data.variants
          |> list.sort(fn(a, b) {
            int.compare(list.length(a.fields), list.length(b.fields))
          })
          |> list.find_map(fn(variant) {
            variant.fields
            |> list.try_map(fn(field) {
              zero(scope, field.ty, [ref, ..visiting])
            })
            |> result.map(construct(scope, ref, variant, _))
          })
        _, _ -> Error(Nil)
      }
    CapabilityT(_) -> Error(Nil)
  }
}

fn data_type(scope: Scope, ref: Ref) -> Result(DataType, Nil) {
  list.find(scope.api.data, fn(data) { data.ref == ref })
}

/// Calls a constructor with an expression for each field.
fn construct(
  scope: Scope,
  ref: Ref,
  variant: Variant,
  values: List(String),
) -> String {
  let constructor = qualified(scope, model.Ref(ref.module, variant.name))
  case variant.fields {
    [] -> constructor
    fields ->
      constructor
      <> "("
      <> join(
        list.map2(fields, values, fn(field, value) {
          case field.label {
            Some(label) if label == value -> label <> ":"
            Some(label) -> label <> ": " <> value
            None -> value
          }
        }),
      )
      <> ")"
  }
}

/// The variable a field is bound to.
fn field_variable(scope: Scope, field: Field) -> String {
  case field.label {
    Some(label) -> variable(scope, label)
    None -> "field_" <> field.key
  }
}

// WIRE ------------------------------------------------------------------------

fn wire_module(scope: Scope) -> Result(String, String) {
  use sections <- result.map(
    list.try_map(scope.api.data, wire_section(scope, _)),
  )
  // Gleam only accepts constants that refer to themselves through a
  // function (recursive types' kinds) when they come before everything
  // else that uses them.
  let kinds =
    list.map(scope.api.data, fn(data) {
      let base = name(scope, data.ref)
      "/// What `"
      <> base
      <> "_decoder` checks before building a value directly.\npub const "
      <> base
      <> "_kind = "
      <> data_kind(scope, data)
    })
  let lazy =
    scope.api.lazy
    |> set.to_list
    |> list.map(fn(edge) { edge.1 })
    |> list.unique
    |> list.sort(fn(a, b) { string.compare(name(scope, a), name(scope, b)) })
    |> list.map(fn(ref) {
      let base = name(scope, ref)
      "fn "
      <> base
      <> "_kind_ref() -> fast_decode.Kind {\n"
      <> base
      <> "_kind\n}"
    })
  module(
    scope,
    [
      "Codecs for the data types that cross the wire, shared by the client and",
      "the server.",
    ],
    string.join(
      [
        section("Kinds") <> string.join(list.append(kinds, lazy), "\n\n"),
        ..sections
      ],
      "\n\n",
    ),
    False,
  )
}

fn wire_section(scope: Scope, data: DataType) -> Result(String, String) {
  let ref = data.ref
  let base = name(scope, ref)
  let type_ = qualified(scope, ref)
  use fallback <- result.map(fallback(scope, data))
  section(ref.name)
  <> "pub fn "
  <> base
  <> "_to_plain(value: "
  <> type_
  <> ") -> plain.Plain {\n"
  <> to_plain(scope, data)
  <> "\n}\n\npub fn "
  <> base
  <> "_decoder() -> decode.Decoder("
  <> type_
  <> ") {\n fast_decode.kind_decoder("
  <> base
  <> "_kind, "
  <> base
  <> "_from_plain, "
  <> base
  <> "_fallback)\n}\n\n"
  <> "/// Builds a value that matched `"
  <> base
  <> "_kind`.\npub fn "
  <> base
  <> "_from_plain(value: dynamic.Dynamic) -> "
  <> type_
  <> " {\n"
  <> from_plain(scope, data)
  <> "\n}\n\nfn "
  <> base
  <> "_fallback() -> decode.Decoder("
  <> type_
  <> ") {\n"
  <> fallback
  <> "\n}"
}

fn to_plain(scope: Scope, data: DataType) -> String {
  let entries = fn(variant: Variant) {
    "["
    <> join(
      list.map(variant.fields, fn(field) {
        "#(\""
        <> field.key
        <> "\", "
        <> encode(scope, field.ty, field_variable(scope, field))
        <> ")"
      }),
    )
    <> "]"
  }
  let pattern = fn(variant: Variant) {
    construct(
      scope,
      data.ref,
      variant,
      list.map(variant.fields, field_variable(scope, _)),
    )
  }
  case data.variants {
    [model.Variant(fields: [], ..)] -> "let _ = value\nplain.object([])"
    [variant] ->
      "let "
      <> pattern(variant)
      <> " = value\nplain.object("
      <> entries(variant)
      <> ")"
    variants ->
      "case value {\n"
      <> string.join(
        list.map(variants, fn(variant) {
          pattern(variant)
          <> " -> plain.tagged(\""
          <> variant.name
          <> "\", "
          <> entries(variant)
          <> ")"
        }),
        "\n",
      )
      <> "\n}"
  }
}

fn data_kind(scope: Scope, data: DataType) -> String {
  let fields = fn(variant: Variant) {
    "["
    <> join(
      list.map(variant.fields, fn(field) {
        "fast_decode.Field(\""
        <> field.key
        <> "\", "
        <> kind(scope, field.ty, Some(data.ref))
        <> ", False)"
      }),
    )
    <> "]"
  }
  case data.variants {
    [variant] -> "fast_decode.RecordKind(" <> fields(variant) <> ")"
    variants ->
      "fast_decode.VariantsKind(["
      <> join(
        list.map(variants, fn(variant) {
          "fast_decode.Variant(\""
          <> variant.name
          <> "\", "
          <> fields(variant)
          <> ")"
        }),
      )
      <> "])"
  }
}

fn from_plain(scope: Scope, data: DataType) -> String {
  let build_variant = fn(variant: Variant) {
    construct(
      scope,
      data.ref,
      variant,
      list.map(variant.fields, fn(field) {
        build(scope, field.ty, Key("value", field.key))
      }),
    )
  }
  case data.variants {
    [model.Variant(fields: [], ..) as variant] ->
      "let _ = value\n" <> build_variant(variant)
    [variant] -> build_variant(variant)
    variants -> {
      let count = list.length(variants)
      "case fast_decode.tag(value) {\n"
      <> string.join(
        list.index_map(variants, fn(variant, index) {
          let pattern = case index == count - 1 {
            True -> "_"
            False -> "\"" <> variant.name <> "\""
          }
          pattern <> " -> " <> build_variant(variant)
        }),
        "\n",
      )
      <> "\n}"
    }
  }
}

fn fallback(scope: Scope, data: DataType) -> Result(String, String) {
  let decode_variant = fn(variant: Variant) {
    list.map(variant.fields, fn(field) {
      "use "
      <> field_variable(scope, field)
      <> " <- decode.field(\""
      <> field.key
      <> "\", "
      <> full_decoder(scope, field.ty)
      <> ")\n"
    })
    |> string.concat
    <> "decode.success("
    <> construct(
      scope,
      data.ref,
      variant,
      list.map(variant.fields, field_variable(scope, _)),
    )
    <> ")"
  }
  case data.variants {
    [variant] -> Ok(decode_variant(variant))
    variants -> {
      use zero <- result.map(
        zero(scope, DataT(data.ref), [])
        |> result.replace_error(
          model.show(data.ref) <> " can't be built without itself.",
        ),
      )
      "use tag <- decode.field(\"$\", decode.string)\ncase tag {\n"
      <> string.join(
        list.map(variants, fn(variant) {
          let decode = case variant.fields {
            [] -> decode_variant(variant)
            _ -> "{\n" <> decode_variant(variant) <> "\n}"
          }
          "\"" <> variant.name <> "\" -> " <> decode
        }),
        "\n",
      )
      <> "\n_ -> decode.failure("
      <> zero
      <> ", \""
      <> data.ref.name
      <> "\")\n}"
    }
  }
}

// SERVER ----------------------------------------------------------------------

fn server_module(scope: Scope) -> String {
  let methods =
    list.map(scope.api.methods, fn(method) {
      dispatcher(
        scope,
        method.name,
        "context: server.Context",
        "api." <> method.name <> "(context" <> arguments_prefix(method),
        method,
      )
    })
  let capabilities =
    list.map(scope.api.capabilities, fn(capability) {
      let prefix = capability_prefix(capability.ref)
      let receiver = variable(scope, prefix)
      let type_ = qualified(scope, capability.ref)
      section(capability.ref.name)
      <> "@external(javascript, \"./targets.ts\", \"new"
      <> capability.ref.name
      <> "Target\")\nfn "
      <> prefix
      <> "_to_plain("
      <> receiver
      <> ": "
      <> type_
      <> ") -> plain.Plain\n\n"
      <> string.join(
        list.map(capability.methods, fn(method) {
          dispatcher(
            scope,
            prefix <> "_" <> method.name,
            receiver <> ": " <> type_,
            receiver <> "." <> method.name <> "(",
            method,
          )
        }),
        "\n\n",
      )
    })
  module(
    scope,
    [
      "RPC dispatchers, called from targets.ts. Each decodes its arguments, calls",
      scope.api.module <> " and encodes the reply.",
    ],
    string.join(list.append(methods, capabilities), "\n\n"),
    True,
  )
}

/// `", "` before the arguments when an API call already has the context.
fn arguments_prefix(method: Method) -> String {
  case method.params {
    [] -> ""
    _ -> ", "
  }
}

fn dispatcher(
  scope: Scope,
  name: String,
  receiver: String,
  call: String,
  method: Method,
) -> String {
  let params = params(scope, method)
  "pub fn "
  <> name
  <> "("
  <> join([
    receiver,
    ..list.map(params, fn(param) { param.1 <> ": dynamic.Dynamic" })
  ])
  <> ") -> promise.Promise(plain.Plain) {\n"
  <> string.concat(
    list.map(params, fn(param) {
      case param.0 {
        Value(ty:, ..) ->
          "use "
          <> param.1
          <> " <- server.arg("
          <> param.1
          <> ", "
          <> decoder(scope, ty)
          <> ")\n"
        Callback(..) ->
          "use " <> param.1 <> " <- server.callback(" <> param.1 <> ")\n"
      }
    }),
  )
  <> call
  <> join(
    list.map(params, fn(param) {
      let value = case param.0 {
        Value(..) -> param.1
        Callback(arguments:, ..) -> {
          let names =
            list.index_map(arguments, fn(_, index) {
              "value_" <> int.to_string(index)
            })
          "fn("
          <> join(names)
          <> ") { "
          <> param.1
          <> "(["
          <> join(
            list.map2(arguments, names, fn(ty, name) { encode(scope, ty, name) }),
          )
          <> "]) }"
        }
      }
      case param.0.label {
        Some(label) if label == value -> label <> ":"
        Some(label) -> label <> ": " <> value
        None -> value
      }
    }),
  )
  <> ")\n|> "
  <> case method.promise {
    True -> "promise.map(" <> encoder(scope, method.returns) <> ")"
    False -> encoder(scope, method.returns) <> "\n|> promise.resolve"
  }
  <> "\n}"
}

/// Each parameter with its variable.
fn params(scope: Scope, method: Method) -> List(#(Param, String)) {
  list.index_map(method.params, fn(param, index) {
    let name = case param.label {
      Some(label) -> variable(scope, label)
      None -> "arg_" <> int.to_string(index + 1)
    }
    #(param, name)
  })
}

// CLIENT ----------------------------------------------------------------------

fn client_module(scope: Scope) -> String {
  let api =
    "pub opaque type Api {
  Api(stub: client.Stub)
}

/// Opens a WebSocket session with the API at `url`, which connects on the
/// first call.
pub fn connect(url: String) -> Api {
  Api(client.connect(url))
}

/// Calls the API over HTTP at `url`, one request per call. Callbacks and
/// capabilities need `connect` instead.
pub fn connect_http(url: String) -> Api {
  Api(client.connect_http(url))
}

/// Calls the API through `stub`, such as a target in the same Worker.
pub fn from_stub(stub: client.Stub) -> Api {
  Api(stub)
}

/// Calls `callback` with the reason when the session breaks. Every later
/// call fails; connect again to recover.
pub fn on_broken(api: Api, callback: fn(String) -> Nil) -> Nil {
  client.on_broken(api.stub, callback)
}

/// Closes the session.
pub fn dispose(api: Api) -> Nil {
  client.dispose(api.stub)
}"
  let methods =
    list.map(scope.api.methods, fn(method) {
      client_function(scope, method.name, "api: Api", "api.stub", method)
    })
  let capabilities =
    list.map(scope.api.capabilities, fn(capability) {
      let prefix = capability_prefix(capability.ref)
      let receiver = variable(scope, prefix)
      let type_ = capability.ref.name
      section(type_)
      <> "pub opaque type "
      <> type_
      <> " {\n"
      <> type_
      <> "(stub: client.Stub)\n}\n\nfn "
      <> prefix
      <> "_decoder() -> decode.Decoder("
      <> type_
      <> ") {\nclient.stub_decoder() |> decode.map("
      <> type_
      <> ")\n}\n\n"
      <> string.join(
        list.map(capability.methods, fn(method) {
          client_function(
            scope,
            prefix <> "_" <> method.name,
            receiver <> ": " <> type_,
            receiver <> ".stub",
            method,
          )
        }),
        "\n\n",
      )
      <> "\n\n/// Releases the capability on the server.\npub fn "
      <> prefix
      <> "_dispose("
      <> receiver
      <> ": "
      <> type_
      <> ") -> Nil {\nclient.dispose("
      <> receiver
      <> ".stub)\n}"
    })
  module(
    scope,
    ["Typed client functions for " <> scope.api.module <> "."],
    string.join([api, ..list.append(methods, capabilities)], "\n\n"),
    False,
  )
}

fn client_function(
  scope: Scope,
  name: String,
  receiver: String,
  stub: String,
  method: Method,
) -> String {
  let params = params(scope, method)
  documentation(method.documentation)
  <> case method.deprecation {
    // The interface has the message as written, escapes and all.
    Some(message) -> "@deprecated(\"" <> message <> "\")\n"
    None -> ""
  }
  <> "pub fn "
  <> name
  <> "("
  <> join([
    receiver,
    ..list.map(params, fn(param) {
      let type_ = case param.0 {
        Value(ty:, ..) -> annotation(scope, ty, True)
        Callback(arguments:, ..) ->
          "fn("
          <> join(list.map(arguments, annotation(scope, _, True)))
          <> ") -> Nil"
      }
      case param.0.label {
        Some(label) -> label <> " " <> param.1 <> ": " <> type_
        None -> param.1 <> ": " <> type_
      }
    })
  ])
  <> ") -> promise.Promise(Result("
  <> annotation(scope, method.returns, True)
  <> ", client.RpcError)) {\nclient.call("
  <> stub
  <> ", \""
  <> method.name
  <> "\", ["
  <> join(
    list.map(params, fn(param) {
      case param.0 {
        Value(ty:, ..) -> encode(scope, ty, param.1)
        Callback(arguments:, ..) -> client_callback(scope, arguments, param.1)
      }
    }),
  )
  <> "], "
  <> decoder(scope, method.returns)
  <> ")\n}"
}

fn client_callback(
  scope: Scope,
  arguments: List(Ty),
  callback: String,
) -> String {
  case arguments {
    [] -> "client.callback(decode.success(Nil), fn(_) { " <> callback <> "() })"
    [argument] ->
      "client.callback(decode.at([0], "
      <> decoder(scope, argument)
      <> "), "
      <> callback
      <> ")"
    _ -> {
      let names =
        list.index_map(arguments, fn(_, index) {
          "value_" <> int.to_string(index)
        })
      "client.callback({ "
      <> string.join(
        list.index_map(list.zip(arguments, names), fn(entry, index) {
          "use "
          <> entry.1
          <> " <- decode.field("
          <> int.to_string(index)
          <> ", "
          <> decoder(scope, entry.0)
          <> ")"
        }),
        " ",
      )
      <> " decode.success(#("
      <> join(names)
      <> ")) }, fn(values) { "
      <> callback
      <> "("
      <> join(
        list.index_map(names, fn(_, index) { "values." <> int.to_string(index) }),
      )
      <> ") })"
    }
  }
}

fn documentation(text: Option(String)) -> String {
  case text {
    None -> ""
    Some(text) ->
      text
      |> string.trim_end
      |> string.split("\n")
      |> list.map(fn(line) { "///" <> line <> "\n" })
      |> string.concat
  }
}

// TARGETS ---------------------------------------------------------------------

fn targets_module(scope: Scope) -> String {
  let depth = list.length(string.split(scope.prefix, "/")) + 1
  let starflame =
    string.repeat("../", depth) <> "starflame/starflame/server.mjs"
  let methods =
    list.map(scope.api.methods, fn(method) {
      target_method(scope, method, method.name, "this.#context")
    })
  let capabilities =
    list.map(scope.api.capabilities, fn(capability) {
      let class = capability.ref.name <> "Target"
      let field = js_name(variable(scope, capability_prefix(capability.ref)))
      "class "
      <> class
      <> " extends RpcTarget {\n  #"
      <> field
      <> ": unknown;\n\n  constructor("
      <> field
      <> ": unknown) {\n    super();\n    this.#"
      <> field
      <> " = "
      <> field
      <> ";\n  }\n"
      <> string.concat(
        list.map(capability.methods, fn(method) {
          target_method(
            scope,
            method,
            capability_prefix(capability.ref) <> "_" <> method.name,
            "this.#" <> field <> " as never",
          )
        }),
      )
      <> "}\n\nexport function new"
      <> class
      <> "("
      <> field
      <> ": unknown) {\n  return new "
      <> class
      <> "("
      <> field
      <> ");\n}\n"
    })
  header("//", scope.api.module)
  <> "//\n// Cap'n Web RpcTarget classes, which forward each call to server.gleam.\n"
  <> "// Gleam can't define JavaScript classes.\n\n"
  <> "import { RpcTarget } from \"capnweb\";\n"
  <> "import * as server from \"./server.mjs\";\n"
  <> "import * as runtime from \""
  <> starflame
  <> "\";\n\n"
  <> "export class Api extends RpcTarget {\n"
  <> "  #context: runtime.Context$;\n\n"
  <> "  constructor(context: runtime.Context$) {\n"
  <> "    super();\n"
  <> "    this.#context = context;\n"
  <> "  }\n"
  <> string.concat(methods)
  <> "}\n\n"
  <> string.concat(list.map(capabilities, fn(class) { class <> "\n" }))
  <> "/**\n"
  <> " * The API's target for a request, with the Worker's `env` and execution\n"
  <> " * context. `auth`, such as the user the Worker verified, is what\n"
  <> " * `server.auth` returns.\n"
  <> " */\n"
  <> "export function newApi(env: unknown, execution: unknown, auth: unknown = null) {\n"
  <> "  const context = runtime.new_context(env, execution);\n"
  <> "  return new Api(runtime.with_auth(context, auth));\n"
  <> "}\n"
}

fn target_method(
  scope: Scope,
  method: Method,
  dispatcher: String,
  receiver: String,
) -> String {
  let names = list.map(params(scope, method), fn(param) { js_name(param.1) })
  "\n  "
  <> method.name
  <> "("
  <> join(list.map(names, fn(name) { name <> ": unknown" }))
  <> ") {\n    return server."
  <> js_name(dispatcher)
  <> "("
  <> join([receiver, ..names])
  <> ");\n  }\n"
}

/// The name the Gleam compiler gives a function or variable in JavaScript.
fn js_name(name: String) -> String {
  case list.contains(js_reserved, name) {
    True -> name <> "$"
    False -> name
  }
}

const js_reserved = [
  "await", "arguments", "break", "case", "catch", "class", "const", "continue",
  "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
  "eval", "false", "finally", "for", "function", "if", "implements", "import",
  "in", "instanceof", "interface", "let", "new", "null", "package", "private",
  "protected", "public", "return", "static", "super", "switch", "this", "throw",
  "true", "try", "typeof", "var", "void", "while", "with", "yield", "undefined",
  "then",
]

// MODULES ---------------------------------------------------------------------

fn header(comment: String, api_module: String) -> String {
  comment
  <> " Generated by starflame_rpc_kit from "
  <> api_module
  <> ". Don't edit: run\n"
  <> comment
  <> " `gleam run -m starflame_rpc_kit -- generate` instead.\n"
}

fn section(title: String) -> String {
  let rule = "// " <> title <> " "
  rule <> string.repeat("-", int.max(3, 80 - string.length(rule))) <> "\n\n"
}

/// A Gleam module: the header, then imports for every module `body` uses.
/// Only the server imports the API module.
fn module(
  scope: Scope,
  description: List(String),
  body: String,
  imports_api: Bool,
) -> String {
  let code =
    body
    |> string.split("\n")
    |> list.filter(fn(line) {
      let line = string.trim(line)
      !string.starts_with(line, "//")
      && !string.starts_with(line, "@deprecated")
    })
    |> string.join("\n")
  let aliases = case imports_api {
    True -> scope.aliases
    False -> dict.delete(scope.aliases, scope.api.module)
  }
  let libraries = [
    #("gleam/dict", "dict"),
    #("gleam/dynamic", "dynamic"),
    #("gleam/dynamic/decode", "decode"),
    #("gleam/javascript/promise", "promise"),
    #("gleam/option", "option"),
    #("starflame/client", "client"),
    #("starflame/fast_decode", "fast_decode"),
    #("starflame/plain", "plain"),
    #("starflame/server", "server"),
    #(scope.prefix <> "/wire", "wire"),
  ]
  let imports =
    list.append(libraries, dict.to_list(aliases))
    |> list.filter(fn(entry) { uses(code, entry.1) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(entry) {
      let #(module, alias) = entry
      let last = case list.last(string.split(module, "/")) {
        Ok(last) -> last
        Error(Nil) -> module
      }
      case last == alias {
        True -> "import " <> module
        False -> "import " <> module <> " as " <> alias
      }
    })
  header("////", scope.api.module)
  <> "////\n"
  <> string.concat(list.map(description, fn(line) { "//// " <> line <> "\n" }))
  <> "\n"
  <> string.join(imports, "\n")
  <> "\n\n"
  <> body
  <> "\n"
}

/// Whether `code` refers to the module imported as `alias`.
fn uses(code: String, alias: String) -> Bool {
  let pieces = string.split(code, alias <> ".")
  let before = list.take(pieces, list.length(pieces) - 1)
  list.any(before, fn(piece) {
    case string.last(piece) {
      Error(Nil) -> True
      Ok(character) -> !is_name_character(character)
    }
  })
}

fn is_name_character(character: String) -> Bool {
  character == "_"
  || character == "."
  || string.contains("abcdefghijklmnopqrstuvwxyz0123456789", character)
  || string.uppercase(character) != string.lowercase(character)
}

/// Whether `value` is a plain variable, rather than an expression.
fn is_name(value: String) -> Bool {
  value
  |> string.to_graphemes
  |> list.all(fn(character) {
    character == "_"
    || string.contains("abcdefghijklmnopqrstuvwxyz0123456789", character)
  })
}

fn join(items: List(String)) -> String {
  string.join(items, ", ")
}
