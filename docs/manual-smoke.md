# Manual smoke checklist (before release)

Run with real MIDI gear, or loopback sources (e.g. configure one hardware
controller plus IAC-style loopback software ports).

1. Launch app: menu-bar icon appears, no Dock icon.
2. Router window shows every current source/destination; missing gear shows a
   gray connected-dot.
3. Cell → "all channels": keys play on destination immediately.
4. Cell → "ch 5": ch-1 notes do NOT reach the destination, ch-5 notes do, and
   MIDI clock still flows (system messages always pass).
5. One source → two destinations: both get traffic.
   Two sources → one destination: merged, no drops.
6. Popover toggle OFF kills that route instantly; ON restores it.
7. Unplug a device: route stays listed, dot goes gray, no error spam.
   Re-plug: auto-reconnects, dot green, traffic resumes.
8. Rearrange ports (change USB order / different port index): routing is
   unchanged — because it is name-based.
9. Save preset "gig", change routes, load "gig": exactly the saved routes come
   back (current enabled flags kept). Delete removes it.
10. Relaunch: last configuration restored automatically without any manual save.
11. Duplicate port names show the ⚠️ warning banner.
12. Send a MIDI controller with SYSEX or continued fragments routed through the engine — verify multi-packet read-walk doesn't drop or corrupt bytes (Task 7 watch-item).
13. Route a source to a destination and send bulk sysex (KB sysex dump) — verify no stack/smashing or lost bytes on the send side (Task 7 watch-item).
14. Kill the app while routes exist; relaunch: routes auto-reconnect from gear without touching UI (spec cold-start path).
