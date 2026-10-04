import blog/db
import gleam/option
import starflame_db/runtime

pub fn invalid() {
  db.NewUser(
    email: "missing@example.com",
    admin: runtime.UseDefault,
    created_at: runtime.UseDefault,
    bio: option.None,
  )
}
