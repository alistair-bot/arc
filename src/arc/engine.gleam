//// The embed-Arc library facade.
////
//// Hides the heap/builtins/globals bootstrapping dance behind a small API.
//// Callers who just want to run some JS should go through `new()` + `eval()`
//// instead of wiring up heap + builtins + entry directly.

import arc/compiler
import arc/parser
import arc/vm/builtins
import arc/vm/builtins/common.{type Builtins}
import arc/vm/completion.{type Completion}
import arc/vm/exec/entry
import arc/vm/heap.{type Heap}
import arc/vm/state
import arc/vm/value.{type JsValue, type Ref}
import gleam/string

// ----------------------------------------------------------------------------
// Engine type
// ----------------------------------------------------------------------------

/// An initialized JS engine — heap, builtins, global object.
///
/// Opaque so callers can't reach inside and mutate pieces independently;
/// the only way to advance an engine is via `eval`.
pub opaque type Engine {
  Engine(heap: Heap, builtins: Builtins, global: Ref)
}

/// Errors from `eval` — covers the whole parse → compile → run pipeline.
pub type EvalError {
  ParseError(message: String)
  CompileError(message: String)
  /// Internal VM error (a bug in Arc, not a JS exception).
  VmError(message: String)
}

// ----------------------------------------------------------------------------
// Constructors
// ----------------------------------------------------------------------------

/// Create a fresh engine with a new heap and all builtins installed.
pub fn new() -> Engine {
  let h = heap.new()
  let #(h, b) = builtins.init(h)
  let #(h, global) = builtins.globals(b, h)
  Engine(heap: h, builtins: b, global:)
}

// ----------------------------------------------------------------------------
// Evaluation
// ----------------------------------------------------------------------------

/// Parse, compile, and run a JS source string. Returns the completion
/// (normal return value or uncaught exception) plus a new engine carrying
/// the updated heap.
///
/// Drains the microtask queue but does NOT run the mailbox-backed event
/// loop — use `eval_with_event_loop` if you need `Arc.receiveAsync` or
/// `Arc.setTimeout` to actually fire.
pub fn eval(
  engine: Engine,
  source: String,
) -> Result(#(Completion, Engine), EvalError) {
  do_eval(engine, source, False)
}

/// Like `eval` but runs the BEAM-mailbox-backed event loop, so
/// `Arc.receiveAsync`, `Arc.setTimeout`, and friends work. Blocks until
/// `outstanding` reaches zero.
pub fn eval_with_event_loop(
  engine: Engine,
  source: String,
) -> Result(#(Completion, Engine), EvalError) {
  do_eval(engine, source, True)
}

fn do_eval(
  engine: Engine,
  source: String,
  event_loop: Bool,
) -> Result(#(Completion, Engine), EvalError) {
  case parser.parse(source, parser.Script) {
    Error(err) -> Error(ParseError(parser.parse_error_to_string(err)))
    Ok(program) ->
      case compiler.compile(program) {
        Error(err) -> Error(CompileError(compile_error_message(err)))
        Ok(template) ->
          case
            entry.run(
              template,
              engine.heap,
              engine.builtins,
              engine.global,
              event_loop,
            )
          {
            Error(vm_err) -> Error(VmError(vm_error_message(vm_err)))
            Ok(completion) ->
              Ok(#(
                completion,
                Engine(..engine, heap: completion_heap(completion)),
              ))
          }
      }
  }
}

// ----------------------------------------------------------------------------
// Accessors
// ----------------------------------------------------------------------------

/// Peek at the engine's heap. Useful for inspecting returned JsValues
/// (since most are heap refs).
pub fn heap(engine: Engine) -> Heap {
  engine.heap
}

/// The engine's global object ref (`globalThis`).
pub fn global(engine: Engine) -> Ref {
  engine.global
}

// ----------------------------------------------------------------------------
// Re-exports
// ----------------------------------------------------------------------------
//
// So users can `import arc/engine` and get the key types without reaching
// into arc/vm/value, arc/vm/completion, etc.

pub type ArcJsValue =
  JsValue

pub type ArcCompletion =
  Completion

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

fn completion_heap(c: Completion) -> Heap {
  case c {
    completion.NormalCompletion(_, h) -> h
    completion.ThrowCompletion(_, h) -> h
    completion.YieldCompletion(_, h) -> h
  }
}

fn compile_error_message(err: compiler.CompileError) -> String {
  case err {
    compiler.BreakOutsideLoop -> "break outside loop"
    compiler.ContinueOutsideLoop -> "continue outside loop"
    compiler.Unsupported(desc) -> "unsupported: " <> desc
  }
}

fn vm_error_message(err: state.VmError) -> String {
  case err {
    state.PcOutOfBounds(pc) -> "pc out of bounds: " <> string.inspect(pc)
    state.StackUnderflow(op) -> "stack underflow in " <> op
    state.LocalIndexOutOfBounds(i) ->
      "local index out of bounds: " <> string.inspect(i)
    state.Unimplemented(op) -> "unimplemented opcode: " <> op
  }
}
