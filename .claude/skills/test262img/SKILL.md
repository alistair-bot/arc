---
name: test262img
description: Run the full test262 execution suite and regenerate the conformance chart.
disable-model-invocation: true
---

# /test262img — Run test262 exec suite & regenerate chart

Run the full test262 execution conformance suite and regenerate the conformance chart image.

## Steps

1. **Run the full test262 execution suite** with results output:

   ```sh
   TEST262_EXEC=1 RESULTS_FILE=.github/test262/results.json gleam test
   ```

   This runs all ~53K test262 tests through the full parse → compile → execute pipeline. Takes ~80 seconds locally, ~10 minutes on CI.

   Other useful env vars:
   - `TEST262_FILTER=path/substring` — run only tests whose path contains the substring (e.g. `TEST262_FILTER=Array/prototype/map`)
   - `FAIL_LOG=/tmp/fails.tsv` — write per-test failure reasons (tab-separated path + reason) for bucketing with `cut -f2 | sort | uniq -c | sort -rn`
   - `UPDATE_SNAPSHOT=1` — update the pass/fail snapshot file

2. **Read the results** from `.github/test262/results.json` and report the pass/fail/skip numbers to the user.

3. **Regenerate the conformance chart** by running:

   ```sh
   python3 .github/scripts/generate_chart.py --add-result .github/test262/results.json
   ```

   This appends today's result to `.github/test262/history.json` and regenerates `.github/test262/conformance.png`.

4. **Show the updated chart** by reading the generated PNG file at `.github/test262/conformance.png`.

5. **Report a summary** to the user with:
   - Pass / fail / skip counts
   - Conformance percentage
   - Whether the percentage changed from the previous run (check history.json)
