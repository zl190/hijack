#!/bin/sh
# One mutation per PropertyTests invariant (Tests/HijackCoreTests/PropertyTests.swift), each run through
# scripts/mutate-check.sh. Committed so the check is reproducible, not something run once by hand.
# Exit 0 only when every mutation goes red, then green again on restore.
set -u
cd "$(dirname "$0")/.."
status=0
run() {
    echo "---- $1 ----"
    scripts/mutate-check.sh Sources/Core/SessionMachine.swift "$2" PropertyTests || status=1
}

# Invariant (line 12): after quit from starting/listening, the state is idle.
run "line 12: quit from starting/listening must go to idle" \
    's/return (\.idle, s == \.listening ? \[\.releaseTalkKey\] : \[\])/return (s, s == .listening ? [.releaseTalkKey] : [])/'

# Invariant (line 4): in hold mode, a release from listening must yield releaseTalkKey.
run "line 4: hold-mode release from listening must release the talk key" \
    's/let release: \[SessionEffect\] = s == \.listening ? \[\.releaseTalkKey\] : \[\]/let release: [SessionEffect] = []/'

# Invariant (lines 4, 12): releaseTalkKey never appears twice with no sendTalkKey between.
run "lines 4, 12: releaseTalkKey must not repeat without a sendTalkKey between" \
    's/case (_, \.quit): return (s, \[\])/case (_, .quit): return (s, [.releaseTalkKey])/'

# Invariant (lines 2, 4, 7, 11, 12): begin must not arrive before the previous sendTalkKey is closed.
run "lines 2, 4, 7, 11, 12: begin must wait for the previous sendTalkKey to close" \
    's/return mode\.toggle \? stop(\.swallowKey) : (s, \[\.swallowKey\])  \/\/ hold: a repeat, swallowed/return mode.toggle ? start([.swallowKey]) : (s, [.swallowKey])  \/\/ hold: a repeat, swallowed/'

exit $status
