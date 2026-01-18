# JJ Workflow (Parallel Agents)

## One workspace per agent

```sh
jj workspace add ../banjo-<agent>
```

- Run each parallel agent in its own workspace.
- Do not edit the same files across workspaces.

## Sync bookmarks

```sh
jj bookmark track master --remote=origin
```

## Start work

```sh
jj new
jj describe -m "<message>"
```

## Clean up

```sh
jj workspace forget <name>
rm -rf ../banjo-<agent>
```
