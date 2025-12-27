# Banjo Demo Skill

Run and debug the banjo LSP demo in Zed.

## Triggers

Use this skill when the user says:
- **"run demo"** or **"run banjo demo"** - Run the full demo
- **"record demo"** - Run demo with screen recording enabled

## Behavior

When running the demo:
1. Run the demo command and capture ALL output
2. Analyze the output for failures
3. If failures found:
   - Identify the root cause
   - Read the relevant demo script sections
   - Propose or apply fixes
4. Report results to user

**Do NOT auto-loop or re-run.** The demo controls the active window and types keystrokes - only run when explicitly requested.

## Demo Location

- Demo script: `../hemis-demo/scripts/banjo.demo`
- Banjo library: `../hemis-demo/scripts/lib/banjo.demo`
- Common library: `../hemis-demo/scripts/lib/common.demo`

## Commands

### Run Demo (with verification)
```bash
cd ../hemis-demo && swift run hemis-demo banjo --editor zed --verify
```

### Run Demo (with recording)
```bash
cd ../hemis-demo && swift run hemis-demo banjo --editor zed --record
```

### Dry Run (dump IR without executing)
```bash
cd ../hemis-demo && swift run hemis-demo banjo --editor zed --dump-ir
```

## Log Analysis

hemis-demo outputs to stdout/stderr. Key patterns to look for:

### Assertion Failures
```
[✗] FAIL: <assertion description>
```
Action: Check the assertion in banjo.demo, verify expected state matches actual behavior.

### Keystroke Errors
```
[keystroke] Failed to create...
[keystroke] Warning: Unknown special key
```
Action: Check key notation in lib/banjo.demo or lib/common.demo.

### LSP/Diagnostic Issues
```
No diagnostics found
Expected cursor at line X, got Y
```
Action: Check banjo LSP is running, verify notes.db was seeded correctly.

### Setup Failures
```
[setup] Warning: could not launch
[window] ... (unavailable)
```
Action: Check Zed is installed, accessibility permissions granted.

## Debugging Steps

1. **Run with --dump-ir** to verify script compiles correctly
2. **Check global-setup** ran (demo project created at /tmp/banjo-demo)
3. **Verify SQLite** has notes: `sqlite3 /tmp/banjo-demo/.banjo/notes.db "SELECT * FROM notes;"`
4. **Check Zed** has banjo LSP configured in settings
5. **Run single phase** by commenting out other phases in banjo.demo

## Fixing Common Issues

### Cursor position assertions failing
The demo inserts lines which shifts note positions. Verify:
- Initial line numbers in INSERT statements match source file
- Position math after insertions is correct (line + inserted_count)

### Popup not visible
Zed's diagnostics panel may not be detected by accessibility. Try:
- Increase sleep duration after opening panel
- Check ZedQueryClient.hasVisiblePopup() logic

### Notes not appearing
- Verify banjo LSP is configured in Zed
- Check notes.db path matches banjo's expected location
- Ensure file path in notes.db matches actual demo file path
