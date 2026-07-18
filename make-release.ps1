# Prepara a pasta site\ para publicação.
#
#   .\make-release.ps1
#
# Junta em site\ tudo que precisa ir pro claybrick.online, pra o deploy ser
# "suba o conteúdo de site\ para o public_html" e você não esquecer um arquivo:
#
#   site\main.html      a página          (fonte, você edita)
#   site\.htaccess      config do Apache  (fonte, você edita)
#   site\install.ps1    o instalador      (CÓPIA de .\install.ps1 — não edite aqui)
#   site\claybrick.zip  o código          (GERADO — não edite)
#
# O zip sai com server/ e plugin/ na raiz, que é o formato que o instalador
# espera. Ficam de fora: o .env (tem a SUA chave da API — nunca vai pro zip
# público), a .venv, o cache do API dump e os __pycache__.

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$stage = Join-Path $env:TEMP "claybrick-release"
$site  = Join-Path $PSScriptRoot "site"
$out   = Join-Path $site "claybrick.zip"

# ---- Versao ----------------------------------------------------------------
# O plugin compara a versao dele com a do servidor e com a do site para decidir
# o que avisar. Se as duas fontes divergirem, ele avisa de atualizacao que nao
# existe (ou fica calado quando deveria avisar) -- e o usuario perde a confianca
# no aviso. Melhor quebrar a build aqui.
$srvVer = (Select-String -Path "server\agent\config.py" -Pattern '^VERSION\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
$plgVer = (Select-String -Path "plugin\ClaudeStudio.luau" -Pattern '^local VERSION\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
if (-not $srvVer) { throw "nao achei VERSION em server\agent\config.py" }
if (-not $plgVer) { throw "nao achei VERSION em plugin\ClaudeStudio.luau" }
if ($srvVer -ne $plgVer) {
    throw "ABORTADO: versoes divergentes -- servidor=$srvVer, plugin=$plgVer. Deixe as duas iguais."
}
Write-Host "versao $srvVer (servidor e plugin batem)" -ForegroundColor Gray

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null

# robocopy devolve 0-7 para sucesso (1 = arquivos copiados), e só >=8 é erro —
# por isso o LASTEXITCODE é zerado na mão, senão o $ErrorActionPreference do
# passo seguinte trata uma cópia bem-sucedida como falha.
robocopy "server" "$stage\server" /E /XD ".venv" ".cache" "__pycache__" /XF ".env" /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy falhou em server\ (código $LASTEXITCODE)" }
robocopy "plugin" "$stage\plugin" /E /XD "__pycache__" /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy falhou em plugin\ (código $LASTEXITCODE)" }
$global:LASTEXITCODE = 0

Copy-Item "README.md" $stage -Force

# Rede de segurança: se um .env escapar para o pacote, é a chave do usuário indo
# para um zip público. Melhor quebrar a build do que descobrir depois.
$leaked = Get-ChildItem $stage -Recurse -Force -Filter ".env"
if ($leaked) { throw "ABORTADO: um .env entrou no pacote ($($leaked[0].FullName))" }

# ---- Impressao digital do conteudo -----------------------------------------
# TEM que ser aqui, com o $stage ainda de pe: mais abaixo ele ja' foi apagado, e
# hashear pasta inexistente devolve o SHA da string vazia -- sempre igual, todo
# build. O guarda de versao esquecida (la' embaixo) nunca dispararia, e daria
# falsa seguranca para sempre.
#
# Hasheia os ARQUIVOS, nao o zip: o zip carrega timestamps, entao seus bytes
# mudam a cada build mesmo sem nada ter mudado.
$sb = New-Object Text.StringBuilder
Get-ChildItem $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [void]$sb.Append($_.FullName.Substring($stage.Length)).Append((Get-FileHash $_.FullName -Algorithm SHA256).Hash)
}
$ms = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($sb.ToString()))
$contentHash = (Get-FileHash -InputStream $ms -Algorithm SHA256).Hash

Remove-Item $out -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $out
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

# O install.ps1 mora na raiz (é a fonte); a cópia em site\ é só o que sobe.
Copy-Item (Join-Path $PSScriptRoot "install.ps1") $site -Force

# ---- version.json ----------------------------------------------------------
# O arquivo que o plugin consulta para saber se saiu versao nova. Fica no site de
# proposito: assim o aviso chega em quem esta com TUDO desatualizado.
#
# As notas saem do CHANGELOG.md e aparecem dentro do plugin, no chat. Sem seccao
# para esta versao a build para: publicar versao sem nota e' avisar "tem coisa
# nova" sem dizer o que -- e aviso vazio ensina a ignorar aviso.
$changelog = Get-Content "CHANGELOG.md" -Raw -Encoding UTF8
$sec = [regex]::Match($changelog, "(?ms)^##\s+" + [regex]::Escape($srvVer) + "\s*\r?\n(.*?)(?=^##\s|\z)")
if (-not $sec.Success) {
    throw "ABORTADO: o CHANGELOG.md nao tem seccao '## $srvVer'. Escreva o que mudou antes de publicar."
}
# Junta as linhas de continuacao ao bullet. Filtrar so' quem comeca com "-"
# jogaria fora a segunda linha de um item quebrado no meio, e a nota chegaria
# cortada na frase -- dentro do plugin, na cara do usuario.
$itens = @()
foreach ($linha in ($sec.Groups[1].Value -split "\r?\n")) {
    $t = $linha.Trim()
    if ($t.StartsWith("-")) { $itens += $t }
    elseif ($t -and $itens.Count -gt 0) { $itens[-1] += " " + $t }
}
$notes = $itens -join "`n"
if (-not $notes) { throw "ABORTADO: a seccao '## $srvVer' do CHANGELOG.md nao tem nenhum item." }

# ConvertTo-Json escapa aspas e quebras de linha sozinho -- montar o JSON com
# string interpolada quebraria no primeiro apostrofo ou acento das notas.
$json = [ordered]@{ version = $srvVer; notes = $notes } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $site "version.json"), $json, (New-Object Text.UTF8Encoding $false))

# ---- Seccao de historico no site -------------------------------------------
# Gerada a partir do MESMO CHANGELOG.md que alimenta o version.json, para as duas
# nao divergirem.
function ConvertTo-SafeHtml([string]$s) {
    $s = $s -replace "&", "&amp;" -replace "<", "&lt;" -replace ">", "&gt;"
    [regex]::Replace($s, '`([^`]+)`', '<code>$1</code>')
}

# "[segurança] texto" vira um chip colorido + o texto. Sem prefixo, so' o texto.
function ConvertTo-Chip([string]$item) {
    $m = [regex]::Match($item, '^\[([^\]]+)\]\s*(.*)$')
    if (-not $m.Success) { return (ConvertTo-SafeHtml $item) }
    $rotulo = $m.Groups[1].Value.Trim()
    $slug = $rotulo.ToLower().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '' -replace '[^a-z0-9]', ''
    "<span class=`"chip chip-$slug`">$(ConvertTo-SafeHtml $rotulo)</span>$(ConvertTo-SafeHtml $m.Groups[2].Value)"
}

$releases = [regex]::Matches($changelog, "(?ms)^##\s+(\d[\w.\-]*)\s*\r?\n(.*?)(?=^##\s|\z)")
if ($releases.Count -eq 0) { throw "ABORTADO: o CHANGELOG.md nao tem nenhuma versao." }

$html = New-Object Text.StringBuilder
foreach ($r in $releases) {
    $ver = $r.Groups[1].Value
    $itens = @()
    foreach ($linha in ($r.Groups[2].Value -split "\r?\n")) {
        $t = $linha.Trim()
        if ($t.StartsWith("-")) { $itens += $t.Substring(1).Trim() }
        elseif ($t -and $itens.Count -gt 0) { $itens[-1] += " " + $t }
    }
    if ($itens.Count -eq 0) { continue }

    $atual = if ($ver -eq $srvVer) { " is-current" } else { "" }
    $badge = if ($ver -eq $srvVer) { "`n          <span class=`"release-badge`">atual</span>" } else { "" }
    [void]$html.Append("`n      <article class=`"release$atual`">")
    [void]$html.Append("`n        <div class=`"release-tag`">")
    [void]$html.Append("`n          <span class=`"release-version`">$ver</span>$badge")
    [void]$html.Append("`n        </div>")
    [void]$html.Append("`n        <ul class=`"release-notes`">")
    foreach ($i in $itens) { [void]$html.Append("`n          <li>$(ConvertTo-Chip $i)</li>") }
    [void]$html.Append("`n        </ul>")
    [void]$html.Append("`n      </article>")
}

$indexPath = Join-Path $site "index.html"
$index = [IO.File]::ReadAllText($indexPath, [Text.UTF8Encoding]::new($false))
$novo = [regex]::Replace(
    $index,
    "(?s)(<!-- CHANGELOG:START -->).*?(<!-- CHANGELOG:END -->)",
    { param($m) $m.Groups[1].Value + $html.ToString() + "`n      " + $m.Groups[2].Value }
)
if ($novo -eq $index -and $index -notmatch "CHANGELOG:START") {
    throw "ABORTADO: nao achei os marcadores CHANGELOG:START/END no index.html."
}
[IO.File]::WriteAllText($indexPath, $novo, [Text.UTF8Encoding]::new($false))
Write-Host "historico no site: $($releases.Count) versoes" -ForegroundColor Gray

# ---- Rede: mudou o codigo e esqueceu de bumpar? ----------------------------
# Este e' o jeito mais facil de quebrar a atualizacao, e ele e' SILENCIOSO: o zip
# novo sobe, o version.json continua na versao velha, e ninguem que ja instalou
# recebe aviso. Nunca. Nada reclama -- por isso reclamamos aqui.
# (O $contentHash foi calculado la' em cima, com o $stage ainda existindo.)
$hash = $contentHash
$statePath = Join-Path $PSScriptRoot ".release-state.json"
$state = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { $null }

if ($state -and $state.version -eq $srvVer -and $state.content_hash -ne $hash) {
    Write-Host ""
    Write-Host "  ATENCAO: o conteudo mudou, mas a versao continua $srvVer." -ForegroundColor Yellow
    Write-Host "  Quem ja instalou NAO vai ser avisado -- para eles, nada mudou." -ForegroundColor Yellow
    Write-Host "  Se isto vai pro ar, suba o VERSION nos dois arquivos e escreva no CHANGELOG.md." -ForegroundColor Yellow
    Write-Host "  (Se e' so' teste local, ignore.)" -ForegroundColor DarkGray
} else {
    # Baseline nova: so' grava quando a versao muda, senao o aviso acima
    # apareceria uma vez so' e sumiria justamente enquanto o erro persiste.
    [ordered]@{ version = $srvVer; content_hash = $hash } | ConvertTo-Json |
        Set-Content $statePath -Encoding UTF8
}

$kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
Write-Host ""
Write-Host "site\ pronto para publicar ($kb KB no zip):" -ForegroundColor Green
Get-ChildItem $site -Force | Where-Object { -not $_.PSIsContainer } |
    ForEach-Object { Write-Host ("   {0,-16} {1,8:N1} KB" -f $_.Name, ($_.Length / 1KB)) }
Write-Host ""
Write-Host "Suba TODOS eles para o public_html (inclusive o .htaccess, que fica" -ForegroundColor Gray
Write-Host "escondido no File Manager ate voce marcar 'Show Hidden Files')." -ForegroundColor Gray
