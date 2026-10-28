BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Graph.ps1')
    . (Join-Path $PSScriptRoot '..\lib\Render.ps1')
    . (Join-Path $PSScriptRoot '..\lib\Export.ps1')

    function Invoke-TestGit {
        param([string[]]$GitArgs)
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & git @GitArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Test setup failed: $output" }
            return $output
        } finally { $ErrorActionPreference = $previous }
    }

    function New-TestGitContext {
        param([string]$Name)
        $root = Join-Path $TestDrive $Name
        [void](New-Item -ItemType Directory -Path $root)
        $options = @{ GitCommit = $true; GitPush = $true; GitMessage = 'Test export'; GitRemoteUrl = ''; GitBranch = '' }
        return (New-IdsContext -Root $root -Options $options -State $null)
    }

    function New-TestRemote {
        param([string]$Name, [switch]$Seed)
        $remote = Join-Path $TestDrive "$Name.git"
        Invoke-TestGit @('init', '--bare', '--initial-branch=main', $remote) | Out-Null
        if ($Seed) {
            $source = Join-Path $TestDrive "$Name-source"
            Invoke-TestGit @('clone', $remote, $source) | Out-Null
            Set-Content -LiteralPath (Join-Path $source 'existing.md') -Value 'Existing history'
            Invoke-TestGit @('-C', $source, 'add', '.') | Out-Null
            Invoke-TestGit @('-C', $source, '-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Seed') | Out-Null
            Invoke-TestGit @('-C', $source, 'push', 'origin', 'main') | Out-Null
        }
        return $remote
    }
}

Describe 'Git publishing options' {
    It 'makes push imply commit' {
        $options = @{ GitCommit = $false; GitPush = $true; GitRemoteUrl = ''; GitBranch = '' }
        Assert-IdsGitOptions -Options $options
        $options.GitCommit | Should -BeTrue
    }

    It 'accepts Azure DevOps HTTPS and SSH clone URLs' {
        foreach ($url in @(
            'https://dev.azure.com/org/project/_git/docs',
            'https://org.visualstudio.com/project/_git/docs',
            'git@ssh.dev.azure.com:v3/org/project/docs',
            'ssh://git@ssh.dev.azure.com/v3/org/project/docs'
        )) {
            $options = @{ GitCommit = $true; GitPush = $true; GitRemoteUrl = $url; GitBranch = 'docs/update' }
            { Assert-IdsGitOptions -Options $options } | Should -Not -Throw
        }
    }

    It 'rejects credential-bearing, non-Azure, and malformed URLs without echoing credentials' {
        foreach ($url in @(
            'https://user:secret@dev.azure.com/org/project/_git/docs',
            'https://dev.azure.com/org/project/_git/docs?token=secret',
            'https://dev.azure.com.evil.example/org/project/_git/docs',
            'https://dev.azure.com/org/project',
            '--upload-pack=secret'
        )) {
            $options = @{ GitCommit = $true; GitPush = $true; GitRemoteUrl = $url; GitBranch = '' }
            $message = ''
            try { Assert-IdsGitOptions -Options $options } catch { $message = $_.Exception.Message }
            $message | Should -Not -BeNullOrEmpty
            $message | Should -Not -Match 'secret'
        }
    }

    It 'rejects invalid branch names' {
        $options = @{ GitCommit = $true; GitPush = $true; GitRemoteUrl = ''; GitBranch = '--all' }
        { Assert-IdsGitOptions -Options $options } | Should -Throw
    }

    It 'accepts and removes the organization username included in Azure DevOps clone links' {
        $options = @{ GitCommit = $true; GitPush = $true; GitRemoteUrl = 'https://org@dev.azure.com/org/project/_git/docs'; GitBranch = '' }
        Assert-IdsGitOptions -Options $options
        $options.GitRemoteUrl | Should -Be 'https://dev.azure.com/org/project/_git/docs'
    }
}

Describe 'Preparing a publishing repository' {
    It 'clones a populated remote and preserves its history' {
        $ctx = New-TestGitContext 'populated'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'populated-remote' -Seed
        Initialize-IdsGitRepository -Ctx $ctx
        (Get-Content -LiteralPath (Join-Path $ctx.Root 'existing.md')) | Should -Be 'Existing history'
        (Invoke-TestGit @('-C', $ctx.Root, 'log', '-1', '--format=%s')) | Should -Be 'Seed'
    }

    It 'publishes the first commit to an empty remote with upstream tracking' {
        $ctx = New-TestGitContext 'empty'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'empty-remote'
        $ctx.Options.GitBranch = 'documentation'
        Initialize-IdsGitRepository -Ctx $ctx
        Set-Content -LiteralPath (Join-Path $ctx.Root 'index.md') -Value 'Documentation'
        $result = Invoke-IdsGit -Ctx $ctx -Meta @{ generated = 'today' }
        $result.committed | Should -BeTrue
        $result.pushed | Should -BeTrue
        (Invoke-TestGit @('-C', $ctx.Root, 'rev-parse', '--abbrev-ref', '@{upstream}')) | Should -Be 'origin/documentation'
        (Invoke-TestGit @('--git-dir', $ctx.Options.GitRemoteUrl, 'show', 'documentation:index.md')) | Should -Be 'Documentation'
    }

    It 'defaults an empty remote to main' {
        $ctx = New-TestGitContext 'default-branch'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'default-remote'
        Initialize-IdsGitRepository -Ctx $ctx
        (Invoke-TestGit @('-C', $ctx.Root, 'symbolic-ref', '--short', 'HEAD')) | Should -Be 'main'
    }

    It 'creates a new target branch from existing remote history' {
        $ctx = New-TestGitContext 'new-branch'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'branch-remote' -Seed
        $ctx.Options.GitBranch = 'docs'
        Initialize-IdsGitRepository -Ctx $ctx
        (Invoke-TestGit @('-C', $ctx.Root, 'branch', '--show-current')) | Should -Be 'docs'
        (Get-Content -LiteralPath (Join-Path $ctx.Root 'existing.md')) | Should -Be 'Existing history'
    }

    It 'refuses a nonempty output folder that is not a checkout' {
        $ctx = New-TestGitContext 'nonempty'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'nonempty-remote'
        Set-Content -LiteralPath (Join-Path $ctx.Root 'keep.md') -Value 'Keep me'
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*not empty*'
        (Get-Content -LiteralPath (Join-Path $ctx.Root 'keep.md')) | Should -Be 'Keep me'
        (Test-Path -LiteralPath (Join-Path $ctx.Root '.git')) | Should -BeFalse
    }

    It 'refuses to replace a different origin' {
        $ctx = New-TestGitContext 'wrong-remote'
        $original = New-TestRemote 'original-remote' -Seed
        Invoke-TestGit @('clone', $original, $ctx.Root) | Out-Null
        $ctx.Options.GitRemoteUrl = New-TestRemote 'replacement-remote'
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*different origin*'
        (Invoke-TestGit @('-C', $ctx.Root, 'remote', 'get-url', 'origin')) | Should -Be $original
    }

    It 'refuses to publish unrelated local changes' {
        $ctx = New-TestGitContext 'dirty'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'dirty-remote' -Seed
        Invoke-TestGit @('clone', $ctx.Options.GitRemoteUrl, $ctx.Root) | Out-Null
        Set-Content -LiteralPath (Join-Path $ctx.Root 'private.txt') -Value 'Not documentation'
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*uncommitted changes*'
        (Get-Content -LiteralPath (Join-Path $ctx.Root 'private.txt')) | Should -Be 'Not documentation'
    }

    It 'fast-forwards a clean checkout before export' {
        $ctx = New-TestGitContext 'behind'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'behind-remote' -Seed
        Invoke-TestGit @('clone', $ctx.Options.GitRemoteUrl, $ctx.Root) | Out-Null
        $source = Join-Path $TestDrive 'behind-remote-source'
        Set-Content -LiteralPath (Join-Path $source 'existing.md') -Value 'Remote update'
        Invoke-TestGit @('-C', $source, 'add', '.') | Out-Null
        Invoke-TestGit @('-C', $source, '-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Update') | Out-Null
        Invoke-TestGit @('-C', $source, 'push') | Out-Null
        Initialize-IdsGitRepository -Ctx $ctx
        (Get-Content -LiteralPath (Join-Path $ctx.Root 'existing.md')) | Should -Be 'Remote update'
    }

    It 'refuses to create an unrelated history when a populated remote has no valid default branch' {
        $ctx = New-TestGitContext 'missing-default'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'missing-default-remote' -Seed
        Invoke-TestGit @('--git-dir', $ctx.Options.GitRemoteUrl, 'symbolic-ref', 'HEAD', 'refs/heads/missing') | Out-Null
        $ctx.Options.GitBranch = 'new-docs'
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*default branch*'
        (Test-Path -LiteralPath (Join-Path $ctx.Root 'index.md')) | Should -BeFalse
    }

    It 'refuses an origin configured to push to another destination' {
        $ctx = New-TestGitContext 'push-url'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'push-url-remote' -Seed
        Invoke-TestGit @('clone', $ctx.Options.GitRemoteUrl, $ctx.Root) | Out-Null
        Invoke-TestGit @('-C', $ctx.Root, 'remote', 'set-url', '--push', 'origin', 'another-destination') | Out-Null
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*push URL*'
    }

    It 'does not continue a pending merge as an export commit' {
        $ctx = New-TestGitContext 'pending-merge'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'pending-merge-remote' -Seed
        Invoke-TestGit @('clone', $ctx.Options.GitRemoteUrl, $ctx.Root) | Out-Null
        $head = Invoke-TestGit @('-C', $ctx.Root, 'rev-parse', 'HEAD')
        Set-Content -LiteralPath (Join-Path $ctx.Root '.git\MERGE_HEAD') -Value $head
        $ctx.Options.GitRemoteUrl = ''
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*in progress*'
    }

    It 'refuses diverged histories without merging or discarding local commits' {
        $ctx = New-TestGitContext 'diverged'
        $ctx.Options.GitRemoteUrl = New-TestRemote 'diverged-remote' -Seed
        Invoke-TestGit @('clone', $ctx.Options.GitRemoteUrl, $ctx.Root) | Out-Null
        foreach ($checkout in @($ctx.Root, (Join-Path $TestDrive 'diverged-remote-source'))) {
            Set-Content -LiteralPath (Join-Path $checkout 'index.md') -Value $checkout
            Invoke-TestGit @('-C', $checkout, 'add', '.') | Out-Null
            Invoke-TestGit @('-C', $checkout, '-c', 'user.name=Test', '-c', 'user.email=test@localhost', 'commit', '-m', 'Diverged update') | Out-Null
        }
        Invoke-TestGit @('-C', (Join-Path $TestDrive 'diverged-remote-source'), 'push') | Out-Null
        $before = Invoke-TestGit @('-C', $ctx.Root, 'rev-parse', 'HEAD')
        { Initialize-IdsGitRepository -Ctx $ctx } | Should -Throw '*failed*'
        (Invoke-TestGit @('-C', $ctx.Root, 'rev-parse', 'HEAD')) | Should -Be $before
        (Invoke-TestGit @('-C', $ctx.Root, 'status', '--porcelain')) | Should -BeNullOrEmpty
    }
}

Describe 'Committing and pushing documentation' {
    It 'retries a push even when there is nothing new to commit' {
        $ctx = New-TestGitContext 'retry'
        $remote = New-TestRemote 'retry-remote'
        Invoke-TestGit @('init', '--initial-branch=main', $ctx.Root) | Out-Null
        Invoke-TestGit @('-C', $ctx.Root, 'remote', 'add', 'origin', $remote) | Out-Null
        Set-Content -LiteralPath (Join-Path $ctx.Root 'index.md') -Value 'Pending push'
        $ctx.Options.GitPush = $false
        Invoke-IdsGit -Ctx $ctx -Meta @{ generated = 'today' } | Out-Null
        $ctx.Options.GitPush = $true
        $result = Invoke-IdsGit -Ctx $ctx -Meta @{ generated = 'today' }
        $result.committed | Should -BeFalse
        $result.pushed | Should -BeTrue
        (Invoke-TestGit @('--git-dir', $remote, 'show', 'main:index.md')) | Should -Be 'Pending push'
    }

    It 'does not report success when a commit hook rejects the commit' {
        $ctx = New-TestGitContext 'commit-error'
        $ctx.Options.GitPush = $false
        Invoke-TestGit @('init', $ctx.Root) | Out-Null
        [IO.File]::WriteAllText((Join-Path $ctx.Root '.git\hooks\pre-commit'), "#!/bin/sh`nexit 1`n")
        Set-Content -LiteralPath (Join-Path $ctx.Root 'index.md') -Value 'Documentation'
        { Invoke-IdsGit -Ctx $ctx -Meta @{ generated = 'today' } } | Should -Throw
    }

    It 'surfaces a rejected push and preserves the local commit for retry' {
        $ctx = New-TestGitContext 'push-error'
        $remote = New-TestRemote 'push-error-remote'
        Invoke-TestGit @('init', '--initial-branch=main', $ctx.Root) | Out-Null
        Invoke-TestGit @('-C', $ctx.Root, 'remote', 'add', 'origin', $remote) | Out-Null
        [IO.File]::WriteAllText((Join-Path $remote 'hooks\pre-receive'), "#!/bin/sh`nexit 1`n")
        Set-Content -LiteralPath (Join-Path $ctx.Root 'index.md') -Value 'Documentation'
        { Invoke-IdsGit -Ctx $ctx -Meta @{ generated = 'today' } } | Should -Throw
        (Invoke-TestGit @('-C', $ctx.Root, 'log', '-1', '--format=%s')) | Should -Be 'Test export'
    }

    It 'preserves an existing non-origin upstream when no repository URL is supplied' {
        $ctx = New-TestGitContext 'custom-upstream'
        $upstream = New-TestRemote 'custom-upstream-remote' -Seed
        $origin = New-TestRemote 'unused-origin'
        Invoke-TestGit @('clone', '--origin', 'documentation', $upstream, $ctx.Root) | Out-Null
        Invoke-TestGit @('-C', $ctx.Root, 'remote', 'add', 'origin', $origin) | Out-Null
        Set-Content -LiteralPath (Join-Path $ctx.Root 'index.md') -Value 'Documentation'
        $result = Invoke-IdsGit -Ctx $ctx -Meta @{ generated = 'today' }
        $result.pushed | Should -BeTrue
        (Invoke-TestGit @('--git-dir', $upstream, 'show', 'main:index.md')) | Should -Be 'Documentation'
        (Invoke-TestGit @('--git-dir', $origin, 'for-each-ref', '--format=%(refname)')) | Should -BeNullOrEmpty
    }
}

Describe 'Export orchestration with Git publishing' {
    BeforeEach {
        Mock Test-IdsGraphConnection { @{ tenantId = 'test-tenant'; organization = 'Test tenant' } }
        Mock Invoke-IdsGraph { @() }
        Mock Get-IdsGraphStats { @{} }
    }

    It 'prepares the requested branch and publishes a deterministic export when only push is enabled' {
        $ctx = New-TestGitContext 'orchestrated'
        $remote = New-TestRemote 'orchestrated-remote' -Seed
        Invoke-TestGit @('clone', $remote, $ctx.Root) | Out-Null
        $options = $ctx.Options
        $options.GitCommit = $false
        $options.GitBranch = 'docs'
        $options.OutputPath = $ctx.Root
        $options.Sections = @()
        $options.IncludeRaw = $true
        $options.IncludeRawFiles = $true
        $options.FrontMatter = $true
        $options.AdoWikiOrder = $true
        $state = @{ Auth = @{ account = 'Test'; method = 'test' }; Export = @{} }
        Start-IdsExport -State $state -Options $options
        $state.Export.error | Should -BeNullOrEmpty
        $state.Export.summary.git.pushed | Should -BeTrue
        (Invoke-TestGit @('--git-dir', $remote, 'show', 'docs:existing.md')) | Should -Be 'Existing history'
        (Invoke-TestGit @('--git-dir', $remote, 'show', 'docs:.intune-docs-manifest.json')) -join "`n" | Should -Match 'test-tenant'
        $before = Invoke-TestGit @('-C', $ctx.Root, 'rev-parse', 'HEAD')
        Start-IdsExport -State $state -Options $options
        $state.Export.error | Should -BeNullOrEmpty
        $state.Export.summary.git.committed | Should -BeFalse
        $state.Export.summary.git.pushed | Should -BeTrue
        (Invoke-TestGit @('-C', $ctx.Root, 'rev-parse', 'HEAD')) | Should -Be $before
    }

    It 'leaves local-only export independent of Git' {
        $ctx = New-TestGitContext 'local-only'
        $options = $ctx.Options
        $options.OutputPath = $ctx.Root
        $options.GitCommit = $false
        $options.GitPush = $false
        $options.Sections = @()
        $state = @{ Auth = @{ account = 'Test'; method = 'test' }; Export = @{} }
        Start-IdsExport -State $state -Options $options
        $state.Export.error | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $ctx.Root 'index.md')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $ctx.Root '.git')) | Should -BeFalse
    }

    It 'reports invalid publishing options before writing documentation' {
        $ctx = New-TestGitContext 'invalid-options'
        $ctx.Options.OutputPath = $ctx.Root
        $ctx.Options.GitRemoteUrl = 'https://example.invalid/repository'
        $state = @{ Export = @{} }
        Start-IdsExport -State $state -Options $ctx.Options
        $state.Export.error | Should -Match 'clone URL'
        @(Get-ChildItem -LiteralPath $ctx.Root -Force).Count | Should -Be 0
    }
}
