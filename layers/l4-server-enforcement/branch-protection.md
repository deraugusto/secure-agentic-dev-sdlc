# Branch protection · the recipe, and the part it cannot cover

The pre-receive hook and branch protection do different jobs and neither
replaces the other. The hook evaluates the *content* of a push. Branch
protection constrains *who* may push *what shape of history* to *which ref*.
Run both.

## What to set, on any forge

| Setting | Value | Why |
|---|---|---|
| Force push | denied on the default branch | A force push rewrites history the audit trail refers to. The hook sees the new state, not the state you lost. |
| Branch deletion | denied on the default branch | Belt and braces: the hook refuses this too, and the two controls fail differently. |
| Push restriction | the smallest set of accounts that actually needs it | The dev host's key is one compromise away from being the attacker's key. |
| Linear history | required, if your workflow tolerates it | Makes `old_sha..new_sha` mean what the hook assumes it means. |
| Signed commits | required, if you have key management | The hook records the signer key and decides nothing on it, on purpose — identity decisions belong here, not in a content guard. |

### Gitea

Repository → Settings → Branches → Add rule for `main`:
enable *Protected*, *Block force push*, *Block deletion*, optionally
*Require signed commits*, and set *Whitelisted users* for push access.

### GitLab

Settings → Repository → Protected branches: `main`, *Allowed to push* set to
the smallest role that works, *Allowed to force push* off. Under Settings →
Repository → Push rules, *Reject unsigned commits* if you sign.

### Plain ssh remote

There is no UI. The equivalents are filesystem permissions on the bare
repository and `receive.denyDeletes` / `receive.denyNonFastForwards` in its
config:

```sh
git -C /path/to/repo.git config receive.denyDeletes true
git -C /path/to/repo.git config receive.denyNonFastForwards true
```

This is, in fairness, the cleanest of the three: the hook and these two config
keys are the whole of the enforcement, and both live on the server.

---

## github.com · the known limit

**github.com does not run pre-receive hooks.** They exist on GitHub Enterprise
Server only. `install-pre-receive.sh --remote` refuses rather than installing
something weaker under the same name.

What you can build there instead:

1. Branch protection with *Require status checks to pass before merging*.
2. A workflow that runs the same evaluation the hook does, on `push` and
   `pull_request`.
3. *Require a pull request before merging*, so direct pushes to the default
   branch are impossible and the check has somewhere to attach.

### The gap, stated plainly

This is **weaker**, in three specific ways, and it is worth knowing which:

- **CI runs after the ref has moved.** A push to a feature branch is accepted
  and then evaluated. The destructive change is already in the repository; you
  learn about it, you do not prevent it. Only merges into a protected branch
  are actually gated.
- **Required checks gate merges, not pushes.** The property the hook has — *no
  ref update happens at all* — is not available.
- **Administrators can override.** Most forges let a sufficiently privileged
  account dismiss a failing check. Pre-receive has no such affordance, which is
  precisely what makes it worth the awkwardness.

If your repository lives on github.com, L4 is a partial layer. Say so in your
own records rather than carrying a checklist item that reads as done. A
control you believe in and do not have is worse than one you know you lack.

## Verifying it is actually on

Configuration drifts, and the drift is silent. Test the property, not the
setting:

```sh
# expect: rejected
git push --force origin main

# expect: rejected
git push origin --delete main
```

If either succeeds, the protection is not doing what its checkbox says.
