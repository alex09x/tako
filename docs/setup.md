# Set up Tako

Tako opens its setup guide after the first terminal window is ready. All steps
are optional. **Finish later** remembers the current step; use **Tako → Set Up
Tako…** or **Settings (⌘,) → Setup…** to return. Closing the guide leaves your
terminal and running programs in place.

If no terminal window is open, explicitly choosing **Set Up Tako…** opens a
clean terminal for the guide. Automatic setup waits for the first usable
terminal window; it respects `initial-window = false`.

- **Appearance:** choose colors and see the entire guide update immediately.
  The choice saves automatically while preserving your font, size and layout.
  Fonts, sizes and complete custom theme editing are available in Settings.
  Workspace and pane overrides retain their priority.
- **Command line:** optionally link this app's bundled `takoctl` into a writable
  bin directory. The installer protects unrelated files and links. Other shells
  must include the selected directory in `PATH`.
- **AI agents:** choose the detected agents to connect. A connection includes
  lifecycle hooks and the Tako skill. The guide checks both, shows failures,
  and preserves unrelated configuration. Already connected agents are checked
  without reinstalling them.
- **Permissions:** review optional macOS access and open the matching Settings
  page. Microphone access can be requested explicitly; this does not
  start recording. Other services show when macOS manages their status instead
  of claiming access is granted. A terminal program can have its own permission
  entry, separate from Tako.
  For Full Disk Access, the guide shows the **+ → select app → enable switch**
  steps, the exact app location, and a **Show app in Finder** action. macOS does
  not provide a normal in-app Allow dialog for that service.
  **Choose a folder to check…** opens the system folder chooser, then performs
  a read check only on the chosen folder. The result applies to this app and
  that folder; it does not claim access for every CLI or session process.
- **Notifications:** choose whether to enable macOS alerts, sounds and badges.
  The guide reads current macOS settings; opening the step does not request
  consent. When access was denied or individual options are off, open macOS
  Settings and use **Check again**, or return to Tako to refresh the status.
  **Check again** sends a test notification when access is allowed, and reports
  success, disabled banners or an error in the guide. It never requests access
  by itself.

Skipping optional integrations does not prevent ordinary terminal use. Opening
setup or checking statuses never requests camera, microphone, Full Disk Access
or screen-recording access. Permission requests require an explicit action.
Tako renders screenshots of its own terminal content without reading other
apps' screens.

Setup progress records navigation and explicit choices. Installed components
and permissions are checked again rather than inferred from a previous click.
Existing “Don't Ask Again” choices are preserved; a previous agent decline
leaves agents unselected until you choose them.
Explicit agent selections, including unchecking every agent, are remembered
when you finish later or close and reopen the guide.

After finishing or dismissing the guide, it does not reopen automatically on
every launch. Release notes remain a separate notice for later app versions.
