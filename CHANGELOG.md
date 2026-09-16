# Changelog

All notable changes to this project will be documented in this file.

## v1.2.0

### ✨ Added

- **Buffer-level toggle** — enable/disable suggestions per buffer with `:LeCodestralToggleBuffer` / `lecodestral#toggle_buffer()` (`b:lecodestral_enabled`).
- **Automatic disabling for special buffers** — suggestions are skipped in `help`, `prompt`, `quickfix`, `terminal` and `nofile` buffers.
- **`g:lecodestral_disabled_filetypes`** — disable suggestions for specific filetypes.
- **Statusline support** — add `%{lecodestral#statusline()}` to `&statusline` to show the plugin state (`OFF`, ` ON`, ` * `, `N/M`, ` 0 `). The statusline auto-refreshes via `redrawstatus()` whenever the state changes.
- **`:LeCodestralStatus` / `lecodestral#status()`** — show why suggestions are disabled (or that they're enabled) via a popup.

### 🔧 Changed

- **Centralized enable checks** — global toggle, buffer toggle, buftype and filetype rules are now evaluated in `s:disabled_reason()` / `s:is_enabled()` and honored by every entry point.
- **Word context extraction** — `lecodestral#cycle()` now trims leading non-word characters; the 'word' context always matches just the first keyword (e.g. `(foo` → `foo`).
- **Indentation** — switched to tabs across the codebase.

## v1.1.0

### ⚠️ Breaking Changes

- **No default keybindings** (since initial release). You must map `<Plug>` actions yourself, e.g.:

  ```vim
  imap <Tab>      <Plug>(lecodestral-accept)
  imap <C-]>      <Plug>(lecodestral-dismiss)
  imap <C-n>      <Plug>(lecodestral-cycle-suggestions)
  imap <S-Tab>    <Plug>(lecodestral-cycle-context)
  imap <S-Space>  <Plug>(lecodestral-complete)
  ```

### ✨ Added

- **Popup notification system** — Replaced `echo` output with non-intrusive popups via `s:notify()`. Messages now appear as hoverable tooltips instead of cluttering the terminal.
- **Multiple suggestions with cycling** — fetches N candidate completions; cycle through them with `:call lecodestral#cycle(1)` / `lecodestral#cycle(-1)` or the `<Plug>` mappings.
- **Cycle context options** — cycle through 'preview', 'full', 'line', and 'word' views via `<Plug>(lecodestral-cycle-context)`.

### 🔧 Changed

- **Better FIM endpoint** — switched to a Mistral fill-in-the-middle completion endpoint based on Mistral documentation.
- **Docs & config refinements** — updated documentation and configuration options.


## v1.0.0 (Initial Release)

- Ghost-text autocomplete powered by Codestral (Vim 9, `+textprop` + `+job`, zero deps beyond `curl`).
- Fill-in-the-middle completion: sends code before *and* after the cursor.
- Async debounced requests with stale-cancel.
