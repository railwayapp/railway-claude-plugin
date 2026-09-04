#!/usr/bin/env pwsh
# Auto-approve railway-api.ps1 and railway CLI commands on Windows

$inputJson = [Console]::In.ReadToEnd()
$data = $inputJson | ConvertFrom-Json

$toolName = $data.tool_name
$command = $data.tool_input.command

if ($toolName -ne "Bash") {
    exit 0
}

# Auto-approve railway-api.ps1 calls
if ($command -match "railway-api\.ps1") {
    $response = @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "allow"
            permissionDecisionReason = "Railway API call auto-approved"
        }
    }
    $response | ConvertTo-Json -Compress
    exit 0
}

# Auto-approve railway CLI commands (via npx or direct)
if ($command -match "^(npx\s+railway|railway)\s") {
    $response = @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            permissionDecision = "allow"
            permissionDecisionReason = "Railway CLI command auto-approved"
        }
    }
    $response | ConvertTo-Json -Compress
    exit 0
}

exit 0