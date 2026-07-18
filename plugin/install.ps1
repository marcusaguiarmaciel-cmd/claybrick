# Instala o plugin na pasta de Plugins do Roblox Studio.
#   .\install.ps1
# Depois, no Studio: aba Plugins -> os plugins recarregam sozinhos (ou reabra).
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$dest = Join-Path $env:LOCALAPPDATA "Roblox\Plugins"
if (-not (Test-Path $dest)) {
    Write-Host "Criando $dest" -ForegroundColor Cyan
    New-Item -ItemType Directory -Force $dest | Out-Null
}

# A FONTE e' .luau (e' Luau, e o editor precisa saber disso), mas o Studio so'
# carrega .lua da pasta de Plugins: a extensao .luau existe justamente para
# ferramentas distinguirem Luau de Lua, e o carregador de plugins locais ficou
# procurando .lua. Um .luau ali dentro e' ignorado em silencio -- o Studio nem
# registra no log que viu o arquivo. Por isso a copia troca a extensao.
Copy-Item ".\ClaudeStudio.luau" -Destination (Join-Path $dest "ClaudeStudio.lua") -Force

# Sobra de instalacoes antigas, que nao carregava. Se ficar, e' so' lixo.
Remove-Item (Join-Path $dest "ClaudeStudio.luau") -Force -ErrorAction SilentlyContinue

Write-Host "Instalado em $dest\ClaudeStudio.lua" -ForegroundColor Green
Write-Host "REINICIE o Studio: a pasta de plugins so' e' lida no boot." -ForegroundColor Yellow
Write-Host "Depois: aba Plugins -> clique em 'Claude Agent'." -ForegroundColor Green
