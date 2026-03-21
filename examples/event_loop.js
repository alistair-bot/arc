// Two async functions running concurrently in the same process.
// `await Arc.receiveAsync()` suspends *only this function* — the other
// one keeps ticking. The BEAM mailbox wakes whoever is waiting.
//
// Run with:  gleam run -- --event-loop examples/event_loop.js

var self = Arc.self();

async function waiter() {
	Arc.log('waiter: awaiting message...');
	var msg = await Arc.receiveAsync();
	Arc.log('waiter: got', msg);
}

async function ticker() {
	for (var i = 1; i <= 3; i++) {
		await new Promise((r) => Arc.setTimeout(r, 100));
		Arc.log('ticker:', i);
	}
}

waiter();
ticker();

// Send from another process, partway through the ticks.
Arc.spawn(() => {
	Arc.sleep(250);
	Arc.send(self, 'hello');
});

// Expected output:
//   waiter: awaiting message...
//   ticker: 1
//   ticker: 2
//   waiter: got hello
//   ticker: 3
