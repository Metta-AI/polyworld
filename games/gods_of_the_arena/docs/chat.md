# Human match chat

Human controllers press **Enter** to open all-chat, **Shift+Enter** to open team-chat, **Enter** to send, or **Esc** to cancel. Backspace removes one UTF-8 codepoint. Empty/whitespace-only messages are ignored. Messages are limited to 1024 UTF-8 bytes; invalid UTF-8, control characters, surrogate/noncharacter values and bidi override/isolate controls are rejected. Canvas text is literal, not HTML.

Chat captures match keyboard input and suppresses polled orders, HUD key aliases, selection, attack/ability activation and camera controls until the closing frame finishes. Silky settings/lobby input retains its own callback focus. The match restores its rune callback on exit.

## Routing

The shared relay has no chat opcode: `SubmitCommand` carries opaque game bytes. GotA network protocol **2** adds category **2** using the same game-owned string envelope as category **1** policy mailboxes (`heroId`, scope, length-prefixed UTF-8). Scope is -2 for all, -1 for team. Categories 0 (actions) and 1 (bot mailboxes) retain their existing layouts and behavior.

Only an authoritative TickPacket creates visible messages; no optimistic echo. Relay seat ownership and game hero/seat/type validation prevent spectators, foreign seats and bot-only controllers from speaking as a human. Display names come from the prepared exact human identity, e.g. `mason :)`, not parsed policy names. Human messages never enter policy inboxes. The bounded independent display history retains 100 messages and renders its latest six; team messages are filtered for human viewers, while omniscient spectators may view both teams. As with every opaque command, team text is present in all authoritative packets: this is a display scope, not encryption/private transport.

## Replay limitations

Buffered spectator packet history includes chat and deduplicates display entries on rewind. GotA exported replays are action-only tapes with fixed numeric payloads: neither the existing policy mailbox nor human text can be serialized by that format. Exported replay files therefore do **not** retain chat. No shared replay format, server opcode or gameplay hash was changed to pretend otherwise.

## Tests

- `nim c -r games/gods_of_the_arena/tests/tests.nim` includes editing/Unicode bounds, history, binary two-human RoomClient/Relay delivery with exact names/text, default-all and team display filtering, ownership/spectator rejection, policy preservation and source-route integration guards.
- `nim c -r -d:silkyTesting games/gods_of_the_arena/tests/test_human_chat_input.nim` exercises actual callback chaining/restoration, rune activation, consumed typing keys and Silky focused-field coexistence.
- `nim check games/gods_of_the_arena/graphics.nim` checks the integrated renderer.

These tests are native/in-process; browser acceptance requires a later authorized WASM build. Protocol-1 and protocol-2 clients cannot join the same exact-version room.
