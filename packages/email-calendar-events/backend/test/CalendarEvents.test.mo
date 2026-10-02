import { test } "mo:test";
import CalendarEvents "../src/calendarEvents";

let organizer = { name = ?"Chair" };
let alice = { who = { email = "alice@example.com"; name = ?"Alice" }; role = #required };
let bob = { who = { email = "bob@example.com"; name = null }; role = #optional };

func withEvent() : CalendarEvents.State {
  let state = CalendarEvents.new();
  ignore CalendarEvents.add(state, "evt-1", "Planning", "Agenda", "Room 1", 1_000, 2_000, organizer, [alice]);
  state;
};

test("cancel returns the stored record: method cancel and the next sequence", func() {
  let state = withEvent();
  let ?cancelled = CalendarEvents.cancel(state, "evt-1") else { assert false; return };
  assert cancelled.method == #cancel;
  assert cancelled.sequence == 1;
  assert CalendarEvents.get(state, "evt-1") == ?cancelled;
});

test("update returns the stored record with the new fields and sequence", func() {
  let state = withEvent();
  let ?updated = CalendarEvents.update(state, "evt-1", ?"Replanning", null, null, null, ?3_000, null, null) else { assert false; return };
  assert updated.summary == "Replanning";
  assert updated.description == "Agenda";
  assert updated.endTime == 3_000;
  assert updated.sequence == 1;
  assert CalendarEvents.get(state, "evt-1") == ?updated;
});

test("adding and removing attendees return the stored record", func() {
  let state = withEvent();
  let ?added = CalendarEvents.addAttendees(state, "evt-1", [bob]) else { assert false; return };
  assert added.attendees == [alice, bob];
  assert added.sequence == 1;
  let ?removed = CalendarEvents.removeAttendees(state, "evt-1", ["alice@example.com"]) else { assert false; return };
  assert removed.attendees == [bob];
  assert removed.sequence == 2;
  assert CalendarEvents.get(state, "evt-1") == ?removed;
});

test("an unknown uid changes nothing and returns null", func() {
  let state = withEvent();
  assert CalendarEvents.cancel(state, "missing") == null;
  assert CalendarEvents.addAttendees(state, "missing", [bob]) == null;
  let ?unchanged = CalendarEvents.get(state, "evt-1") else { assert false; return };
  assert unchanged.sequence == 0;
});

test("hostOf keeps the host of the frontend URL: no scheme, port or path", func() {
  assert CalendarEvents.hostOf("https://my-app.caffeine.xyz") == "my-app.caffeine.xyz";
  assert CalendarEvents.hostOf("https://my-app.caffeine.xyz/") == "my-app.caffeine.xyz";
  assert CalendarEvents.hostOf("http://localhost:3000/events") == "localhost";
  assert CalendarEvents.hostOf("my-app.caffeine.xyz") == "my-app.caffeine.xyz";
});
