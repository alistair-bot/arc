-module(arc_console_ffi).
-export([monotonic_ms/0]).

monotonic_ms() ->
    erlang:monotonic_time(millisecond) * 1.0.
