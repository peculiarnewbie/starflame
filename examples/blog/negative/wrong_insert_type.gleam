import blog/db
import gleam/option
import starflame_db/runtime

pub fn invalid() {
  db.NewUser(
    email: 42,
    display_name: "Wrong type",
    admin: runtime.UseDefault,
    created_at: runtime.UseDefault,
    bio: option.None,
  )
}
