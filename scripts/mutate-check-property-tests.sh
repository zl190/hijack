#!/bin/sh
# One mutation per PropertyTests invariant (Tests/HijackCoreTests/PropertyTests.swift), each run through
# scripts/mutate-check.sh. Committed so the check is reproducible, not something run once by hand.
# review 6, S8 added #5 (the other half of line 12) and #6 (the surviving mutant the review read out:
# stop()'s mode.toggle && !mode.switchesInput branch), after the invariants were strengthened to one
# talkKeyDown bool. Exit 0 only when every mutation goes red, then green again on restore.
set -u
cd "$(dirname "$0")/.."
status=0
run() {
    echo "---- $1 ----"
    scripts/mutate-check.sh Sources/Core/SessionMachine.swift "$2" PropertyTests || status=1
}

# 1. Invariant (line 12, first half): quit from starting/listening must go to idle.
run "1. line 12 (quit from starting/listening must go to idle)" \
    's/return (\.idle, s == \.listening ? \[\.releaseTalkKey\] : \[\])/return (s, s == .listening ? [.releaseTalkKey] : [])/'

# 2. Invariant (line 4): in hold mode, a release from listening must yield releaseTalkKey.
run "2. line 4 (hold-mode release from listening must release the talk key)" \
    's/let release: \[SessionEffect\] = s == \.listening ? \[\.releaseTalkKey\] : \[\]/let release: [SessionEffect] = []/'

# 3. Invariant (lines 2, 4, 7, 11, 12): sendTalkKey/releaseTalkKey strictly alternate.
run "3. lines 2, 4, 7, 11, 12 (releaseTalkKey must not repeat without a sendTalkKey between)" \
    's/case (_, \.quit): return (s, \[\])/case (_, .quit): return (s, [.releaseTalkKey])/'

# 4. Invariant (lines 2, 4, 7, 11, 12): begin/finish must wait for the previous sendTalkKey to close.
run "4. lines 2, 4, 7, 11, 12 (begin must wait for the previous sendTalkKey to close)" \
    's/return mode\.toggle \? stop(\.swallowKey) : (s, \[\.swallowKey\])  \/\/ hold: a repeat, swallowed/return mode.toggle ? start([.swallowKey]) : (s, [.swallowKey])  \/\/ hold: a repeat, swallowed/'

# 5. Invariant (line 12, second half): quit elsewhere must leave the state unchanged, not just "not idle".
run "5. line 12, other half (quit outside starting/listening must leave the state exactly as it was)" \
    's/case (_, \.quit): return (s, \[\])/case (_, .quit): return (.idle, [])/'

# 6. Invariant (line 4): review 6's own surviving mutant — a toggle-mode app session (mode.toggle &&
# !mode.switchesInput) must still release the talk key when it stops, same as every other case of stop().
# The old, hold-mode-only check at line 4 could not see this; the strengthened "key is up at every finish"
# check (line 7) does, because stop() emits finish and releaseTalkKey together in that branch.
run "6. line 4 (toggle-mode app session must still release the talk key on stop)" \
    's/let release: \[SessionEffect\] = s == \.listening ? \[\.releaseTalkKey\] : \[\]/let release: [SessionEffect] = s == .listening \&\& !(mode.toggle \&\& !mode.switchesInput) ? [.releaseTalkKey] : []/'

exit $status
