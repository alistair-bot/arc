import arc/vm/coerce
import arc/vm/frame.{type State, State}
import arc/vm/heap
import arc/vm/js_elements
import arc/vm/object
import arc/vm/value.{
  type JsValue, ArrayObject, Finite, JsNumber, JsObject, JsString, JsUndefined,
  ObjectSlot,
}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

// ============================================================================
// Computed property access helpers
// ============================================================================

/// Read a property from a unified object using a JsValue key.
/// Dispatches on ExoticKind: arrays use elements dict, others use properties.
/// Returns Result to handle thrown exceptions from js_to_string (ToPrimitive).
pub fn get_elem_value(
  state: State,
  ref: value.Ref,
  key: JsValue,
) -> Result(#(JsValue, State), #(JsValue, State)) {
  case key {
    // Symbol keys use the separate symbol_properties dict
    value.JsSymbol(sym_id) ->
      object.get_symbol_value(state, ref, sym_id, JsObject(ref))
    _ -> {
      // Numeric fast path for arrays/arguments
      case to_array_index(key) {
        Some(idx) ->
          case heap.read(state.heap, ref) {
            Some(ObjectSlot(kind: ArrayObject(length:), elements:, ..)) ->
              case idx < length {
                True -> Ok(#(js_elements.get(elements, idx), state))
                False -> Ok(#(JsUndefined, state))
              }
            Some(ObjectSlot(
              kind: value.ArgumentsObject(_),
              elements:,
              prototype:,
              ..,
            )) ->
              case js_elements.get_option(elements, idx) {
                Some(v) -> Ok(#(v, state))
                None ->
                  case prototype {
                    Some(proto_ref) -> get_elem_value(state, proto_ref, key)
                    None -> Ok(#(JsUndefined, state))
                  }
              }
            _ ->
              // Non-array/arguments: delegate to get_value with stringified key
              object.get_value(state, ref, int.to_string(idx), JsObject(ref))
          }
        None -> {
          // Non-numeric key: stringify and delegate to get_value
          use #(key_str, state) <- result.try(coerce.js_to_string(state, key))
          object.get_value(state, ref, key_str, JsObject(ref))
        }
      }
    }
  }
}

/// Write a property to a unified object using a JsValue key.
/// Returns Result to handle thrown exceptions from setter calls / js_to_string.
pub fn put_elem_value(
  state: State,
  ref: value.Ref,
  key: JsValue,
  val: JsValue,
) -> Result(State, #(JsValue, State)) {
  let receiver = JsObject(ref)
  case key {
    // Symbol keys use the separate symbol_properties dict
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
      // Numeric fast path for arrays/arguments (direct element write)
      case to_array_index(key) {
        Some(idx) ->
          case heap.read(state.heap, ref) {
            Some(ObjectSlot(
              kind: ArrayObject(length:),
              properties:,
              elements:,
              prototype:,
              symbol_properties:,
              extensible:,
            )) ->
              case extensible {
                False -> {
                  // Non-extensible (frozen/sealed): delegate to set_value which
                  // properly checks writable/configurable/extensible constraints.
                  use #(state, _) <- result.map(object.set_value(
                    state,
                    ref,
                    int.to_string(idx),
                    val,
                    receiver,
                  ))
                  state
                }
                True -> {
                  let new_elements = js_elements.set(elements, idx, val)
                  let new_length = case idx >= length {
                    True -> idx + 1
                    False -> length
                  }
                  let new_heap =
                    heap.write(
                      state.heap,
                      ref,
                      ObjectSlot(
                        kind: ArrayObject(new_length),
                        properties:,
                        elements: new_elements,
                        prototype:,
                        symbol_properties:,
                        extensible:,
                      ),
                    )
                  Ok(State(..state, heap: new_heap))
                }
              }
            Some(ObjectSlot(
              kind: value.ArgumentsObject(_) as args_kind,
              properties:,
              elements:,
              prototype:,
              symbol_properties:,
              extensible:,
            )) -> {
              let new_heap =
                heap.write(
                  state.heap,
                  ref,
                  ObjectSlot(
                    kind: args_kind,
                    properties:,
                    elements: js_elements.set(elements, idx, val),
                    prototype:,
                    symbol_properties:,
                    extensible:,
                  ),
                )
              Ok(State(..state, heap: new_heap))
            }
            _ -> {
              // Non-array/arguments: delegate to set_value
              use #(state, _) <- result.map(object.set_value(
                state,
                ref,
                int.to_string(idx),
                val,
                receiver,
              ))
              state
            }
          }
        None -> {
          // Non-numeric key: stringify and delegate to set_value
          use #(key_str, state) <- result.try(coerce.js_to_string(state, key))
          use #(state, _) <- result.map(object.set_value(
            state,
            ref,
            key_str,
            val,
            receiver,
          ))
          state
        }
      }
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
