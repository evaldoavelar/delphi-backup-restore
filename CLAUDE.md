# CLAUDE.md — mesmo conteúdo de AGENTS.md (regras para agentes)

## Branches e worktrees
- Integração na branch **`develop`**. A `main` só recebe Pull Requests; cada merge na `main` gera um release
  (ver `.github/workflows/release.yml`).
- **Cada agente trabalha em uma worktree própria dentro da pasta do projeto, em `.wc/<tarefa>`**, numa branch
  criada a partir da `develop`. Exemplo:
  ```
  git worktree add .wc/fix-tela-principal -b fix/tela-principal develop
  ```
  O orquestrador integra a branch na `develop` e remove a worktree (`git worktree remove .wc/<tarefa>`).
  `.wc/` é ignorada pelo Git.
- Nunca trabalhe direto na `main`; nunca faça force-push em `develop`/`main`.

## Commits
- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `ci:`, `refactor:`, `chore:`).
- **Sem** trailers `Co-Authored-By` ou de sessão.

## Código
- Contrato e donos das units: `docs/ARCHITECTURE.md`. Tipos compartilhados: `src/Core.Types.pas`.
- O fonte precisa compilar no **Delphi XE8 ou superior** — regras em `CONTRIBUTING.md` e
  `docs/ARCHITECTURE.md` (sem inline vars, sem DFM, sem ternário, sem System.Threading/System.Net).
- Build: `build.bat` (dcc32). Testes: `build.bat --tests`.
- Nunca rode restore na máquina de desenvolvimento real (escreve no registro e em Program Files); use VM.
