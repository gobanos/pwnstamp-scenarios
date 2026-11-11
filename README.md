# pwnstamp scenarios

The scenarios of [pwnstamp](https://github.com/gobanos/pwnstamp): one directory per scenario,
with its Compose project (`compose.yaml`) and the app it runs. The platform derives each
scenario's run definition and identity from them.

Want a target? Open an issue with a challenge request.

Every scenario has a page at `https://scenarios.pwnstamp.org/<scenario id>/`: its tuple, run and
VM definitions, and a bundle to reproduce it. Pages are never removed: when a scenario changes,
its previous id keeps its page, marked superseded. Each pull request lists the ids a merge would
publish.

## Adding a scenario

A directory named after the scenario (`[a-z0-9-]`), holding:

- `compose.yaml`: one service with `expose` (the target), images pinned by platform manifest
  digest, read-only bind volumes, and an `x-pwnstamp` block:

  ```yaml
  x-pwnstamp:
    name: node:26.13.0-trixie-slim   # the target's official image reference
    vm: "2026.11.10"                 # a https://github.com/gobanos/pwnstamp-vm release
  ```

- the app it mounts, with the info page (`info.html`, the same in every scenario).

`scripts/site.sh ids` prints the id of each scenario, and `scripts/site.sh build DIR` builds the
site into `DIR` (see the script for what it needs).

## Run one locally

```sh
cd node-26-13-0-trixie-slim && docker compose up
```

## License

MIT or Apache-2.0, at your option.
