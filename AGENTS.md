# SketchCam Agent Notes

## Atomic Human-In-The-Loop

When the user invokes `atomic-human-in-the-loop` or `human assist mode`, use the local skill at `/Users/liuboto/.agents/skills/atomic-human-in-the-loop/SKILL.md`.

- Keep changes atomic and focused.
- Do not run build, test, install, or app-launch commands unless explicitly requested.
- Prefer one visual or behavioral fix per turn.
- End with what changed and the exact behavior the user should manually test.
