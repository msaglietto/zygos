# Examples

For an offline demonstration with scripted providers and a temporary workspace,
run `./test/e2e/m45/run.sh` from the repository root. It requires Node.js and
git, uses loopback fixtures, and does not need provider credentials.

For a real provider, copy `examples/providers.toml` to the ignored
`providers.local.toml`. Replace `endpoint` and `model` with values from your
provider, and set the same model in a copy of `quickstart/zygos.zon`. Export
the key variable named by `key_env`. The provider catalog format and supported
types are documented in [provider catalog](../docs/specs/providers.md).

```sh
cp examples/providers.toml providers.local.toml
# Edit providers.local.toml and a local copy of quickstart/zygos.zon first.
export AI_PROVIDERS_CONFIG="$PWD/providers.local.toml"
export ZYGOS_CONFIG=/absolute/path/to/your/zygos.zon
# Export your provider key through your usual secret manager or shell setup.
bin="$PWD/zig-out/bin/zygos"
brief="$PWD/examples/quickstart/brief.md"
workspace=$(mktemp -d)
cd "$workspace"
"$bin" mission start "$brief" --no-tui
```

This spends provider tokens and allows commands as your OS user. The token
budget is a cap, not a price guarantee. Read [SECURITY.md](../SECURITY.md) first.
Keep the planning transcript private and inspect the script before running it.

`x5-dogfood/` and `research-radar/` preserve historical route tables and mission
briefs. Their provider slugs/model IDs describe the maintainer's original
catalog; replace their routes with your own or the quickstart default. These
examples do not require access to the maintainer's vault or catalog. The Y5
real-vault acceptance run remains a maintainer gate in `GOAL.md`.
