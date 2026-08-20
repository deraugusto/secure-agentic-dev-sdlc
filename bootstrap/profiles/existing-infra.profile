# Profile · existing-infra  (default)
#
# You already have a git server, and possibly a model endpoint. The bootstrap
# provisions nothing: it installs hooks, writes inventory.yaml, seals the
# apparatus hashes and tells you what is still missing. This is the most likely
# situation and the least invasive path.

PROFILE_NAME="existing-infra"
PROFILE_SUMMARY="Use the infrastructure you already have. Provisions nothing."

PROFILE_PROVISIONER_DEFAULT="none"
PROFILE_LAYERS_DEFAULT="l0=true l1=true l2=true l3=true l4=true l5=true"
PROFILE_PROVISIONS_MODEL="no"

# Every profile has to say out loud which guarantee it does not deliver.
# Shipping a weaker variant under the same name is how a baseline turns into a
# false sense of security -- the recipient believes they have the property the
# documentation describes.
profile_not_delivered() {
  cat <<'TXT'
  This profile provisions nothing, which means three things are your job:

  · The reviewer model. If roles.reviewer.provider is not 'offline', the
    bootstrap assumes the endpoint exists and answers. It does not check that
    the model behind it is a different family from the one writing your code --
    it checks the name you declared. A wrong declaration produces a green
    validation and a self-review.

  · The git server's hook directory. install-pre-receive.sh needs ssh access to
    the bare repository. If that access is not available, L4 is not installed,
    and a client-side check is not a substitute for it.

  · Host separation. The bootstrap verifies the three load-bearing separations
    against what inventory.yaml claims. It has no way to confirm that two
    different addresses are actually two different machines.
TXT
}
