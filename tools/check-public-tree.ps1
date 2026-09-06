[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Push-Location $repoRoot
try {
    $raw = & git ls-files -z
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed" }
    $tracked = @($raw -split [char]0 | Where-Object { $_ })

    $forbidden = '(?i)(^|/)(AGENTS(?:\.override)?\.md|CLAUDE\.md|CODEX\.md)$|(^|/)(tests?|qa|fixtures|corpus|harness|coverage)(/|$)|(^|/)(console\.txt|[^/]+\.(?:log|zip|tar\.gz|bak))$|(^|/)\.env(?:\..*)?$|(^|/)\.(?:agents|claude|codex)(/|$)'
    $blocked = @($tracked | Where-Object { ($_ -replace '\\','/') -match $forbidden })
    if ($blocked.Count -gt 0) {
        Write-Error ("Forbidden tracked paths:" + [Environment]::NewLine + ($blocked -join [Environment]::NewLine))
    }

    $maxBytes = 25MB
    $oversize = @()
    foreach ($path in $tracked) {
        $sizeText = & git cat-file -s (":" + $path) 2>$null
        if ($LASTEXITCODE -eq 0 -and [int64]$sizeText -gt $maxBytes) {
            $oversize += "$path ($sizeText bytes)"
        }
    }
    if ($oversize.Count -gt 0) {
        Write-Error ("Anomalous tracked files (>25 MiB):" + [Environment]::NewLine + ($oversize -join [Environment]::NewLine))
    }

    $secretPattern = 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{24,}|xox[baprs]-[A-Za-z0-9-]{20,}'
    $secretHits = & git grep --cached -I -n -E $secretPattern -- . ':(exclude)tools/check-public-tree.ps1' 2>$null
    $grepCode = $LASTEXITCODE
    if ($grepCode -eq 0) {
        Write-Error ("Apparent secret material in index:" + [Environment]::NewLine + ($secretHits -join [Environment]::NewLine))
    }
    if ($grepCode -gt 1) { throw "git grep failed with exit code $grepCode" }

    Write-Host "PUBLIC_TREE_GATE PASS: $($tracked.Count) tracked paths checked."
}
finally {
    Pop-Location
}
