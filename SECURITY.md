# Security Policy

## Known historical secret leak

A Pixeldrain API key was committed to `scripts/deploy-pixeldrain.sh` in the
initial commit and remained in the repo until commit `9d78ea3` ("remove
sensitive file") removed it from the working tree. The key value was:

```
cf0f2917-1083-4989-abf6-00835a21d4d6
```

**The key is still recoverable from git history** (`git log -p --all -- scripts/deploy-pixeldrain.sh`).
Anyone with read access to this repo can retrieve it.

### Action required from the maintainer

1. **Rotate / revoke this key in Pixeldrain immediately.** Removing the file
   from the working tree does NOT invalidate the key — only Pixeldrain's UI
   can do that.
2. After rotating, optionally rewrite the git history to scrub the key from
   all commits. Tools: `git filter-repo`, `BFG Repo-Cleaner`, or GitHub's
   secret scanning. **Force-push will be required** and all clones/forks
   must re-sync.

### How to read deploy secrets correctly going forward

The deleted `scripts/deploy-pixeldrain.sh` should be rewritten (if needed)
to read its API key from an environment variable, e.g.:

```bash
API_KEY="${PIXELDRAIN_API_KEY:?PIXELDRAIN_API_KEY is required}"
```

Never commit real credentials. Use a `.env` file (gitignored) or a secrets
manager for local development, and GitHub Actions / OIDC for CI.
