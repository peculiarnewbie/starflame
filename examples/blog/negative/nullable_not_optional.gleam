import blog/db
import gleam/option
import starflame_db/runtime

pub fn invalid() {
  db.NewUser(
    email: "nullable@example.com",
    display_name: "Nullable",
    admin: runtime.UseDefault,
    created_at: runtime.UseDefault,
    bio: "not optional",
  )
}
