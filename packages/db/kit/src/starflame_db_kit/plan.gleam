//// Diffs two schemas into D1-safe SQL.
////
//// D1 always enforces foreign keys (`PRAGMA foreign_keys = OFF` is ignored),
//// and `DROP TABLE` runs an implicit DELETE that fires ON DELETE actions. So
//// a table that SQLite can't alter in place is rebuilt together with every
//// table that references it, directly or indirectly: all of them are copied
//// to backups before anything is dropped, then restored under their final
//// names, with foreign key checks deferred to the end of the migration.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import starflame_db/schema.{
  type Column, type Reference, type Schema, type Table, Column, Index, Reference,
}
import starflame_db_kit/sql.{quote}
import starflame_db_kit/validate

/// Decisions the planner will not guess.
pub type Options {
  Options(renames: List(Rename), allow_destructive: Bool)
}

/// A column rename, `--rename table.from=to`.
pub type Rename {
  Rename(table: String, from: String, to: String)
}

pub type Plan {
  Plan(statements: List(String), notes: List(String))
}

const backup_prefix = "__sf_bak_"

pub fn plan(
  old: Schema,
  new: Schema,
  options: Options,
) -> Result(Plan, List(String)) {
  use new <- result.try(validate.validate(new))
  let old_tables = by_name(old.tables)
  let new_tables = by_name(new.tables)
  use <- guard(check_renames(options.renames, old_tables, new_tables))

  let created =
    list.filter(new.tables, fn(t) { !dict.has_key(old_tables, t.name) })
  let dropped =
    list.filter(old.tables, fn(t) { !dict.has_key(new_tables, t.name) })
  let kept =
    list.filter_map(new.tables, fn(t) {
      dict.get(old_tables, t.name) |> result.map(fn(o) { #(o, t) })
    })
    |> list.sort(fn(a, b) { string.compare({ a.1 }.name, { b.1 }.name) })

  let referenced = referenced_columns(old)
  let changes =
    list.map(kept, fn(pair) {
      table_changes(pair.0, pair.1, options, referenced)
    })
  use <- guard(
    list.flat_map(changes, fn(c) { c.errors })
    |> list.append(case options.allow_destructive {
      False ->
        list.map(dropped, fn(t) {
          "dropping table "
          <> t.name
          <> " deletes its data; pass --allow-destructive to confirm"
        })
      True -> []
    }),
  )

  let direct =
    list.filter_map(changes, fn(c) {
      option.to_result(c.rebuild, Nil) |> result.replace(c.table)
    })
  let rebuild =
    closure(list.map(kept, fn(pair) { pair.1 }), set.from_list(direct))
  let rebuilt = fn(name) { set.contains(rebuild, name) }
  let in_place = list.filter(changes, fn(c) { !rebuilt(c.table) })
  let rebuilds = list.filter(kept, fn(pair) { rebuilt({ pair.1 }.name) })

  let notes =
    list.flatten([
      list.map(options.renames, fn(r) {
        "rename " <> r.table <> "." <> r.from <> " to " <> r.to
      }),
      list.flat_map(changes, fn(c) { c.notes }),
      list.map(dropped, fn(t) { "drop table " <> t.name }),
      list.filter_map(changes, fn(c) {
        option.to_result(c.rebuild, Nil)
        |> result.map(fn(reason) { "rebuild " <> c.table <> ": " <> reason })
      }),
      set.to_list(rebuild)
        |> list.filter(fn(name) { !list.contains(direct, name) })
        |> list.sort(string.compare)
        |> list.map(fn(name) {
          "rebuild "
          <> name
          <> ": references a rebuilt table, and D1 cannot disable foreign keys"
        }),
    ])

  let statements =
    list.flatten([
      case rebuilds, dropped {
        [], [] -> []
        _, _ -> ["PRAGMA defer_foreign_keys = ON"]
      },
      list.flat_map(in_place, fn(c) { c.drop_indexes }),
      list.flat_map(in_place, fn(c) { c.alters }),
      list.map(created, sql.create_table),
      rebuild_statements(rebuilds, options.renames),
      children_first(dropped)
        |> list.map(fn(t) { "DROP TABLE " <> quote(t.name) }),
      list.flat_map(in_place, fn(c) { c.create_indexes }),
      list.flat_map(created, create_indexes),
      list.flat_map(rebuilds, fn(pair) { create_indexes(pair.1) }),
    ])
  Ok(Plan(statements:, notes:))
}

fn check_renames(
  renames: List(Rename),
  old: Dict(String, Table),
  new: Dict(String, Table),
) -> List(String) {
  let has = fn(tables: Dict(String, Table), name: String, column: String) {
    case dict.get(tables, name) {
      Ok(table) -> list.any(table.columns, fn(c) { c.name == column })
      Error(Nil) -> False
    }
  }
  list.flat_map(renames, fn(r) {
    let at = "--rename " <> r.table <> "." <> r.from <> "=" <> r.to <> ": "
    case dict.has_key(old, r.table), dict.has_key(new, r.table) {
      True, True ->
        list.flatten([
          case has(old, r.table, r.from) && !has(new, r.table, r.from) {
            True -> []
            False -> [at <> r.from <> " must exist only in the old schema"]
          },
          case has(new, r.table, r.to) && !has(old, r.table, r.to) {
            True -> []
            False -> [at <> r.to <> " must exist only in the new schema"]
          },
        ])
      _, _ -> [at <> "table " <> r.table <> " must exist before and after"]
    }
  })
  |> list.append(
    renames
    |> list.group(fn(r) { #(r.table, r.from) })
    |> dict.filter(fn(_, group) { list.length(group) > 1 })
    |> dict.keys
    |> list.map(fn(key) { "renamed more than once: " <> key.0 <> "." <> key.1 }),
  )
}

type Changes {
  Changes(
    table: String,
    rebuild: Option(String),
    alters: List(String),
    drop_indexes: List(String),
    create_indexes: List(String),
    notes: List(String),
    errors: List(String),
  )
}

fn table_changes(
  old: Table,
  new: Table,
  options: Options,
  referenced: Set(#(String, String)),
) -> Changes {
  let renamed = renamer(options.renames)
  // The old columns under their new names, with references to renamed
  // columns updated, so they compare equal to unchanged new columns.
  let old_columns =
    list.map(old.columns, fn(c) {
      #(renamed(old.name, c.name), rename_reference(c, renamed))
    })
    |> dict.from_list
  let new_names = list.map(new.columns, fn(c) { c.name }) |> set.from_list
  let added =
    list.filter(new.columns, fn(c) { !dict.has_key(old_columns, c.name) })
  let removed =
    list.filter(old.columns, fn(c) {
      !set.contains(new_names, renamed(old.name, c.name))
    })
  let changed =
    list.filter(new.columns, fn(c) {
      case dict.get(old_columns, c.name) {
        Ok(o) -> sql.column(Column(..o, name: c.name)) != sql.column(c)
        Error(Nil) -> False
      }
    })
  let renames = list.filter(options.renames, fn(r) { r.table == new.name })

  let old_indexes =
    list.map(old.indexes, fn(i) {
      #(i.name, Index(..i, columns: list.map(i.columns, renamed(old.name, _))))
    })
    |> dict.from_list
  let new_indexes =
    list.map(new.indexes, fn(i) { #(i.name, i) }) |> dict.from_list
  let dropped_indexes =
    list.filter(old.indexes, fn(i) {
      dict.get(new_indexes, i.name) != dict.get(old_indexes, i.name)
    })
  let created_indexes =
    list.filter(new.indexes, fn(i) { dict.get(old_indexes, i.name) != Ok(i) })

  let errors =
    list.flatten([
      list.filter_map(added, fn(c) {
        case c.nullable || c.default != None || sql.is_rowid(c) {
          True -> Error(Nil)
          False ->
            Ok(
              new.name
              <> "."
              <> c.name
              <> " is NOT NULL without a default, so existing rows have no value for it. "
              <> "Add a default, or add it as nullable, backfill it in a custom migration "
              <> "and then make it NOT NULL"
              <> rename_hint(
                new.name,
                list.filter(removed, fn(r) { r.kind == c.kind })
                  |> list.map(fn(r) { #(r.name, c.name) }),
              ),
            )
        }
      }),
      case options.allow_destructive {
        True -> []
        False ->
          list.map(removed, fn(c) {
            "dropping "
            <> new.name
            <> "."
            <> c.name
            <> " deletes its data; pass --allow-destructive to confirm"
            <> rename_hint(
              new.name,
              list.filter(added, fn(a) { a.kind == c.kind })
                |> list.map(fn(a) { #(c.name, a.name) }),
            )
          })
      },
    ])

  let checks_changed =
    canonical_checks(old.checks) != canonical_checks(new.checks)
  let reasons =
    list.flatten([
      list.map(changed, fn(c) { c.name <> " changed" }),
      list.filter_map(added, fn(c) {
        case addable(c) {
          True -> Error(Nil)
          False -> Ok(c.name <> " can't be added with ALTER TABLE")
        }
      }),
      list.filter_map(removed, fn(c) {
        case droppable(old, c, referenced) {
          True -> Error(Nil)
          False -> Ok(c.name <> " can't be dropped with ALTER TABLE")
        }
      }),
      case checks_changed {
        True -> ["checks changed"]
        False -> []
      },
    ])

  let table = quote(new.name)
  Changes(
    table: new.name,
    rebuild: case reasons {
      [] -> None
      reasons -> Some(string.join(reasons, ", "))
    },
    alters: list.flatten([
      list.map(renames, fn(r) {
        "ALTER TABLE "
        <> table
        <> " RENAME COLUMN "
        <> quote(r.from)
        <> " TO "
        <> quote(r.to)
      }),
      list.map(removed, fn(c) {
        "ALTER TABLE " <> table <> " DROP COLUMN " <> quote(c.name)
      }),
      list.map(added, fn(c) {
        "ALTER TABLE " <> table <> " ADD COLUMN " <> sql.column(c)
      }),
    ]),
    drop_indexes: list.map(dropped_indexes, fn(i) {
      "DROP INDEX " <> quote(i.name)
    }),
    create_indexes: list.map(created_indexes, sql.create_index(new.name, _)),
    notes: list.map(removed, fn(c) {
      "drop column " <> new.name <> "." <> c.name
    }),
    errors:,
  )
}

/// Suggests renames between a dropped and an added column of the same kind.
fn rename_hint(table: String, candidates: List(#(String, String))) -> String {
  case candidates {
    [] -> ""
    _ ->
      ". If it was renamed, pass "
      <> list.map(candidates, fn(pair) {
        "--rename " <> table <> "." <> pair.0 <> "=" <> pair.1
      })
      |> string.join(" or ")
  }
}

fn renamer(renames: List(Rename)) -> fn(String, String) -> String {
  let lookup =
    list.map(renames, fn(r) { #(#(r.table, r.from), r.to) }) |> dict.from_list
  fn(table, column) {
    dict.get(lookup, #(table, column)) |> result.unwrap(column)
  }
}

fn rename_reference(
  column: Column,
  renamed: fn(String, String) -> String,
) -> Column {
  case column.references {
    Some(reference) ->
      Column(
        ..column,
        references: Some(
          Reference(
            ..reference,
            column: renamed(reference.table, reference.column),
          ),
        ),
      )
    None -> column
  }
}

/// SQLite's ADD COLUMN rules: no PRIMARY KEY or UNIQUE, a constant default,
/// NOT NULL needs a non-NULL default, and REFERENCES needs a NULL default.
fn addable(column: Column) -> Bool {
  !column.primary_key
  && !column.unique
  && case column.default, column.references {
    Some(schema.Expression(_)), _ -> False
    Some(schema.Literal(_)), Some(_) -> False
    Some(schema.Literal(_)), None -> True
    None, _ -> column.nullable
  }
}

/// SQLite's DROP COLUMN rules, conservatively: not a key, not UNIQUE, not a
/// foreign key on either side, not indexed and not mentioned by a CHECK.
/// Indexes that use the column are dropped first, because the new schema
/// can't have them.
fn droppable(
  table: Table,
  column: Column,
  referenced: Set(#(String, String)),
) -> Bool {
  !column.primary_key
  && !column.unique
  && column.references == None
  && !set.contains(referenced, #(table.name, column.name))
  && !list.any(table.checks, fn(check) {
    string.contains(check.sql, column.name)
  })
}

/// #(table, column) pairs that some foreign key points at.
fn referenced_columns(schema: Schema) -> Set(#(String, String)) {
  list.flat_map(schema.tables, fn(table) {
    list.filter_map(table.columns, fn(c) {
      option.to_result(c.references, Nil)
      |> result.map(fn(r: Reference) { #(r.table, r.column) })
    })
  })
  |> set.from_list
}

fn canonical_checks(checks: List(schema.Check)) -> List(schema.Check) {
  list.sort(checks, fn(a, b) { string.compare(a.name, b.name) })
}

/// Grows the set with every table that references a member.
fn closure(tables: List(Table), seed: Set(String)) -> Set(String) {
  let next =
    list.fold(tables, seed, fn(acc, table) {
      case list.any(parents(table), set.contains(acc, _)) {
        True -> set.insert(acc, table.name)
        False -> acc
      }
    })
  case set.size(next) == set.size(seed) {
    True -> seed
    False -> closure(tables, next)
  }
}

/// Tables this one references, excluding itself.
fn parents(table: Table) -> List(String) {
  list.filter_map(table.columns, fn(c) {
    case c.references {
      Some(r) if r.table != table.name -> Ok(r.table)
      _ -> Error(Nil)
    }
  })
}

/// Orders tables so each comes before the tables it references. Dropping in
/// this order means no ON DELETE action or RESTRICT check sees a child row.
/// Cycles are broken by name.
fn children_first(tables: List(Table)) -> List(Table) {
  let sorted = list.sort(tables, fn(a, b) { string.compare(a.name, b.name) })
  do_children_first(sorted, [])
}

fn do_children_first(remaining: List(Table), done: List(Table)) -> List(Table) {
  case remaining {
    [] -> list.reverse(done)
    [first, ..] -> {
      let referenced = list.flat_map(remaining, parents) |> set.from_list
      let next =
        list.find(remaining, fn(t) { !set.contains(referenced, t.name) })
        |> result.unwrap(first)
      do_children_first(list.filter(remaining, fn(t) { t.name != next.name }), [
        next,
        ..done
      ])
    }
  }
}

fn rebuild_statements(
  pairs: List(#(Table, Table)),
  renames: List(Rename),
) -> List(String) {
  let renamed = renamer(renames)
  let copies =
    list.map(pairs, fn(pair) {
      let #(old, new) = pair
      let new_names = list.map(new.columns, fn(c) { c.name })
      let columns =
        list.filter_map(old.columns, fn(c) {
          let target = renamed(old.name, c.name)
          case list.contains(new_names, target) {
            True -> Ok(#(c.name, target))
            False -> Error(Nil)
          }
        })
      #(old, new, columns)
    })
  let backup = fn(name) { quote(backup_prefix <> name) }
  let names = fn(columns: List(#(String, String)), pick) {
    list.map(columns, fn(c) { quote(pick(c)) }) |> string.join(", ")
  }
  let parents_first =
    children_first(list.map(pairs, fn(pair) { pair.1 })) |> list.reverse
  let copy_for = fn(table: Table) {
    list.find(copies, fn(copy) { { copy.1 }.name == table.name })
  }
  list.flatten([
    list.map(copies, fn(copy) {
      let #(old, new, columns) = copy
      "CREATE TABLE "
      <> backup(new.name)
      <> " AS SELECT "
      <> names(columns, fn(c) { c.0 })
      <> " FROM "
      <> quote(old.name)
    }),
    children_first(list.map(pairs, fn(pair) { pair.0 }))
      |> list.map(fn(t) { "DROP TABLE " <> quote(t.name) }),
    list.map(parents_first, sql.create_table),
    list.filter_map(parents_first, fn(table) {
      use #(_, new, columns) <- result.map(copy_for(table))
      "INSERT INTO "
      <> quote(new.name)
      <> " ("
      <> names(columns, fn(c) { c.1 })
      <> ") SELECT "
      <> names(columns, fn(c) { c.0 })
      <> " FROM "
      <> backup(new.name)
    }),
    list.map(copies, fn(copy) { "DROP TABLE " <> backup({ copy.1 }.name) }),
  ])
}

fn create_indexes(table: Table) -> List(String) {
  list.map(table.indexes, sql.create_index(table.name, _))
}

fn by_name(tables: List(Table)) -> Dict(String, Table) {
  list.map(tables, fn(t) { #(t.name, t) }) |> dict.from_list
}

fn guard(
  errors: List(String),
  next: fn() -> Result(a, List(String)),
) -> Result(a, List(String)) {
  case errors {
    [] -> next()
    _ -> Error(errors)
  }
}
