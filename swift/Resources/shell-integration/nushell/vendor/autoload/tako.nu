# Tako shell integration
export module tako {
  def has_feature [feature: string] {
    $feature in ($env.TAKO_SHELL_FEATURES | default "" | split row ',')
  }

  # Wrap `ssh` with `tako +ssh` and translate the shell-integration
  # feature flags into command options.
  @complete external
  export def --wrapped ssh [...args] {
    if not ((has_feature "ssh-env") or (has_feature "ssh-terminfo")) {
      ^ssh ...$args
      return
    }

    let tako = ($env.TAKO_BIN_DIR? | default "") | path join "tako"
    mut flags = []
    if not (has_feature "ssh-env") {
      $flags = ($flags ++ ["--forward-env=false"])
    }
    if not (has_feature "ssh-terminfo") {
      $flags = ($flags ++ ["--terminfo=false"])
    }
    ^$tako "+ssh" ...$flags "--" ...$args
  }

  # Wrap `sudo` to preserve Tako's TERMINFO environment variable
  @complete external
  export def --wrapped sudo [...args] {
    mut sudo_args = $args

    if (has_feature "sudo") {
      # Extract just the sudo options (before the command)
      let sudo_options = (
        $args | take until {|arg|
          not (($arg | str starts-with "-") or ($arg | str contains "="))
        }
      )

      # Prepend TERMINFO preservation flag if not using sudoedit
      if (not ("-e" in $sudo_options or "--edit" in $sudo_options)) {
        $sudo_args = ($args | prepend "--preserve-env=TERMINFO")
      }
    }

    ^sudo ...$sudo_args
  }
}

# Clean up XDG_DATA_DIRS by removing TAKO_SHELL_INTEGRATION_XDG_DIR
if 'TAKO_SHELL_INTEGRATION_XDG_DIR' in $env {
  if 'XDG_DATA_DIRS' in $env {
    $env.XDG_DATA_DIRS = ($env.XDG_DATA_DIRS | str replace $"($env.TAKO_SHELL_INTEGRATION_XDG_DIR):" "")
  }
  hide-env TAKO_SHELL_INTEGRATION_XDG_DIR
}
