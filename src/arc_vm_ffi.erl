-module(arc_vm_ffi).
-export([read_line/1]).
-export([array_get/2, array_set/3, array_repeat/2, array_grow/3]).
-export([tree_array_new/1, tree_array_from_list/2, tree_array_to_list/1,
         tree_array_get/2, tree_array_get_option/2, tree_array_set/3,
         tree_array_size/1, tree_array_resize/2]).
-export([send_message/2, receive_message_infinite/0, receive_message_timeout/1, pid_to_string/1]).
-export([receive_any_event/0, receive_settle_only/0, send_after/3, cancel_timer/1]).
-export([receive_user_message/0, receive_user_message_timeout/1]).
-export([get_script_args/0, sleep/1]).

read_line(Prompt) ->
    case io:get_line(Prompt) of
        eof -> {error, nil};
        {error, _} -> {error, nil};
        Line -> {ok, Line}
    end.

%% Array (tuple-backed) operations
array_get(Index, Tuple) ->
    case Index >= 0 andalso Index < tuple_size(Tuple) of
        true -> {some, element(Index + 1, Tuple)};
        false -> none
    end.
array_set(Index, Value, Tuple) ->
    case Index >= 0 andalso Index < tuple_size(Tuple) of
        true -> {ok, setelement(Index + 1, Tuple, Value)};
        false -> {error, nil}
    end.
%% Cap tuple-backed arrays at 10M elements (~80MB on 64-bit).
%% JS specs allow arrays up to 2^32-1 but we use a sparse dict for those.
%% Keep in sync with limits.max_iteration in src/arc/vm/limits.gleam.
-define(MAX_DENSE_ELEMENTS, 10000000).

array_repeat(Value, Count) when Count =< ?MAX_DENSE_ELEMENTS ->
    erlang:make_tuple(Count, Value);
array_repeat(_Value, _Count) ->
    erlang:error(array_too_large).

%% Grow a tuple to NewSize, filling new slots with Default.
%% If NewSize =< current size, returns Tuple unchanged.
%% O(NewSize) — converts to list, pads, converts back. No repeated setelement.
array_grow(Tuple, NewSize, Default) when NewSize =< ?MAX_DENSE_ELEMENTS ->
    Old = tuple_size(Tuple),
    case NewSize =< Old of
        true -> Tuple;
        false ->
            Pad = lists:duplicate(NewSize - Old, Default),
            list_to_tuple(tuple_to_list(Tuple) ++ Pad)
    end;
array_grow(_Tuple, _NewSize, _Default) ->
    erlang:error(array_too_large).

%% Erlang's array module — O(log n) functional array for JS elements.
%% Default is the caller-provided JsUndefined so unset slots and to_list
%% both return valid JsValues (no atom sentinel leaks into Gleam).
tree_array_new(Default) ->
    array:new({default, Default}).
tree_array_from_list(List, Default) ->
    array:from_list(List, Default).
tree_array_to_list(A) ->
    array:to_list(A).
tree_array_get(Index, A) when Index >= 0 ->
    array:get(Index, A);
tree_array_get(_Index, A) ->
    array:default(A).
%% DenseElements has no holes by design (delete promotes to sparse), so
%% "in bounds" = "has value". Out-of-bounds or negative index = none.
tree_array_get_option(Index, A) when Index >= 0 ->
    case Index < array:size(A) of
        true -> {some, array:get(Index, A)};
        false -> none
    end;
tree_array_get_option(_Index, _A) ->
    none.
tree_array_set(Index, Value, A) when Index >= 0, Index < ?MAX_DENSE_ELEMENTS ->
    array:set(Index, Value, A);
tree_array_set(_Index, _Value, A) ->
    A.
tree_array_size(A) ->
    array:size(A).
tree_array_resize(A, NewSize) when NewSize >= 0 ->
    array:resize(NewSize, A);
tree_array_resize(A, _NewSize) ->
    A.

%% Process primitives for Arc.send/receive
send_message(Pid, Msg) -> Pid ! Msg, nil.
receive_message_infinite() ->
    receive Msg -> Msg end.
receive_message_timeout(Timeout) ->
    receive Msg -> {ok, Msg}
    after Timeout -> {error, nil}
    end.
pid_to_string(Pid) -> list_to_binary(pid_to_list(Pid)).
get_script_args() -> [list_to_binary(A) || A <- init:get_plain_arguments()].
sleep(Ms) -> timer:sleep(Ms), nil.

%% Selective receive for the event loop. Gleam MailboxEvent variants compile to
%% tagged tuples: UserMessage(pm) = {user_message, Pm},
%% SettlePromise(ref, outcome) = {settle_promise, Ref, Outcome}.
%%
%% When the event loop has pending receivers it accepts any event. Otherwise it
%% only accepts settle_promise, leaving user_message in the mailbox for blocking
%% Arc.receive() or a future receiveAsync() call to pick up.
receive_any_event() ->
    receive
        {user_message, _} = E -> E;
        {settle_promise, _, _} = E -> E;
        {receiver_timeout, _} = E -> E
    end.
receive_settle_only() ->
    receive
        {settle_promise, _, _} = E -> E;
        {receiver_timeout, _} = E -> E
    end.

%% Selective receive for Arc.receive() — only matches user_message, leaves
%% settle_promise in the mailbox for the event loop.
receive_user_message() ->
    receive
        {user_message, Pm} -> Pm
    end.
receive_user_message_timeout(Timeout) ->
    receive
        {user_message, Pm} -> {ok, Pm}
    after Timeout -> {error, nil}
    end.

send_after(Ms, Pid, Msg) ->
    erlang:send_after(Ms, Pid, Msg).

%% Returns true if the timer was still active (cancelled successfully),
%% false if it had already fired.
cancel_timer(TRef) ->
    case erlang:cancel_timer(TRef) of
        false -> false;
        _TimeLeft -> true
    end.
