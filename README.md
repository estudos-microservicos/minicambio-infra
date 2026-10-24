# minicambio-infra

Orquestração local do MiniCâmbio com Docker Compose: três microserviços .NET (Rates, Payments e Orders),
cada um com o seu PostgreSQL, e o frontend React servido por nginx.

> Repositório em construção (Fase 0: estrutura). O `docker-compose.yml`, o `.env.example`, o smoke test e a
> coleção de requisições entram na Fase 5.

## Repositórios

Os cinco repositórios ficam lado a lado na mesma pasta:

```
minicambio/
├── minicambio-rates/
├── minicambio-payments/
├── minicambio-orders/
├── minicambio-web/
└── minicambio-infra/
```
