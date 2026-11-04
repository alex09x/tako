# Set up Tako

Tako opens its setup guide after the first terminal window is ready. All steps
are optional. **Finish later** remembers the current step; use **Tako → Set Up
Tako…** or **Settings (⌘,) → Setup…** to return. Closing the guide leaves your
terminal and running programs in place.

If no terminal window is open, explicitly choosing **Set Up Tako…** opens a
clean terminal for the guide. Automatic setup waits for the first usable
terminal window; it respects `initial-window = false`.

- **Appearance:** choose a complete theme preset. The choice applies and saves
  immediately. Custom themes, fonts and sizes remain available in Settings.
  Workspace and pane overrides retain their priority.
- **Command line:** optionally link this app's bundled `takoctl` into a writable
  bin directory. The installer protects unrelated files and links. Other shells
  must include the selected directory in `PATH`.
- **AI agents:** choose the detected agents to connect. A connection includes
  lifecycle hooks and the Tako skill. The guide checks both, shows failures,
  and preserves unrelated configuration. Already connected agents are checked
  without reinstalling them.
- **Notifications:** choose whether to enable macOS alerts, sounds and badges.
  The guide reads current macOS settings; opening the step does not request
  consent. When access was denied or individual options are off, open macOS
  Settings and use **Check again**, or return to Tako to refresh the status.

Skipping optional integrations does not prevent ordinary terminal use. Setup
does not request camera, microphone, Full Disk Access or screen-recording
access. Tako renders screenshots of its own terminal content without reading
other apps' screens.

Setup progress records navigation and explicit choices. Installed components
and permissions are checked again rather than inferred from a previous click.
Existing “Don't Ask Again” choices are preserved; a previous agent decline
leaves agents unselected until you choose them.
Explicit agent selections, including unchecking every agent, are remembered
when you finish later or close and reopen the guide.

After finishing or dismissing the guide, it does not reopen automatically on
every launch. Release notes remain a separate notice for later app versions.
