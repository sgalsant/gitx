# gitx 2.4.0-win - Guided Git and GitHub helper for Windows PowerShell.
# Run directly: powershell -ExecutionPolicy Bypass -File .\gitx.ps1

[CmdletBinding()]
param(
    [switch]$VerboseMode,
    [switch]$Quiet,
    [switch]$Doctor,
    [switch]$SetupGit,
    [switch]$SetupGitignore,
    [switch]$ShowConfig,
    [switch]$RestoreConfig,
    [switch]$Version,
    [switch]$Help,
    [switch]$SkipDiagnosis
)

$script:GitxVersion = '2.4.0-win'
$script:ConfigDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'gitx'
$script:SettingsFile = Join-Path $script:ConfigDir 'settings.json'
$script:BackupDir = Join-Path $script:ConfigDir 'backups'
$script:GitignoreBackupDir = Join-Path $script:ConfigDir 'gitignore-backups'
$script:VerboseExplanations = $false

if (Test-Path -LiteralPath $script:SettingsFile) {
    try {
        $settings = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
        $script:VerboseExplanations = [bool]$settings.VerboseExplanations
    } catch {
        Write-Warning 'Could not read gitx settings; using defaults.'
    }
}

function Write-Message([string]$Text) { Write-Host "`n$Text" }
function Write-Info([string]$Text) { Write-Host "* $Text" }
function Write-Warn([string]$Text) { Write-Warning $Text }
function Pause-Gitx { [void](Read-Host 'Press Enter to continue') }

function Confirm-Gitx([string]$Prompt) {
    $answer = Read-Host "$Prompt [y/N]"
    return $answer -match '^[Yy]([Ee][Ss])?$'
}

function Explain([string]$Text) {
    if ($script:VerboseExplanations) { Write-Message "What this will do: $Text" }
}

function Test-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Warn "Required program not found: $Name"
        return $false
    }
    return $true
}

function Test-InRepository {
    & git rev-parse --is-inside-work-tree 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Get-RepositoryRoot { (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1) }
function Get-CurrentBranch { (& git branch --show-current 2>$null | Select-Object -First 1) }

function Get-DefaultBranch {
    $remoteHead = & git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null | Select-Object -First 1
    if ($remoteHead) { return $remoteHead -replace '^origin/', '' }
    & git show-ref --verify --quiet refs/heads/main 2>$null
    if ($LASTEXITCODE -eq 0) { return 'main' }
    & git show-ref --verify --quiet refs/heads/master 2>$null
    if ($LASTEXITCODE -eq 0) { return 'master' }
    return Get-CurrentBranch
}

function Test-WorkingTreeDirty {
    return [bool](@(& git status --porcelain=v1 2>$null).Count)
}

function Save-Settings {
    New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    @{ VerboseExplanations = $script:VerboseExplanations } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding utf8
}

function ConvertTo-Slug([string]$Value) {
    $normalized = $Value.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder
    foreach ($character in $normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }
    $slug = $builder.ToString().ToLowerInvariant() -replace '\s+', '-' -replace '[^a-z0-9-]', '' -replace '-+', '-'
    return $slug.Trim('-')
}

function Show-Status {
    if (-not (Test-InRepository)) { Write-Warn 'This folder is not a Git repository.'; return }

    $staged = @(& git diff --cached --name-only 2>$null).Count
    $modified = @(& git diff --name-only 2>$null).Count
    $untracked = @(& git ls-files --others --exclude-standard 2>$null).Count
    $branch = Get-CurrentBranch
    $base = Get-DefaultBranch
    $remote = & git remote get-url origin 2>$null | Select-Object -First 1
    if (-not $remote) { $remote = 'not configured' }

    Write-Message 'Project status'
    Write-Info "Current branch: $(if ($branch) { $branch } else { 'detached' })"
    Write-Info "Main branch: $(if ($base) { $base } else { 'not detected' })"
    Write-Info "Remote: $remote"
    if ($staged -eq 0 -and $modified -eq 0 -and $untracked -eq 0) {
        Write-Info 'Working folder: clean'
    } else {
        Write-Warn "Pending changes - staged: $staged, modified: $modified, new: $untracked"
        if ($branch -eq $base) { Write-Info 'Choose option 1 to move these changes to a task branch.' }
        else { Write-Info 'Choose option 3 to prepare a commit.' }
    }
}

function Invoke-Doctor {
    Write-Message 'gitx diagnosis'
    if (-not (Test-Command git)) { return $false }
    Write-Info "Git: $((& git --version) -join ' ')"
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $login = & gh api user --jq .login 2>$null | Select-Object -First 1
            Write-Info "GitHub CLI: authenticated as $(if ($login) { $login } else { 'unknown' })"
        } else { Write-Warn 'GitHub CLI is installed but not authenticated.' }
    } else { Write-Warn 'GitHub CLI is not installed.' }
    $name = & git config --global user.name 2>$null | Select-Object -First 1
    $email = & git config --global user.email 2>$null | Select-Object -First 1
    Write-Info "Commit identity: $(if ($name) { $name } else { 'unset' }) <$(if ($email) { $email } else { 'unset' })>"
    if (Test-InRepository) { Show-Status | Out-Null } else { Write-Info 'Current folder is not a Git repository.' }
}

function Invoke-GitHubQuery([string[]]$Arguments) {
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = 'gh'
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    [void]$process.Start()
    if (-not $process.WaitForExit(5000)) {
        $process.Kill()
        $process.WaitForExit()
        return
    }
    $output = $process.StandardOutput.ReadToEnd()
    [void]$process.StandardError.ReadToEnd()
    if ($process.ExitCode -eq 0) { return $output.TrimEnd("`r", "`n") }
}

function Show-ContextDashboard {
    Write-Message 'Current context'
    if (-not (Test-InRepository)) {
        Write-Info 'Project: none'
        Write-Info 'Task: none'
        Write-Info 'Next recommended step: option 7 - create or publish a project'
        return
    }

    $root = Get-RepositoryRoot
    $project = Split-Path $root -Leaf
    $branch = Get-CurrentBranch
    $base = Get-DefaultBranch
    $staged = @(& git diff --cached --name-only 2>$null).Count
    $modified = @(& git diff --name-only 2>$null).Count
    $untracked = @(& git ls-files --others --exclude-standard 2>$null).Count
    $pending = $staged + $modified + $untracked
    $ahead = (& git rev-list --count "$base..HEAD" 2>$null | Select-Object -First 1)
    if (-not $ahead) { $ahead = 0 }
    $task = if ($branch -eq $base) { 'none' } else { "active - $branch" }
    $prStatus = 'unavailable'
    $checkStatus = 'not checked'
    $prState = ''
    $prDraft = ''
    $prMergeState = ''
    $prNumber = ''
    $prUrl = ''

    if ($branch -ne $base -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        & gh auth status 2>$null | Out-Null
        $ghAuthenticated = $LASTEXITCODE -eq 0
        & git remote get-url origin 2>$null | Out-Null
        $hasOrigin = $LASTEXITCODE -eq 0
        if ($ghAuthenticated -and $hasOrigin) {
            $prLine = Invoke-GitHubQuery -Arguments @('pr', 'list', '--head', $branch, '--state', 'all', '--limit', '1', '--json', 'number,state,isDraft,mergeStateStatus,url', '--jq', '.[] | [.number,.state,.isDraft,.mergeStateStatus,.url] | @tsv')
            if ($prLine) {
                $prNumber, $prState, $prDraft, $prMergeState, $prUrl = $prLine -split "`t", 5
                $prStatus = "#$prNumber - $($prState.ToLowerInvariant())"
                if ($prState -eq 'OPEN') {
                    $checks = Invoke-GitHubQuery -Arguments @('pr', 'checks', $branch, '--json', 'state', '--jq', '.[].state')
                    if (-not $checks) { $checkStatus = 'no automated checks configured' }
                    elseif ($checks -match '(?m)^(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE)$') { $checkStatus = 'failed' }
                    elseif ($checks -match '(?m)^(PENDING|QUEUED|IN_PROGRESS|WAITING|REQUESTED)$') { $checkStatus = 'pending' }
                    else { $checkStatus = 'passed' }
                } elseif ($prState -eq 'MERGED') { $checkStatus = 'completed' }
                else { $checkStatus = 'not applicable' }
            } else { $prStatus = 'not created' }
        }
    }

    if ($branch -eq $base) {
        $recommendation = if ($pending -gt 0) { 'option 1 - move the current changes to a task branch' } else { 'option 1 - start a new task' }
    } elseif ($pending -gt 0) { $recommendation = 'option 3 - create a commit' }
    elseif ([int]$ahead -eq 0) { $recommendation = 'option 3 - create the first commit for this task' }
    elseif ($prState -eq 'OPEN' -and $prDraft -eq 'true') { $recommendation = "mark Pull Request #$prNumber as ready for review" }
    elseif ($prState -eq 'OPEN' -and $prMergeState -eq 'DIRTY') { $recommendation = "resolve the conflicts in Pull Request #$prNumber" }
    elseif ($prState -eq 'OPEN' -and $checkStatus -eq 'failed') { $recommendation = 'review the failed checks before merging' }
    elseif ($prState -eq 'OPEN' -and $checkStatus -eq 'pending') { $recommendation = 'wait for the automated checks' }
    elseif ($prState -eq 'OPEN') { $recommendation = "option 5 - validate and merge Pull Request #$prNumber" }
    elseif ($prState -eq 'MERGED') { $recommendation = 'option 5 - synchronize main and clean the completed branch' }
    elseif ($prState -eq 'CLOSED') { $recommendation = 'review the closed Pull Request before continuing' }
    elseif ($prStatus -eq 'unavailable') { $recommendation = 'GitHub is unavailable - reconnect, then choose option 4' }
    else { $recommendation = 'option 4 - publish the branch and create a Pull Request' }

    Write-Info "Project: $project"
    Write-Info "Main branch: $base"
    Write-Info "Current branch: $branch"
    Write-Info "Task: $task"
    Write-Info "Pending changes: $pending"
    if ($branch -ne $base) { Write-Info "Commits ahead of ${base}: $ahead"; Write-Info "Pull Request: $prStatus" }
    if ($branch -ne $base -and $prStatus -notin @('not created', 'unavailable')) { Write-Info "Checks: $checkStatus" }
    if ($prUrl) { Write-Info "Pull Request URL: $prUrl" }
    Write-Info "Next recommended step: $recommendation"
}

function Backup-GitConfig {
    New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
    $gitConfig = Join-Path $HOME '.gitconfig'
    if (Test-Path -LiteralPath $gitConfig) {
        Copy-Item -LiteralPath $gitConfig -Destination (Join-Path $script:BackupDir "gitconfig-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
    }
}

function Setup-GitConfiguration {
    Explain 'Back up your global Git configuration and apply safe Windows defaults.'
    Backup-GitConfig
    $currentName = & git config --global user.name 2>$null | Select-Object -First 1
    $currentEmail = & git config --global user.email 2>$null | Select-Object -First 1
    $name = Read-Host "Name shown in commits [$currentName]"
    $email = Read-Host "Email shown in commits [$currentEmail]"
    if ($name) { & git config --global user.name $name }
    if ($email) { & git config --global user.email $email }
    if (Confirm-Gitx 'Apply the recommended Windows settings?') {
        & git config --global init.defaultBranch main
        & git config --global pull.ff only
        & git config --global fetch.prune true
        & git config --global push.autoSetupRemote true
        & git config --global push.default simple
        & git config --global core.autocrlf true
        & git config --global merge.conflictStyle zdiff3
        Write-Info 'Recommended Windows settings applied.'
    }
    if ((Get-Command gh -ErrorAction SilentlyContinue) -and (Confirm-Gitx 'Configure Git to use GitHub CLI credentials?')) {
        & gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { & gh auth login; if ($LASTEXITCODE -ne 0) { return } }
        & gh auth setup-git
    }
}

function Restore-GitConfiguration {
    $backup = Get-ChildItem -LiteralPath $script:BackupDir -Filter 'gitconfig-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $backup) { Write-Warn 'No Git configuration backup was found.'; return }
    if (Confirm-Gitx 'Restore the latest global Git configuration backup?') {
        Copy-Item -LiteralPath $backup.FullName -Destination (Join-Path $HOME '.gitconfig') -Force
        Write-Info 'Global Git configuration restored.'
    }
}

function Add-UniqueRule([string]$File, [string]$Rule) {
    if (-not (Select-String -LiteralPath $File -SimpleMatch -Quiet -Pattern $Rule -ErrorAction SilentlyContinue)) {
        Add-Content -LiteralPath $File -Value $Rule -Encoding utf8
    }
}

function Get-DetectedStack {
    if ((Test-Path pyproject.toml) -or (Test-Path requirements.txt) -or (Test-Path uv.lock)) { return 'python' }
    if (Test-Path package.json) { return 'node' }
    if ((Test-Path pom.xml) -or (Test-Path build.gradle) -or (Test-Path build.gradle.kts)) { return 'java' }
    if (Get-ChildItem -Filter '*.csproj' -ErrorAction SilentlyContinue | Select-Object -First 1) { return 'dotnet' }
    if ((Test-Path Dockerfile) -or (Test-Path compose.yml) -or (Test-Path docker-compose.yml)) { return 'docker' }
    return 'none'
}

function Setup-GitignoreFile {
    if (-not (Test-InRepository)) { Write-Warn 'Initialize Git before configuring .gitignore.'; return }
    $root = Get-RepositoryRoot
    $file = Join-Path $root '.gitignore'
    Explain 'Create or extend .gitignore without removing your existing rules.'
    New-Item -ItemType Directory -Force -Path $script:GitignoreBackupDir | Out-Null
    if (Test-Path -LiteralPath $file) { Copy-Item $file (Join-Path $script:GitignoreBackupDir "gitignore-$(Get-Date -Format 'yyyyMMdd-HHmmss')") }
    else { New-Item -ItemType File -Path $file | Out-Null }
    $common = @('.env', '.env.*', '!.env.example', '*.pem', '*.key', 'credentials.json', 'secrets.json', '.DS_Store', 'Thumbs.db', 'Desktop.ini', '*:Zone.Identifier', '*.log', '*.tmp', '*.temp', '.cache/', 'tmp/', 'temp/', 'coverage/', '.coverage', 'htmlcov/', 'dist/', 'build/', 'out/', '.venv/', '.venv-*/', 'venv/')
    $common | ForEach-Object { Add-UniqueRule $file $_ }
    Push-Location $root
    try { $detected = Get-DetectedStack } finally { Pop-Location }
    $stack = Read-Host "Project stack [$detected] (python/node/java/dotnet/docker/none)"
    if (-not $stack) { $stack = $detected }
    $rules = switch ($stack) {
        'python' { @('__pycache__/', '*.py[cod]', '.pytest_cache/', '.ruff_cache/', '.mypy_cache/', '.pyright/', '.ipynb_checkpoints/', '*.egg-info/') }
        'node' { @('node_modules/', 'npm-debug.log*', 'yarn-debug.log*', 'pnpm-debug.log*', '.vite/', '.next/', '.nuxt/') }
        'java' { @('*.class', 'target/', '.gradle/', 'bin/') }
        'dotnet' { @('bin/', 'obj/', '.vs/', '*.user', '*.suo') }
        'docker' { @('docker-data/', 'volumes/') }
        default { @() }
    }
    $rules | ForEach-Object { Add-UniqueRule $file $_ }
    if (Confirm-Gitx 'Ignore local VS Code settings?') { Add-UniqueRule $file '.vscode/' }
    if (Confirm-Gitx 'Ignore local database files?') { @('*.db', '*.sqlite', '*.sqlite3') | ForEach-Object { Add-UniqueRule $file $_ } }
    Write-Info "Updated $file"
    $trackedIgnored = & git -C $root ls-files -ci --exclude-standard 2>$null
    if ($trackedIgnored) { Write-Warn "Some ignored files are already tracked. gitx did not remove them automatically:`n$($trackedIgnored -join "`n")" }
}

function Test-ProtectedPath([string]$Path) {
    $normalized = $Path -replace '\\', '/'
    $base = Split-Path $normalized -Leaf
    if ($normalized -match '(^|/)(\.venv|\.venv-[^/]+|venv|node_modules)(/|$)') { return $true }
    if ($base -eq '.env.example') { return $false }
    return $base -eq '.env' -or $base -like '.env.*' -or $base -like '*.pem' -or $base -like '*.key' -or $base -in @('credentials.json', 'secrets.json')
}

function Test-LargeFile([string]$Path) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).Length -gt 50MB)
}

function Add-SafePath([string]$Path, [string]$Original = '') {
    if ((Test-ProtectedPath $Path) -or ($Original -and (Test-ProtectedPath $Original))) { Write-Warn "Skipped protected local file: $Path"; return $false }
    if (Test-LargeFile $Path) { Write-Warn "Skipped file larger than 50 MB: $Path"; return $false }
    & git add -A -- $Path
    if ($Original) { & git add -A -- $Original }
    return $LASTEXITCODE -eq 0
}

function Get-ChangedPaths {
    $bytes = & git status --porcelain=v1 -z --untracked-files=all 2>$null
    # PowerShell decodes NUL output differently across versions; use UTF-8 bytes from cmd.exe only when necessary.
    $records = ($bytes -join [string][char]0).Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)
    $items = @()
    for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i]
        if ($record.Length -lt 4) { continue }
        $status = $record.Substring(0, 2)
        $path = $record.Substring(3)
        $original = ''
        if ($status.Contains('R') -or $status.Contains('C')) { $i++; if ($i -lt $records.Count) { $original = $records[$i] } }
        if (-not ($items | Where-Object { $_.Path -eq $path })) { $items += [pscustomobject]@{ Path = $path; Original = $original } }
    }
    return $items
}

function Reset-Index {
    & git rev-parse --verify HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { & git reset -q HEAD -- } else { & git rm --cached -r -q --ignore-unmatch . }
}

function New-GitCommit {
    if (-not (Test-InRepository)) { Write-Warn 'This folder is not a Git repository.'; return }
    $root = Get-RepositoryRoot
    Push-Location $root
    try {
        $files = @(Get-ChangedPaths)
        if ($files.Count -eq 0) { Write-Info 'There are no changes to commit.'; return }
        $indexPath = & git rev-parse --git-path index 2>$null | Select-Object -First 1
        $indexExisted = Test-Path -LiteralPath $indexPath
        $indexBackup = Join-Path ([IO.Path]::GetTempPath()) "gitx-index-$([guid]::NewGuid())"
        if ($indexExisted) { Copy-Item -LiteralPath $indexPath -Destination $indexBackup }
        function Restore-Index { if ($indexExisted) { Copy-Item $indexBackup $indexPath -Force } else { Remove-Item $indexPath -Force -ErrorAction SilentlyContinue }; Remove-Item $indexBackup -Force -ErrorAction SilentlyContinue }
        if (& git diff --cached --name-only 2>$null) { Write-Info 'The existing staged selection will be replaced. Unselected files will remain in your working folder.' }
        Write-Message 'Choose what to include in this commit'
        for ($i = 0; $i -lt $files.Count; $i++) { Write-Host "$($i + 1)) $($files[$i].Path)" }
        Write-Host 'A) Add all safe files'; Write-Host 'N) Choose file numbers'; Write-Host 'P) Choose parts interactively'; Write-Host 'C) Cancel'
        $choice = Read-Host 'Choice'
        Reset-Index
        if ($LASTEXITCODE -ne 0) { Restore-Index; return }
        switch -Regex ($choice) {
            '^[Aa]$' { $files | ForEach-Object { Add-SafePath $_.Path $_.Original | Out-Null } }
            '^[Nn]$' { foreach ($number in (Read-Host 'Numbers separated by spaces').Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) { if ($number -match '^\d+$' -and [int]$number -gt 0 -and [int]$number -le $files.Count) { $file = $files[[int]$number - 1]; Add-SafePath $file.Path $file.Original | Out-Null } else { Write-Warn "Ignored invalid selection: $number" } } }
            '^[Pp]$' { & git add -p; if ($LASTEXITCODE -ne 0) { Restore-Index; return } }
            default { Restore-Index; return }
        }
        if (-not (& git diff --cached --name-only 2>$null)) { Write-Warn 'No files are selected.'; Restore-Index; return }
        & git diff --cached --check
        if ($LASTEXITCODE -ne 0 -and -not (Confirm-Gitx 'Git found whitespace warnings. Continue without changing those spaces?')) { Restore-Index; return }
        Write-Message 'Files selected for this commit'; & git diff --cached --name-status
        if (-not (Confirm-Gitx 'Create the commit with exactly these files?')) { Restore-Index; return }
        $type = Read-Host 'Type [feat]'; $scope = Read-Host 'Optional scope'; $description = Read-Host 'Short description'
        if (-not $description) { Write-Warn 'A description is required.'; Restore-Index; return }
        if (-not $type) { $type = 'feat' }; $type = ConvertTo-Slug $type
        $message = if ($scope) { "${type}($(ConvertTo-Slug $scope)): $description" } else { "${type}: $description" }
        & git commit -m $message
        if ($LASTEXITCODE -eq 0) { Remove-Item $indexBackup -Force -ErrorAction SilentlyContinue; Write-Info 'Commit created.' } else { Restore-Index; Write-Warn 'The commit failed; the previous staged selection was restored.' }
    } finally { Pop-Location }
}

function Start-Task {
    if (-not (Test-InRepository)) { Write-Warn 'This folder is not a Git repository.'; return }
    $branch = Get-CurrentBranch; $base = Get-DefaultBranch; $dirty = Test-WorkingTreeDirty
    if (-not $base) { Write-Warn 'Could not detect the main branch.'; return }
    if ($branch -ne $base) {
        if ($dirty) { Write-Warn "You are already working on branch '$branch' with pending changes."; Write-Info 'Use option 3 to create a commit before starting another task.'; return }
        if (-not (Confirm-Gitx "Switch from '$branch' to '$base' and start a different task?")) { return }
        & git switch $base; if ($LASTEXITCODE -ne 0) { return }
    }
    if ($dirty) { Explain 'Create a task branch while keeping the current local changes. The main branch will not be updated first.' }
    else { Explain 'Update the main branch and create a separate branch for this task.'; & git pull --ff-only; if ($LASTEXITCODE -ne 0) { Write-Warn 'The main branch could not be updated. No task branch was created.'; return } }
    $type = Read-Host 'Task type [feature]'; $name = Read-Host 'Short task name'
    if (-not $type) { $type = 'feature' }; $type = ConvertTo-Slug $type; $name = ConvertTo-Slug $name
    if (-not $type -or -not $name) { Write-Warn 'Enter a valid task type and name.'; return }
    $newBranch = "$type/$name"; & git show-ref --verify --quiet "refs/heads/$newBranch"
    if ($LASTEXITCODE -eq 0) { Write-Warn "Branch '$newBranch' already exists."; return }
    & git switch -c $newBranch; if ($LASTEXITCODE -eq 0) { Write-Info "Task branch created: $newBranch" }
}

function Test-GitHubReady {
    if (-not (Test-Command gh)) { return $false }
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn 'GitHub CLI is not authenticated. Run option 9 first.'; return $false }
    & git remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warn 'This repository has no origin remote.'; return $false }
    return $true
}

function New-PullRequest {
    if (-not (Test-InRepository) -or -not (Test-GitHubReady)) { return }
    $branch = Get-CurrentBranch; $base = Get-DefaultBranch
    if ($branch -eq $base) { Write-Warn 'Create a task branch before opening a Pull Request.'; return }
    if (Test-WorkingTreeDirty) { Write-Warn 'There are pending local changes. Choose option 3 before opening the Pull Request.'; return }
    & git log --format=%H "$base..HEAD" 2>$null | Out-Null
    if (-not (& git log --format=%H "$base..HEAD" 2>$null)) { Write-Warn 'There is no commit on this task branch. Choose option 3 first.'; return }
    Explain 'Publish the current task branch and create its Pull Request.'; & git push -u origin HEAD
    if ($LASTEXITCODE -ne 0) { Write-Warn 'The branch could not be published. No Pull Request was created.'; return }
    & gh pr view --json number,url,state 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Info 'A Pull Request already exists for this branch:'; & gh pr view --json number,url,state --jq '"#\(.number) \(.state) \(.url)"'; return }
    & gh pr create --base $base --fill
    if ($LASTEXITCODE -ne 0) { Write-Warn 'GitHub could not create the Pull Request.' }
}

function Remove-CompletedBranch([string]$Branch, [string]$Base) {
    & git switch $Base
    if ($LASTEXITCODE -ne 0) { return }
    & git pull --ff-only
    if ($LASTEXITCODE -ne 0) { return }
    & git show-ref --verify --quiet "refs/heads/$Branch"
    if ($LASTEXITCODE -eq 0) {
        & git branch -D $Branch
        if ($LASTEXITCODE -ne 0) { return }
    }
    & git fetch --prune
    Write-Info 'Main is synchronized and the completed task branch was removed.'
}

function Merge-PullRequest {
    if (-not (Test-InRepository) -or -not (Test-GitHubReady)) { return }
    $branch = Get-CurrentBranch; $base = Get-DefaultBranch
    if ($branch -eq $base) { Write-Warn 'Switch to the task branch whose Pull Request you want to merge.'; return }
    if (Test-WorkingTreeDirty) { Write-Warn 'There are pending local changes. Commit or discard them before merging.'; return }
    & gh pr view 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { Write-Warn "No Pull Request exists for branch '$branch'."; return }
    $state = & gh pr view --json state --jq .state; $draft = & gh pr view --json isDraft --jq .isDraft; $mergeState = & gh pr view --json mergeStateStatus --jq .mergeStateStatus
    if ($state -eq 'MERGED') {
        Write-Info 'This Pull Request has already been merged.'
        if (Confirm-Gitx 'Synchronize main and remove the completed local branch?') { Remove-CompletedBranch $branch $base }
        return
    }
    if ($state -ne 'OPEN') { Write-Warn 'The Pull Request is not open.'; return }; if ($draft -ne 'false') { Write-Warn 'The Pull Request is still a draft.'; return }; if ($mergeState -eq 'DIRTY') { Write-Warn 'The Pull Request has conflicts that must be resolved first.'; return }
    $checks = & gh pr checks --json state --jq '.[].state' 2>$null
    if ($checks -and (@($checks | Where-Object { $_ -notin @('SUCCESS', 'SKIPPED', 'NEUTRAL') }).Count -gt 0)) { Write-Warn 'Some automated checks have not passed.'; & gh pr checks; return }
    Explain 'Squash the task into one commit, merge it, and clean up its branches.'; & gh pr view
    if (-not (Confirm-Gitx 'Squash and merge this Pull Request?')) { return }
    & gh pr merge --squash --delete-branch; if ($LASTEXITCODE -ne 0) { Write-Warn 'GitHub could not merge the Pull Request.'; return }
    Remove-CompletedBranch $branch $base
}

function New-Release {
    if (-not (Test-InRepository) -or -not (Test-GitHubReady)) { return }
    $branch = Get-CurrentBranch; $base = Get-DefaultBranch
    if ($branch -ne $base) { Write-Warn "Releases must be created from '$base'."; return }; if (Test-WorkingTreeDirty) { Write-Warn 'The working folder has pending changes.'; return }
    & git fetch origin; if ($LASTEXITCODE -ne 0) { return }; & git pull --ff-only; if ($LASTEXITCODE -ne 0) { return }
    if ((& git rev-parse HEAD) -ne (& git rev-parse "origin/$base")) { Write-Warn 'The local and remote main branches do not point to the same commit.'; return }
    $latest = & git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | Select-Object -First 1; Write-Info "Latest version: $(if ($latest) { $latest } else { 'none' })"
    $version = Read-Host 'New version tag (for example v1.2.3)'; if ($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { Write-Warn 'Use semantic version format: vMAJOR.MINOR.PATCH.'; return }
    & git rev-parse --verify --quiet "refs/tags/$version"; if ($LASTEXITCODE -eq 0) { Write-Warn "Tag '$version' already exists locally."; return }; & git ls-remote --exit-code --tags origin "refs/tags/$version" 2>$null; if ($LASTEXITCODE -eq 0) { Write-Warn "Tag '$version' already exists on GitHub."; return }
    Explain 'Create an annotated Git tag, publish it, and create a GitHub Release.'; if (-not (Confirm-Gitx "Create release $version from the current main commit?")) { return }
    & git tag -a $version -m "Release $version"; if ($LASTEXITCODE -ne 0) { return }; & git push origin $version
    if ($LASTEXITCODE -ne 0) { & git tag -d $version | Out-Null; Write-Warn 'The tag could not be published and was removed locally.'; return }; & gh release create $version --generate-notes
    if ($LASTEXITCODE -ne 0) { Write-Warn 'The tag was published, but the GitHub Release could not be created.' }
}

function New-Project {
    if (Test-Path .git) { Write-Warn 'This folder is already a Git repository.'; return }; if (-not (Test-Command git)) { return }
    Explain 'Initialize this folder, create safe defaults, make the first commit, and optionally publish it.'; & git init -b main; if ($LASTEXITCODE -ne 0) { return }
    if (-not (Test-Path README.md)) { "# $(Split-Path (Get-Location) -Leaf)" | Set-Content README.md -Encoding utf8 }
    Setup-GitignoreFile
    $paths = & git ls-files --others --exclude-standard
    $paths | ForEach-Object { Add-SafePath $_ | Out-Null }
    if (-not (& git diff --cached --name-only)) { Write-Warn 'No safe files are available for the initial commit.'; return }
    & git diff --cached --check; if ($LASTEXITCODE -ne 0 -and -not (Confirm-Gitx 'Whitespace warnings were found in the initial files. Continue with the initial commit?')) { return }
    & git commit -m 'chore: initial version'; if ($LASTEXITCODE -ne 0) { return }
    if ((Get-Command gh -ErrorAction SilentlyContinue) -and (Confirm-Gitx 'Create and publish a GitHub repository now?')) { $visibility = Read-Host 'Visibility [private] (private/public)'; if (-not $visibility) { $visibility = 'private' }; if ($visibility -notin @('private', 'public')) { Write-Warn 'Visibility must be private or public.'; return }; & gh auth status 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { & gh auth login; if ($LASTEXITCODE -ne 0) { return } }; & gh repo create (Split-Path (Get-Location) -Leaf) "--$visibility" --source=. --remote=origin --push }
}

function Show-Help {
    @"
gitx $script:GitxVersion

Run directly without installation:
  powershell -ExecutionPolicy Bypass -File .\gitx.ps1
  .\gitx.ps1 -SkipDiagnosis

Options:
  -Doctor  -SetupGit  -SetupGitignore  -ShowConfig  -RestoreConfig
  -VerboseMode  -Quiet  -Version  -Help

Quick workflow:
  1) Start a task  2) Work normally  3) Create a commit
  4) Create a Pull Request  5) Validate and merge
  6) Create a Release (optional)

Use R in the menu to refresh the context and its recommended next step.
"@ | Write-Host
}

function Show-Menu {
    Show-ContextDashboard
    while ($true) {
        Write-Message "gitx $script:GitxVersion - guided Git and GitHub"
        @('1) Start a new task', '2) Show project status', '3) Create a commit', '4) Publish branch and create Pull Request', '5) Validate and merge Pull Request', '6) Create version and GitHub Release', '7) Create and publish a new project', '8) Configure .gitignore', '9) Configure global Git and GitHub', 'D) Run diagnosis', 'R) Refresh context and recommendation', 'V) Toggle short explanations', 'H) Show quick workflow help', '0) Exit') | ForEach-Object { Write-Host $_ }
        $choice = Read-Host 'Choose an option'
        switch ($choice.ToUpperInvariant()) {
            '1' { Start-Task; Show-ContextDashboard }; '2' { Show-Status }; '3' { New-GitCommit; Show-ContextDashboard }; '4' { New-PullRequest; Show-ContextDashboard }; '5' { Merge-PullRequest; Show-ContextDashboard }; '6' { New-Release }; '7' { New-Project }; '8' { Setup-GitignoreFile }; '9' { Setup-GitConfiguration }; 'D' { Invoke-Doctor }
            'R' { Show-ContextDashboard }; 'H' { Show-Help }
            'V' { $script:VerboseExplanations = -not $script:VerboseExplanations; Save-Settings; Write-Info "Short explanations: $script:VerboseExplanations" }
            '0' { return }; default { Write-Warn 'Invalid option.' }
        }
        Pause-Gitx
    }
}

if ($Help) { Show-Help }
elseif ($Version) { Write-Output $script:GitxVersion }
elseif ($Doctor) { Invoke-Doctor }
elseif ($SetupGit) { Setup-GitConfiguration }
elseif ($SetupGitignore) { Setup-GitignoreFile }
elseif ($ShowConfig) { & git config --global --list --show-origin }
elseif ($RestoreConfig) { Restore-GitConfiguration }
else {
    if ($VerboseMode) { $script:VerboseExplanations = $true; Save-Settings }
    if ($Quiet) { $script:VerboseExplanations = $false; Save-Settings }
    if (-not $SkipDiagnosis) { Invoke-Doctor }
    Show-Menu
}
