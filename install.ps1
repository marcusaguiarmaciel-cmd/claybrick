# Claybrick - instalador.
#
#   irm https://claybrick.online/install.ps1 | iex
#
# O que ele faz, nesta ordem:
#   1. confere se voce tem Python 3.10+ (se nao tiver, para e diz onde pegar)
#   2. baixa o Claybrick para %LOCALAPPDATA%\Claybrick
#   3. cria o ambiente virtual e instala as dependencias
#   4. copia o plugin para a pasta de Plugins do Roblox Studio
#
# Fora dessas duas pastas ele nao escreve nada, e nao instala nada alem do que
# esta no requirements.txt. Rodar de novo atualiza a instalacao e PRESERVA o
# seu .env -- a chave da API nao se perde.
#
# ESTE ARQUIVO E' ASCII PURO, DE PROPOSITO. Ele chega no usuario via
# `irm | iex`, e o Invoke-RestMethod decodifica o corpo como ISO-8859-1 quando
# a resposta nao traz charset=utf-8 no Content-Type. Isso acontece ANTES do
# script rodar, entao nao ha como corrigir por dentro: qualquer acento aqui
# viraria lixo na tela de quem instala, dependendo do host. Sem acento, funciona
# em qualquer servidor. Nao "conserte" a acentuacao deste arquivo.

$ErrorActionPreference = "Stop"

# O PowerShell 5.1 ainda negocia TLS 1.0 por padrao, e o download falha sem isto.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SourceZip = "https://claybrick.online/claybrick.zip"
$Root      = Join-Path $env:LOCALAPPDATA "Claybrick"
$PluginDir = Join-Path $env:LOCALAPPDATA "Roblox\Plugins"
$MinPython = [version]"3.10"

function Step($msg) { Write-Host "  ..  " -ForegroundColor Cyan -NoNewline; Write-Host $msg }
function Ok($msg)   { Write-Host "  ok  " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Warn($msg) { Write-Host "  !   " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Fail($msg) { Write-Host "  x   " -ForegroundColor Red -NoNewline; Write-Host $msg }

function Find-Python {
    # Devolve o caminho do python.exe, nao o nome do comando: o `py -3` e um
    # launcher, e passar "py -3" adiante como se fosse executavel quebraria
    # todo o resto.
    foreach ($candidate in @("py -3", "python", "python3")) {
        $parts = $candidate.Split(" ")
        $cmd = Get-Command $parts[0] -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }

        # O stub da Microsoft Store se chama python.exe, nao roda nada e ainda
        # abre a loja. Ignorar e o que evita o suporte mais chato do mundo.
        if ($cmd.Source -like "*\WindowsApps\*") { continue }

        $rest = @($parts | Select-Object -Skip 1)
        try {
            $exe = & $parts[0] @rest -c "import sys; print(sys.executable)" 2>$null
            $ver = & $parts[0] @rest -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        } catch { continue }

        if ($exe -and $ver -and ([version]$ver -ge $MinPython)) {
            return [pscustomobject]@{ Exe = "$exe".Trim(); Version = "$ver".Trim() }
        }
    }
    return $null
}

function Install-Claybrick {
    Write-Host ""
    Write-Host "  Claybrick" -ForegroundColor Red -NoNewline
    Write-Host "  -  o Claude construindo dentro do Roblox Studio"
    Write-Host ""

    # ---- 1. Python ---------------------------------------------------------
    $py = Find-Python
    if (-not $py) {
        Fail "Python $MinPython+ nao encontrado."
        Write-Host ""
        Write-Host "      Instale em https://www.python.org/downloads/ e marque" -ForegroundColor Gray
        Write-Host "      'Add python.exe to PATH' na primeira tela do instalador." -ForegroundColor Gray
        Write-Host "      Depois abra um PowerShell novo e rode este comando de novo." -ForegroundColor Gray
        Write-Host ""
        return
    }
    Ok "Python $($py.Version) encontrado"

    # ---- 2. Baixar ---------------------------------------------------------
    $stamp = Get-Random
    $zip   = Join-Path $env:TEMP "claybrick-$stamp.zip"
    $stage = Join-Path $env:TEMP "claybrick-stage-$stamp"
    try {
        Step "Baixando o Claybrick..."
        try {
            Invoke-WebRequest -Uri $SourceZip -OutFile $zip -UseBasicParsing
        } catch {
            Fail "Nao deu para baixar de $SourceZip"
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Gray
            return
        }

        Expand-Archive -Path $zip -DestinationPath $stage -Force

        # Zips costumam vir com uma pasta raiz so; entra nela se for o caso.
        $top = @(Get-ChildItem $stage)
        if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $stage = $top[0].FullName }

        if (-not (Test-Path (Join-Path $stage "server\app.py"))) {
            Fail "O zip baixado nao parece o Claybrick (faltou server\app.py)."
            return
        }

        # ---- 3. Instalar os arquivos --------------------------------------
        # O .env e do usuario e tem a chave da API dentro. Guardar e devolver e
        # o que faz reinstalar nao custar caro.
        $envFile = Join-Path $Root "server\.env"
        $savedEnv = if (Test-Path $envFile) { Get-Content $envFile -Raw } else { $null }

        New-Item -ItemType Directory -Force $Root | Out-Null
        Copy-Item (Join-Path $stage "*") -Destination $Root -Recurse -Force
        Ok "Instalado em $Root"

        if ($savedEnv) {
            # NAO troque por Set-Content -Encoding UTF8: no PS 5.1 isso escreve
            # BOM, e o BOM faz o python-dotenv ler a primeira chave do .env como
            # "<U+FEFF>ANTHROPIC_API_KEY". A chave some sem erro nenhum e o
            # servidor jura que voce nao configurou nada.
            [IO.File]::WriteAllText($envFile, $savedEnv, (New-Object Text.UTF8Encoding $false))
            Ok ".env preservado (sua chave continua la)"
        } elseif (-not (Test-Path $envFile)) {
            Copy-Item (Join-Path $Root "server\.env.example") $envFile -Force
        }

        # ---- 4. Ambiente virtual e dependencias ---------------------------
        $srv    = Join-Path $Root "server"
        $venv   = Join-Path $srv ".venv"
        $venvPy = Join-Path $venv "Scripts\python.exe"

        if (-not (Test-Path $venvPy)) {
            Step "Criando o ambiente virtual..."
            & $py.Exe -m venv $venv
            if (-not (Test-Path $venvPy)) { Fail "Falhou ao criar a venv em $venv"; return }
        }

        Step "Instalando dependencias (demora um pouco na primeira vez)..."
        & $venvPy -m pip install --quiet --upgrade pip
        & $venvPy -m pip install --quiet -r (Join-Path $srv "requirements.txt")
        if ($LASTEXITCODE -ne 0) { Fail "pip falhou ao instalar as dependencias."; return }
        Ok "Dependencias instaladas"

        # ---- 5. Plugin do Studio ------------------------------------------
        # A fonte e' .luau (e' Luau), mas o Studio so' carrega .lua da pasta de
        # Plugins: a extensao .luau existe para ferramentas distinguirem Luau de
        # Lua, e o carregador de plugins locais ficou procurando .lua. Um .luau
        # ali e' ignorado em silencio -- o Studio nem registra que viu o arquivo,
        # e o usuario fica olhando uma aba Plugins vazia sem nenhuma pista.
        New-Item -ItemType Directory -Force $PluginDir | Out-Null
        Copy-Item (Join-Path $Root "plugin\ClaudeStudio.luau") -Destination (Join-Path $PluginDir "ClaudeStudio.lua") -Force
        Remove-Item (Join-Path $PluginDir "ClaudeStudio.luau") -Force -ErrorAction SilentlyContinue
        Ok "Plugin instalado em $PluginDir"

    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:TEMP "claybrick-stage-$stamp") -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- 6. O que falta ----------------------------------------------------
    Write-Host ""
    Warn "Falta escolher quem paga a conta:"
    Write-Host ""
    Write-Host "      Sua chave da API (pago por token)" -ForegroundColor Gray
    Write-Host "        notepad `"$Root\server\.env`"" -ForegroundColor White
    Write-Host "        preencha ANTHROPIC_API_KEY e deixe DEFAULT_BACKEND=api" -ForegroundColor Gray
    Write-Host ""
    Write-Host "      Sua assinatura Pro/Max (usa a cota, nao cobra por token)" -ForegroundColor Gray
    Write-Host "        npm install -g @anthropic-ai/claude-code" -ForegroundColor White
    Write-Host "        claude       # escolha 'Log in with Claude', nao a opcao de API" -ForegroundColor White
    Write-Host "        e ponha DEFAULT_BACKEND=subscription no .env" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Depois disso, para subir a ponte:" -ForegroundColor Gray
    Write-Host "        cd `"$Root\server`"; .\run.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "  No Studio: aba Plugins -> Claude Agent." -ForegroundColor Gray
    # O Studio le a pasta de plugins uma vez, no boot. Com ele aberto, o plugin
    # simplesmente nao aparece -- e nada indica por que.
    Write-Host "  Se o Studio ja estava aberto, feche e abra de novo: ele so' le" -ForegroundColor Gray
    Write-Host "  a pasta de plugins quando inicia." -ForegroundColor Gray
    Write-Host ""
}

Install-Claybrick
