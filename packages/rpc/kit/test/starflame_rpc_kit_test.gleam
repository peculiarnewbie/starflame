import gleam/list
import gleam/string
import gleeunit
import simplifile
import starflame_rpc_kit

pub fn main() -> Nil {
  gleeunit.main()
}

// FIXTURES --------------------------------------------------------------------

/// The RPC example has every dependency generated code needs, so fixtures
/// borrow its gleam.toml, manifest and downloaded packages. Each test gets a
/// fresh `src/`; the kit's scratch build in the project is reused.
fn project(name: String, files: List(#(String, String))) -> String {
  let root = "build/kit-test/" <> name
  let example = "../../../examples/rpc"
  let packages = absolute("../..") <> "/"
  let assert Ok(_) = simplifile.create_directory_all(root <> "/build")
  let assert Ok(toml) = simplifile.read(example <> "/gleam.toml")
  let assert Ok(manifest) = simplifile.read(example <> "/manifest.toml")
  let assert Ok(_) =
    simplifile.write(
      root <> "/gleam.toml",
      string.replace(toml, "\"../../packages/", "\"" <> packages),
    )
  let assert Ok(_) =
    simplifile.write(
      root <> "/manifest.toml",
      string.replace(manifest, "\"../../packages/", "\"" <> packages),
    )
  case simplifile.is_directory(root <> "/build/packages") {
    Ok(True) -> Nil
    _ -> {
      let assert Ok(_) =
        simplifile.copy_directory(
          example <> "/build/packages",
          root <> "/build/packages",
        )
      Nil
    }
  }
  let _ = simplifile.delete(root <> "/src")
  list.each(files, fn(file) {
    let path = root <> "/src/" <> file.0
    let assert Ok(_) = simplifile.create_directory_all(parent(path))
    let assert Ok(_) = simplifile.write(path, file.1)
  })
  root
}

fn parent(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}

fn generate(root: String) -> Result(String, String) {
  starflame_rpc_kit.run(root, ["generate"])
}

fn expect_error(files: List(#(String, String)), expected: String) -> Nil {
  case generate(project("errors", files)) {
    Ok(output) -> panic as { "Expected an error, got: " <> output }
    Error(error) ->
      case string.contains(error, expected) {
        True -> Nil
        False ->
          panic as {
            "Expected an error containing " <> expected <> ", got: " <> error
          }
      }
  }
}

fn api(source: String) -> List(#(String, String)) {
  [
    #("spike/api.gleam", "import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}
import gleam/option.{type Option}
import spike/types.{type Item}
import starflame/server.{type Context}
" <> source),
    #(
      "spike/types.gleam",
      "import gleam/javascript/promise.{type Promise}

pub type Item {
  Item(id: Int)
}

pub type Box(a) {
  Box(item: a)
}

pub opaque type Secret {
  Secret(value: Int)
}

pub type Holder {
  Holder(callback: fn() -> Nil, id: Int)
}

pub type Proto {
  Proto(constructor: Int)
}

pub type Handle {
  Handle(get: fn() -> Promise(Int))
}
",
    ),
  ]
}

// EDGE CASES ------------------------------------------------------------------

const types_module = "import gleam/dict.{type Dict}
import gleam/option.{type Option}

/// Recursive.
pub type Tree {
  Tree(label: String, children: List(Tree))
}

/// Mutually recursive.
pub type Ping {
  Ping(pong: Option(Pong))
}

pub type Pong {
  Pong(pings: List(Ping))
}

/// Shares its name with other.Item.
pub type Item {
  Item(id: Int)
}

pub type Mixed {
  Mixed(Int, name: String)
}

pub type Unit {
  Unit
}

/// No variant without fields.
pub type Shape {
  Circle(radius: Float)
  Square(side: Float)
}

/// Field labels that are also names the generated code uses.
pub type Clashing {
  Clashing(
    plain: Int,
    decode: String,
    value: Bool,
    tuple: #(Int, #(String, Bool)),
    api: Nil,
    context: Float,
    fast_decode: List(#(Int, String)),
    wire: Dict(String, List(Int)),
    option: Option(List(Int)),
    result: Result(Nil, String),
  )
}
"

const api_module = "import gleam/javascript/promise.{type Promise}
import spike/client.{type Note}
import spike/other
import spike/types.{
  type Clashing, type Mixed, type Ping, type Shape, type Tree, type Unit,
}
import starflame/server.{type Context}

/// Returns another capability, and takes a callback.
pub type Account {
  Account(
    profile: fn() -> Promise(Profile),
    watch: fn(fn(Int, String) -> Nil) -> Promise(Nil),
  )
}

pub type Profile {
  Profile(name: fn() -> String)
}

/// Echoes a tree.
pub fn tree(_context: Context, tree tree: Tree) -> Promise(Tree) {
  promise.resolve(tree)
}

pub fn ping(_context: Context, ping ping: Ping) -> Ping {
  ping
}

pub fn items(
  _context: Context,
  a a: types.Item,
  b b: other.Item,
) -> Promise(#(types.Item, other.Item)) {
  promise.resolve(#(a, b))
}

pub fn mixed(
  _context: Context,
  mixed mixed: Mixed,
  unit unit: Unit,
  shape shape: Shape,
) -> Promise(#(Mixed, Unit, Shape)) {
  promise.resolve(#(mixed, unit, shape))
}

pub fn clashing(
  _context: Context,
  clashing clashing: Clashing,
) -> Promise(Clashing) {
  promise.resolve(clashing)
}

pub fn note(_context: Context, note note: Note) -> Promise(Note) {
  promise.resolve(note)
}

pub fn delete(_context: Context, id id: Int) -> Promise(Nil) {
  let _ = id
  promise.resolve(Nil)
}

pub fn notify(
  _context: Context,
  ready ready: fn() -> Nil,
  progress progress: fn(Int, String) -> Nil,
) -> Promise(Nil) {
  ready()
  progress(1, \"one\")
  promise.resolve(Nil)
}

pub fn login(_context: Context) -> Promise(Account) {
  promise.resolve(
    Account(
      profile: fn() { promise.resolve(Profile(name: fn() { \"ada\" })) },
      watch: fn(callback) {
        callback(1, \"one\")
        promise.resolve(Nil)
      },
    ),
  )
}

pub fn labels(
  _context: Context,
  plain plain: Int,
  value value: String,
  api api: Int,
) -> Promise(Int) {
  let _ = value
  promise.resolve(plain + api)
}
"

/// Encodes, copies through JSON and decodes values of each type, through
/// the fast path alone and through the full decoder.
const roundtrip_module = "import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/option.{None, Some}
import gleam/string
import spike/client.{Note}
import spike/generated/wire
import spike/other
import spike/types.{
  Circle, Clashing, Item, Mixed, Ping, Pong, Square, Tree, Unit,
}
import starflame/fast_decode
import starflame/plain

pub fn main() {
  let tree = Tree(\"a\", [Tree(\"b\", []), Tree(\"c\", [Tree(\"d\", [])])])
  check(\"tree\", tree, wire.tree_to_plain, wire.tree_kind, wire.tree_from_plain, wire.tree_decoder())
  let ping = Ping(Some(Pong([Ping(None), Ping(Some(Pong([])))])))
  check(\"ping\", ping, wire.ping_to_plain, wire.ping_kind, wire.ping_from_plain, wire.ping_decoder())
  check(\"types item\", Item(1), wire.types_item_to_plain, wire.types_item_kind, wire.types_item_from_plain, wire.types_item_decoder())
  check(\"other item\", other.Item(\"x\"), wire.other_item_to_plain, wire.other_item_kind, wire.other_item_from_plain, wire.other_item_decoder())
  check(\"mixed\", Mixed(3, name: \"m\"), wire.mixed_to_plain, wire.mixed_kind, wire.mixed_from_plain, wire.mixed_decoder())
  check(\"unit\", Unit, wire.unit_to_plain, wire.unit_kind, wire.unit_from_plain, wire.unit_decoder())
  check(\"circle\", Circle(1.5), wire.shape_to_plain, wire.shape_kind, wire.shape_from_plain, wire.shape_decoder())
  check(\"square\", Square(2.0), wire.shape_to_plain, wire.shape_kind, wire.shape_from_plain, wire.shape_decoder())
  check(\"note\", Note(\"hi\"), wire.note_to_plain, wire.note_kind, wire.note_from_plain, wire.note_decoder())
  let clashing =
    Clashing(
      plain: 1,
      decode: \"d\",
      value: True,
      tuple: #(2, #(\"t\", False)),
      api: Nil,
      context: 0.5,
      fast_decode: [#(1, \"a\"), #(2, \"b\")],
      wire: dict.from_list([#(\"x\", [1, 2]), #(\"y\", [])]),
      option: Some([3]),
      result: Error(\"no\"),
    )
  check(\"clashing\", clashing, wire.clashing_to_plain, wire.clashing_kind, wire.clashing_from_plain, wire.clashing_decoder())
  check(\"clashing ok\", Clashing(..clashing, option: None, result: Ok(Nil)), wire.clashing_to_plain, wire.clashing_kind, wire.clashing_from_plain, wire.clashing_decoder())

  let bad_tree =
    plain.object([
      #(\"label\", plain.string(\"a\")),
      #(\"children\", plain.array([plain.object([#(\"label\", plain.int(5)), #(\"children\", plain.array([]))])])),
    ])
  reject(\"bad tree\", bad_tree, wire.tree_decoder(), \"children\")
  reject(\"unknown variant\", plain.tagged(\"Triangle\", []), wire.shape_decoder(), \"Shape\")
  reject(\"missing field\", plain.object([]), wire.mixed_decoder(), \"Field\")
  reject(\"wrong field type\", plain.tagged(\"Circle\", [#(\"radius\", plain.string(\"1\"))]), wire.shape_decoder(), \"Float\")
}

fn check(
  name: String,
  value: a,
  encode: fn(a) -> plain.Plain,
  kind: fast_decode.Kind,
  build: fn(Dynamic) -> a,
  decoder: decode.Decoder(a),
) -> Nil {
  let data = json_copy(plain.to_dynamic(encode(value)))
  let fast_only =
    fast_decode.kind_decoder(kind, build, fn() { decode.failure(value, \"the fast path\") })
  case decode.run(data, fast_only), decode.run(data, decoder) {
    Ok(fast), Ok(full) if fast == value && full == value -> io.println(\"PASS \" <> name)
    fast, full -> io.println(\"FAIL \" <> name <> \": \" <> string.inspect(#(fast, full)))
  }
}

fn reject(name: String, data: plain.Plain, decoder: decode.Decoder(a), expected: String) -> Nil {
  case decode.run(json_copy(plain.to_dynamic(data)), decoder) {
    Error(errors) ->
      case string.contains(string.inspect(errors), expected) {
        True -> io.println(\"PASS \" <> name)
        False -> io.println(\"FAIL \" <> name <> \": \" <> string.inspect(errors))
      }
    Ok(value) -> io.println(\"FAIL \" <> name <> \": \" <> string.inspect(value))
  }
}

@external(javascript, \"./roundtrip_ffi.mjs\", \"json_copy\")
fn json_copy(value: Dynamic) -> Dynamic
"

pub fn edge_cases_compile_and_round_trip_test() {
  let root =
    project("edges", [
      #("spike/types.gleam", types_module),
      #("spike/other.gleam", "pub type Item {\n  Item(name: String)\n}\n"),
      #("spike/client.gleam", "pub type Note {\n  Note(text: String)\n}\n"),
      #("spike/api.gleam", api_module),
      #("spike/roundtrip.gleam", roundtrip_module),
      #(
        "spike/roundtrip_ffi.mjs",
        "export function json_copy(value) {\n  return JSON.parse(JSON.stringify(value));\n}\n",
      ),
    ])
  let assert Ok(_) = generate(root)
  let assert Ok(_) =
    shell(root, "gleam", [
      "format",
      "--check",
      "src/spike/generated/wire.gleam",
      "src/spike/generated/server.gleam",
      "src/spike/generated/client.gleam",
    ])
  case shell(root, "gleam", ["build", "--warnings-as-errors"]) {
    Ok(_) -> Nil
    Error(output) -> panic as output
  }
  let assert Ok(output) = shell(root, "gleam", ["run", "-m", "spike/roundtrip"])
  let lines = string.split(output, "\n")
  let failures = list.filter(lines, string.starts_with(_, "FAIL"))
  let passes = list.filter(lines, string.starts_with(_, "PASS"))
  case failures, list.length(passes) {
    [], 15 -> Nil
    _, _ -> panic as output
  }

  let assert Ok(targets) =
    simplifile.read(root <> "/src/spike/generated/targets.ts")
  // Gleam renames functions that are JavaScript keywords.
  let assert True =
    string.contains(targets, "server.delete$(this.#context, id)")
  let assert True = string.contains(targets, "class ProfileTarget")
  let assert Ok(client) =
    simplifile.read(root <> "/src/spike/generated/client.gleam")
  let assert True =
    string.contains(client, "import spike/client as spike_client")
  // Only the server imports the API module.
  let assert False = string.contains(client, "import spike/api")
}

// CHECK -----------------------------------------------------------------------

const small_api = "import gleam/javascript/promise.{type Promise}
import spike/types.{type Item}
import starflame/server.{type Context}

pub fn get(_context: Context, id id: Int) -> Promise(Item) {
  promise.resolve(types.Item(id))
}
"

pub fn check_reports_stale_code_test() {
  let files = [
    #("spike/types.gleam", "pub type Item {\n  Item(id: Int)\n}\n"),
    #("spike/api.gleam", small_api),
  ]
  let root = project("check", files)
  let assert Error(missing) = starflame_rpc_kit.run(root, ["check"])
  let assert True = string.contains(missing, "wire.gleam is missing")
  let assert Ok(_) = generate(root)
  let assert Ok(_) = starflame_rpc_kit.run(root, ["check"])
  let assert Ok(unchanged) = generate(root)
  let assert True =
    string.contains(unchanged, "Unchanged src/spike/generated/wire.gleam")

  // Adding a field breaks the generated code, which mustn't stop the kit.
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/types.gleam",
      "pub type Item {\n  Item(id: Int, name: String)\n}\n",
    )
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/spike/api.gleam",
      string.replace(small_api, "types.Item(id)", "types.Item(id, \"\")"),
    )
  let assert Error(stale) = starflame_rpc_kit.run(root, ["check"])
  let assert True = string.contains(stale, "wire.gleam is out of date")
  let assert Ok(_) = generate(root)
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  Nil
}

pub fn deprecated_method_test() {
  let root =
    project("deprecated", [
      #("spike/types.gleam", "pub type Item {\n  Item(id: Int)\n}\n"),
      #(
        "spike/api.gleam",
        string.replace(
          small_api,
          "pub fn get(",
          "/// Gets an item.\n@deprecated(\"Use \\\"find\\\" instead\")\npub fn get(",
        ),
      ),
    ])
  let assert Ok(_) = generate(root)
  let assert Ok(client) =
    simplifile.read(root <> "/src/spike/generated/client.gleam")
  let assert True =
    string.contains(
      client,
      "/// Gets an item.\n@deprecated(\"Use \\\"find\\\" instead\")\npub fn get(",
    )
  // The server still serves it, which Gleam warns about.
  let assert Ok(_) = shell(root, "gleam", ["build"])
  Nil
}

pub fn custom_paths_test() {
  let files = [
    #("spike/types.gleam", "pub type Item {\n  Item(id: Int)\n}\n"),
    #("spike/rpc.gleam", small_api),
  ]
  let root = project("paths", files)
  let assert Ok(output) =
    starflame_rpc_kit.run(root, [
      "generate", "--api", "spike/rpc", "--out", "spike/rpc_generated",
    ])
  let assert True =
    string.contains(output, "src/spike/rpc_generated/wire.gleam")
  let assert Ok(server) =
    simplifile.read(root <> "/src/spike/rpc_generated/server.gleam")
  let assert True = string.contains(server, "import spike/rpc as api")
  let assert Ok(_) = shell(root, "gleam", ["build", "--warnings-as-errors"])
  Nil
}

// ERRORS ----------------------------------------------------------------------

pub fn unlabelled_argument_test() {
  api(
    "pub fn get(_c: Context, id: Int) -> Promise(Int) { promise.resolve(id) }",
  )
  |> expect_error("argument 2 has no label")
}

pub fn missing_context_test() {
  api("pub fn helper(id id: Int) -> Int { id }")
  |> expect_error("first argument must be a starflame/server.Context")
}

pub fn generic_type_test() {
  api(
    "pub fn get(_c: Context, box box: types.Box(Int)) -> Promise(Int) { promise.resolve(box.item) }",
  )
  |> expect_error("spike/types.Box is generic")
}

pub fn opaque_type_test() {
  api(
    "pub fn get(_c: Context, secret secret: types.Secret) -> Promise(Nil) { let _ = secret promise.resolve(Nil) }",
  )
  |> expect_error("has no public constructors")
}

pub fn capability_argument_test() {
  api(
    "pub fn get(_c: Context, handle handle: types.Handle) -> Promise(Nil) { let _ = handle promise.resolve(Nil) }",
  )
  |> expect_error("is a capability, so it can only be returned")
}

pub fn dict_key_test() {
  api(
    "pub fn get(_c: Context, d d: Dict(Int, Int)) -> Promise(Nil) { let _ = d promise.resolve(Nil) }",
  )
  |> expect_error("keys must be Strings")
}

pub fn nested_option_test() {
  api(
    "pub fn get(_c: Context, o o: Option(Option(Int))) -> Promise(Nil) { let _ = o promise.resolve(Nil) }",
  )
  |> expect_error("Some(None)")
}

pub fn data_in_api_module_test() {
  api(
    "pub type Local { Local(id: Int) }
pub fn get(_c: Context) -> Promise(Local) { promise.resolve(Local(1)) }",
  )
  |> expect_error("move spike/api.Local out of spike/api")
}

pub fn function_in_data_test() {
  api(
    "pub fn get(_c: Context, h h: types.Holder) -> Promise(Nil) { let _ = h promise.resolve(Nil) }",
  )
  |> expect_error("all its fields must be functions")
}

pub fn reserved_method_test() {
  api("pub fn then(_c: Context) -> Promise(Int) { promise.resolve(1) }")
  |> expect_error("reserve the name `then`")
}

pub fn callback_reply_test() {
  api(
    "pub fn get(_c: Context, f f: fn(Int) -> Int) -> Promise(Nil) { let _ = f promise.resolve(Nil) }",
  )
  |> expect_error("callbacks must return Nil")
}

pub fn foreign_type_test() {
  api(
    "pub fn get(_c: Context, d d: Dynamic) -> Promise(Nil) { let _ = d promise.resolve(Nil) }",
  )
  |> expect_error("Dynamic can't cross the wire")
}

pub fn constructor_label_test() {
  api(
    "pub fn get(_c: Context, p p: types.Proto) -> Promise(Nil) { let _ = p promise.resolve(Nil) }",
  )
  |> expect_error("can't be called `constructor`")
}

pub fn name_collision_test() {
  api(
    "pub fn handle_get(_c: Context) -> Promise(Nil) { promise.resolve(Nil) }
pub fn handle(_c: Context) -> Promise(types.Handle) { promise.resolve(types.Handle(fn() { promise.resolve(1) })) }",
  )
  |> expect_error("`handle_get` twice")
}

pub fn generated_import_test() {
  [
    #(
      "spike/api.gleam",
      "import spike/generated/wire\nimport starflame/server.{type Context}\npub fn get(_c: Context) -> Int { let _ = wire.x 1 }\n",
    ),
  ]
  |> expect_error("spike/api imports spike/generated/wire")
}

pub fn compile_error_test() {
  api("pub fn get(_c: Context) -> Promise(Int) { promise.resolve(\"x\") }")
  |> expect_error("build/kit-test/errors/src/spike/api.gleam")
}

@external(javascript, "./starflame_rpc_kit_test_ffi.mjs", "shell")
fn shell(
  directory: String,
  command: String,
  args: List(String),
) -> Result(String, String)

@external(javascript, "./starflame_rpc_kit_test_ffi.mjs", "absolute")
fn absolute(path: String) -> String

pub fn only_local_dependency_paths_become_absolute_test() {
  let toml =
    "[dependencies]
local = { path = \"../local\" }
remote = { git = \"https://example.com/repo\", ref = \"abc\", path = \"packages/remote\" }

[repository]
path = \"packages/app\"
"
  let manifest =
    "packages = [
  { name = \"local\", source = \"local\", path = \"../local\" },
  { name = \"remote\", source = \"git\", repo = \"https://example.com/repo\", commit = \"abc\", path = \"packages/remote\" },
]
"
  let assert True =
    string.contains(
      absolute_paths(toml, "/app"),
      "local = { path = \"/local\" }",
    )
  let assert True =
    string.contains(
      absolute_paths(toml, "/app"),
      "path = \"packages/remote\" }",
    )
  let assert True =
    string.contains(absolute_paths(toml, "/app"), "path = \"packages/app\"\n")
  let assert True =
    string.contains(absolute_paths(manifest, "/app"), "path = \"/local\" }")
  let assert True =
    string.contains(
      absolute_paths(manifest, "/app"),
      "commit = \"abc\", path = \"packages/remote\" }",
    )
}

@external(javascript, "./starflame_rpc_kit_ffi.mjs", "absolutePaths")
fn absolute_paths(toml: String, root: String) -> String
