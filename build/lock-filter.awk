# Print every lock line that can be pinned, and drop the ones that cannot.
#
# Two git-snapshot encodings appear in practice: a '+git' release suffix, and a
# '^<count>.git<sha>' version suffix, which duxlabs publishes as
# dux-qt-base-git. Neither resolves to a stable NEVRA, so recording one only
# re-arms the drift gate on the next upstream rebuild.
#
# A caller that sets -v note=1 gets each dropped line on stderr, so a new
# unpinnable package stays visible when the lock is regenerated. The comparator
# leaves note unset, because its contract is to print nothing when the sets
# match.
{
  if (index($0, "+git") || $0 ~ /\^[0-9]+\.git[0-9a-f]+/) {
    if (note) print "note: excluding unpinnable NEVRA: " $0 > "/dev/stderr"
    next
  }
  print
}
