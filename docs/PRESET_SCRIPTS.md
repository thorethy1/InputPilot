# Preset scripts

Enable **Script** on a text preset (leave **Shortcut** off). Existing presets default to plain text; enable Script explicitly for existing bracket-based presets. Plain text mode continues to send the complete text, including line breaks and brackets.

Scripts use one action per line. Blank lines are ignored; a line break does not press Enter. Ordinary lines are typed verbatim, preserving leading zeros and spaces. Use `STRING ` to type a line that looks like a command or starts with `[`. Inline tokens such as `hello[TAB]world` are not expanded.

```text
[TAB]
[TAB]
Example user
[TAB]
Demo project
[TAB]
00001234
[TAB]
42
[DELAY 500]
[ENTER]
```

The following DuckyScript subset is also supported:

```text
REM Example form
CTRL A
STRING Hello world
TAB
DELAY 500
ENTER
```

- Keys: TAB, ENTER/RETURN, ESC, BACKSPACE, SPACE, DELETE, INSERT, HOME, END, PAGEUP/PAGEDOWN, arrow keys, CAPSLOCK, PRINTSCREEN, F1–F12.
- Combinations: `[CTRL+A]`, `[SHIFT+TAB]`, `CTRL ALT DELETE`, `GUI R`. Modifiers include CTRL/CONTROL, SHIFT, ALT/OPTION, GUI/WIN/CMD/COMMAND.
- `DELAY 500` or `[DELAY 500]` waits 500 milliseconds. Range: 0–60000 per delay. A duration is required.
- `STRING text` types literal text; `REM comment` is ignored.
- This is not a full DuckyScript interpreter: loops, variables, conditionals and DEFAULT_DELAY are not supported.

Actions use the existing BLE/Wi-Fi ordered transport session and selected text keyboard layout. There is a 50 ms pause after each text/key action; typing speed controls the additional per-character delay. Add explicit delays for slow forms. Key combinations use the existing firmware key mapping.

The complete script and text characters are validated before execution. Errors appear in the Presets list. Run is disabled during execution; Stop or leaving the screen cancels playback and attempts to release keys. A send failure aborts playback. “Enter after” adds another Enter at the end, so leave it off when the script already ends with ENTER.
