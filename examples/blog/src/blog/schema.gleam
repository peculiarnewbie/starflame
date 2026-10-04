//// Blog schema. Migration history changes it in small, reviewable steps.

import starflame_db/schema as s

pub fn schema() -> s.Schema {
  s.schema([
    s.table("users", row: "User")
      |> s.int("id", [s.primary_key()])
      |> s.text("email", [s.unique()])
      |> s.text("display_name", [])
      |> s.bool("admin", [s.default(False)])
      |> s.timestamp("created_at", [s.default_now()])
      |> s.text("bio", [s.nullable()])
      |> s.check("users_email_at", "instr(email, '@') > 1")
      |> s.check("users_display_name_nonempty", "length(display_name) > 0")
      |> s.index("users_name_idx", ["display_name"]),
    s.table("posts", row: "Post")
      |> s.int("id", [s.primary_key()])
      |> s.int("user_id", [s.references("users", "id", on_delete: s.Cascade)])
      |> s.text("title", [])
      |> s.text("slug", [s.default("pending")])
      |> s.text("body", [s.nullable(), s.default("")])
      |> s.text("type", [s.default("article")])
      |> s.float("rating", [s.nullable()])
      |> s.index("posts_user_idx", ["user_id"]),
    s.table("comments", row: "Comment")
      |> s.int("id", [s.primary_key()])
      |> s.int("post_id", [s.references("posts", "id", on_delete: s.Cascade)])
      |> s.int("editor_id", [
        s.nullable(),
        s.references("users", "id", on_delete: s.SetNull),
      ])
      |> s.text("body", []),
  ])
}
