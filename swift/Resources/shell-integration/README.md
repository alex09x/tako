# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that Tako
supports.

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README.

## Implementation Details

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/tako.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/tako.bash`.
This also works for older versions of Bash.

```bash
# Tako shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${TAKO_RESOURCES_DIR}" ]; then
    builtin source "${TAKO_RESOURCES_DIR}/shell-integration/bash/tako.bash"
fi
```

> [!NOTE]
>
> The version of Bash distributed with macOS (`/bin/bash`) does not support
> automatic shell integration. You'll need to manually source the shell
> integration script (as shown above). You can also install a standard
> version of Bash from Homebrew or elsewhere and set it as your shell.

### Elvish

For [Elvish](https://elv.sh), `$TAKO_RESOURCES_DIR/src/shell-integration`
contains an `./elvish/lib/tako-integration.elv` file.

Elvish, on startup, searches for paths defined in `XDG_DATA_DIRS`
variable for `./elvish/lib/*.elv` files and imports them. They are thus
made available for use as modules by way of `use <filename>`.

Tako launches Elvish, passing the environment with `XDG_DATA_DIRS` prepended
with `$TAKO_RESOURCES_DIR/src/shell-integration`. It contains
`./elvish/lib/tako-integration.elv`. The user can then import it
by `use tako-integration` every time after shell startup or
autostart integration in `$XDG_CONFIG_HOME/elvish/rc.elv`,
which will run the integration routines.

If you decide to autostart `tako-integration` with `rc.elv`, you should
detect whether the terminal is Tako or not. To do this, add this to the end
of your `rc.elv` file:

```elvish
if (eq $E:TERM_PROGRAM "tako") {
  try { use tako-integration } catch { }
}
```

### Fish

For [Fish](https://fishshell.com/), Tako prepends to the
`XDG_DATA_DIRS` directory. Fish automatically loads configuration
files in `<XDG_DATA_DIR>/fish/vendor_conf.d/*.fish` on startup,
allowing us to automatically integrate with the shell. For details
on the Fish startup process, see the
[Fish documentation](https://fishshell.com/docs/current/language.html).

### Nushell

For [Nushell](https://www.nushell.sh/), Tako prepends to the
`XDG_DATA_DIRS` directory, making the `tako` module available through
Nushell's vendor autoload mechanism. Tako then automatically imports
the module using the `-e "use tako *"` flag when starting Nushell.

Nushell provides many shell features itself, such as `title` and `cursor`,
so our integration focuses on Tako-specific features like `sudo`,
`ssh-env`, and `ssh-terminfo`.

The shell integration is automatically enabled when running Nushell in Tako,
but you can also load it manually is shell integration is disabled:

```nushell
source $TAKO_RESOURCES_DIR/shell-integration/nushell/vendor/autoload/tako.nu
use tako *
```

### Zsh

Automatic [Zsh](https://www.zsh.org/) integration works by temporarily setting
`ZDOTDIR` to our `zsh` directory. An existing `ZDOTDIR` environment variable
value will be retained and restored after our shell integration scripts are
run.

However, if `ZDOTDIR` is set in a system-wide file like `/etc/zshenv`, it will
override Tako's `ZDOTDIR` value, preventing the shell integration from being
loaded. In this case, the shell integration needs to be loaded manually.

To load the Zsh shell integration manually:

```zsh
if [[ -n $TAKO_RESOURCES_DIR ]]; then
  source "$TAKO_RESOURCES_DIR"/shell-integration/zsh/tako-integration
fi
```

Shell integration requires Zsh 5.1+.
