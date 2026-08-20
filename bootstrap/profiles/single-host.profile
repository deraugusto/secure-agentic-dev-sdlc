# Profile · single-host
#
# One machine for everything except git. Dev, reviewer and sink co-locate. This
# is a supported and honest configuration -- it just declares fewer guarantees,
# and the bootstrap will not let you forget which ones.

PROFILE_NAME="single-host"
PROFILE_SUMMARY="Everything on one box except git. Fewest moving parts."

PROFILE_PROVISIONER_DEFAULT="none"
# L5 is off by default here, and that is not an oversight. The deploy target
# would be the dev host, which collapses the targets != dev separation; the
# inventory validator refuses that combination rather than accepting it
# quietly. Enable L5 only once you have somewhere else to deploy to.
PROFILE_LAYERS_DEFAULT="l0=true l1=true l2=true l3=true l4=true l5=false"
PROFILE_PROVISIONS_MODEL="no"

profile_not_delivered() {
  cat <<'TXT'
  Two of the three load-bearing separations survive on a single host. The third
  does not, and the difference is worth being precise about:

  · git != dev SURVIVES, because git stays remote. The server-side hook remains
    outside the reach of a compromised dev host, which is the whole reason that
    separation is load-bearing.

  · reviewer model != author model SURVIVES. It is a property of the weights,
    not of the hardware. A reviewer on the same box is still a second opinion
    as long as it is a different family.

  · targets != dev DOES NOT SURVIVE if you deploy to this same machine. The
    hand that writes code would reach the running service directly, and the
    deployment boundary becomes decorative. That is why L5 defaults to off in
    this profile. If you turn it on and point it at localhost, the validator
    refuses -- deliberately, and it is not overridable by a flag.

  The reviewer also shares a blast radius with the code it reviews. An agent
  that can write to this filesystem can reach the reviewer's own files; the
  apparatus hash check is what turns that from silent into loud, which is a
  detection property, not a prevention one.
TXT
}
