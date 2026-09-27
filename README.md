# crucible-action

`crucible` is a CLI that deploys a project to `crucibled`, a service running on one machine on your Tailscale tailnet. The CLI reads a `crucible.yml` file describing the project, connects to the machine over the tailnet, and streams the deploy's progress. This action installs `crucible`, joins the tailnet as an ephemeral, tagged node, and runs the deploy from a GitHub Actions job.

## What the action does

1. Resolves the project name, either from the `project` input or from the top-level `project:` key of the project file, and validates it.
2. Downloads the matching `crucible` CLI release from `jaisonerick/crucible`, using a fine-grained token, and verifies it against `SHA256SUMS`.
3. Joins the tailnet as an ephemeral node tagged `tag:ci-<project>`, using [`tailscale/github-action`](https://github.com/tailscale/github-action).
4. Resolves the machine's tailnet address and runs `crucible deploy`, passing the registry token on stdin so it never appears in a log or in a process listing.

The join step waits up to three minutes for the machine to answer on the tailnet, accepting a relayed path, before the deploy step runs. A machine the tailnet policy hides from `tag:ci-<project>` fails there, before `crucible deploy` starts.

## Prerequisites

### The machine owner does

Grant the project to the CI tag, once per project:

```sh
crucible project grant example tag:ci-example
```

### The tailnet admin does

- Creates the tag `tag:ci-<project>` and a grant from it to the machine, on `tcp:7080`.
- Creates a Tailscale federated identity for the project's repository, scoped to `auth_keys`:
  - Issuer: `https://token.actions.githubusercontent.com`
  - Subject: `repo:<owner>/<repo>:ref:refs/heads/main`
  - Tags: `tag:ci-<project>`

A job that declares an `environment:` gets a different OIDC subject (it includes the environment name), so the subject pattern above only matches a job with no `environment:` key, running on `main`.

### The project repository holds

- Secret `CRUCIBLE_TOKEN`: a fine-grained personal access token with read-only Contents access on `jaisonerick/crucible`.
- Variables `TS_CLIENT_ID` and `TS_AUDIENCE`: the federated identity's client ID and audience, from the Terraform resource above. Neither is a secret.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: read
      id-token: write
    steps:
      - uses: actions/checkout@v5
      - uses: jaisonerick/crucible-action@v1
        with:
          tag: ${{ github.sha }}
          crucible-token: ${{ secrets.CRUCIBLE_TOKEN }}
          tailscale-client-id: ${{ vars.TS_CLIENT_ID }}
          tailscale-audience: ${{ vars.TS_AUDIENCE }}
```

### OAuth client alternative

Use an OAuth client and secret instead of workload identity federation:

```yaml
      - uses: jaisonerick/crucible-action@v1
        with:
          tag: ${{ github.sha }}
          crucible-token: ${{ secrets.CRUCIBLE_TOKEN }}
          tailscale-client-id: ${{ vars.TS_CLIENT_ID }}
          tailscale-oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
```

## Inputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `tag` | yes | | Image tag passed to `crucible deploy`, usually `${{ github.sha }}` |
| `crucible-token` | yes | | Token that can read `jaisonerick/crucible` releases |
| `tailscale-client-id` | yes | | Federated identity (or OAuth client) ID |
| `tailscale-audience` | no | `''` | Federated identity audience, for workload identity federation |
| `tailscale-oauth-secret` | no | `''` | OAuth client secret, the alternative to workload identity federation |
| `project` | no | `''` | Project name; when empty, read from the file's `project:` key |
| `file` | no | `crucible.yml` | Project file |
| `machine` | no | `crucible` | The machine's tailnet short name |
| `crucible-version` | no | `latest` | Release to download: `latest`, `0.8.0` or `v0.8.0` |
| `registry` | no | `ghcr.io` | Registry the registry token authenticates to |
| `registry-user` | no | `${{ github.actor }}` | Registry username |
| `registry-token` | no | `${{ github.token }}` | Registry token passed to the machine for this deploy; empty means images are public |

This action declares no outputs.

## Behaviour

The job fails when the deploy fails, and the failure message names the deploy number and the reason reported by the machine. Cancelling the job does not cancel the deploy: it keeps running on the machine, and `crucible status <project>` shows how it ends. The ephemeral tailnet node is removed at the end of the job, whether the job succeeds or fails. The registry token is the job's own `GITHUB_TOKEN` (or whatever the caller passes in `registry-token`): it lives only as long as the job, and the machine keeps no registry login after the deploy finishes.

## Security notes

`crucible-token` and `registry-token` are masked in the log as soon as the action reads them, and the registry token is only ever passed to `crucible deploy` on stdin, never as a command-line argument. `crucible` itself never prints the registry token. Pin this action by commit SHA, the same way this action pins `tailscale/github-action`, rather than by a mutable tag.
