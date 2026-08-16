#!/usr/bin/env bash
# gitx 2.3.0 — Guided Git and GitHub helper for WSL

set -o pipefail

VERSION="2.3.0"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gitx"
SETTINGS_FILE="$CONFIG_DIR/settings"
BACKUP_DIR="$CONFIG_DIR/backups"
GITIGNORE_BACKUP_DIR="$CONFIG_DIR/gitignore-backups"
VERBOSE=false
declare -A RENAME_SOURCE=()

[[ -f "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE" 2>/dev/null || true

msg() { printf '\n%s\n' "$*"; }
info() { printf '• %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
pause() { read -r -p "Press Enter to continue..." _; }

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

explain() {
  $VERBOSE && msg "What this will do: $1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "Required program not found: $1"
    return 1
  }
}

in_repository() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

repository_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

current_branch() {
  git branch --show-current 2>/dev/null
}

default_branch() {
  local remote_head
  remote_head="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"

  if [[ -n "$remote_head" ]]; then
    printf '%s\n' "${remote_head#origin/}"
  elif git show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
  elif git show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
  else
    current_branch
  fi
}

working_tree_dirty() {
  [[ -n "$(git status --porcelain=v1 2>/dev/null)" ]]
}

save_settings() {
  mkdir -p "$CONFIG_DIR"
  printf 'VERBOSE=%q\n' "$VERBOSE" >"$SETTINGS_FILE"
}

slugify() {
  local value="$1"

  if command -v iconv >/dev/null 2>&1; then
    value="$(printf '%s' "$value" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$value")"
  fi

  printf '%s' "$value" |
    tr '[:upper:] ' '[:lower:]-' |
    sed 's/[^a-z0-9-]//g;s/--*/-/g;s/^-//;s/-$//'
}

show_status() {
  in_repository || {
    warn "This folder is not a Git repository."
    return 1
  }

  local staged modified untracked branch base remote
  staged="$(git diff --cached --name-only -z | tr -cd '\0' | wc -c)"
  modified="$(git diff --name-only -z | tr -cd '\0' | wc -c)"
  untracked="$(git ls-files --others --exclude-standard -z | tr -cd '\0' | wc -c)"
  branch="$(current_branch)"
  base="$(default_branch)"
  remote="$(git remote get-url origin 2>/dev/null || printf 'not configured')"

  msg "Project status"
  info "Current branch: ${branch:-detached}"
  info "Main branch: ${base:-not detected}"
  info "Remote: $remote"

  if (( staged == 0 && modified == 0 && untracked == 0 )); then
    info "Working folder: clean"
  else
    warn "Pending changes — staged: $staged, modified: $modified, new: $untracked"
    if [[ "$branch" == "$base" ]]; then
      info "Choose option 1 to move these changes to a task branch."
    else
      info "Choose option 3 to prepare a commit."
    fi
  fi
}

doctor() {
  msg "gitx diagnosis"

  require_command git || return 1
  info "Git: $(git --version)"

  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      info "GitHub CLI: authenticated as $(gh api user --jq .login 2>/dev/null || printf 'unknown')"
    else
      warn "GitHub CLI is installed but not authenticated."
    fi
  else
    warn "GitHub CLI is not installed."
  fi

  info "Commit identity: $(git config --global user.name || printf 'unset') <$(git config --global user.email || printf 'unset')>"

  if in_repository; then
    show_status
  else
    info "Current folder is not a Git repository."
  fi
}

backup_git_config() {
  mkdir -p "$BACKUP_DIR"
  if [[ -f "$HOME/.gitconfig" ]]; then
    cp "$HOME/.gitconfig" "$BACKUP_DIR/gitconfig-$(date +%Y%m%d-%H%M%S)"
  fi
}

setup_git() {
  explain "Back up your global Git configuration and apply safe WSL defaults."
  backup_git_config

  local current_name current_email name email
  current_name="$(git config --global user.name || true)"
  current_email="$(git config --global user.email || true)"

  read -r -p "Name shown in commits [$current_name]: " name
  read -r -p "Email shown in commits [$current_email]: " email

  [[ -n "$name" ]] && git config --global user.name "$name"
  [[ -n "$email" ]] && git config --global user.email "$email"

  if confirm "Apply the recommended WSL settings?"; then
    git config --global init.defaultBranch main
    git config --global pull.ff only
    git config --global fetch.prune true
    git config --global push.autoSetupRemote true
    git config --global push.default simple
    git config --global core.autocrlf input
    git config --global merge.conflictStyle zdiff3
    info "Recommended WSL settings applied."
  fi

  if command -v gh >/dev/null 2>&1 && confirm "Configure Git to use GitHub CLI credentials?"; then
    gh auth status >/dev/null 2>&1 || gh auth login || return 1
    gh auth setup-git || return 1
  fi
}

restore_git_config() {
  local backup
  backup="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'gitconfig-*' 2>/dev/null | sort -r | head -n1)"

  [[ -n "$backup" ]] || {
    warn "No Git configuration backup was found."
    return 1
  }

  if confirm "Restore the latest global Git configuration backup?"; then
    cp "$backup" "$HOME/.gitconfig"
    info "Global Git configuration restored."
  fi
}

append_unique_rule() {
  local file="$1" rule="$2"
  grep -Fqx -- "$rule" "$file" 2>/dev/null || printf '%s\n' "$rule" >>"$file"
}

detect_stack() {
  [[ -f pyproject.toml || -f requirements.txt || -f uv.lock ]] && {
    printf 'python\n'
    return
  }
  [[ -f package.json ]] && {
    printf 'node\n'
    return
  }
  [[ -f pom.xml || -f build.gradle || -f build.gradle.kts ]] && {
    printf 'java\n'
    return
  }
  compgen -G '*.csproj' >/dev/null && {
    printf 'dotnet\n'
    return
  }
  [[ -f Dockerfile || -f compose.yml || -f docker-compose.yml ]] && {
    printf 'docker\n'
    return
  }
  printf 'none\n'
}

common_ignore_rules() {
  cat <<'EOF'
.env
.env.*
!.env.example
*.pem
*.key
credentials.json
secrets.json
.DS_Store
Thumbs.db
Desktop.ini
*:Zone.Identifier
*.log
*.tmp
*.temp
.cache/
tmp/
temp/
coverage/
.coverage
htmlcov/
dist/
build/
out/
.venv/
.venv-*/
venv/
EOF
}

stack_ignore_rules() {
  case "$1" in
    python)
      printf '%s\n' '__pycache__/' '*.py[cod]' '.pytest_cache/' '.ruff_cache/' '.mypy_cache/' '.pyright/' '.ipynb_checkpoints/' '*.egg-info/'
      ;;
    node)
      printf '%s\n' 'node_modules/' 'npm-debug.log*' 'yarn-debug.log*' 'pnpm-debug.log*' '.vite/' '.next/' '.nuxt/'
      ;;
    java)
      printf '%s\n' '*.class' 'target/' '.gradle/' 'bin/'
      ;;
    dotnet)
      printf '%s\n' 'bin/' 'obj/' '.vs/' '*.user' '*.suo'
      ;;
    docker)
      printf '%s\n' 'docker-data/' 'volumes/'
      ;;
  esac
}

setup_gitignore() {
  in_repository || {
    warn "Initialize Git before configuring .gitignore."
    return 1
  }

  local root file detected stack rule
  root="$(repository_root)"
  file="$root/.gitignore"
  cd "$root" || return 1

  explain "Create or extend .gitignore without removing your existing rules."
  mkdir -p "$GITIGNORE_BACKUP_DIR"

  if [[ -f "$file" ]]; then
    cp "$file" "$GITIGNORE_BACKUP_DIR/gitignore-$(date +%Y%m%d-%H%M%S)"
  else
    touch "$file"
  fi

  while IFS= read -r rule; do
    append_unique_rule "$file" "$rule"
  done < <(common_ignore_rules)

  detected="$(detect_stack)"
  read -r -p "Project stack [$detected] (python/node/java/dotnet/docker/none): " stack
  [[ -n "$stack" ]] || stack="$detected"

  while IFS= read -r rule; do
    [[ -n "$rule" ]] && append_unique_rule "$file" "$rule"
  done < <(stack_ignore_rules "$stack")

  if confirm "Ignore local VS Code settings?"; then
    append_unique_rule "$file" '.vscode/'
  fi

  if confirm "Ignore local database files?"; then
    append_unique_rule "$file" '*.db'
    append_unique_rule "$file" '*.sqlite'
    append_unique_rule "$file" '*.sqlite3'
  fi

  info "Updated $file"

  local tracked_ignored
  tracked_ignored="$(git ls-files -ci --exclude-standard)"
  if [[ -n "$tracked_ignored" ]]; then
    warn "Some ignored files are already tracked. gitx did not remove them automatically:"
    printf '%s\n' "$tracked_ignored"
  fi
}

protected_path() {
  local path="${1#./}" base
  base="${path##*/}"

  case "/$path/" in
    */.venv/* | */.venv-*/* | */venv/* | */node_modules/*)
      return 0
      ;;
  esac

  case "$base" in
    .env.example)
      return 1
      ;;
    .env | .env.* | *.pem | *.key | credentials.json | secrets.json)
      return 0
      ;;
  esac

  return 1
}

large_file() {
  local path="$1" size
  [[ -f "$path" ]] || return 1
  size="$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')"
  (( size > 50 * 1024 * 1024 ))
}

stage_path() {
  local path="$1" original="${RENAME_SOURCE[$1]:-}"

  if protected_path "$path" || { [[ -n "$original" ]] && protected_path "$original"; }; then
    warn "Skipped protected local file: $path"
    return 1
  fi

  if large_file "$path"; then
    warn "Skipped file larger than 50 MB: $path"
    return 1
  fi

  git add -A -- "$path" || return 1
  [[ -z "$original" ]] || git add -A -- "$original"
}

collect_changed_paths() {
  local -n output=$1
  local -a records=()
  local record status path original
  local i
  declare -A seen=()
  output=()
  RENAME_SOURCE=()

  mapfile -d '' -t records < <(git status --porcelain=v1 -z --untracked-files=all)

  for ((i = 0; i < ${#records[@]}; i++)); do
    record="${records[i]}"
    status="${record:0:2}"
    path="${record:3}"

    if [[ -n "$path" && -z "${seen[$path]+x}" ]]; then
      output+=("$path")
      seen["$path"]=1
    fi

    if [[ "$status" == *R* || "$status" == *C* ]]; then
      ((i += 1))
      original="${records[i]:-}"
      [[ -z "$original" ]] || RENAME_SOURCE["$path"]="$original"
    fi
  done
}

unstage_all() {
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git reset -q HEAD --
  else
    git rm --cached -r -q --ignore-unmatch .
  fi
}

restore_index() {
  local backup="$1" index_path="$2" existed="$3"

  if [[ "$existed" == true ]]; then
    cp "$backup" "$index_path"
  else
    rm -f "$index_path"
  fi
}

create_commit() {
  in_repository || {
    warn "This folder is not a Git repository."
    return 1
  }

  local root
  root="$(repository_root)"
  cd "$root" || return 1

  local -a files=()
  collect_changed_paths files

  ((${#files[@]} > 0)) || {
    info "There are no changes to commit."
    return 0
  }

  local index_path index_backup index_existed=false
  index_path="$(git rev-parse --git-path index)"
  index_backup="$(mktemp)"

  if [[ -f "$index_path" ]]; then
    cp "$index_path" "$index_backup"
    index_existed=true
  fi

  if [[ -n "$(git diff --cached --name-only)" ]]; then
    info "The existing staged selection will be replaced. Unselected files will remain in your working folder."
  fi

  msg "Choose what to include in this commit"
  local i
  for i in "${!files[@]}"; do
    printf '%d) %q\n' "$((i + 1))" "${files[i]}"
  done

  printf '%s\n' "A) Add all safe files" "N) Choose file numbers" "P) Choose parts interactively" "C) Cancel"

  local choice numbers number path
  read -r -p "Choice: " choice

  unstage_all || {
    restore_index "$index_backup" "$index_path" "$index_existed"
    rm -f "$index_backup"
    return 1
  }

  case "$choice" in
    A | a)
      for path in "${files[@]}"; do
        stage_path "$path" || true
      done
      ;;
    N | n)
      read -r -p "Numbers separated by spaces: " numbers
      for number in $numbers; do
        if [[ "$number" =~ ^[0-9]+$ ]] && ((number > 0 && number <= ${#files[@]})); then
          stage_path "${files[number - 1]}" || true
        else
          warn "Ignored invalid selection: $number"
        fi
      done
      ;;
    P | p)
      git add -p || {
        restore_index "$index_backup" "$index_path" "$index_existed"
        rm -f "$index_backup"
        return 1
      }
      ;;
    *)
      restore_index "$index_backup" "$index_path" "$index_existed"
      rm -f "$index_backup"
      return 0
      ;;
  esac

  if [[ -z "$(git diff --cached --name-only)" ]]; then
    warn "No files are selected."
    restore_index "$index_backup" "$index_path" "$index_existed"
    rm -f "$index_backup"
    return 1
  fi

  if ! git diff --cached --check; then
    warn "Git found whitespace warnings in the selected changes."
    if ! confirm "Continue without changing those spaces?"; then
      restore_index "$index_backup" "$index_path" "$index_existed"
      rm -f "$index_backup"
      return 0
    fi
  fi

  msg "Files selected for this commit"
  git diff --cached --name-status

  if ! confirm "Create the commit with exactly these files?"; then
    restore_index "$index_backup" "$index_path" "$index_existed"
    rm -f "$index_backup"
    return 0
  fi

  local type scope description message
  read -r -p "Type [feat]: " type
  read -r -p "Optional scope: " scope
  read -r -p "Short description: " description

  type="${type:-feat}"
  type="$(slugify "$type")"

  [[ -n "$description" ]] || {
    warn "A description is required."
    restore_index "$index_backup" "$index_path" "$index_existed"
    rm -f "$index_backup"
    return 1
  }

  if [[ -n "$scope" ]]; then
    scope="$(slugify "$scope")"
    message="$type($scope): $description"
  else
    message="$type: $description"
  fi

  if git commit -m "$message"; then
    rm -f "$index_backup"
    info "Commit created."
  else
    restore_index "$index_backup" "$index_path" "$index_existed"
    rm -f "$index_backup"
    warn "The commit failed; the previous staged selection was restored."
    return 1
  fi
}

start_task() {
  in_repository || {
    warn "This folder is not a Git repository."
    return 1
  }

  local branch base dirty type name
  branch="$(current_branch)"
  base="$(default_branch)"
  dirty=false
  working_tree_dirty && dirty=true

  [[ -n "$base" ]] || {
    warn "Could not detect the main branch."
    return 1
  }

  if [[ "$branch" != "$base" ]]; then
    if $dirty; then
      warn "You are already working on branch '$branch' with pending changes."
      info "Use option 3 to create a commit before starting another task."
      return 1
    fi

    if ! confirm "Switch from '$branch' to '$base' and start a different task?"; then
      return 0
    fi

    git switch "$base" || return 1
  fi

  if $dirty; then
    explain "Create a task branch while keeping the current local changes. The main branch will not be updated first."
  else
    explain "Update the main branch and create a separate branch for this task."
    git pull --ff-only || {
      warn "The main branch could not be updated. No task branch was created."
      return 1
    }
  fi

  read -r -p "Task type [feature]: " type
  read -r -p "Short task name: " name

  type="$(slugify "${type:-feature}")"
  name="$(slugify "$name")"

  [[ -n "$type" && -n "$name" ]] || {
    warn "Enter a valid task type and name."
    return 1
  }

  local new_branch="$type/$name"
  if git show-ref --verify --quiet "refs/heads/$new_branch"; then
    warn "Branch '$new_branch' already exists."
    return 1
  fi

  git switch -c "$new_branch" || return 1
  info "Task branch created: $new_branch"
}

github_ready() {
  require_command gh || return 1

  gh auth status >/dev/null 2>&1 || {
    warn "GitHub CLI is not authenticated. Run option 9 first."
    return 1
  }

  git remote get-url origin >/dev/null 2>&1 || {
    warn "This repository has no origin remote."
    return 1
  }
}

create_pull_request() {
  in_repository || {
    warn "This folder is not a Git repository."
    return 1
  }
  github_ready || return 1

  local branch base
  branch="$(current_branch)"
  base="$(default_branch)"

  [[ "$branch" != "$base" ]] || {
    warn "Create a task branch before opening a Pull Request."
    return 1
  }

  if working_tree_dirty; then
    warn "There are pending local changes. Choose option 3 before opening the Pull Request."
    return 1
  fi

  if ! git log --format=%H "$base..HEAD" | grep -q .; then
    warn "There is no commit on this task branch. Choose option 3 first."
    return 1
  fi

  explain "Publish the current task branch and create its Pull Request."
  git push -u origin HEAD || {
    warn "The branch could not be published. No Pull Request was created."
    return 1
  }

  if gh pr view --json number,url,state >/dev/null 2>&1; then
    info "A Pull Request already exists for this branch:"
    gh pr view --json number,url,state --jq '"#\(.number) \(.state) \(.url)"'
    return 0
  fi

  gh pr create --base "$base" --fill || {
    warn "GitHub could not create the Pull Request."
    return 1
  }
}

merge_pull_request() {
  in_repository || {
    warn "This folder is not a Git repository."
    return 1
  }
  github_ready || return 1

  local branch base state draft merge_state checks
  branch="$(current_branch)"
  base="$(default_branch)"

  [[ "$branch" != "$base" ]] || {
    warn "Switch to the task branch whose Pull Request you want to merge."
    return 1
  }

  if working_tree_dirty; then
    warn "There are pending local changes. Commit or discard them before merging."
    return 1
  fi

  gh pr view >/dev/null 2>&1 || {
    warn "No Pull Request exists for branch '$branch'."
    return 1
  }

  state="$(gh pr view --json state --jq .state)"
  draft="$(gh pr view --json isDraft --jq .isDraft)"
  merge_state="$(gh pr view --json mergeStateStatus --jq .mergeStateStatus)"

  [[ "$state" == "OPEN" ]] || {
    warn "The Pull Request is not open."
    return 1
  }
  [[ "$draft" == "false" ]] || {
    warn "The Pull Request is still a draft."
    return 1
  }
  [[ "$merge_state" != "DIRTY" ]] || {
    warn "The Pull Request has conflicts that must be resolved first."
    return 1
  }

  checks="$(gh pr checks --json state --jq '.[].state' 2>/dev/null || true)"
  if [[ -n "$checks" ]] && printf '%s\n' "$checks" | grep -Evq '^(SUCCESS|SKIPPED|NEUTRAL)$'; then
    warn "Some automated checks have not passed."
    gh pr checks
    return 1
  fi

  explain "Squash the task into one commit, merge it, and clean up its branches."
  gh pr view
  confirm "Squash and merge this Pull Request?" || return 0

  gh pr merge --squash --delete-branch || {
    warn "GitHub could not merge the Pull Request."
    return 1
  }

  git switch "$base" || return 1
  git pull --ff-only || return 1

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch -D "$branch"
  fi

  git fetch --prune
  info "Pull Request merged and local repository cleaned."
}

latest_version_tag() {
  git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -n1
}

create_release() {
  in_repository || {
    warn "This folder is not a Git repository."
    return 1
  }
  github_ready || return 1

  local branch base latest version
  branch="$(current_branch)"
  base="$(default_branch)"

  [[ "$branch" == "$base" ]] || {
    warn "Releases must be created from '$base'."
    return 1
  }

  working_tree_dirty && {
    warn "The working folder has pending changes."
    return 1
  }

  git fetch origin || return 1
  git pull --ff-only || return 1

  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$base")" ]]; then
    warn "The local and remote main branches do not point to the same commit."
    return 1
  fi

  latest="$(latest_version_tag)"
  info "Latest version: ${latest:-none}"
  read -r -p "New version tag (for example v1.2.3): " version

  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    warn "Use semantic version format: vMAJOR.MINOR.PATCH."
    return 1
  }

  if git rev-parse --verify --quiet "refs/tags/$version" >/dev/null; then
    warn "Tag '$version' already exists locally."
    return 1
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1; then
    warn "Tag '$version' already exists on GitHub."
    return 1
  fi

  explain "Create an annotated Git tag, publish it, and create a GitHub Release."
  confirm "Create release $version from the current main commit?" || return 0

  git tag -a "$version" -m "Release $version" || return 1

  if ! git push origin "$version"; then
    git tag -d "$version" >/dev/null
    warn "The tag could not be published and was removed locally."
    return 1
  fi

  gh release create "$version" --generate-notes || {
    warn "The tag was published, but the GitHub Release could not be created."
    return 1
  }
}

new_project() {
  [[ ! -e .git ]] || {
    warn "This folder is already a Git repository."
    return 1
  }

  require_command git || return 1
  explain "Initialize this folder, create safe defaults, make the first commit, and optionally publish it."

  git init -b main || return 1
  [[ -f README.md ]] || printf '# %s\n' "$(basename "$PWD")" >README.md
  setup_gitignore || return 1

  local path
  while IFS= read -r -d '' path; do
    stage_path "$path" || true
  done < <(git ls-files --others --exclude-standard -z)

  [[ -n "$(git diff --cached --name-only)" ]] || {
    warn "No safe files are available for the initial commit."
    return 1
  }

  git diff --cached --check || {
    warn "Whitespace warnings were found in the initial files."
    confirm "Continue with the initial commit?" || return 0
  }

  git commit -m "chore: initial version" || return 1

  if command -v gh >/dev/null 2>&1 && confirm "Create and publish a GitHub repository now?"; then
    local visibility
    read -r -p "Visibility [private] (private/public): " visibility
    visibility="${visibility:-private}"
    [[ "$visibility" == "private" || "$visibility" == "public" ]] || {
      warn "Visibility must be private or public."
      return 1
    }

    gh auth status >/dev/null 2>&1 || gh auth login || return 1
    gh repo create "$(basename "$PWD")" "--$visibility" --source=. --remote=origin --push
  fi
}

install_global() {
  local target="$HOME/.local/bin/gitx"
  mkdir -p "$(dirname "$target")"
  cp "$0" "$target"
  chmod +x "$target"
  info "Installed gitx $VERSION at $target"

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "Add \$HOME/.local/bin to PATH, then open a new terminal." ;;
  esac
}

uninstall_global() {
  local target="$HOME/.local/bin/gitx"
  confirm "Remove the global gitx installation?" || return 0
  rm -f "$target"
  info "Global gitx installation removed."
}

show_help() {
  cat <<EOF
gitx $VERSION

Usage:
  gitx
  gitx --verbose
  gitx --quiet
  gitx --doctor
  gitx --setup-git
  gitx --setup-gitignore
  gitx --show-config
  gitx --restore-config
  gitx --install
  gitx --uninstall
  gitx --version
EOF
}

menu() {
  while true; do
    msg "gitx $VERSION — guided Git and GitHub"
    cat <<'EOF'
1) Start a new task
2) Show project status
3) Create a commit
4) Publish branch and create Pull Request
5) Validate and merge Pull Request
6) Create version and GitHub Release
7) Create and publish a new project
8) Configure .gitignore
9) Configure global Git and GitHub
D) Run diagnosis
V) Toggle short explanations
0) Exit
EOF

    local choice
    read -r -p "Choose an option: " choice

    case "$choice" in
      1) start_task ;;
      2) show_status ;;
      3) create_commit ;;
      4) create_pull_request ;;
      5) merge_pull_request ;;
      6) create_release ;;
      7) new_project ;;
      8) setup_gitignore ;;
      9) setup_git ;;
      D | d) doctor ;;
      V | v)
        if $VERBOSE; then
          VERBOSE=false
        else
          VERBOSE=true
        fi
        save_settings
        info "Short explanations: $VERBOSE"
        ;;
      0) return 0 ;;
      *) warn "Invalid option." ;;
    esac

    pause
  done
}

case "${1:-}" in
  --verbose)
    VERBOSE=true
    save_settings
    menu
    ;;
  --quiet)
    VERBOSE=false
    save_settings
    menu
    ;;
  --doctor) doctor ;;
  --setup-git) setup_git ;;
  --setup-gitignore) setup_gitignore ;;
  --show-config) git config --global --list --show-origin ;;
  --restore-config) restore_git_config ;;
  --install) install_global ;;
  --uninstall) uninstall_global ;;
  --version) printf '%s\n' "$VERSION" ;;
  --help | -h) show_help ;;
  "") menu ;;
  *)
    warn "Unknown option: $1"
    show_help
    exit 1
    ;;
esac
