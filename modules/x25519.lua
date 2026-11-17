Warfront = Warfront or {}

local WF = Warfront
local X25519 = {}
WF.X25519 = X25519

-- X25519 key agreement and a sealed short text, for the BattleTag exchange of
-- bridge matchmaking (decision 0127 point 4). A port of TweetNaCl's
-- crypto_scalarmult (public domain) on the field helpers of modules/ed25519.lua
-- (16 limbs of 16 bits, doubles only). Keys are one-use and dropped after the
-- exchange. Lua cannot run in constant time; a timing side channel inside one
-- game client is outside this threat model (a bridge on the path is the
-- attacker, decision 0127 point 7).
--
-- Seal: shared = X25519(mine, theirs); stream = SHA-512(shared .. "WFX1" ..
-- context); cipher = text xor stream; tag = first 8 bytes of SHA-512(shared ..
-- "WFT1" .. context .. cipher); output lowercase hex of cipher then tag.

local floor = math.floor
local Kit = WF.Ed25519 and WF.Ed25519.Kit
local Sha512 = WF.Ed25519 and WF.Ed25519.Sha512
local MAX_TEXT = 48

-- r = 1 swaps p and q, r = 0 keeps them (TweetNaCl sel25519, arithmetic).
local function Sel(p, q, r)
  for i = 0, 15 do
    local t = r * (p[i] - q[i])
    p[i] = p[i] - t
    q[i] = q[i] + t
  end
end

-- q = n * p on Curve25519 (32-byte little-endian tables, index 0 to 31).
local function ScalarMult(q, n, p)
  local Gf, Set, A, Z, M, S = Kit.Gf, Kit.Set, Kit.A, Kit.Z, Kit.M, Kit.S
  local z = {}
  for i = 0, 31 do z[i] = n[i] end
  local top = n[31] % 128
  if top < 64 then top = top + 64 end
  z[31] = top
  z[0] = n[0] - n[0] % 8
  local x = Gf()
  Kit.Unpack25519(x, p)
  local a, b, c, d, e, f = Gf(), Gf(), Gf(), Gf(), Gf(), Gf()
  local k = Gf({ 56129, 1 })
  Set(b, x)
  a[0] = 1
  d[0] = 1
  for i = 254, 0, -1 do
    local r = floor(z[floor(i / 8)] / 2 ^ (i % 8)) % 2
    Sel(a, b, r)
    Sel(c, d, r)
    A(e, a, c)
    Z(a, a, c)
    A(c, b, d)
    Z(b, b, d)
    S(d, e)
    S(f, a)
    M(a, c, a)
    M(c, b, e)
    A(e, a, c)
    Z(a, a, c)
    S(b, a)
    Z(c, d, f)
    M(a, c, k)
    A(a, a, d)
    M(c, c, a)
    M(a, d, f)
    M(d, b, x)
    S(b, e)
    Sel(a, b, r)
    Sel(c, d, r)
  end
  Kit.Inv25519(c, c)
  M(a, a, c)
  Kit.Pack25519(q, a)
end

local function Xor8(a, b)
  local result, place = 0, 1
  for _ = 1, 8 do
    local x, y = a % 2, b % 2
    if x ~= y then result = result + place end
    a, b, place = (a - x) / 2, (b - y) / 2, place * 2
  end
  return result
end

local function ToHex(bytes, n)
  local parts = {}
  for i = 0, n - 1 do parts[#parts + 1] = string.format("%02x", bytes[i]) end
  return table.concat(parts)
end

-- 0-based bytes and count from lowercase or uppercase hex, or nil.
local function FromHex(text)
  if type(text) ~= "string" or string.len(text) % 2 ~= 0 or string.find(text, "[^%x]") then return nil end
  local bytes, n = {}, string.len(text) / 2
  for i = 0, n - 1 do bytes[i] = tonumber(string.sub(text, 2 * i + 1, 2 * i + 2), 16) end
  return bytes, n
end

local function Append(list, n, text)
  for i = 1, string.len(text) do
    list[n] = string.byte(text, i)
    n = n + 1
  end
  return n
end

function X25519.Available()
  return Kit ~= nil and Sha512 ~= nil
end

X25519.ToHex = ToHex
X25519.FromHex = FromHex

-- Public key (64 hex) of a 32-byte secret table.
function X25519.Public(secret)
  local base, out = {}, {}
  for i = 0, 31 do base[i] = 0 end
  base[0] = 9
  ScalarMult(out, secret, base)
  return ToHex(out, 32)
end

-- Raw X25519 for test vectors: hex scalar and hex point, hex result.
function X25519.Raw(scalarHex, pointHex)
  local n, nn = FromHex(scalarHex)
  local p, pn = FromHex(pointHex)
  if not n or nn ~= 32 or not p or pn ~= 32 then return nil end
  local out = {}
  ScalarMult(out, n, p)
  return ToHex(out, 32)
end

-- A fresh 32-byte secret from mixed client sources hashed by SHA-512.
-- `extra` adds caller entropy (session id, names); never secret on its own.
function X25519.NewSecret(extra)
  local seed, n = {}, 0
  local sources = { tostring(extra or ""), tostring({}) }
  local random = math.random
  for _ = 1, 16 do sources[#sources + 1] = tostring(random(0, 2147483646)) end
  local clocks = { "GetTime", "debugprofilestop", "GetServerTime", "time" }
  for i = 1, #clocks do
    local fn = _G[clocks[i]]
    if type(fn) == "function" then
      local ok, value = pcall(fn)
      if ok then sources[#sources + 1] = tostring(value) end
    end
  end
  n = Append(seed, n, table.concat(sources, ":"))
  local digest = Sha512(seed, n)
  local secret = {}
  for i = 0, 31 do secret[i] = digest[i] end
  return secret
end

local function Shared(secret, theirHex)
  local p, pn = FromHex(theirHex)
  if not p or pn ~= 32 then return nil end
  local out = {}
  ScalarMult(out, secret, p)
  local any = 0
  for i = 0, 31 do any = any + out[i] end
  if any == 0 then return nil end
  return out
end

local function Digest(shared, label, context, body, bodyCount)
  local list, n = {}, 0
  for i = 0, 31 do list[i] = shared[i] end
  n = Append(list, 32, label .. context)
  for i = 0, (bodyCount or 0) - 1 do
    list[n] = body[i]
    n = n + 1
  end
  return Sha512(list, n)
end

-- Hex seal of `text` (1 to MAX_TEXT bytes) for `theirHex`, bound to `context`
-- (offer id and direction). nil on a bad key or text.
function X25519.Seal(secret, theirHex, context, text)
  if type(text) ~= "string" or string.len(text) < 1 or string.len(text) > MAX_TEXT then return nil end
  local shared = Shared(secret, theirHex)
  if not shared then return nil end
  local stream = Digest(shared, "WFX1", context or "")
  local cipher, n = {}, string.len(text)
  for i = 0, n - 1 do cipher[i] = Xor8(string.byte(text, i + 1), stream[i]) end
  local tag = Digest(shared, "WFT1", context or "", cipher, n)
  return ToHex(cipher, n) .. ToHex(tag, 8)
end

-- The text sealed by X25519.Seal, or nil when the tag does not match.
function X25519.Open(secret, theirHex, context, sealed)
  local bytes, total = FromHex(sealed)
  if not bytes or total < 9 or total > MAX_TEXT + 8 then return nil end
  local shared = Shared(secret, theirHex)
  if not shared then return nil end
  local n = total - 8
  local tag = Digest(shared, "WFT1", context or "", bytes, n)
  local diff = 0
  for i = 0, 7 do
    if tag[i] ~= bytes[n + i] then diff = diff + 1 end
  end
  if diff ~= 0 then return nil end
  local stream = Digest(shared, "WFX1", context or "")
  local chars = {}
  for i = 0, n - 1 do chars[#chars + 1] = string.char(Xor8(bytes[i], stream[i])) end
  return table.concat(chars)
end
