# Command Center v2.3 dependency regression

Reduced from the 2026-11-23 split design and observer findings 1 and 5:21 PM.
M02's web extraction cannot block host/deploy work. The per-slot lock integration
belongs to both deploy milestones and must be serialized before acceptance.

## Implementation Sequence
1. Web shared extraction.
2. Host slots and deploy.
3. Gate selection and per-slot locks.

## Milestone Surfaces
| milestone-id | write-surface | provides | consumes | design-source |
| --- | --- | --- | --- | --- |
| M01 | web/src/** | module:shared | - | v23 M2 shared extraction |
| M02 | host/**; deploy/deploy.py; deploy/target_lock.py | config:slot_lock | - | v23 M4 host slots and deploy |
| M03 | deploy/suites.py; deploy/release.py; deploy/target_lock.py | module:gates | config:slot_lock | v23 M5 gate selection plus 5:21 PM lock integration |

## Throughput and hardware
Fixture host: isolated temp roots, two suite processes, 512 MiB budget per process.
| milestone-id | dependencies | execution | test-execution |
| --- | --- | --- | --- |
| M01 | - | parallel | parallel: isolated fixture |
| M02 | M01 | parallel | parallel: isolated fixture |
| M03 | M01 | parallel | parallel: isolated fixture |

## Validation Gates
- M01: `node --test tests/web.js`
- M02: `python -m pytest tests/host.py`
- M03: `python -m pytest tests/deploy.py`
