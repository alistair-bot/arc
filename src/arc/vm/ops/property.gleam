import arc/vm/ops/coerce
import arc/vm/ops/object
import arc/vm/state.{type State}
import arc/vm/value.{
  type JsValue, type PropertyKey, Finite, Index, JsNumber, JsObject, JsString,
  Named,
}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

// ============================================================================
// Computed property access helpers
// ============================================================================

/// ToPropertyKey (§7.1.19) for non-symbol keys — canonicalizes a JsValue to a
/// PropertyKey ONCE so downstream [[Get]]/[[Set]] don't round-trip through
/// strings. Numbers that are valid array indices → Index(n) (no stringify).
/// Strings go through canonical_key. Everything else → ToString → canonical_key.
pub fn to_property_key(
  state: State,
  key: JsValue,
) -> Result(#(PropertyKey, State), #(JsValue, State)) {
  case key {
    JsNumber(Finite(n)) -> {
      let i = float.truncate(n)
      case int.to_float(i) == n && i >= 0 {
        // Valid array index — skip stringification entirely.
        True -> Ok(#(Index(i), state))
        // Non-index number — stringify (e.g. 1.5 → "1.5", -1 → "-1").
        False -> Ok(#(Named(value.js_format_number(n)), state))
      }
    }
    JsNumber(value.NaN) -> Ok(#(Named("NaN"), state))
    JsNumber(value.Infinity) -> Ok(#(Named("Infinity"), state))
    JsNumber(value.NegInfinity) -> Ok(#(Named("-Infinity"), state))
    JsString(s) -> Ok(#(value.canonical_key(s), state))
    _ -> {
      use #(s, state) <- result.map(coerce.js_to_string(state, key))
      #(value.canonical_key(s), state)
    }
  }
}

/// [[Get]] with a JsValue key — ToPropertyKey (§7.1.19) then delegate to
/// the single [[Get]] implementation. The elements/properties storage split
/// is handled by get_own_property; this layer doesn't know about it.
pub fn get_elem_value(
  state: State,
  ref: value.Ref,
  key: JsValue,
) -> Result(#(JsValue, State), #(JsValue, State)) {
  case key {
    value.JsSymbol(sym_id) ->
      object.get_symbol_value(state, ref, sym_id, JsObject(ref))
    _ -> {
      use #(pk, state) <- result.try(to_property_key(state, key))
      object.get_value(state, ref, pk, JsObject(ref))
    }
  }
}

/// [[Set]] with a JsValue key — ToPropertyKey (§7.1.19) then delegate to
/// the single [[Set]] implementation. set_value handles setter invocation,
/// proto-walk, and element storage for Index keys on arrays.
pub fn put_elem_value(
  state: State,
  ref: value.Ref,
  key: JsValue,
  val: JsValue,
) -> Result(State, #(JsValue, State)) {
  let receiver = JsObject(ref)
  case key {
    value.JsSymbol(sym_id) -> {
      use #(state, _) <- result.map(object.set_symbol_value(
        state,
        ref,
        sym_id,
        val,
        receiver,
      ))
      state
    }
    _ -> {
      use #(pk, state) <- result.try(to_property_key(state, key))
      use #(state, _) <- result.map(object.set_value(
        state,
        ref,
        pk,
        val,
        receiver,
      ))
      state
    }
  }
}

/// ES2024 §6.1.7 — Array Index
pub fn to_array_index(key: JsValue) -> Option(Int) {
  case key {
    // Numeric key: must be a finite, non-negative, integer-valued float.
    JsNumber(Finite(n)) -> {
      let i = float.truncate(n)
      case int.to_float(i) == n && i >= 0 {
        True -> Some(i)
        False -> None
      }
    }
    // String key: parse as integer, must be non-negative.
    JsString(s) ->
      case int.parse(s) {
        Ok(i) if i >= 0 -> Some(i)
        _ -> None
      }
    _ -> None
  }
}
