//// Types shared by the API and the browser.

pub const max_bytes = 2_000_000
pub const max_name_length = 120

pub const allowed_types = [
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/gif",
]

pub type Photo {
  Photo(
    id: String,
    owner: String,
    name: String,
    content_type: String,
    size: Int,
    created_at: Int,
  )
}

pub type PhotoError {
  EmptyName
  NameTooLong(limit: Int)
  EmptyFile
  UnsupportedType(content_type: String)
  TooLarge(limit: Int)
  NotFound(id: String)
  NotYours(id: String)
  StorageFailed
}
