import arc/vm/builtins/common
import arc/vm/heap
import arc/vm/internal/elements
import arc/vm/state.{type Heap, type State, State}
import arc/vm/value.{
  type ConsoleNativeFn, type JsValue, type Ref, ConsoleAssert, ConsoleClear,
  ConsoleCount, ConsoleCountReset, ConsoleDebug, ConsoleError, ConsoleInfo,
  ConsoleLog, ConsoleNative, ConsoleTime, ConsoleTimeEnd, ConsoleTimeLog,
  ConsoleTrace, ConsoleWarn, JsBigInt, JsBool, JsNull, JsNumber, JsObject,
  JsString, JsSymbol, JsUndefined, JsUninitialized, ObjectSlot, OrdinaryObject,
}
import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string

// -- FFI for timing -----------------------------------------------------------

@external(erlang, "arc_console_ffi", "monotonic_ms")
@external(javascript, "../../arc_console_ffi.mjs", "monotonic_ms")
fn ffi_monotonic_ms() -> Float

// -- Init --------------------------------------------------------------------

pub fn init(h: Heap, object_proto: Ref, function_proto: Ref) -> #(Heap, Ref) {
  let #(h, methods) =
    common.alloc_methods(h, function_proto, [
      #("log", ConsoleNative(ConsoleLog), 1),
      #("warn", ConsoleNative(ConsoleWarn), 1),
      #("error", ConsoleNative(ConsoleError), 1),
      #("info", ConsoleNative(ConsoleInfo), 1),
      #("debug", ConsoleNative(ConsoleDebug), 1),
      #("assert", ConsoleNative(ConsoleAssert), 1),
      #("clear", ConsoleNative(ConsoleClear), 0),
      #("count", ConsoleNative(ConsoleCount), 0),
      #("countReset", ConsoleNative(ConsoleCountReset), 0),
      #("time", ConsoleNative(ConsoleTime), 0),
      #("timeLog", ConsoleNative(ConsoleTimeLog), 0),
      #("timeEnd", ConsoleNative(ConsoleTimeEnd), 0),
      #("trace", ConsoleNative(ConsoleTrace), 0),
    ])

  let properties = common.named_props(methods)
  let symbol_properties =
    dict.from_list([
      #(
        value.symbol_to_string_tag,
        value.data(JsString("console")) |> value.configurable(),
      ),
    ])

  let #(h, console_ref) =
    heap.alloc(
      h,
      ObjectSlot(
        kind: OrdinaryObject,
        properties:,
        elements: elements.new(),
        prototype: Some(object_proto),
        symbol_properties:,
        extensible: True,
      ),
    )
  let h = heap.root(h, console_ref)

  #(h, console_ref)
}

/// Per-module dispatch for console native functions.
pub fn dispatch(
  native: ConsoleNativeFn,
  args: List(JsValue),
  _this: JsValue,
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  case native {
    ConsoleLog -> log(args, state)
    ConsoleWarn -> warn(args, state)
    ConsoleError -> error_(args, state)
    ConsoleInfo -> info(args, state)
    ConsoleDebug -> debug(args, state)
    ConsoleAssert -> assert_(args, state)
    ConsoleClear -> clear(state)
    ConsoleCount -> count(args, state)
    ConsoleCountReset -> count_reset(args, state)
    ConsoleTime -> time(args, state)
    ConsoleTimeLog -> time_log(args, state)
    ConsoleTimeEnd -> time_end(args, state)
    ConsoleTrace -> trace(args, state)
  }
}

// -- Logging methods ---------------------------------------------------------
// WHATWG Console Standard §1.2: Logging

/// console.log(...args)
/// WHATWG Console Standard §1.2.1: Logger("log", args)
fn log(args: List(JsValue), state: State) -> #(State, Result(JsValue, JsValue)) {
  let #(state, parts) = stringify_args(args, state, [])
  io.println(string.join(parts, " "))
  #(state, Ok(JsUndefined))
}

/// console.warn(...args)
/// WHATWG Console Standard §1.2.4: Logger("warn", args)
fn warn(args: List(JsValue), state: State) -> #(State, Result(JsValue, JsValue)) {
  let #(state, parts) = stringify_args(args, state, [])
  io.println_error("warn: " <> string.join(parts, " "))
  #(state, Ok(JsUndefined))
}

/// console.error(...args)
/// WHATWG Console Standard §1.2.2: Logger("error", args)
fn error_(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let #(state, parts) = stringify_args(args, state, [])
  io.println_error("error: " <> string.join(parts, " "))
  #(state, Ok(JsUndefined))
}

/// console.info(...args)
/// WHATWG Console Standard §1.2.3: Logger("info", args)
fn info(args: List(JsValue), state: State) -> #(State, Result(JsValue, JsValue)) {
  let #(state, parts) = stringify_args(args, state, [])
  io.println(string.join(parts, " "))
  #(state, Ok(JsUndefined))
}

/// console.debug(...args)
/// WHATWG Console Standard §1.2.5: Logger("debug", args)
fn debug(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let #(state, parts) = stringify_args(args, state, [])
  io.println(string.join(parts, " "))
  #(state, Ok(JsUndefined))
}

/// console.assert(condition, ...args)
/// WHATWG Console Standard §1.2.6
/// If condition is falsy, prints "Assertion failed: " followed by args.
fn assert_(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let #(condition, rest) = case args {
    [c, ..r] -> #(c, r)
    [] -> #(JsUndefined, [])
  }

  case is_truthy(condition) {
    True -> #(state, Ok(JsUndefined))
    False -> {
      case rest {
        [] -> {
          io.println_error("Assertion failed")
          #(state, Ok(JsUndefined))
        }
        _ -> {
          let #(state, parts) = stringify_args(rest, state, [])
          io.println_error("Assertion failed: " <> string.join(parts, " "))
          #(state, Ok(JsUndefined))
        }
      }
    }
  }
}

/// console.clear()
/// WHATWG Console Standard §1.1.1
fn clear(state: State) -> #(State, Result(JsValue, JsValue)) {
  // On a terminal, clear would reset the console. We print a marker.
  io.println("\u{001b}[2J\u{001b}[H")
  #(state, Ok(JsUndefined))
}

// -- Counting methods --------------------------------------------------------
// WHATWG Console Standard §1.3: Counting

/// console.count(label?)
/// WHATWG Console Standard §1.3.1
fn count(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let label = get_label(args)
  let counts = state.console_counts
  let n = case dict.get(counts, label) {
    Ok(v) -> v + 1
    Error(_) -> 1
  }
  let counts = dict.insert(counts, label, n)
  io.println(label <> ": " <> int.to_string(n))
  #(State(..state, console_counts: counts), Ok(JsUndefined))
}

/// console.countReset(label?)
/// WHATWG Console Standard §1.3.2
fn count_reset(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let label = get_label(args)
  let counts = state.console_counts
  case dict.has_key(counts, label) {
    True -> {
      let counts = dict.insert(counts, label, 0)
      #(State(..state, console_counts: counts), Ok(JsUndefined))
    }
    False -> {
      io.println_error("countReset: \"" <> label <> "\" counter does not exist")
      #(state, Ok(JsUndefined))
    }
  }
}

// -- Timing methods ----------------------------------------------------------
// WHATWG Console Standard §1.4: Timing

/// console.time(label?)
/// WHATWG Console Standard §1.4.1
fn time(args: List(JsValue), state: State) -> #(State, Result(JsValue, JsValue)) {
  let label = get_label(args)
  let timers = state.console_timers
  case dict.has_key(timers, label) {
    True -> {
      io.println_error("time: \"" <> label <> "\" timer already exists")
      #(state, Ok(JsUndefined))
    }
    False -> {
      let now = ffi_monotonic_ms()
      let timers = dict.insert(timers, label, now)
      #(State(..state, console_timers: timers), Ok(JsUndefined))
    }
  }
}

/// console.timeLog(label?, ...args)
/// WHATWG Console Standard §1.4.2
fn time_log(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let #(label, rest) = case args {
    [JsString(l), ..r] -> #(l, r)
    _ -> #("default", args)
  }
  let timers = state.console_timers
  case dict.get(timers, label) {
    Ok(start) -> {
      let elapsed = ffi_monotonic_ms() -. start
      let prefix = label <> ": " <> format_duration(elapsed)
      let state = case rest {
        [] -> {
          io.println(prefix)
          state
        }
        _ -> {
          let #(state, parts) = stringify_args(rest, state, [])
          io.println(prefix <> " " <> string.join(parts, " "))
          state
        }
      }
      #(state, Ok(JsUndefined))
    }
    Error(_) -> {
      io.println_error("timeLog: \"" <> label <> "\" timer does not exist")
      #(state, Ok(JsUndefined))
    }
  }
}

/// console.timeEnd(label?)
/// WHATWG Console Standard §1.4.3
fn time_end(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let label = get_label(args)
  let timers = state.console_timers
  case dict.get(timers, label) {
    Ok(start) -> {
      let elapsed = ffi_monotonic_ms() -. start
      io.println(label <> ": " <> format_duration(elapsed))
      let timers = dict.delete(timers, label)
      #(State(..state, console_timers: timers), Ok(JsUndefined))
    }
    Error(_) -> {
      io.println_error("timeEnd: \"" <> label <> "\" timer does not exist")
      #(state, Ok(JsUndefined))
    }
  }
}

/// console.trace(...args)
/// WHATWG Console Standard §1.2.7
/// Prints "Trace: " followed by args. In a full implementation this would
/// also print a stack trace, but we don't have access to the JS call stack
/// from a HostFn, so we just print the label.
fn trace(
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  let #(state, parts) = stringify_args(args, state, [])
  let msg = case parts {
    [] -> "Trace"
    _ -> "Trace: " <> string.join(parts, " ")
  }
  io.println(msg)
  #(state, Ok(JsUndefined))
}

// -- Helpers -----------------------------------------------------------------

/// Extract the label argument, defaulting to "default" per WHATWG spec.
fn get_label(args: List(JsValue)) -> String {
  case args {
    [JsString(s), ..] -> s
    _ -> "default"
  }
}

/// Format a duration in milliseconds for console.time output.
fn format_duration(ms: Float) -> String {
  float.to_string(ms) <> "ms"
}

/// ES ToBoolean — used by console.assert.
fn is_truthy(val: JsValue) -> Bool {
  case val {
    JsUndefined | JsNull | JsUninitialized -> False
    JsBool(b) -> b
    JsNumber(value.Finite(0.0)) -> False
    JsNumber(value.NaN) -> False
    JsNumber(_) -> True
    JsString("") -> False
    JsString(_) -> True
    JsBigInt(value.BigInt(0)) -> False
    JsBigInt(_) -> True
    JsObject(_) -> True
    JsSymbol(_) -> True
  }
}

/// Stringify a list of JS values for console output.
fn stringify_args(
  args: List(JsValue),
  state: State,
  acc: List(String),
) -> #(State, List(String)) {
  case args {
    [] -> #(state, list.reverse(acc))
    [arg, ..rest] -> {
      let #(state, s) = stringify_one(arg, state)
      stringify_args(rest, state, [s, ..acc])
    }
  }
}

/// Stringify a single JS value for console output.
fn stringify_one(val: JsValue, state: State) -> #(State, String) {
  case val {
    JsUndefined -> #(state, "undefined")
    JsNull -> #(state, "null")
    JsBool(True) -> #(state, "true")
    JsBool(False) -> #(state, "false")
    JsNumber(value.Finite(n)) -> #(state, value.js_format_number(n))
    JsNumber(value.NaN) -> #(state, "NaN")
    JsNumber(value.Infinity) -> #(state, "Infinity")
    JsNumber(value.NegInfinity) -> #(state, "-Infinity")
    JsString(s) -> #(state, s)
    JsBigInt(value.BigInt(n)) -> #(state, int.to_string(n) <> "n")
    JsSymbol(_) -> #(state, "Symbol()")
    JsUninitialized -> #(state, "undefined")
    JsObject(_) ->
      case state.js_to_string(state, val) {
        Ok(#(s, state)) -> #(state, s)
        Error(#(_, state)) -> #(state, "[object Object]")
      }
  }
}
