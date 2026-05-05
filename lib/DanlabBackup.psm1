Set-StrictMode -Version Latest

function Initialize-DanlabBackupKey {
    [CmdletBinding()]
    param(
        [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi",
        [switch]$Rotate
    )

    Add-Type -AssemblyName System.Security

    $keyDir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $keyDir)) {
        New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    }

    if ((Test-Path -LiteralPath $KeyPath) -and -not $Rotate) {
        return Get-Item -LiteralPath $KeyPath
    }

    $key = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($key)
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $key,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [System.IO.File]::WriteAllBytes($KeyPath, $protected)
    }
    finally {
        if ($rng) { $rng.Dispose() }
        [Array]::Clear($key, 0, $key.Length)
    }

    return Get-Item -LiteralPath $KeyPath
}

function Get-DanlabBackupKey {
    [CmdletBinding()]
    param(
        [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi"
    )

    Add-Type -AssemblyName System.Security

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Initialize-DanlabBackupKey -KeyPath $KeyPath | Out-Null
    }

    $protected = [System.IO.File]::ReadAllBytes($KeyPath)
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
}

function Get-DanlabFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = $sha.ComputeHash($stream)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Protect-DanlabBackupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi",
        [switch]$DeleteInput
    )

    $key = Get-DanlabBackupKey -KeyPath $KeyPath
    $iv = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $aes = [System.Security.Cryptography.Aes]::Create()
    $input = $null
    $output = $null
    $crypto = $null

    try {
        $rng.GetBytes($iv)
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        }

        $input = [System.IO.File]::OpenRead($InputPath)
        $output = [System.IO.File]::Create($OutputPath)
        $magic = [System.Text.Encoding]::ASCII.GetBytes("DLBKP1`n")
        $output.Write($magic, 0, $magic.Length)
        $output.Write($iv, 0, $iv.Length)

        $crypto = New-Object System.Security.Cryptography.CryptoStream(
            $output,
            $aes.CreateEncryptor(),
            [System.Security.Cryptography.CryptoStreamMode]::Write
        )
        $input.CopyTo($crypto)
        $crypto.FlushFinalBlock()
    }
    finally {
        if ($crypto) { $crypto.Dispose() }
        if ($input) { $input.Dispose() }
        if ($output) { $output.Dispose() }
        if ($rng) { $rng.Dispose() }
        if ($aes) { $aes.Dispose() }
        [Array]::Clear($key, 0, $key.Length)
        [Array]::Clear($iv, 0, $iv.Length)
    }

    if ($DeleteInput) {
        Remove-Item -LiteralPath $InputPath -Force
    }

    return Get-Item -LiteralPath $OutputPath
}

function Unprotect-DanlabBackupFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$KeyPath = "$env:USERPROFILE\.danlab-backup\backup-key.dpapi"
    )

    $key = Get-DanlabBackupKey -KeyPath $KeyPath
    $aes = [System.Security.Cryptography.Aes]::Create()
    $input = $null
    $output = $null
    $crypto = $null

    try {
        $input = [System.IO.File]::OpenRead($InputPath)
        $magic = New-Object byte[] 7
        if ($input.Read($magic, 0, $magic.Length) -ne $magic.Length) {
            throw "Invalid encrypted artifact header."
        }
        $magicText = [System.Text.Encoding]::ASCII.GetString($magic)
        if ($magicText -ne "DLBKP1`n") {
            throw "Unsupported encrypted artifact format."
        }

        $iv = New-Object byte[] 16
        if ($input.Read($iv, 0, $iv.Length) -ne $iv.Length) {
            throw "Invalid encrypted artifact IV."
        }

        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

        $outDir = Split-Path -Parent $OutputPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        }

        $output = [System.IO.File]::Create($OutputPath)
        $crypto = New-Object System.Security.Cryptography.CryptoStream(
            $input,
            $aes.CreateDecryptor(),
            [System.Security.Cryptography.CryptoStreamMode]::Read
        )
        $crypto.CopyTo($output)
    }
    finally {
        if ($crypto) { $crypto.Dispose() }
        if ($input) { $input.Dispose() }
        if ($output) { $output.Dispose() }
        if ($aes) { $aes.Dispose() }
        [Array]::Clear($key, 0, $key.Length)
        if ($iv) { [Array]::Clear($iv, 0, $iv.Length) }
    }

    return Get-Item -LiteralPath $OutputPath
}

function Invoke-DanlabNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$ErrorMessage = "Native command failed."
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage Exit code: $LASTEXITCODE"
    }
}

Export-ModuleMember -Function Initialize-DanlabBackupKey, Get-DanlabBackupKey, Get-DanlabFileSha256, Protect-DanlabBackupFile, Unprotect-DanlabBackupFile, Invoke-DanlabNative
