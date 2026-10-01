# GOTA

POST `/v1/games/gota/run` to run a ten-player match.

```json
{
  "seed": 2026,
  "roster": [{"player": {"source": "end\n"}}],
  "config": {"max_ticks": 240}
}
```

Replace `end\n` with your bot's BASIC script. This example uses it in all ten
seats. Save the response ZIP for the replay and your bots' logs.

- `slot`: 0–9, or omit it to fill open seats.
- `config.max_ticks`: 1–28800; default 28800.
- BASIC source limit: 64 KiB.
- ZIP limit: 16 MiB. Include exactly one `.bas` file and any bot resources.

See [/docs/llms.txt](/docs/llms.txt) for policy references, ZIP uploads,
batches, response files and errors.
