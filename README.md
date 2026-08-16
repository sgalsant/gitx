# gitx

`gitx` is an interactive Bash helper for a safer Git and GitHub workflow on WSL. It guides common tasks such as configuring Git, creating task branches, selecting files for commits, opening and merging pull requests, and publishing releases.

It is intended for developers who want the Git workflow to be explicit and repeatable without having to remember every command. It does not replace Git or GitHub CLI: it runs them with checks and confirmations before operations that affect branches, commits, remotes, or configuration.

## Requirements

- WSL or another Bash environment
- Git
- GitHub CLI (`gh`) for GitHub authentication, pull requests, merges, and releases

Run the diagnostic command to verify the local setup:

```bash
bash gitx-2.3.0.sh --doctor
```

## Quick start

Install the current working version globally:

```bash
bash gitx-2.3.0.sh --install
```

Make sure `~/.local/bin` is in your `PATH`, open a new terminal, then start `gitx` from a Git repository. It runs a diagnostic first and then opens the interactive menu:

```bash
gitx
```

For the usual task workflow, choose these menu options in order:

1. **Start a new task**: updates the main branch when safe and creates a branch such as `feature/add-login`.
2. **Create a commit**: choose all files, specific files, or individual hunks; protected files and files larger than 50 MB are skipped.
3. **Publish branch and create Pull Request**: pushes the branch and opens a PR with GitHub CLI.
4. **Validate and merge Pull Request**: verifies the PR status and checks, squash-merges it, then updates the local main branch.

## Commands

| Command | Purpose |
| --- | --- |
| `gitx` | Run a diagnostic, then open the interactive workflow menu. |
| `gitx -x` | Open the interactive workflow menu without running the initial diagnostic. |
| `gitx --doctor` | Check Git, GitHub CLI authentication, commit identity, and repository status. |
| `gitx --setup-git` | Back up and configure global Git defaults for WSL; optionally configure GitHub CLI credentials. |
| `gitx --setup-gitignore` | Add safe common and stack-specific rules to the current repository's `.gitignore`. |
| `gitx --show-config` | Show global Git configuration and where each value comes from. |
| `gitx --restore-config` | Restore the most recent Git configuration backup created by the tool. |
| `gitx --verbose` | Open the menu with short explanations enabled. This preference is saved. |
| `gitx --quiet` | Open the menu with explanations disabled. This preference is saved. |
| `gitx --version` | Print the installed script version. |
| `gitx --uninstall` | Remove the global installation from `~/.local/bin/gitx`. |

## Creating a project

Run `gitx` inside an empty project directory and choose **Create and publish a new project**. The tool initializes a `main` branch, creates a README if one does not exist, configures `.gitignore`, creates the initial commit, and can create a private or public GitHub repository when `gh` is available.

## Safety behavior

- Git configuration and `.gitignore` changes are backed up under `~/.config/gitx/` by default.
- Commits require reviewing and confirming the selected files.
- `.env` files, private keys, credential files, virtual environments, and `node_modules` are not staged by the guided commit flow.
- Pull requests cannot be opened from the main branch or with uncommitted changes.
- Releases require a clean, up-to-date main branch and a semantic version tag such as `v1.2.3`.

## Running without installation

You can use the script directly from this repository:

```bash
bash gitx-2.3.0.sh
```

Add `-x` to skip the initial diagnostic, or use `bash gitx-2.3.0.sh --help` to display the available command-line options.
