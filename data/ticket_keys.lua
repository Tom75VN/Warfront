Warfront = Warfront or {}

-- Public keys of the Worker's membership ticket signatures (decision 0061),
-- by key id. Public on purpose: they only verify. Written by the companion
-- repository's worker/scripts/ticket-key.mjs, at most two at a time (rotation).
-- Empty: no ticket can be verified yet, every player stays unverified, nobody
-- is blocked (OBSERVE mode).
Warfront.TicketKeys = {
  schema = 1,
  keys = {
    ["1"] = "de6c3557b12eef06f2b9c7f386a4fe09e91fd3d3f4fcc1f6fb474caecfc1ad23",
  },
}
