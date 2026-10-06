//// The notes database.

import starflame_db/schema as s

pub fn schema() -> s.Schema {
  s.schema([
    s.table("users", row: "User")
      |> s.int("id", [s.primary_key()])
      |> s.text("email", [s.unique()])
      // Google's ID for the account, once someone has signed in with it.
      |> s.text("google_subject", [s.nullable(), s.unique()])
      |> s.timestamp("created_at", [s.default_now()]),
    s.table("notes", row: "Note")
      |> s.int("id", [s.primary_key()])
      |> s.int("user_id", [s.references("users", "id", on_delete: s.Cascade)])
      |> s.text("body", [])
      |> s.timestamp("created_at", [s.default_now()])
      |> s.index("notes_user_idx", ["user_id"]),
  ])
}
