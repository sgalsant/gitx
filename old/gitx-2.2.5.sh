#!/usr/bin/env bash
# gitx 2.2.1
set +u
V=2.2.5
C="$HOME/.config/gitx"
ask(){ read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]; }
msg(){ printf '\n%s\n' "$*"; }
info(){ printf '• %s\n' "$*"; }
warn(){ printf '⚠ %s\n' "$*" >&2; }
repo(){ git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
branch(){ git branch --show-current; }
main(){ r=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true);[ -n "$r" ]&&{ echo "$r"|sed 's#origin/##';return; };git show-ref --verify --quiet refs/heads/main&&{ echo main;return; };git show-ref --verify --quiet refs/heads/master&&{ echo master;return; };git branch --show-current; }
slug(){ printf '%s' "$1"|iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null|tr '[:upper:] ' '[:lower:]-'|sed 's/[^a-z0-9-]//g;s/--*/-/g;s/^-//;s/-$//'; }
status(){
  repo||{ warn "Not a Git repository.";return; }
  staged=$(git diff --cached --name-only|wc -l);changed=$(git diff --name-only|wc -l);new=$(git ls-files --others --exclude-standard|wc -l)
  msg "Project status"
  info "Current branch: $(branch)";info "Main branch: $(main)";info "Remote: $(git remote get-url origin 2>/dev/null||echo not-configured)"
  if [ "$staged" -eq 0 ]&&[ "$changed" -eq 0 ]&&[ "$new" -eq 0 ];then info "Working folder: clean";else warn "Pending changes — staged: $staged, modified: $changed, new: $new";info "Use option 1 to create a task branch, then option 3 to save them.";fi
}
doctor(){
  msg "gitx diagnosis";command -v git >/dev/null||{ warn "Git is not installed.";return; };info "Git: $(git --version)";status
  command -v gh >/dev/null&&{ gh auth status >/dev/null 2>&1&&info "GitHub CLI: authenticated as $(gh api user --jq .login 2>/dev/null)"||warn "GitHub CLI: not authenticated"; }||warn "GitHub CLI is not installed."
  info "Commit identity: $(git config --global user.name||echo unset) <$(git config --global user.email||echo unset)>"
}
setup(){ mkdir -p "$C/backups";[ -f "$HOME/.gitconfig" ]&&cp "$HOME/.gitconfig" "$C/backups/gitconfig-$(date +%s)";read -r -p "Name: " n;read -r -p "Email: " e;git config --global user.name "$n";git config --global user.email "$e";git config --global init.defaultBranch main;git config --global pull.ff only;git config --global fetch.prune true;git config --global push.autoSetupRemote true;git config --global push.default simple;git config --global core.autocrlf input;git config --global merge.conflictStyle zdiff3;command -v gh>/dev/null&&ask "Configure GitHub CLI?"&&{ gh auth status||gh auth login;gh auth setup-git;}; }
ignore(){ f="$(git rev-parse --show-toplevel)/.gitignore";mkdir -p "$C/gitignore-backups";[ -f "$f" ]&&cp "$f" "$C/gitignore-backups/gitignore-$(date +%s)";touch "$f";for x in .env '.env.*' '!.env.example' '*.pem' '*.key' credentials.json secrets.json .DS_Store Thumbs.db Desktop.ini '*:Zone.Identifier' '*.log' '*.tmp' .cache/ tmp/ temp/ coverage/ .coverage htmlcov/ dist/ build/ out/ '.venv-*/';do grep -Fqx "$x" "$f"||echo "$x">>"$f";done;read -r -p "Stack python/node/java/dotnet/docker: " s;case "$s" in python)x='__pycache__/ *.py[cod] .venv/ venv/ .pytest_cache/ .ruff_cache/ .mypy_cache/ .pyright/ *.egg-info/';;node)x='node_modules/ npm-debug.log* yarn-debug.log* pnpm-debug.log* .vite/ .next/ .nuxt/';;java)x='*.class target/ .gradle/ bin/';;dotnet)x='bin/ obj/ .vs/ *.user *.suo';;docker)x='docker-data/ volumes/';;esac;for y in $x;do grep -Fqx "$y" "$f"||echo "$y">>"$f";done; }
new(){ git init -b main;[ -f README.md ]||echo "# $(basename "$PWD")">README.md;ignore;git add -A;git commit -m "chore: initial version";command -v gh>/dev/null&&ask "Publish GitHub repo?"&&gh repo create "$(basename "$PWD")" --private --source=. --remote=origin --push; }
task(){ repo||{ warn "Not a Git repository.";return; };m=$(main);[ -n "$m" ]||{ warn "Could not detect the main branch.";return; };git switch "$m"&&git pull --ff-only;read -r -p "Type [feature]: " t;read -r -p "Name: " n;[ -n "$t" ]||t=feature;t=$(slug "$t");n=$(slug "$n");[ -n "$t" ]&&[ -n "$n" ]||{ warn "Enter a valid branch name.";return; };info "Creating branch: $t/$n";git switch -c "$t/$n"; }
sensitive(){ case "$1" in .env|.env.*|*.pem|*.key|credentials.json|secrets.json|.venv-*|venv/*|node_modules/*) return 0;; *) return 1;; esac; }
stage_file(){ if sensitive "$1";then warn "Skipped protected local file: $1";else git add -- "$1";fi; }
commit(){
  repo||{ warn "Not a Git repository.";return; }
  # -z keeps spaces, accents and apostrophes in paths intact. Human-readable
  # git status output may quote those paths, which must not be passed to git add.
  mapfile -d '' -t records < <(git status --porcelain=v1 -z)
  files=()
  for record in "${records[@]}";do
    files+=("${record:3}")
  done
  [ "${#files[@]}" -gt 0 ]||{ info "There are no changes to commit.";return; }
  msg "Choose what to include in this commit"
  for i in "${!files[@]}";do printf '%d) %s\n' "$((i+1))" "${files[i]}";done
  echo "A) Add all safe files   N) Choose file numbers   P) Choose parts of files   C) Cancel"
  read -r -p "Choice: " choice
  case "$choice" in
    A|a) for file in "${files[@]}";do stage_file "$file";done;;
    N|n) read -r -p "Numbers separated by spaces: " numbers;for n in $numbers;do [[ "$n" =~ ^[0-9]+$ ]]&&[ "$n" -gt 0 ]&&[ "$n" -le "${#files[@]}" ]&&stage_file "${files[n-1]}";done;;
    P|p) git add -p;;
    *) return;;
  esac
  if ! git diff --cached --check;then
    warn "Git found trailing spaces. They do not prevent saving this commit."
    ask "Continue without changing those spaces?"||return
  fi
  [ -n "$(git diff --cached --name-only)" ]||{ warn "No files are selected.";return; }
  msg "Files selected for this commit";git diff --cached --name-status
  ask "Create the commit with these files?"||return
  read -r -p "Type [feat]: " t;read -r -p "Description: " d;[ -n "$t" ]||t=feat;[ -n "$d" ]||{ warn "A description is required.";return; };git commit -m "$t: $d"
}
pr(){
  repo||{ warn "Not a Git repository.";return; }
  m=$(main);b=$(branch)
  [ "$b" != "$m" ]||{ warn "Create a task branch first.";return; }
  git log --format=%H "$m..HEAD"|grep -q .||{ warn "There is no commit on this branch yet. Choose option 3 first.";return; }
  git push -u origin HEAD
  gh pr view --json number >/dev/null 2>&1&&gh pr view||gh pr create --base "$m" --fill
}
merge(){ gh pr view&&gh pr checks --watch;ask "Squash merge?"&&{ b=$(git branch --show-current);m=$(main);gh pr merge --squash --delete-branch&&git switch "$m"&&git pull --ff-only&&ask "Delete local branch?"&&git branch -D "$b";git fetch --prune;}; }
release(){ read -r -p "Tag: " v;git tag -a "$v" -m "Release $v";git push origin "$v";command -v gh>/dev/null&&ask "Create GitHub release?"&&gh release create "$v" --generate-notes; }
install(){ mkdir -p "$HOME/.local/bin";cp "$0" "$HOME/.local/bin/gitx";chmod +x "$HOME/.local/bin/gitx"; }
menu(){ while :;do echo "gitx $V: 1 task 2 status 3 commit 4 PR 5 merge 6 release 7 new 8 ignore 9 setup D doctor V verbose 0 exit";read -r -p "Choose: " x;case "$x" in 1)task;;2)status;;3)commit;;4)pr;;5)merge;;6)release;;7)new;;8)ignore;;9)setup;;D|d)doctor;;V|v)echo "Verbose explanations are enabled for this run.";;0)break;;esac;done; }
case "$1" in --install)install;;--setup-git)setup;;--setup-gitignore)ignore;;--doctor)status;git config --global --list;;--version)echo "$V";;--help|-h)echo "gitx: --install --setup-git --setup-gitignore --doctor";;*)menu;;esac
