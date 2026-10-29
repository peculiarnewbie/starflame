//// Types shared by the board API, the capability protocol and the browser.

pub const max_points = 2000
pub const max_width = 12.0

pub const palette = [
  "#7cc4ff",
  "#ffd166",
  "#ef6f6c",
  "#8ad0a8",
  "#c792ea",
]

pub type Point {
  Point(x: Float, y: Float)
}

/// What a client sends: coordinates are normalised to 0..1 so boards render at
/// any size.
pub type StrokeDraft {
  StrokeDraft(points: List(Point), color: String, width: Float)
}

pub type Stroke {
  Stroke(
    id: String,
    author: String,
    points: List(Point),
    color: String,
    width: Float,
    created_at: Int,
  )
}

/// What the board capability pushes to subscribers.
pub type BoardEvent {
  StrokeAdded(stroke: Stroke)
  Cleared
  Presence(online: Int)
}

pub type CanvasError {
  EmptyStroke
  TooManyPoints(limit: Int)
  BadColor(color: String)
  BadWidth
}
