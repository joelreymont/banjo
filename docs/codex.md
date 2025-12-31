# Codex CLI + App-Server Notes

## CLI Highlights (from `codex --help`)

- `-i, --image <FILE>...` attaches one or more images to the initial prompt.
- `-m, --model <MODEL>` selects the model.
- `-a, --ask-for-approval <APPROVAL_POLICY>` controls approval flow.
- `-s, --sandbox <SANDBOX_MODE>` selects sandbox policy.
- `--search` enables web search tool.
- `-C, --cd <DIR>` sets working directory.
- `--add-dir <DIR>` adds writable directories.

## App-Server Protocol (schema-generated)

`codex app-server generate-json-schema --out <dir>` exposes the protocol.
In `v2/TurnStartParams.json`, `input` supports the following `UserInput` variants:

- `{"type":"text","text":"..."}`
- `{"type":"image","url":"..."}` (data URL)
- `{"type":"localImage","path":"/absolute/path/to/file"}`

No audio input variant appears in the schema.

## Turn Completion Errors

`turn/completed` can include a `turn.error` object:

```json
{
  "method": "turn/completed",
  "params": {
    "turn": {
      "id": "turn_1",
      "status": "completed",
      "error": { "code": "max_turns", "message": "Max turns reached", "type": "max_turns" }
    }
  }
}
```

Banjo inspects `turn.error` for max-turn markers and, when Dots reports pending
tasks via `dot ls --json`, automatically sends a follow-up `continue` turn.

## Implications for Banjo

- Codex app-server can accept images directly (URL or local path).
- ACP `image` blocks could map to `localImage` if a file path exists, or `image` with a data URL.
- ACP `audio` blocks have no Codex app-server mapping today.

## Sources

- Codex CLI README: https://github.com/openai/codex
- Local CLI: `codex --help`
- Local schema: `codex app-server generate-json-schema --out /tmp/codex-app-schema`
