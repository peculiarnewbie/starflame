import { toList } from "../gleam.mjs";
import { Point, StrokeDraft } from "./shared.mjs";

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

/// Captures freehand strokes and hands them to Gleam as a StrokeDraft.
export function attach(id, onDraft) {
  whenCanvas(id, (canvas) => {
    if (canvas.dataset.attached) return;
    canvas.dataset.attached = "1";
    let points = null;

    const point = (event) => {
      const rect = canvas.getBoundingClientRect();
      return new Point(
        (event.clientX - rect.left) / Math.max(1, rect.width),
        (event.clientY - rect.top) / Math.max(1, rect.height),
      );
    };

    canvas.addEventListener("pointerdown", (event) => {
      canvas.setPointerCapture(event.pointerId);
      points = [point(event)];
    });
    canvas.addEventListener("pointermove", (event) => {
      if (points) points.push(point(event));
    });
    const finish = () => {
      if (points && points.length > 0) {
        onDraft(new StrokeDraft(toList(points), "#7cc4ff", 3.0));
      }
      points = null;
    };
    canvas.addEventListener("pointerup", finish);
    canvas.addEventListener("pointercancel", finish);
  });
}

export function draw(id, strokes, readOnly) {
  whenCanvas(id, (canvas) => {
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
    if (readOnly) ctx.globalAlpha = 0.85;

    for (const stroke of list(strokes)) {
      const points = list(stroke.points);
      if (points.length === 0) continue;
      ctx.beginPath();
      ctx.strokeStyle = stroke.color;
      ctx.lineWidth = stroke.width;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.moveTo(points[0].x * width, points[0].y * height);
      for (let i = 1; i < points.length; i++) {
        ctx.lineTo(points[i].x * width, points[i].y * height);
      }
      ctx.stroke();
    }
  });
}

function list(value) {
  return value?.toArray ? value.toArray() : value;
}

function whenCanvas(id, run) {
  const canvas = document.getElementById(id);
  if (canvas) run(canvas);
  else requestAnimationFrame(() => whenCanvas(id, run));
}
