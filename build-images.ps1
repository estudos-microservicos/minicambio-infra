#Requires -Version 5.1
<#
.SYNOPSIS
    Constrói as imagens do MiniCâmbio com a tag do commit (Passo 34 do curso de Kubernetes).

.DESCRIPTION
    Para cada serviço pedido, usa o SHA curto do commit atual do repositório irmão (../minicambio-<servico>) como
    tag da imagem: minicambio-rates-api:053d175, por exemplo. A imagem também ganha a etiqueta
    org.opencontainers.image.revision com o SHA completo (docker inspect mostra de qual commit ela veio).

    Recusa construir se algum repositório pedido tiver mudanças sem commit, inclusive arquivos novos: a tag diria
    um commit e a imagem teria outro conteúdo (e um rollout undo voltaria para algo diferente do que o nome diz).
    Confere todos antes de construir o primeiro: ou constrói tudo, ou nada.

    Se a imagem com essa tag já existe, não constrói de novo (a não ser com -Forcar).

    Não mexe no cluster. No fim, mostra o bloco "images:" para colar em k8s/overlays/<ambiente>/kustomization.yaml.
    Depois: apagar os Jobs de migração dos serviços que mudaram de tag (o template do Job é imutável) e rodar
    kubectl apply -k k8s/overlays/<ambiente>.

    Funciona no PowerShell 7 (pwsh) e no Windows PowerShell 5.1.

.EXAMPLE
    ./build-images.ps1
    Os 4 serviços (rates, orders, payments, web).
.EXAMPLE
    ./build-images.ps1 -Servicos rates
    Só o Rates.
.EXAMPLE
    ./build-images.ps1 -Servicos rates,orders -Forcar
    Reconstrói mesmo que a tag já exista (por exemplo, depois de apagar o cache do Docker).
#>
[CmdletBinding()]
param(
    [ValidateSet('rates', 'orders', 'payments', 'web')]
    [string[]]$Servicos = @('rates', 'orders', 'payments', 'web'),
    [switch]$Forcar
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repositório irmão e nome da imagem de cada serviço (os mesmos nomes que a base do Kustomize usa).
# "Migracoes": se o serviço tem Job de migração (o web não tem).
$catalogo = [ordered]@{
    rates    = @{ Repo = 'minicambio-rates';    Imagem = 'minicambio-rates-api';    Migracoes = $true }
    orders   = @{ Repo = 'minicambio-orders';   Imagem = 'minicambio-orders-api';   Migracoes = $true }
    payments = @{ Repo = 'minicambio-payments'; Imagem = 'minicambio-payments-api'; Migracoes = $true }
    web      = @{ Repo = 'minicambio-web';      Imagem = 'minicambio-web';          Migracoes = $false }
}
$raiz = Split-Path -Parent $PSScriptRoot # a pasta que contém os 5 repositórios, lado a lado

# Comandos nativos (git, docker) escrevem progresso no stderr. No Windows PowerShell 5.1, com
# $ErrorActionPreference = 'Stop', isso pode virar erro; aqui o resultado é conferido pelo código de saída.
function Invoke-Nativo([scriptblock]$Comando, [string]$Descricao) {
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $saida = & $Comando } finally { $ErrorActionPreference = $anterior }
    if ($LASTEXITCODE -ne 0) { throw "$Descricao falhou (código $LASTEXITCODE)." }
    $saida
}

# ------------------------------------------------------------------------ 1) conferir todos antes de construir
$plano = @(foreach ($nome in $catalogo.Keys) {
    if ($Servicos -notcontains $nome) { continue }
    $s = $catalogo[$nome]
    $repo = Join-Path $raiz $s.Repo
    if (-not (Test-Path (Join-Path $repo '.git'))) { throw "Repositório não encontrado: $repo" }

    $pendentes = @(Invoke-Nativo { git -C $repo status --porcelain } "git status em $($s.Repo)")
    if ($pendentes.Count -gt 0) {
        Write-Host "$($s.Repo): $($pendentes.Count) arquivo(s) sem commit:" -ForegroundColor Red
        $pendentes | ForEach-Object { Write-Host "    $_" }
        throw "Faça o commit (ou descarte as mudanças) em $($s.Repo) antes de construir: a tag precisa corresponder ao conteúdo."
    }

    $shaCompleto = "$(Invoke-Nativo { git -C $repo rev-parse HEAD } "git rev-parse em $($s.Repo)")".Trim()
    [pscustomobject]@{
        Nome      = $nome
        Repo      = $repo
        Imagem    = $s.Imagem
        Tag       = $shaCompleto.Substring(0, 7)
        Sha       = $shaCompleto
        Migracoes = $s.Migracoes
    }
})

# ------------------------------------------------------------------------ 2) construir o que ainda não existe
foreach ($p in $plano) {
    $ref = "$($p.Imagem):$($p.Tag)"
    $existente = "$(Invoke-Nativo { docker images -q $ref } "docker images")".Trim()
    if ($existente -and -not $Forcar) {
        Write-Host "$ref já existe ($existente): nada a construir" -ForegroundColor DarkGray
        continue
    }
    Write-Host "Construindo $ref ..." -ForegroundColor Cyan
    $inicio = Get-Date
    Invoke-Nativo {
        docker build --label "org.opencontainers.image.revision=$($p.Sha)" -t $ref $p.Repo
    } "docker build de $ref" | Out-Host
    Write-Host ("$ref pronta em {0:N0} s" -f ((Get-Date) - $inicio).TotalSeconds) -ForegroundColor Green
}

# ------------------------------------------------------------------------ 3) o que fazer com as tags
Write-Host ''
Write-Host 'Bloco para k8s/overlays/<ambiente>/kustomization.yaml (tags SEMPRE entre aspas):' -ForegroundColor Cyan
if ($plano.Count -lt $catalogo.Count) {
    Write-Host '(só os serviços pedidos; os outros continuam como estão no overlay)' -ForegroundColor DarkGray
}
Write-Host 'images:'
foreach ($p in $plano) {
    Write-Host "  - name: $($p.Imagem)"
    Write-Host "    newTag: `"$($p.Tag)`""
}

$jobs = @($plano | Where-Object { $_.Migracoes } | ForEach-Object { "$($_.Nome)-migrations" })
Write-Host ''
Write-Host 'Depois de trocar as tags no overlay (só para os serviços cuja tag mudou):' -ForegroundColor Cyan
if ($jobs.Count -gt 0) {
    Write-Host "  kubectl delete job $($jobs -join ' ') -n <namespace>   # template do Job é imutável"
}
Write-Host '  kubectl apply -k k8s/overlays/<ambiente>'
