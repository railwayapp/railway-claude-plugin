#!/usr/bin/env pwsh
# Railway GraphQL API helper for Windows PowerShell
# Usage: ./railway-api.ps1 '<graphql-query>' ['<variables-json>']

$ErrorActionPreference = "Stop"

# Check for jq (optional on Windows, we can use ConvertFrom-Json)
# For full jq support, install via: winget install jqlang.jq

$ConfigFile = Join-Path $env:USERPROFILE ".railway\config.json"

if (-not (Test-Path $ConfigFile)) {
    Write-Output '{"error": "Railway config not found. Run: railway login"}'
    exit 1
}

try {
    $config = Get-Content $ConfigFile | ConvertFrom-Json
    $Token = $config.user.token
} catch {
    Write-Output '{"error": "Failed to parse Railway config. Run: railway login"}'
    exit 1
}

if ([string]::IsNullOrEmpty($Token) -or $Token -eq "null") {
    Write-Output '{"error": "No Railway token found. Run: railway login"}'
    exit 1
}

if ([string]::IsNullOrEmpty($args[0])) {
    Write-Output '{"error": "No query provided"}'
    exit 1
}

$Query = $args[0]
$Variables = if ($args[1]) { $args[1] | ConvertFrom-Json } else { $null }

$Payload = @{
    query = $Query
}

if ($Variables) {
    $Payload.variables = $Variables
}

$Body = $Payload | ConvertTo-Json -Depth 10 -Compress

try {
    $Response = Invoke-RestMethod `
        -Uri "https://backboard.railway.com/graphql/v2" `
        -Method Post `
        -Headers @{
            "Authorization" = "Bearer $Token"
            "Content-Type" = "application/json"
        } `
        -Body $Body `
        -ErrorAction Stop
    
    $Response | ConvertTo-Json -Depth 10
} catch {
    Write-Output ('{{"error": "{0}"}}' -f $_.Exception.Message.Replace('"', "'"))
    exit 1
}