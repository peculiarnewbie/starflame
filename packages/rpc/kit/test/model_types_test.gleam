import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import starflame_rpc_kit/codegen
import starflame_rpc_kit/interface.{
  type Interface, Constructor, Fn, Interface, Module, Named, Parameter, Tuple,
  TypeDefinition, Variable,
}
import starflame_rpc_kit/model

const root = "spike/client"

fn named(module: String, name: String) -> interface.Type {
  Named("spike", module, name, [])
}

fn definition(fields: List(interface.Type)) -> interface.TypeDefinition {
  TypeDefinition(0, [
    Constructor("Value", list.map(fields, Parameter(None, _))),
  ])
}

fn package(types: List(#(String, interface.TypeDefinition))) -> Interface {
  Interface(
    "spike",
    dict.from_list([
      #(root, Module(dict.from_list(types), dict.new())),
      #(
        "spike/other",
        Module(
          dict.from_list([
            #("Leaf", TypeDefinition(0, [Constructor("Leaf", [])])),
          ]),
          dict.new(),
        ),
      ),
    ]),
  )
}

pub fn analyse_types_orders_nested_custom_dependencies_test() {
  let interface =
    package([
      #(
        "AState",
        definition([
          Tuple([
            Named("", "gleam", "List", [
              Named("gleam_stdlib", "gleam/option", "Option", [
                named(root, "ZDetail"),
              ]),
            ]),
            Named("gleam_stdlib", "gleam/dict", "Dict", [
              Named("", "gleam", "String", []),
              named("spike/other", "Leaf"),
            ]),
          ]),
        ]),
      ),
      #("Unused", TypeDefinition(0, [Constructor("Unused", [])])),
      #("ZDetail", definition([named("spike/other", "Leaf")])),
    ])
  let assert Ok(types) = model.analyse_types(interface, root)
  let assert True = types.types_only
  let assert [] = types.methods
  let assert [] = types.capabilities
  list.map(types.data, fn(data) { model.show(data.ref) })
  |> should_equal([
    "spike/other.Leaf", "spike/client.ZDetail", "spike/client.AState",
    "spike/client.Unused",
  ])
}

pub fn analyse_types_relaxes_root_rule_and_imports_root_test() {
  let assert Ok(types) =
    model.analyse_types(
      package([
        #("Local", TypeDefinition(0, [Constructor("Local", [])])),
      ]),
      root,
    )
  let assert Ok(source) = codegen.generate_codecs(types, "spike/codecs")
  let assert True =
    string.contains(source, "import spike/client as spike_client")
  let assert True = string.contains(source, "value: spike_client.Local")
  let assert True =
    string.contains(source, "-- codecs spike/client --out spike/codecs")
  Nil
}

pub fn analyse_types_preserves_recursive_edges_test() {
  let assert Ok(types) =
    model.analyse_types(
      package([
        #("Ping", definition([named(root, "Pong")])),
        #("Pong", definition([named(root, "Ping")])),
        #(
          "Tree",
          definition([Named("", "gleam", "List", [named(root, "Tree")])]),
        ),
      ]),
      root,
    )
  let assert True =
    set.contains(types.lazy, #(model.Ref(root, "Pong"), model.Ref(root, "Ping")))
  let assert True =
    set.contains(types.lazy, #(model.Ref(root, "Tree"), model.Ref(root, "Tree")))
  Nil
}

fn rejects(definition: interface.TypeDefinition, message: String) {
  let assert Error(error) =
    model.analyse_types(package([#("Unsupported", definition)]), root)
  let assert True = string.contains(error, "spike/client.Unsupported")
  let assert True = string.contains(error, message)
  Nil
}

pub fn analyse_types_rejects_opaque_test() {
  rejects(TypeDefinition(0, []), "has no public constructors")
}

pub fn analyse_types_rejects_generic_and_phantom_parameters_test() {
  rejects(
    TypeDefinition(1, [
      Constructor("Generic", [Parameter(Some("value"), Variable(0))]),
    ]),
    "is generic",
  )
  rejects(TypeDefinition(2, [Constructor("Phantom", [])]), "is generic")
}

pub fn analyse_types_rejects_capabilities_and_function_fields_test() {
  let function = Fn([], Named("", "gleam", "Nil", []))
  rejects(
    definition([function]),
    "is a capability; functions cannot be encoded",
  )
  rejects(
    definition([function, Named("", "gleam", "Int", [])]),
    "functions cannot be encoded",
  )
}

pub fn analyse_types_checks_transitive_dependencies_test() {
  let interface =
    Interface(
      "spike",
      dict.from_list([
        #(
          root,
          Module(
            dict.from_list([
              #("State", definition([named("spike/other", "Hidden")])),
            ]),
            dict.new(),
          ),
        ),
        #(
          "spike/other",
          Module(
            dict.from_list([#("Hidden", TypeDefinition(0, []))]),
            dict.new(),
          ),
        ),
      ]),
    )
  let assert Error(error) = model.analyse_types(interface, root)
  let assert True =
    string.contains(error, "spike/other.Hidden has no public constructors")
  Nil
}

pub fn analyse_types_missing_module_test() {
  let assert Error(error) = model.analyse_types(package([]), "missing")
  let assert True = string.contains(error, "There's no public module missing")
  Nil
}

fn should_equal(actual: a, expected: a) -> Nil {
  let assert True = actual == expected
  Nil
}
