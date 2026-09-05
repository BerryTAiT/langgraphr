# 04 — File Tree

```
creatingWrapper For LangGraph/
├── 00-project/                        # docs; the single source of truth
│   ├── 01-vision.md 02-glossary.md 03-architecture.md 04-file-tree.md
│   ├── 05-libraries.md 06-api-contracts.md 07-state-schema.md
│   ├── 08-build-process.md 09-error-and-hiding.md
│   └── annotated/                     # full commented code, one MD per file
│       ├── R/   zzz.md client.md server.md schema.md agent.md
│       │        dsl.md compiler.md memory.md
│       ├── py/  app.md registry.md runtime.md graph_spec.md bridge.md
│       └── sh/  setup.md run-dev.md build-pkg.md
├── langgraphr/                        # R package (extracted from annotated/)
│   ├── DESCRIPTION  NAMESPACE  LICENSE  .Rbuildignore
│   ├── R/            zzz.R client.R server.R schema.R agent.R dsl.R
│   │                 compiler.R memory.R
│   ├── inst/server/  app.py registry.py runtime.py graph_spec.py bridge.py
│   │                 requirements.txt pyproject.toml README.md .env.example
│   │                 tests/bridge_smoke.py
│   ├── tests/        testthat.R testthat/test-*.R
│   └── .venv/        (created at first run; gitignored, NOT committed)
├── scripts/          setup_server.ps1 run_server_dev.ps1 build_r_package.ps1
├── examples/         quickstart.R multi_agent.R
├── README.md         (user guide)
├── HISTORY.md        (creation documentation — this project's own log)
└── .gitignore
```

## Ownership map
| File | Responsibility | Authoring file |
|---|---|---|
| `langgraphr/R/*.R` | R package logic | `00-project/annotated/R/*.md` |
| `langgraphr/inst/server/*.py` | Hidden LangGraph server | `00-project/annotated/py/*.md` |
| `scripts/*.ps1` | Setup / dev / build | `00-project/annotated/sh/*.md` |
| `langgraphr/DESCRIPTION`, `NAMESPACE`, `LICENSE`, `.Rbuildignore` | Package metadata | written directly (non-code) |
| config: `requirements.txt`, `pyproject.toml`, `.env.example` | Server metadata | written directly |
| `langgraphr/inst/server/tests/bridge_smoke.py` | Regression test | written directly |
| `examples/*.R` | Demos | written directly (fully commented) |

## Roadmap milestones
| # | Scope | Status |
|---|---|---|
| M1 | Specs (`00-project/01–09`) | done |
| M2 | Annotated MDs (all code) | this build |
| M3 | Real files extracted + server verified | this build |
| M4 | Examples + README + HISTORY | this build |
| M5+ | durable SQLite default, parallel Send, streaming, binary bundles, CRAN/R-universe | later |

## Workflow rule
Real source files are **generated** from `annotated/*.md` code blocks by
`scripts/tools/extract_code.py` (see 08). Never edit real code without editing
its annotated MD first.
