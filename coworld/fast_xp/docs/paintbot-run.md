# Paintbot

POST `/v1/games/paintbot-pw/run` to run a 16-player match.

```json
{
  "seed": 2026,
  "roster": [{"player": {"source": "end\n"}}],
  "config": {"max_ticks": 240}
}
```

Replace `end\n` with your bot's BASIC script. This example uses it in all 16
seats. Save the response ZIP for the replay and your bots' logs.

- `slot`: 0–15. Even seats are red; odd seats are blue.
- `config.max_ticks`: 1–28800; default 14400.
- Matches use the default map and game settings. External LLM calls are unavailable.
- BASIC source limit: 128 KiB.

For `package_base64`, upload the ZIP you submit to Paintbot. It must contain
exactly `manifest.json`, `policy.bas` and `model.bin`. Supported manifest schemas
are `paintbot-neural-basic/1` and `paintbot-neural-basic/2`.

Limits: 128 KiB BASIC source, 16 MiB model, 8 KiB manifest, and 16920576 bytes for
the complete ZIP before base64 encoding.

See [/docs/llms.txt](/docs/llms.txt) for policy references, ZIP uploads,
batches, response files and errors.
