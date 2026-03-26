/// REPL-runnable demos showcasing Arc's actor model on the BEAM.
/// Each example is a self-contained JS snippet using only blocking
/// primitives (spawn/send/receive/sleep) so it runs in the REPL
/// without the event loop.
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type Example {
  Example(title: String, blurb: String, source: String)
}

pub fn all() -> List(Example) {
  [
    spawn_hello(),
    ping_pong(),
    counter_actor(),
    parallel_map(),
    pubsub(),
    request_reply(),
    worker_pool(),
    ring(),
  ]
}

pub fn get(n: Int) -> Option(Example) {
  all() |> list.drop(n - 1) |> list.first |> option.from_result
}

/// Print the `/examples` menu.
pub fn print_list() -> Nil {
  io.println("")
  io.println("  Arc examples — run one with `/examples <n>`")
  io.println("")
  all()
  |> list.index_fold(Nil, fn(_, ex, i) {
    let num = string.pad_start(int.to_string(i + 1), 2, " ")
    io.println("  " <> num <> ". " <> ex.title <> " — " <> ex.blurb)
  })
  io.println("")
}

/// Print the source of an example before it runs.
pub fn print_source(ex: Example) -> Nil {
  io.println("")
  io.println("── " <> ex.title <> " " <> string.repeat("─", 50))
  io.println(ex.blurb)
  io.println("")
  io.println(ex.source)
  io.println(string.repeat("─", 60))
  io.println("")
}

// -- 1. Spawn & Message ------------------------------------------------------

fn spawn_hello() -> Example {
  Example(
    title: "Spawn & Message",
    blurb: "The hello-world of actors: spawn a process, send it a message.",
    source: "const child = Arc.spawn(() => {
  const msg = Arc.receive();
  Arc.log('[' + Arc.self() + '] got:', msg.greeting);
});

Arc.log('[' + Arc.self() + '] spawned', child);
Arc.send(child, { greeting: 'hello from main!' });
Arc.sleep(50);",
  )
}

// -- 2. Ping Pong ------------------------------------------------------------

fn ping_pong() -> Example {
  Example(
    title: "Ping Pong",
    blurb: "Two processes volleying messages back and forth.",
    source: "const pong = Arc.spawn(() => {
  while (true) {
    const m = Arc.receive();
    if (m === 'stop') return;
    Arc.log('    <- pong', m.n);
    Arc.send(m.from, { n: m.n + 1 });
  }
});

let n = 0;
Arc.send(pong, { n, from: Arc.self() });
while (n < 5) {
  const m = Arc.receive(1000);
  n = m.n;
  Arc.log('ping ->', n);
  Arc.send(pong, { n, from: Arc.self() });
}
Arc.send(pong, 'stop');",
  )
}

// -- 3. Counter Actor --------------------------------------------------------

fn counter_actor() -> Example {
  Example(
    title: "Counter Actor",
    blurb: "A stateful server process — the GenServer pattern in JS.",
    source: "const counter = Arc.spawn(() => {
  let n = 0;
  while (true) {
    const msg = Arc.receive();
    if (msg.op === 'inc') n += msg.by;
    if (msg.op === 'get') Arc.send(msg.from, n);
    if (msg.op === 'stop') return;
  }
});

const me = Arc.self();
Arc.send(counter, { op: 'inc', by: 10 });
Arc.send(counter, { op: 'inc', by: 5 });
Arc.send(counter, { op: 'inc', by: 27 });
Arc.send(counter, { op: 'get', from: me });
Arc.log('counter value:', Arc.receive(1000));
Arc.send(counter, { op: 'stop' });",
  )
}

// -- 4. Parallel Map ---------------------------------------------------------

fn parallel_map() -> Example {
  Example(
    title: "Parallel Map",
    blurb: "Fan-out work to N processes, fan-in the results. True parallelism.",
    source: "const me = Arc.self();
const inputs = [22, 23, 24, 25, 26, 27];

function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

// Fan out: one process per input, each runs on its own BEAM scheduler.
for (const x of inputs) {
  Arc.spawn(() => Arc.send(me, { x, y: fib(x) }));
}

// Fan in: results arrive in completion order, not input order.
for (let i = 0; i < inputs.length; i++) {
  const r = Arc.receive(5000);
  Arc.log('fib(' + r.x + ') =', r.y);
}
Arc.log('done —', inputs.length, 'results computed in parallel');",
  )
}

// -- 5. PubSub ---------------------------------------------------------------

fn pubsub() -> Example {
  Example(
    title: "PubSub",
    blurb: "A broker fanning messages out to many subscribers.",
    source: "const broker = Arc.spawn(() => {
  const subs = [];
  while (true) {
    const m = Arc.receive();
    if (m.sub) { subs.push(m.sub); Arc.log('[broker] +sub, total:', subs.length); }
    if (m.pub) for (const s of subs) Arc.send(s, m.pub);
    if (m.stop) return;
  }
});

// Spawn three subscribers.
for (let i = 1; i <= 3; i++) {
  const pid = Arc.spawn(() => {
    while (true) {
      const m = Arc.receive();
      if (m === 'stop') return;
      Arc.log('  [sub', i + ']', 'received:', m);
    }
  });
  Arc.send(broker, { sub: pid });
}

Arc.sleep(20);
Arc.send(broker, { pub: 'breaking news' });
Arc.send(broker, { pub: 'more news' });
Arc.sleep(50);
Arc.send(broker, { stop: true });",
  )
}

// -- 6. Request/Reply --------------------------------------------------------

fn request_reply() -> Example {
  Example(
    title: "Request/Reply",
    blurb: "Synchronous calls over async messages — the `call` pattern.",
    source: "const server = Arc.spawn(() => {
  const data = { alice: 30, bob: 25, carol: 35 };
  while (true) {
    const m = Arc.receive();
    if (m === 'stop') return;
    Arc.send(m.from, { ref: m.ref, result: data[m.key] });
  }
});

let ref = 0;
function call(key) {
  const myRef = ++ref;
  Arc.send(server, { from: Arc.self(), ref: myRef, key });
  const reply = Arc.receive(1000);
  return reply.result;
}

Arc.log('alice is', call('alice'));
Arc.log('bob is', call('bob'));
Arc.log('carol is', call('carol'));
Arc.send(server, 'stop');",
  )
}

// -- 7. Worker Pool ----------------------------------------------------------

fn worker_pool() -> Example {
  Example(
    title: "Worker Pool",
    blurb: "A pool of workers pulling jobs from a shared queue.",
    source: "const queue = Arc.spawn(() => {
  const jobs = [];
  const waiting = [];
  while (true) {
    const m = Arc.receive();
    if (m.push) {
      if (waiting.length) Arc.send(waiting.shift(), m.push);
      else jobs.push(m.push);
    }
    if (m.pull) {
      if (jobs.length) Arc.send(m.pull, jobs.shift());
      else waiting.push(m.pull);
    }
    if (m.stop) { for (const w of waiting) Arc.send(w, null); return; }
  }
});

// Spawn 3 workers that pull jobs forever.
for (let w = 1; w <= 3; w++) {
  Arc.spawn(() => {
    while (true) {
      Arc.send(queue, { pull: Arc.self() });
      const job = Arc.receive();
      if (job === null) return;
      Arc.sleep(30); // simulate work
      Arc.log('[worker', w + ']', 'finished job', job);
    }
  });
}

// Push 8 jobs — watch them get distributed across workers.
for (let j = 1; j <= 8; j++) Arc.send(queue, { push: j });
Arc.sleep(400);
Arc.send(queue, { stop: true });",
  )
}

// -- 8. Ring -----------------------------------------------------------------

fn ring() -> Example {
  Example(
    title: "Ring Benchmark",
    blurb: "Pass a token around a ring of 500 processes, 10 times.",
    source: "const N = 500, LAPS = 10;
const first = Arc.self();
let prev = first;

for (let i = 0; i < N; i++) {
  const next = prev;
  prev = Arc.spawn(() => {
    while (true) {
      const m = Arc.receive();
      if (m === 'stop') { Arc.send(next, 'stop'); return; }
      Arc.send(next, m + 1);
    }
  });
}

Arc.log('ring of', N, 'processes built, sending token...');
Arc.send(prev, 0);
for (let lap = 1; lap <= LAPS; lap++) {
  const hops = Arc.receive(5000);
  Arc.log('lap', lap, '->', hops, 'hops');
  if (lap < LAPS) Arc.send(prev, 0);
}
Arc.send(prev, 'stop');
Arc.log('total:', N * LAPS, 'message passes');",
  )
}
