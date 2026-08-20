# Profile · proxmox-full
#
# The reference topology: separate containers per role, with a firewall between
# them. This is the arrangement the baseline was extracted from. It is offered
# as one profile among three, not as the recommended shape -- the security
# properties live in the three separations, not in the hypervisor.

PROFILE_NAME="proxmox-full"
PROFILE_SUMMARY="Separate container per role, firewalled. The reference topology."

PROFILE_PROVISIONER_DEFAULT="proxmox"
PROFILE_LAYERS_DEFAULT="l0=true l1=true l2=true l3=true l4=true l5=true"
PROFILE_PROVISIONS_MODEL="yes"

profile_not_delivered() {
  cat <<'TXT'
  This is the only profile that creates infrastructure, so it is the only one
  that can create it in the wrong place. Read the role table above before
  confirming; a mistyped node identifier puts containers on someone else's
  cluster.

  What it still does not give you:

  · Provisioning is a plan, not a promise. bootstrap/provision/proxmox/ emits
    the container and firewall definitions and applies them through the
    hypervisor's own CLI. If that CLI is not reachable, the bootstrap stops
    rather than continuing with a partially built topology.

  · The model pull is the one egress this bootstrap performs, and it is
    confirmed separately. Until it completes, L3 runs with provider=offline,
    which returns a canned verdict: the gate mechanics are real, the review
    is not.

  · Firewall rules are generated from inventory.yaml and constrain the paths
    the baseline uses. They are not a host hardening baseline and do not
    pretend to be one.
TXT
}
