# minicambio-infra

Orquestração local do MiniCâmbio com Docker Compose: três microserviços .NET (Rates, Payments e Orders),
cada um com o seu PostgreSQL, e o frontend React servido por nginx. Também traz o smoke test e uma coleção de
requisições para exercitar as APIs.

```
Navegador ──► web (nginx :3000) ──/api/*──► orders-api ──► rates-api    (cotações)
                                                 └──────► payments-api (pagamentos mockados)
```

## Clonar os repositórios

Os cinco repositórios precisam ficar lado a lado na mesma pasta, porque o compose faz build a partir dos irmãos
(`../minicambio-rates` etc.):

```powershell
mkdir minicambio; cd minicambio
foreach ($repo in 'rates', 'payments', 'orders', 'web', 'infra') {
    git clone "https://github.com/estudos-microservicos/minicambio-$repo.git"
}
```

```
minicambio/
├── minicambio-rates/
├── minicambio-payments/
├── minicambio-orders/
├── minicambio-web/
└── minicambio-infra/
```

## Subir o ambiente

```powershell
cd minicambio-infra
Copy-Item .env.example .env      # só na primeira vez; ajuste as credenciais se quiser
docker compose up --build -d
docker compose ps                # os 7 containers devem ficar "healthy"
```

As APIs aplicam as próprias migrations ao subir (`Database__ApplyMigrationsOnStartup=true`) e o Rates já cria as
moedas USD, EUR, GBP e CHF. Na primeira vez o build das imagens leva alguns minutos.

## Usar pela interface

Abra **<http://localhost:3000>**:

1. **Nova ordem**: escolha moeda, operação e valor, informe o beneficiário e clique em "Cotar e criar ordem".
2. Na tela da ordem, confirme antes de a cotação (60 s) expirar. O status passa por *Pagamento solicitado* e chega
   a *Concluída* em poucos segundos (a tela se atualiza sozinha).
3. Ou cancele: "Cancelar ordem" → "Sim, cancelar ordem" → status *Cancelada*.

Cenários do mock de pagamentos para testar falhas:

| Cenário | Como criar a ordem | Resultado após confirmar |
|---|---|---|
| Beneficiário recusado | nome contendo `FAIL` (ex.: `FAIL Teste`) | *Falhou* — `BENEFICIARY_REJECTED` |
| Compliance | país Coreia do Norte ou Irã | *Falhou* — `COMPLIANCE_BLOCKED` |
| Limite | valor acima de 100.000 | *Falhou* — `LIMIT_EXCEEDED` |
| Cotação expirada | não confirmar em 60 s | *Expirada* |

## Portas e URLs

| Serviço | Container | Porta no host | URLs úteis |
|---|---|---|---|
| Frontend (nginx) | `web` | `3000` | <http://localhost:3000> · `/healthz` |
| Orders | `orders-api` | `5000` | <http://localhost:5000/scalar> |
| Rates | `rates-api` | `5001` | <http://localhost:5001/scalar> |
| Payments | `payments-api` | `5002` | <http://localhost:5002/scalar> |
| Banco do Rates | `rates-db` | `5433` | |
| Banco do Payments | `payments-db` | `5434` | |
| Banco do Orders | `orders-db` | `5435` | |

As APIs rodam em `Development`, por isso a documentação OpenAPI fica disponível no Scalar (`/scalar`) e em
`/openapi/v1.json`. Cada API expõe `/health/live` (só o processo) e `/health/ready` (inclui o banco), usado no
healthcheck do compose. As portas dos bancos existem apenas para inspeção local (psql, DBeaver etc.), com as
credenciais do `.env`.

## Smoke test

Com o ambiente no ar:

```powershell
./smoke-test.ps1          # PowerShell 7 (pwsh) ou Windows PowerShell 5.1
```

O script aguarda os health checks, cria/confirma/cancela ordens (sucesso, `FAIL Teste`, cancelamento,
idempotência, moeda inválida), valida o proxy `/api` e o fallback de SPA do nginx e termina com código de saída 1
se alguma verificação falhar. Se a política de execução bloquear o script:
`powershell -ExecutionPolicy Bypass -File .\smoke-test.ps1`.

## Coleção de requisições

`requests.http` tem exemplos de todas as rotas dos três serviços (e do nginx). Abra no VS Code com a extensão
REST Client, no JetBrains HTTP Client ou no Visual Studio.

## Redes

Cada banco só é visível para a própria API:

| Rede | Membros |
|---|---|
| `rates-net` | `rates-db`, `rates-api` |
| `payments-net` | `payments-db`, `payments-api` |
| `orders-net` | `orders-db`, `orders-api` |
| `backend` | `rates-api`, `payments-api`, `orders-api` |
| `frontend` | `web`, `orders-api` |

Assim, o `orders-api` não resolve `rates-db` nem `payments-db`, e o `web` só enxerga o `orders-api`.

## Logs e derrubada

```powershell
docker compose logs -f orders-api   # logs de um serviço (JSON, com CorrelationId no escopo)
docker compose down                 # para e remove os containers (mantém os dados)
docker compose down -v              # remove também os volumes dos bancos
```
