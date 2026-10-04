export function row_text(row) {
  return Object.values(row)
    .map((value) => (value === null ? "" : String(value)))
    .join("|");
}
