---
name: nativefunction
description: Implement a new JavaScript native/builtin function (e.g. Array.from, String.prototype.trim, Math.abs).
---

# /nativefunction — Implement a JS native function

Implement a new JavaScript built-in/native function in the Arc runtime.

The user will specify the function, e.g. `/nativefunction Array.from` or `/nativefunction String.prototype.trim`.

## Phase 1: Research prior art (MANDATORY)

Before writing any code, study how existing JS engines implement this function. This is critical — JS semantics are full of subtle edge cases.

1. **Read the ECMAScript spec** — WebSearch for the spec section (e.g. "Array.from ecma262 spec").
2. **Study QuickJS** — Best first reference. Search GitHub for the function name in `quickjs.c`:
   - WebFetch `https://raw.githubusercontent.com/bellard/quickjs/master/quickjs.c` or search GitHub
   - Look for the C implementation, note edge cases, type coercions, error conditions
3. **Cross-reference engine262** — JS engine in JS, maps directly to spec. Search in `engine262/src/`:
   - WebFetch from `https://github.com/engine262/engine262`
4. **Check test262** — Look at existing test cases to understand expected behavior:
   - Search `vendor/test262/test/built-ins/` for the relevant directory

Summarize the key semantics, edge cases, and spec requirements before proceeding.

## Phase 2: Implementation

Touch these files in order:

### 1. `src/arc/vm/value.gleam` — Add variant to the module's NativeFn type

NativeFn is split per-module. Find the right type and add a variant:

| JS Object               | Type in value.gleam                  |
| ----------------------- | ------------------------------------ |
| Array                   | `ArrayNativeFn`                      |
| Object                  | `ObjectNativeFn`                     |
| String                  | `StringNativeFn`                     |
| Number                  | `NumberNativeFn`                     |
| Boolean                 | `BooleanNativeFn`                    |
| Math                    | `MathNativeFn`                       |
| JSON                    | `JsonNativeFn`                       |
| Map/Set/WeakMap/WeakSet | `MapNativeFn` / `SetNativeFn` / etc. |
| RegExp                  | `RegExpNativeFn`                     |
| Error + subtypes        | `ErrorNativeFn`                      |
| Arc (engine-specific)   | `ArcNativeFn`                        |

Naming convention (no `Native` prefix on variants):

```gleam
pub type ArrayNativeFn {
  // ... existing variants ...
  ArrayFrom              // Array.from — static
  ArrayPrototypeMap      // Array.prototype.map — instance
  ArrayConstructor       // Array() / new Array() — constructor
}
```

These are plain tag variants with no GC implications — no other value.gleam changes needed.

**New global (e.g. Date, Proxy)**: create a new `<Name>NativeFn` type, then add a wrapper variant to the top-level `NativeFn` type:

```gleam
pub type NativeFn {
  // ... existing ...
  DateNative(DateNativeFn)
}
```

### 2. `src/arc/vm/builtins/<module>.gleam` — Implement + dispatch

Find or create the module:

| JS Object   | Module                                      |
| ----------- | ------------------------------------------- |
| Array       | `builtins/array.gleam`                      |
| Object      | `builtins/object.gleam`                     |
| String      | `builtins/string.gleam`                     |
| Number      | `builtins/number.gleam`                     |
| Math        | `builtins/math.gleam`                       |
| JSON        | `builtins/json.gleam`                       |
| Map/Set     | `builtins/map.gleam` / `builtins/set.gleam` |
| RegExp      | `builtins/regexp.gleam`                     |
| Error       | `builtins/error.gleam`                      |
| Arc         | `builtins/arc.gleam`                        |
| New globals | **NEW** `builtins/<name>.gleam`             |

#### a) Add to the module's `dispatch` function

Every module has `pub fn dispatch(native, args, this, state)` that routes variants to implementations:

```gleam
pub fn dispatch(
  native: ArrayNativeFn,
  args: List(JsValue),
  this: JsValue,
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  case native {
    // ... existing cases ...
    ArrayPrototypeMap -> array_map(this, args, state)
    ArrayFrom -> array_from(args, state)
  }
}
```

#### b) Implement the function

**Signature**: takes `State`, returns `#(State, Result(JsValue, JsValue))`:

```gleam
fn array_map(
  this: JsValue,
  args: List(JsValue),
  state: State,
) -> #(State, Result(JsValue, JsValue)) {
  use _ref, length, elements, state <- require_array(this, state)
  use cb, this_arg, state <- require_callback(args, state)
  // ... spec steps ...
}
```

Static methods omit `this`; constructors take `args` and return the new instance.

#### c) Wire into `init`

Add to the `common.alloc_methods` list:

```gleam
pub fn init(h: Heap, object_proto: Ref, function_proto: Ref) -> #(Heap, BuiltinType) {
  let #(h, proto_methods) =
    common.alloc_methods(h, function_proto, [
      // ... existing ...
      #("map", ArrayNative(ArrayPrototypeMap), 1),   // name, wrapped variant, .length
    ])
  let #(h, static_methods) =
    common.alloc_methods(h, function_proto, [
      #("from", ArrayNative(ArrayFrom), 1),
    ])
  common.init_type(h, object_proto, function_proto, proto_methods, ..., static_methods)
}
```

### 3. `src/arc/vm/exec/call.gleam` — Wire new module (new globals only)

Skip if adding methods to an existing type. For a **new** global (e.g. Date), add a dispatch case to `dispatch_native`:

```gleam
pub fn dispatch_native(native, args, this, state, ...) {
  case native {
    // ... existing ...
    value.DateNative(n) -> builtins_date.dispatch(n, args, this, state)
  }
}
```

Add the import at the top of call.gleam.

### 4. `src/arc/vm/builtins.gleam` — Register new global (new globals only)

Add import, add field to `Builtins` type, call `<module>.init()` in `builtins.init()`, add to `builtins.globals()`.

### 5. `test/compiler_test.gleam` — Add tests

```gleam
pub fn array_from_basic_test() -> Nil {
  assert_normal("Array.from([1,2,3]).join(',')", JsString("1,2,3"))
}

pub fn array_from_throws_test() -> Nil {
  assert_thrown("Array.from(null)")
}
```

Helpers: `assert_normal(src, expected)`, `assert_normal_number(src, float)`, `assert_thrown(src)`.

## Phase 3: Verify

1. `gleam check` — fast type check
2. `gleam test` — all existing + new tests must pass
3. Report test count

## Key patterns

### State / heap / errors

- Functions thread `State`, not bare `Heap`. Access heap via `state.heap`.
- Update: `State(..state, heap: new_heap)`
- Throw errors: `state.type_error(state, msg)` / `state.range_error(state, msg)` — returns `#(State, Error(err))`
- Lower-level: `common.make_type_error(heap, builtins, msg)` returns `#(Heap, JsValue)`
- Length guards: `use <- state.guard_length(state, length, "Invalid array length")` throws RangeError if length > `limits.max_iteration`

### Re-entering JS from a builtin

Call a JS callback via `state.call` (DI function field on State):

```gleam
use result, state <- state.try_call(state, callback, this_arg, [arg1, arg2])
```

Or lower-level: `case state.call(state, fn_val, this, args) { Ok(#(v, state)) -> ..., Error(#(thrown, state)) -> ... }`

### ToString / coercion

```gleam
use str, state <- state.try_to_string(state, val)     // full ToPrimitive, re-enters VM
helpers.to_number_int(val) |> option.unwrap(0)        // simple Number coercion
```

### Property access

- `object.get_value_of(state, val, key)` — top-level `[[Get]]` for any JsValue (handles primitive→prototype)
- `object.get_value(state, ref, key, receiver)` — `[[Get]]` on a Ref (proto walk + getter invocation)
- `object.set_value(state, ref, key, val, receiver)` — `[[Set]]` (setter invocation + non-writable check)
- `heap.read(h, ref)` / `heap.write(h, ref, slot)` — direct heap slot access

### Allocating

- Arrays: `common.alloc_array(heap, list_of_values, array_proto)` → `#(Heap, Ref)`
- Objects: `heap.alloc(heap, ObjectSlot(kind: OrdinaryObject, properties: dict, elements: elements.new(), prototype: Some(proto), symbol_properties: dict.new(), extensible: True))`
- Native functions: `common.alloc_native_fn(h, function_proto, variant, name, length)`

### JsValue / JsNum

- `JsUndefined`, `JsNull`, `JsBool(Bool)`, `JsNumber(JsNum)`, `JsString(String)`, `JsObject(Ref)`, `JsBigInt(Int)`, `JsSymbol(SymbolId)`
- `JsNum`: `Finite(Float)` | `NaN` | `Infinity` | `NegInfinity` (BEAM can't represent NaN/Inf as native floats)
- Property flags: `value.data_property(v)` (enumerable/writable/configurable true), `value.builtin_property(v)` (non-enumerable)
