# Agent Visualization Eval Fixtures

This directory contains deterministic e2e fixtures for Donkey's agent action
visualization layer. These cases validate the feedback-loop shape without
launching real apps or moving the real macOS pointer.

Each fixture declares an exact normalized cursor path. The runner samples the
overlay path on a fixed test screen, verifies every arrival lands on the
expected point, and checks each midpoint is actually in flight between points.

Run the simulator suite:

```bash
python3 scripts/evals/run_agent_visualization_e2e.py --dry-run
```

The runner writes `agent-visualization.latest-report.json` as a generated local
artifact. Source fixtures live in `agent-visualization.jsonl`.
