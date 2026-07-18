# Sobe o servidor-ponte. Rode:  .\run.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path ".\.venv")) {
    Write-Host "Criando ambiente virtual..." -ForegroundColor Cyan
    python -m venv .venv
}

Write-Host "Instalando dependencias..." -ForegroundColor Cyan
& .\.venv\Scripts\python.exe -m pip install --quiet --upgrade pip
& .\.venv\Scripts\python.exe -m pip install --quiet -r requirements.txt

if (-not (Test-Path ".\.env")) {
    Write-Host "AVISO: .env nao encontrado. Copie .env.example para .env e coloque sua ANTHROPIC_API_KEY." -ForegroundColor Yellow
}

# Sem anunciar a porta aqui: ela vem do .env, e este texto era fixo em 8000 --
# ou seja, mentia para quem trocasse a porta. Quem sabe a porta de verdade e o
# proprio uvicorn, que ja imprime a URL certa uma linha abaixo.
Write-Host "Iniciando servidor..." -ForegroundColor Green
& .\.venv\Scripts\python.exe app.py
