# Permissions

Zygos has no accounts, roles in a token, or database row policies. Scope is the process, the bus worker id, and the policy rules loaded at boot.

## Principals

| Principal | Where it comes from | What it is allowed to do |
|---|---|---|
| Operator | OS user who execs the binary | Everything the process can do: files, shell, network, vault, provider spend. |
| Loopback peer | TCP to `127.0.0.1:port` | Register and invoke functions on a bare kernel. No shared secret. |
| Mission model | Provider HTTP, routed by `step_id` | Emit text and tool calls. Tools run only after policy (and approval, if `ask`). |
| Policy worker | In-process, rules from `policySeed` or a caller-supplied list | Return allow / deny / ask. Default when nothing matches is deny. |
| Approver | TUI key, stdin line, or timeout | Approve or deny a parked ask or the completion gate. Timeout denies. |
| MCP stdio client | Parent process of `mcp-gateway` | Call registered tessera tools. |
| External MCP server | `zygos.zon` `.mcp_servers` argv | Its own tools, registered as `zygos::mcp::<server>::<tool>`, under the same policy seed (allow). |
| Cron | The crontab user | Same as the operator, non-interactively. |

## Resource × operation

| Resource | Operation | Who | Deny case |
|---|---|---|---|
| Bus function | register | Any connected worker | Malformed frame rejected. Last registration wins. |
| Bus function | invoke | Any connected worker | Unknown function → error body. Owner CAS stops a stale worker from deleting a newer registration. |
| Bus function | teardown | Disconnecting owner | Stale generation no-ops (`catalog` CAS). |
| Trigger binding | register / GC | Registrant | Connection-owned bindings die with the connection. Durable bindings survive. |
| Channel | take | Holder of the access key | Single consumer. Wrong key does not take. |
| Workspace file | read / write | `zygos::tools::{read_file,write_file}` | Absolute path, empty path, or lexical `..` escape → `PathEscapesWorkspace`. Symlink to an outside target is not rejected. |
| Shell | execute | `zygos::tools::bash` when policy allows | Policy deny or ask-timeout. No path jail inside the command. |
| URL | fetch | `zygos::tools::web_fetch` when policy allows | Non-http(s), missing host, non-2xx, oversize, non-text. Private hosts are not denied. |
| Search | query | `zygos::tools::web_search` when policy allows and an engine is configured | Unknown engine, missing searxng endpoint, missing brave key, malformed upstream JSON. |
| Mission | start | CLI caller | Bad brief, unknown provider slug, existing substrate without resume or run-stamp, vault checkpoint failure. |
| Mission | complete (`done`) | Gate approval | No gate, bad gate reply, deny, or unanswered timeout (parks). |
| Mission | abort | `missions::abort` | Stops at the next role boundary. |
| Budget scope | record / check | Turn driver | Over limit or unreachable checker stops the turn. |
| Vault path | write via tessera | Continuity, capture, undo | Outside the configured root is the worker's path check. Mission CLI refuses to proceed if the pre-run checkpoint fails. |
| Provider key | attach to outbound HTTP | `provider_boot` | Unknown slug refuses boot. Key material is not a bus argument. |

## Code-enforced vs storage-enforced

Every check above is in process code. There is no database and no row-level security.

Policy match is exact or prefix (`trailing *`) on `tool` or `function_id` (`policy.zig` `matches`). First match wins. The mission CLI does not ship a deny rule for bash.

A turn that omits `policy_function` does not consult the gate. That is the M1 auto path. Mission role turns set the policy function; a hand-rolled `turns::run` caller can forget it. The driver does not invent a default policy function.
