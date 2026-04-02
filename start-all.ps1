param(
    [int]$PythonPort = 8001,
    [int]$PowerShellPort = 8002,
    [int]$ProxyPort = 8080,
    [switch]$SkipProxy
)

& (Join-Path $PSScriptRoot "scripts\start-all.ps1") `
    -PythonPort $PythonPort `
    -PowerShellPort $PowerShellPort `
    -ProxyPort $ProxyPort `
    -SkipProxy:$SkipProxy
