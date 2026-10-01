---
mission: hello
budget:
  max_tokens: 20000
gates:
  completion: human
---

# Objective

Write a POSIX shell script `hello.sh` in the current workspace that prints
`Hello from Zygos` followed by a newline.

## Success criteria

| Criterion | Verified by |
|---|---|
| Script prints exactly `Hello from Zygos` plus a newline | `sh hello.sh` exits 0; compare stdout with the expected line |
| Script is valid POSIX shell syntax | `sh -n hello.sh` exits 0 |

## Non-goals

- Do not install dependencies or change files outside this workspace.
- Do not fetch remote content or modify the planning control channel.
