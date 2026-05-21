# Sync workflow

This repo has two remotes:

| Remote | Purpose |
|---|---|
| `origin` → `mlobo2012/ai-heroes-long-running-agent-harness-internal` (**private**) | Active development. Push experiments here. |
| `public` → `mlobo2012/ai-heroes-long-running-agent-harness` (**public**) | Stable. Only push when work has stabilised internally. |

## Daily workflow

```bash
# normal work
git add -A && git commit -m "..." && git push origin main
```

That pushes to the private mirror only. Nothing visible externally.

## Promoting a release to public

After the change has been validated in the private repo:

```bash
git push public main
```

That moves the same commit history to the public mirror.

## Bringing the two remotes back in sync

If the public repo accepts a community PR or external commit, pull it back into the private repo:

```bash
git fetch public
git merge public/main          # or rebase, depending on history
git push origin main
```

## Tag and release

When a release is ready:

```bash
git tag v0.1.0
git push origin v0.1.0
git push public v0.1.0
gh release create v0.1.0 --repo mlobo2012/ai-heroes-long-running-agent-harness --notes-file CHANGELOG.md
```
