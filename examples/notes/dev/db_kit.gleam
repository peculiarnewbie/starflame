import notes/schema
import starflame_db_kit

pub fn main() -> Nil {
  starflame_db_kit.main(
    schema.schema(),
    starflame_db_kit.Config(
      ..starflame_db_kit.default_config(),
      module: "src/notes/db.gleam",
    ),
  )
}
