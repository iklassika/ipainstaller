# AGENTS.md

Правила для агентов, работающих с этим репозиторием.

## Git

- **Если ты opencode**, все коммиты делай с флагом
  `-m "Co-authored-by: opencode-agent[bot] <opencode-agent[bot]@users.noreply.github.com>"`.
  Пример:
  ```sh
  git commit -m "Краткое описание изменений" -m "Co-authored-by: opencode-agent[bot] <opencode-agent[bot]@users.noreply.github.com>"
  ```
- **НИКОГДА НЕ ПЕРЕЗАПИСЫВАТЬ git-конфиг.** Не изменять `git config` (локальный,
  глобальный или системный), файлы `.git/config`, `~/.gitconfig`,
  `$XDG_CONFIG_HOME/git/config`, а также `user.name`, `user.email` и прочие
  настройки git. Ни при каких обстоятельствах, без исключений. Это правило
  имеет наивысший приоритет.
