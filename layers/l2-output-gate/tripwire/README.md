# Tripwire directory

Files here exist to be untouched. S3 verifies their hashes on every gate run and
refuses the push if one changed, disappeared, or if a canary token turned up
somewhere in the changeset.

The mechanism is worth what its obscurity is worth, so what ships here is an
example, not a deployment. **Replace it.** Put your own canaries in places an
agent would plausibly wander into and a human would not routinely edit, record
them in `../tripwire.sha256`, and re-seal:

```sh
python3 layers/l2-output-gate/pipeline.py --seal-manifests
```

The canary list is chained into the S3 manifest hash, so editing the list
without re-sealing is itself caught. That closes the obvious attack — rewrite
the list, then rewrite the canary — at the cost of one deliberate command
whenever you change canaries on purpose.

What this does not do: a canary tells you something walked past. It does not
tell you what it did, and it does not stop it. S3 is a smoke detector, not a
door.
