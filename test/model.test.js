// Tests for Model.js, run with: node --test test/
//
// Model.js is a QML `.pragma library` script, not a CommonJS module, so it is
// evaluated in a fresh context with the pragma line dropped; its top-level
// functions land on that context.
"use strict"
// The autumn-DST case only means something where the machine's own zone has
// that repeated hour; pin it so the test bites on any machine.
process.env.TZ = "Europe/Stockholm"
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = vm.createContext({})
vm.runInContext(source, M)

const at = text => M.parseNaive(text)
const NOW = at("2026-11-12T10:00:00")

test("minutes are floored, as SL counts them", () => {
  assert.equal(M.departureMinutes({ expected: "2026-11-12T10:00:40" }, NOW), 0)
  assert.equal(M.departureMinutes({ expected: "2026-11-12T10:04:40" }, NOW), 4)
  assert.equal(M.toRows([{ expected: "2026-11-12T10:00:40" }], NOW)[0].minutesText, "now")
})

test("a stale board drops departures more than a minute gone", () => {
  const later = NOW + 40 * 60000
  const rows = M.toRows([
    { expected: "2026-11-12T10:02:00", line: { designation: "17" } },
    { expected: "2026-11-12T10:39:30", line: { designation: "18" } },
    { expected: "2026-11-12T10:41:30", line: { designation: "19" } }
  ], later)
  assert.deepEqual(Array.from(rows, r => [r.line, r.minutesText]), [["18", "now"], ["19", "1"]])
})

test("a null deviation entry does not throw", () => {
  const rows = M.toRows([{ expected: "2026-11-12T10:05:00", deviations: [null] }], NOW)
  assert.equal(rows.length, 1)
  assert.equal(rows[0].cancelled, false)
})

test("a platform or destination change counts as a different board", () => {
  const row = (berth, destination) => M.toRows([{
    expected: "2026-11-12T10:05:00", scheduled: "2026-11-12T10:05:00",
    journey: { id: 1 }, stop_point: { designation: berth }, destination: destination
  }], NOW)
  assert.equal(M.sameRows(row("1", "A"), row("1", "A")), true)
  assert.equal(M.sameRows(row("1", "A"), row("7", "A")), false)
  assert.equal(M.sameRows(row("1", "A"), row("1", "B")), false)
})

test("the clock anchor survives the repeated autumn hour", () => {
  // 02:30 on the second pass through the hour (01:30 UTC on 2026-10-25).
  const realNow = Date.UTC(2026, 9, 25, 1, 30)
  const payload = [
    { display: "10 min", expected: "2026-10-25T02:40:00" },
    { expected: "2026-10-25T03:05:00" }
  ]
  const offset = M.clockOffset(payload, realNow)
  assert.ok(M.saneClockOffset(offset))
  assert.equal(M.departureMinutes(payload[1], realNow + offset), 35)
})

test("folding matches the picker's keyboard", () => {
  assert.equal(M.fold("Södermalm"), "sodermalm")
  assert.equal(M.fold("Södermalm"), "sodermalm")  // decomposed ö
  assert.equal(M.fold("Ørestad"), "orestad")
  assert.equal(M.fold("Æble"), "aeble")
  assert.equal(M.fold("Straße"), "strasse")
})

test("the HTTP status line is read and stripped", () => {
  const now = Date.UTC(2026, 10, 12, 10, 0)
  assert.deepEqual({ ...M.parseHttpStatus("curl: (22) The requested URL returned error: 429\nSLHTTP 429 300\n", now) },
    { code: 429, retryAfterMs: 300000 })
  assert.equal(M.parseHttpStatus("SLHTTP 429 " + new Date(now + 120000).toUTCString(), now).retryAfterMs, 120000)
  assert.equal(M.parseHttpStatus("SLHTTP 429 999999", now).retryAfterMs, M.RETRY_AFTER_CAP_MS)
  assert.equal(M.parseHttpStatus("SLHTTP 429 soon", now).retryAfterMs, 0)
  assert.equal(M.parseHttpStatus("SLHTTP 200 \n", now).code, 200)
  assert.equal(M.parseHttpStatus("curl: (6) Could not resolve host\nSLHTTP 000 \n", now).code, 0)
  assert.equal(M.parseHttpStatus("", now).code, 0)
  assert.equal(M.stripHttpStatus("curl: (22) The requested URL returned error: 503\nSLHTTP 503 \n"),
    "curl: (22) The requested URL returned error: 503")
  assert.equal(M.stripHttpStatus("SLHTTP 200 \n"), "")
})
