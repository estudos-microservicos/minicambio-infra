# minicambio-infra

Orquestração local do MiniCâmbio com Docker Compose: três microserviços .NET (Rates, Payments e Orders),
cada um com o seu PostgreSQL, e o frontend React servido por nginx.

> Em construção: o smoke test (`smoke-test.ps1`) e a coleção de requisições (`requests.http`) entram na Fase 5.

## Repositórios

Os cinco repositórios ficam lado a lado na mesma pasta, porque o compose faz build a partir dos irmãos
(`../minicambio-rates` etc.):

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
Copy-Item .env.example .env      # só na primeira vez; ajuste as credenciais se quiser
docker compose up --build -d
docker compose ps
```

Frontend: <http://localhost:3000>

| Serviço | Container | Porta no host |
|---|---|---|
| Frontend (nginx) | `web` | `3000` |
| Orders | `orders-api` | `5000` |
| Rates | `rates-api` | `5001` |
| Payments | `payments-api` | `5002` |
| Banco do Rates | `rates-db` | `5433` |
| Banco do Payments | `payments-db` | `5434` |
| Banco do Orders | `orders-db` | `5435` |

As portas dos bancos existem apenas para inspeção local (psql, DBeaver etc.). As APIs rodam em
`Development`, então a documentação OpenAPI/Scalar de cada uma fica em `http://localhost:<porta>/scalar`
assim que for implementada.

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
docker compose logs -f orders-api   # logs de um serviço
docker compose down                 # para e remove os containers (mantém os dados)
docker compose down -v              # remove também os volumes dos bancos
```
