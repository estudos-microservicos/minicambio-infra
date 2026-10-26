#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke test do MiniCâmbio rodando no Docker Compose.

.DESCRIPTION
    Com o ambiente no ar (docker compose up --build -d), exercita os fluxos principais através das APIs e do
    nginx do frontend. Termina com código de saída 1 se qualquer verificação falhar.
    Funciona no PowerShell 7 (pwsh) e no Windows PowerShell 5.1.

.EXAMPLE
    ./smoke-test.ps1
#>
[CmdletBinding()]
param(
    [string]$OrdersUrl = 'http://localhost:5000',
    [string]$RatesUrl = 'http://localhost:5001',
    [string]$PaymentsUrl = 'http://localhost:5002',
    [string]$WebUrl = 'http://localhost:3000',
    [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# HttpClient em vez de Invoke-WebRequest: não lança exceção em 4xx/5xx e se comporta igual no 5.1 e no 7.
Add-Type -AssemblyName System.Net.Http
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(30)
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:CompletedOrderId = $null

# ------------------------------------------------------------------------------------------------ helpers

function Invoke-Api {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Url,
        $Body = $null,
        [hashtable]$Headers = @{}
    )

    $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method)), $Url
    [void]$request.Headers.TryAddWithoutValidation('X-Correlation-Id', "smoke-$([guid]::NewGuid().ToString('N').Substring(0, 12))")
    foreach ($name in $Headers.Keys) {
        [void]$request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name])
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $request.Content = New-Object System.Net.Http.StringContent $json, ([System.Text.Encoding]::UTF8), 'application/json'
    }

    try {
        $response = $script:Http.SendAsync($request).GetAwaiter().GetResult()
    }
    catch {
        return [pscustomobject]@{ Status = 0; Body = $null; Text = $_.Exception.Message; ContentType = '' }
    }

    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $contentType = ''
    if ($response.Content.Headers.ContentType) { $contentType = $response.Content.Headers.ContentType.MediaType }
    $parsed = $null
    if ($contentType -like '*json*' -and $text) { $parsed = $text | ConvertFrom-Json }

    [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $parsed; Text = $text; ContentType = $contentType }
}

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Status($Response, [int]$Expected) {
    if ($Response.Status -ne $Expected) {
        throw "esperado HTTP $Expected, recebido $($Response.Status): $($Response.Text)"
    }
}

function Invoke-Step([string]$Name, [scriptblock]$Action) {
    Write-Host "==> $Name" -ForegroundColor Cyan
    try {
        & $Action
        Write-Host '    OK' -ForegroundColor Green
    }
    catch {
        $script:Failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "    FALHOU: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Wait-Http200([string]$Url) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $response = Invoke-Api -Method GET -Url $Url
        if ($response.Status -eq 200) { return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "$Url não respondeu 200 em $TimeoutSeconds s (último status: $($response.Status))"
}

function New-OrderBody {
    param(
        [string]$Currency = 'USD',
        [string]$Side = 'Buy',
        [decimal]$Amount = 1000,
        [string]$Name = 'Maria Silva',
        [string]$Country = 'BR'
    )
    @{
        currency      = $Currency
        side          = $Side
        foreignAmount = $Amount
        beneficiary   = @{ name = $Name; country = $Country; accountNumber = '123456789' }
    }
}

function New-Order($Body, [string]$IdempotencyKey = [guid]::NewGuid().ToString()) {
    Invoke-Api -Method POST -Url "$OrdersUrl/api/v1/orders" -Body $Body -Headers @{ 'Idempotency-Key' = $IdempotencyKey }
}

function New-QuotedOrder($Body) {
    $response = New-Order $Body
    Assert-Status $response 201
    Assert-That ($response.Body.status -eq 'Quoted') "ordem criada com status $($response.Body.status), esperado Quoted"
    $response.Body
}

function Confirm-Order([string]$Id) {
    $response = Invoke-Api -Method POST -Url "$OrdersUrl/api/v1/orders/$Id/confirm"
    Assert-Status $response 200
    $response.Body
}

function Get-Order([string]$Id) {
    $response = Invoke-Api -Method GET -Url "$OrdersUrl/api/v1/orders/$Id"
    Assert-Status $response 200
    $response.Body
}

function Wait-OrderStatus([string]$Id, [string]$Expected) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $order = Get-Order $Id
        if ($order.status -eq $Expected) { return $order }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "ordem $Id não chegou a $Expected em $TimeoutSeconds s (status atual: $($order.status))"
}

# ------------------------------------------------------------------------------------------------ verificações

Invoke-Step '1. Serviços prontos (/health/ready das APIs e /healthz do web)' {
    Wait-Http200 "$RatesUrl/health/ready"
    Wait-Http200 "$PaymentsUrl/health/ready"
    Wait-Http200 "$OrdersUrl/health/ready"
    Wait-Http200 "$WebUrl/healthz"
}

Invoke-Step '2. Ordem válida: Quoted -> confirmar -> Completed' {
    $order = New-QuotedOrder (New-OrderBody)
    Assert-That ($order.canConfirm -and $order.canCancel) 'ordem Quoted deveria ter canConfirm e canCancel'
    $confirmed = Confirm-Order $order.id
    Assert-That ($confirmed.status -in @('Confirmed', 'PaymentRequested')) "status após confirmar: $($confirmed.status)"
    $completed = Wait-OrderStatus $order.id 'Completed'
    Assert-That (-not $completed.canConfirm -and -not $completed.canCancel) 'ordem Completed não deveria permitir ações'
    $script:CompletedOrderId = $order.id
}

Invoke-Step '3. Beneficiário "FAIL Teste" -> Failed com BENEFICIARY_REJECTED' {
    $order = New-QuotedOrder (New-OrderBody -Name 'FAIL Teste')
    [void](Confirm-Order $order.id)
    $failed = Wait-OrderStatus $order.id 'Failed'
    Assert-That ($failed.failureReason -eq 'BENEFICIARY_REJECTED') "failureReason: $($failed.failureReason)"
}

Invoke-Step '4. Cancelar (204) -> Cancelled; confirmar depois -> 422' {
    $order = New-QuotedOrder (New-OrderBody -Currency 'EUR' -Side 'Sell' -Amount 250.5)
    $cancel = Invoke-Api -Method DELETE -Url "$OrdersUrl/api/v1/orders/$($order.id)"
    Assert-Status $cancel 204
    $cancelled = Get-Order $order.id
    Assert-That ($cancelled.status -eq 'Cancelled') "status após cancelar: $($cancelled.status)"
    $confirm = Invoke-Api -Method POST -Url "$OrdersUrl/api/v1/orders/$($order.id)/confirm"
    Assert-Status $confirm 422
}

Invoke-Step '5. Cancelar ordem já Completed -> 422' {
    Assert-That ($null -ne $script:CompletedOrderId) 'depende da ordem concluída no passo 2'
    $cancel = Invoke-Api -Method DELETE -Url "$OrdersUrl/api/v1/orders/$script:CompletedOrderId"
    Assert-Status $cancel 422
}

Invoke-Step '6. Mesmo Idempotency-Key duas vezes -> mesma ordem' {
    $key = [guid]::NewGuid().ToString()
    $body = New-OrderBody -Currency 'GBP' -Amount 10
    $first = New-Order $body $key
    $second = New-Order $body $key
    Assert-Status $first 201
    Assert-That ($second.Status -in @(200, 201)) "segunda criação devolveu HTTP $($second.Status)"
    Assert-That ($first.Body.id -eq $second.Body.id) "ids diferentes: $($first.Body.id) e $($second.Body.id)"
}

Invoke-Step '7. Moeda XYZ -> 422' {
    $response = New-Order (New-OrderBody -Currency 'XYZ')
    Assert-Status $response 422
}

Invoke-Step '8. Proxy do nginx: GET /api/v1/orders pelo web -> 200' {
    $response = Invoke-Api -Method GET -Url "$WebUrl/api/v1/orders"
    Assert-Status $response 200
    Assert-That ($null -ne $response.Body.items) 'resposta sem items'
}

Invoke-Step '9. Fallback de SPA: GET /orders/qualquer-coisa pelo web -> 200 com HTML' {
    $response = Invoke-Api -Method GET -Url "$WebUrl/orders/qualquer-coisa"
    Assert-Status $response 200
    Assert-That ($response.ContentType -eq 'text/html') "Content-Type: $($response.ContentType)"
    Assert-That ($response.Text -match '<div id="root">') 'HTML não parece ser o index.html do app'
}

# ------------------------------------------------------------------------------------------------ resultado

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "Smoke test FALHOU ($($script:Failures.Count) verificação(ões)):" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Smoke test passou: todas as verificações OK.' -ForegroundColor Green
exit 0
