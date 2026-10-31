import { toList } from "../gleam.mjs";
import { Point, StrokeDraft } from "./shared.mjs";

const COLOR = "#7cc4ff";
const WIDTH = 3.0;

// The last strokes from the model, plus the two local layers that keep drawing
// responsive: the stroke under the pointer, and the one just released while its
// RPC reply is in flight.
let current = [];
let draft = null;
let pending = null;
let readOnly = false;

export function session() {
  return localStorage.getItem("canvas:session") ?? "";
}

export function basePath() {
  const parts = location.pathname.split("/").filter(Boolean);
  return parts[0] === "app" && parts[1] ? `/app/${parts[1]}` : "";
}

export function roomName() {
  const path = location.pathname.slice(basePath().length);
  const parts = path.split("/").filter(Boolean);
  const raw = parts[0] === "b" && parts[1] ? decodeURIComponent(parts[1]) : "lobby";
  const cleaned = raw.toLowerCase().replace(/[^a-z0-9_-]/g, "").slice(0, 40);
  return cleaned.length > 0 ? cleaned : "lobby";
}

export function attach(id, onDraft) {
  whenCanvas(id, (canvas) => {
    if (canvas.dataset.attached) return;
    canvas.dataset.attached = "1";

    const point = (event) => {
      const rect = canvas.getBoundingClientRect();
      return new Point(
        (event.clientX - rect.left) / Math.max(1, rect.width),
        (event.clientY - rect.top) / Math.max(1, rect.height),
      );
    };

    canvas.addEventListener("pointerdown", (event) => {
      if (readOnly) return;
      canvas.setPointerCapture(event.pointerId);
      draft = [point(event)];
      render(canvas);
    });

    canvas.addEventListener("pointermove", (event) => {
      if (!draft) return;
      draft.push(point(event));
      render(canvas);
    });

    const finish = () => {
      if (draft && draft.length > 0) {
        const finished = draft;
        draft = null;
        // Keep painting it until the model includes the server's stroke.
        pending = finished;
        render(canvas);
        onDraft(new StrokeDraft(toList(finished), COLOR, WIDTH));
      } else {
        draft = null;
        render(canvas);
      }
    };
    canvas.addEventListener("pointerup", finish);
    canvas.addEventListener("pointercancel", finish);
  });
}

export function draw(id, strokes, nextReadOnly) {
  const next = list(strokes);
  // A change in the model means the pending stroke has landed (or another one
  // did); drop the local copy either way.
  if (pending && next.length !== current.length) pending = null;
  current = next;
  if (nextReadOnly !== undefined) readOnly = nextReadOnly;
  whenCanvas(id, (canvas) => {
    canvas.style.cursor = readOnly ? "default" : "crosshair";
    render(canvas);
  });
}

function render(canvas) {
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;
  if (canvas.width !== width * ratio || canvas.height !== height * ratio) {
    canvas.width = width * ratio;
    canvas.height = height * ratio;
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  ctx.globalAlpha = readOnly ? 0.85 : 1;

  for (const stroke of current) {
    paint(ctx, list(stroke.points), stroke.color, stroke.width, width, height);
  }
  if (pending) paint(ctx, pending, COLOR, WIDTH, width, height);
  if (draft) paint(ctx, draft, COLOR, WIDTH, width, height);
}

function paint(ctx, points, color, lineWidth, width, height) {
  if (points.length === 0) return;
  ctx.beginPath();
  ctx.strokeStyle = color;
  ctx.lineWidth = lineWidth;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.moveTo(points[0].x * width, points[0].y * height);
  for (let i = 1; i < points.length; i++) {
    ctx.lineTo(points[i].x * width, points[i].y * height);
  }
  ctx.stroke();
}

function list(value) {
  return value?.toArray ? value.toArray() : value;
}

function whenCanvas(id, run) {
  const canvas = document.getElementById(id);
  if (canvas) run(canvas);
  else requestAnimationFrame(() => whenCanvas(id, run));
}
