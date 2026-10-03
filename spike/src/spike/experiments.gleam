//// End-to-end experiments: Gleam client stubs -> Cap'n Web over WebSocket ->
//// Worker in Miniflare -> Gleam API. Driven by experiments/run.mjs.

import starflame/client.{Remote}
import gleam/dict
import gleam/int
import gleam/io
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import spike/generated/client as api
import spike/shared.{
  Admin, Everything, Guest, Invalid, Member, NotFound, Point, Unauthorized,
}

pub fn main(url: String) -> Promise(Int) {
  let conn = api.connect(url)
  let failures = []

  use failures <- step(failures, "get_user ok", {
    use reply <- promise.map(api.get_user(conn, 1))
    case reply {
      Ok(Ok(user)) if user.name == "ada" && user.role == Admin -> pass(user)
      other -> fail(other)
    }
  })

  use failures <- step(failures, "get_user typed error", {
    use reply <- promise.map(api.get_user(conn, 99))
    case reply {
      Ok(Error(NotFound(99))) -> pass(reply)
      other -> fail(other)
    }
  })

  use failures <- step(failures, "list_users with Option(Role) arg", {
    use all <- promise.await(api.list_users(conn, None))
    use members <- promise.map(api.list_users(conn, Some(Member("compilers"))))
    case all, members {
      Ok(all), Ok([grace]) if grace.name == "grace" ->
        pass(#(list.length(all), grace))
      _, _ -> fail(#(all, members))
    }
  })

  let everything =
    Everything(
      pair: #(42, "answer"),
      scores: dict.from_list([#("a", 1.5), #("b", -0.25)]),
      maybe: Some(0),
      nested: [[1, 2], [], [3]],
      unit: Nil,
      flag: False,
      big: 9_007_199_254_740_991,
      whole_float: 2.0,
      point: Point(-1, 7),
      roles: [Admin, Member("x"), Guest],
      outcome: Error("nope"),
    )
  use failures <- step(failures, "echo_everything round trip", {
    use reply <- promise.map(api.echo_everything(conn, everything))
    case reply {
      Ok(echoed) if echoed == everything -> pass("structurally equal")
      other -> fail(other)
    }
  })

  use failures <- step(failures, "login returns capability", {
    use reply <- promise.await(api.login(conn, "grace"))
    case reply {
      Ok(Ok(session)) -> {
        use me <- promise.await(api.session_me(session))
        use renamed <- promise.await(api.session_rename(session, "Grace H."))
        use invalid <- promise.map(api.session_rename(session, ""))
        case me, renamed, invalid {
          Ok(me), Ok(Ok(renamed)), Ok(Error(Invalid(_))) ->
            pass(#(me.name, renamed.name))
          _, _, _ -> fail(#(me, renamed, invalid))
        }
      }
      other -> promise.resolve(fail(other))
    }
  })

  use failures <- step(failures, "login unknown user", {
    use reply <- promise.map(api.login(conn, "mallory"))
    case reply {
      Ok(Error(Unauthorized)) -> pass(Nil)
      other -> fail(other)
    }
  })

  use failures <- step(failures, "callback progress during a call", {
    let seen = new_log()
    use reply <- promise.map(
      api.count_slowly(conn, 5, fn(n) { push(seen, int.to_string(n)) }),
    )
    let seen = entries(seen)
    case reply, seen {
      Ok(5), ["1", "2", "3", "4", "5"] -> pass(seen)
      _, _ -> fail(#(reply, seen))
    }
  })

  use failures <- step(failures, "panic becomes RpcError", {
    use reply <- promise.map(api.crash(conn, "boom"))
    case reply {
      Error(Remote(message)) -> pass(message)
      other -> fail(other)
    }
  })

  api.dispose(conn)
  promise.resolve(list.length(failures))
}

type Outcome {
  Pass(String)
  Fail(String)
}

fn pass(detail: a) -> Outcome {
  Pass(string.inspect(detail))
}

fn fail(detail: a) -> Outcome {
  Fail(string.inspect(detail))
}

fn step(
  failures: List(String),
  name: String,
  run: Promise(Outcome),
  next: fn(List(String)) -> Promise(Int),
) -> Promise(Int) {
  use outcome <- promise.await(run)
  case outcome {
    Pass(detail) -> {
      io.println("  PASS " <> name <> "  " <> detail)
      next(failures)
    }
    Fail(detail) -> {
      io.println("  FAIL " <> name <> "  " <> detail)
      next([name, ..failures])
    }
  }
}

type Log

@external(javascript, "./experiments_ffi.mjs", "newLog")
fn new_log() -> Log

@external(javascript, "./experiments_ffi.mjs", "push")
fn push(log: Log, entry: String) -> Nil

@external(javascript, "./experiments_ffi.mjs", "entries")
fn entries(log: Log) -> List(String)
