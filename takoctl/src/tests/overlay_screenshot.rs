/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::super::*;
use serde_json::json;

#[test]
fn test_skills_subcommands_and_options() {
    let opts_default = parse(&["skills".into()]).unwrap();
    assert_eq!(opts_default.cmd, "skills");
    assert_eq!(opts_default.args["action"], "list");

    let opts_list = parse(&["skills".into(), "list".into()]).unwrap();
    assert_eq!(opts_list.cmd, "skills");
    assert_eq!(opts_list.args["action"], "list");

    let opts_status = parse(&["skills".into(), "status".into(), "claude".into()]).unwrap();
    assert_eq!(opts_status.cmd, "skills");
    assert_eq!(opts_status.args["action"], "status");
    assert_eq!(opts_status.args["agent"], "claude");

    let opts_install = parse(&[
        "skills".into(),
        "install".into(),
        "gemini".into(),
        "--yes".into(),
        "--diff-only".into(),
        "--skill-path".into(),
        "/tmp/custom/SKILL.md".into(),
    ])
    .unwrap();
    assert_eq!(opts_install.cmd, "skills");
    assert_eq!(opts_install.args["action"], "install");
    assert_eq!(opts_install.args["agent"], "gemini");
    assert_eq!(opts_install.args["yes"], true);
    assert_eq!(opts_install.args["diff_only"], true);
    assert_eq!(opts_install.args["skill_path"], "/tmp/custom/SKILL.md");

    let opts_uninstall = parse(&["skills".into(), "uninstall".into(), "aider".into()]).unwrap();
    assert_eq!(opts_uninstall.cmd, "skills");
    assert_eq!(opts_uninstall.args["action"], "uninstall");
    assert_eq!(opts_uninstall.args["agent"], "aider");
}

#[test]
fn test_mcp_command_and_capabilities_option() {
    let opts_mcp = parse(&["mcp".into()]).unwrap();
    assert_eq!(opts_mcp.cmd, "mcp");
    assert!(!opts_mcp.args.contains_key("capabilities"));

    let opts_scoped =
        parse(&["mcp".into(), "--capabilities".into(), "read,signal".into()]).unwrap();
    assert_eq!(opts_scoped.cmd, "mcp");
    assert_eq!(opts_scoped.args["capabilities"], "read,signal");
}

#[test]
fn test_overlay_subcommands_and_options_parsed_and_rendered() {
    // 1. Open
    let opts_open = parse(&[
        "overlay".into(),
        "open".into(),
        "/tmp/artifact.md".into(),
        "--split".into(),
        "right".into(),
        "--type".into(),
        "markdown".into(),
    ])
    .unwrap();
    assert_eq!(opts_open.cmd, "overlay");
    assert_eq!(opts_open.args["subcommand"], "open");
    assert_eq!(opts_open.args["file"], "/tmp/artifact.md");
    assert_eq!(opts_open.args["split"], "right");
    assert_eq!(opts_open.args["type"], "markdown");

    let open_val = json!({
        "id": "pane-1",
        "target": "pane-0",
        "open": true,
        "file": "/tmp/artifact.md",
        "title": "artifact.md",
        "type": "markdown",
        "sandboxed": "/tmp",
        "split": "right"
    });
    let rep_open = render("overlay", &open_val);
    assert!(rep_open.contains("Overlay active on pane pane-1 (split right):"));
    assert!(rep_open.contains("File: /tmp/artifact.md"));
    assert!(rep_open.contains("Type: markdown"));
    assert!(rep_open.contains("Sandboxed: /tmp"));

    // 2. Close
    let opts_close = parse(&["overlay".into(), "close".into()]).unwrap();
    assert_eq!(opts_close.cmd, "overlay");
    assert_eq!(opts_close.args["subcommand"], "close");

    let rep_closed = render("overlay", &json!({"id": "pane-1", "closed": true}));
    assert_eq!(rep_closed, "Closed overlay for pane pane-1.\n");

    let rep_not_closed = render("overlay", &json!({"id": "pane-1", "closed": false}));
    assert_eq!(
        rep_not_closed,
        "No active overlay to close on pane pane-1.\n"
    );

    // 3. Status
    let opts_st = parse(&["overlay".into()]).unwrap();
    assert_eq!(opts_st.cmd, "overlay");
    assert_eq!(opts_st.args["subcommand"], "status");

    let rep_st_inactive = render("overlay", &json!({"id": "pane-1", "open": false}));
    assert_eq!(rep_st_inactive, "No overlay active on pane pane-1.\n");

    // 4. Reload
    let opts_reload = parse(&["overlay".into(), "reload".into()]).unwrap();
    assert_eq!(opts_reload.cmd, "overlay");
    assert_eq!(opts_reload.args["subcommand"], "reload");

    let rep_reload = render("overlay", &json!({"id": "pane-1", "reloaded": true}));
    assert_eq!(rep_reload, "Reloaded overlay for pane pane-1.\n");
}

#[test]
fn test_text_styled_and_screenshot_options() {
    // 1. Text with --styled and --lines
    let opts_text = parse(&[
        "text".into(),
        "--lines".into(),
        "50".into(),
        "--styled".into(),
    ])
    .unwrap();
    assert_eq!(opts_text.cmd, "text");
    assert_eq!(opts_text.args["lines"], 50);
    assert_eq!(opts_text.args["styled"], true);

    // 2. Screenshot with positional path
    let opts_ss1 = parse(&["screenshot".into(), "/tmp/screen.png".into()]).unwrap();
    assert_eq!(opts_ss1.cmd, "screenshot");
    assert_eq!(opts_ss1.args["out"], "/tmp/screen.png");

    // 3. Screenshot with --out flag
    let opts_ss2 =
        parse(&["screenshot".into(), "--out".into(), "/tmp/out.png".into()]).unwrap();
    assert_eq!(opts_ss2.cmd, "screenshot");
    assert_eq!(opts_ss2.args["out"], "/tmp/out.png");

    // 4. Render screenshot
    let ss_val = json!({
        "id": "pane-1",
        "width": 800,
        "height": 600,
        "format": "png",
        "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg=="
    });
    let rep_ss = render("screenshot", &ss_val);
    assert_eq!(rep_ss, "screenshot of pane pane-1 (800x600 png)\n");

    // 5. Base64 decode verification
    let bytes = decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg==").unwrap();
    assert_eq!(
        &bytes[0..8],
        &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    );
}

#[test]
fn test_write_exclusive_temp_screenshot() {
    let fake_png = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    let path = write_exclusive_temp_file("testpane", &fake_png).unwrap();
    assert!(path.exists());
    let file_name = path.file_name().unwrap().to_str().unwrap();
    assert!(file_name.starts_with("tako-screenshot-testpane-"));
    assert!(file_name.ends_with(".png"));

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata = std::fs::metadata(&path).unwrap();
        let mode = metadata.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    let read_bytes = std::fs::read(&path).unwrap();
    assert_eq!(read_bytes, fake_png);

    let _ = std::fs::remove_file(&path);
}

#[test]
#[cfg(unix)]
fn test_screenshot_temp_refuses_symlink_overwrite() {
    use std::os::unix::fs::{OpenOptionsExt, symlink};
    let temp_dir = std::env::temp_dir();
    let target_file = temp_dir.join(format!("test-target-{}.txt", random_hex(8)));
    std::fs::write(&target_file, b"secret original data").unwrap();

    let link_path = temp_dir.join(format!("test-link-{}.png", random_hex(8)));
    symlink(&target_file, &link_path).unwrap();

    // Attempting to exclusively create a file at link_path must fail
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    opts.custom_flags(libc::O_NOFOLLOW);
    let res = opts.open(&link_path);
    assert!(res.is_err(), "exclusive open must refuse existing symlink");

    // Target content must remain untouched
    let content = std::fs::read_to_string(&target_file).unwrap();
    assert_eq!(content, "secret original data");

    let _ = std::fs::remove_file(&link_path);
    let _ = std::fs::remove_file(&target_file);
}
