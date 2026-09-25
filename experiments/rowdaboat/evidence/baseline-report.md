# Hosted baseline evidence audit

XP: `xreq_0ad92adc-2c3b-44e3-a1f2-7fcd0fa5805d`. [Hosted source](https://softmax.com/api/observatory/v2/experience-requests/xreq_0ad92adc-2c3b-44e3-a1f2-7fcd0fa5805d).

Source snapshot: `research/baseline-xp-status.json`. Coworld `cow_e282a46f-31c4-43b1-a9e2-aaa31d3aaed4`, version `2026.9.24.2`.

Validation: PASS. Ten completed children; own policy `ab664012-84b3-48b3-ae1b-86f3f6cf960c` once per episode; three seats each for the pinned live policies below; our rotations cover seats 0–9 once each. These statements are verified only when validation passes.

- Own zero-score episodes: 10 of 10.
- Missing or invalid hosted score values: 0.
- Hosted child errors: 0.
- Validation errors: 0; children with validation errors: 0.

Hosted own-policy logs: 10 contain only the expected seat-started and seat-completed messages; 0 missing; 0 have unexpected diagnostics or missing lifecycle messages. No source compile/runtime diagnostics appeared in the verified logs. Raw logs are under `research/baseline-own-logs/`; exact API sources are in the JSON sidecar.

All values below come directly from hosted experience responses. Opponent values are the website's policy-level scores for their three seats. No scores are generated from replays, and no between-episode mean, comparison of means, or significance claim is made. This initial baseline alone cannot establish an improvement.

| Job | Our seat | RowDaBoat v1 | khors v208 | arisk v4 | richard v245 |
| --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0.0 | 1061.0 | 2538.3333333333335 | 132.0 |
| 1 | 1 | 0.0 | 0.0 | 3287.6666666666665 | 673.6666666666666 |
| 2 | 2 | 0.0 | 2933.3333333333335 | 98.66666666666667 | 322.3333333333333 |
| 3 | 3 | 0.0 | 2201.6666666666665 | 0.0 | 1816.3333333333333 |
| 4 | 4 | 0.0 | 3389.3333333333335 | 518.0 | 0.0 |
| 5 | 5 | 0.0 | 828.0 | 1256.0 | 668.3333333333334 |
| 6 | 6 | 0.0 | 531.6666666666666 | 27.0 | 2175.3333333333335 |
| 7 | 7 | 0.0 | 1326.3333333333333 | 225.33333333333334 | 1830.0 |
| 8 | 8 | 0.0 | 2477.0 | 454.3333333333333 | 0.0 |
| 9 | 9 | 0.0 | 2359.3333333333335 | 1930.3333333333333 | 0.0 |

Pinned policy versions:

- `rowdaboat-gods-of-the-arena:v1`: `ab664012-84b3-48b3-ae1b-86f3f6cf960c`.
- `khors:v208`: `bf6c6cc2-362e-4eee-a105-810b23adf437`.
- `arisk-gods-of-the-arena:v4`: `61f4440b-140d-4f7d-80b8-2802f7a3100d`.
- `richard-gods-of-the-arena:v245`: `7fd19643-c66a-429e-ba24-3c1e6c0d8e06`.

Source IDs:

| Job | Child request ID | Recorded episode ID | Hosted job ID |
| --- | --- | --- | --- |
| 0 | `ereq_c9e9fc33-09b3-4c21-8241-11afc6cc0490` | `88b0584c-a256-4fbf-acba-38137f2affd7` | `88078960-a20c-4eda-b0cf-4a8e4753086f` |
| 1 | `ereq_7428093d-8c53-4bda-a7bf-3c35e9c4d8aa` | `7703fed1-20f7-4f9f-b35c-02ce53e3ace3` | `07cda9d9-3720-4a7e-b392-6846a2987d3d` |
| 2 | `ereq_ade4b793-d0be-4a97-b1b0-fe84653a8b4a` | `d9210e12-e883-4b5a-ada5-bd901e9cdd52` | `b3699821-86d1-489f-a514-360272983844` |
| 3 | `ereq_0353f362-6698-4246-b6de-d97a0feecaff` | `d053006f-e41e-4382-bcf7-6e39b6c36014` | `ea026690-8dcf-4790-a200-e238ec290cdd` |
| 4 | `ereq_fe9793da-26b8-48ae-bbf0-49f03d26bc02` | `884fc79d-edef-48f7-b3a9-9c50f564cff7` | `c3844cd5-ff81-4ae0-a279-bd25026b83c9` |
| 5 | `ereq_ec2ef1fb-bf7e-47dd-b91b-d24f22fdaecc` | `da22e716-8257-4ecc-bb70-812403bfe659` | `0506c2f1-166e-476c-b5f3-251bd0436634` |
| 6 | `ereq_f9a0412d-c3d2-421f-aebb-247be6cf7316` | `d838f251-09e9-4354-97e4-5e6114d5ce24` | `ac9221b5-fd02-4be4-9793-395e7b7778f1` |
| 7 | `ereq_d9a92d2a-daf0-4a10-a750-dafceb527649` | `b43dd5ab-94a0-476e-bdc0-f03f924512e0` | `908ffbc1-dcbf-4dd9-b8af-dafeedf1b001` |
| 8 | `ereq_75018035-493f-4bcc-ba87-e7adb4056e44` | `f2f2d7be-f0ad-4fe3-b3d4-c8910c1179af` | `903ed3be-b285-45e1-bae0-57273c9ffbd2` |
| 9 | `ereq_a4d3212a-9dd0-4357-bb97-fbcf5f0e5782` | `c6f35078-738e-4f69-bf57-03d0d675b3be` | `b0d82a64-4a6c-4156-9cb0-ca656c5ac6b5` |

Sanitized machine-readable scores and exact seat-level values: `research/baseline-report.json`.

## First hosted replay: execution evidence only

Hosted job `88078960-a20c-4eda-b0cf-4a8e4753086f`, our seat 0. Replayed only recorded hosted actions; 28909 tick hashes verified with 0 mismatches. This proves the trace reconstructed the hosted game; it is not a new local scoring run.

The policy drafted VanguardKnight, issued 8 ability-level actions, 165 attack-target actions, 298 attack-move actions, 115 targeted/point casts, 32 purchase actions, and 6 portal-use actions. End state: level 8, deaths 6, lifetime XP 2555, inventory `[RangerBoots, NoItem, NoItem, NoItem, NoItem, NoItem]`. These are replay diagnostics, separate from the hosted score table.

Purchases and navigation show repeated recovery/shop travel and consumable spending, with RangerBoots the only permanent item remaining at the end. This identifies an economy/navigation hypothesis for comparison with top-player replays; it does not establish that a change would improve hosted performance. Raw action/event streams and the complete summary are saved beside `research/baseline-replay-00.summary.json`.
