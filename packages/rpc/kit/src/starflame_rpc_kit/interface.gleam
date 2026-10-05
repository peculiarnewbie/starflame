//// The parts of `gleam export package-interface` the generator reads: every
//// public function and type, with fully resolved types.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type Interface {
  Interface(name: String, modules: Dict(String, Module))
}

pub type Module {
  Module(types: Dict(String, TypeDefinition), functions: Dict(String, Function))
}

pub type TypeDefinition {
  /// Opaque and external types have no constructors.
  TypeDefinition(parameters: Int, constructors: List(Constructor))
}

pub type Constructor {
  Constructor(name: String, parameters: List(Parameter))
}

pub type Parameter {
  Parameter(label: Option(String), type_: Type)
}

pub type Function {
  Function(
    parameters: List(Parameter),
    return: Type,
    documentation: Option(String),
    deprecation: Option(String),
  )
}

pub type Type {
  /// Built-in types like `Int` are in the `gleam` module of package `""`.
  Named(package: String, module: String, name: String, parameters: List(Type))
  Tuple(elements: List(Type))
  Fn(parameters: List(Type), return: Type)
  Variable(id: Int)
}

pub fn parse(source: String) -> Result(Interface, String) {
  json.parse(source, interface_decoder())
  |> result.map_error(fn(error) {
    "Couldn't read the package interface: " <> string.inspect(error)
  })
}

fn interface_decoder() -> Decoder(Interface) {
  use name <- decode.field("name", decode.string)
  use modules <- decode.field(
    "modules",
    decode.dict(decode.string, module_decoder()),
  )
  decode.success(Interface(name:, modules:))
}

fn module_decoder() -> Decoder(Module) {
  use types <- decode.field(
    "types",
    decode.dict(decode.string, type_definition_decoder()),
  )
  use functions <- decode.field(
    "functions",
    decode.dict(decode.string, function_decoder()),
  )
  decode.success(Module(types:, functions:))
}

fn type_definition_decoder() -> Decoder(TypeDefinition) {
  use parameters <- decode.field("parameters", decode.int)
  use constructors <- decode.field(
    "constructors",
    decode.list(constructor_decoder()),
  )
  decode.success(TypeDefinition(parameters:, constructors:))
}

fn constructor_decoder() -> Decoder(Constructor) {
  use name <- decode.field("name", decode.string)
  use parameters <- decode.field("parameters", decode.list(parameter_decoder()))
  decode.success(Constructor(name:, parameters:))
}

fn parameter_decoder() -> Decoder(Parameter) {
  use label <- decode.field("label", decode.optional(decode.string))
  use type_ <- decode.field("type", type_decoder())
  decode.success(Parameter(label:, type_:))
}

fn function_decoder() -> Decoder(Function) {
  use parameters <- decode.field("parameters", decode.list(parameter_decoder()))
  use return <- decode.field("return", type_decoder())
  use documentation <- decode.field(
    "documentation",
    decode.optional(decode.string),
  )
  use deprecation <- decode.field(
    "deprecation",
    decode.optional(decode.at(["message"], decode.string)),
  )
  decode.success(Function(parameters:, return:, documentation:, deprecation:))
}

fn type_decoder() -> Decoder(Type) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "named" -> {
      use package <- decode.field("package", decode.string)
      use module <- decode.field("module", decode.string)
      use name <- decode.field("name", decode.string)
      use parameters <- decode.field(
        "parameters",
        decode.list(decode.recursive(type_decoder)),
      )
      decode.success(Named(package:, module:, name:, parameters:))
    }
    "tuple" -> {
      use elements <- decode.field(
        "elements",
        decode.list(decode.recursive(type_decoder)),
      )
      decode.success(Tuple(elements:))
    }
    "fn" -> {
      use parameters <- decode.field(
        "parameters",
        decode.list(decode.recursive(type_decoder)),
      )
      use return <- decode.field("return", decode.recursive(type_decoder))
      decode.success(Fn(parameters:, return:))
    }
    "variable" -> {
      use id <- decode.field("id", decode.int)
      decode.success(Variable(id:))
    }
    _ -> decode.failure(Variable(0), "type kind")
  }
}
