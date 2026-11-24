#!/usr/bin/env python3
"""Ask Lista's reward-proof API which contract signers it accepts (see DeployListaProofProbe.s.sol).

Usage:  PROBE_KEY_FILE=<file with the throwaway private key, mode 600> \\
        PROBE_HOST=<ListaProofProbeHost address> [ETH_RPC_URL=<BSC RPC>] python3 probe.py [--local]

--local  only run the on-chain eth_call checks (fork rehearsal); the API cannot see a fork.

Nothing here sends a transaction. The key signs login texts only; it is read from the file and never printed.
Every signature is first checked against the chain with eth_call (what the contract itself answers), then the
same (address, message, signature) is sent to the API. API answers: code 000000000 = signature accepted,
1005 = "Invalid signature", 401 = message too old.
"""
import datetime, json, os, subprocess, sys, urllib.parse, urllib.request

RPC = os.environ.get("ETH_RPC_URL", "https://bsc-rpc.publicnode.com")
KEY = open(os.environ["PROBE_KEY_FILE"]).read().strip()
HOST = os.environ["PROBE_HOST"]
LOCAL = "--local" in sys.argv
SUFFIX = "\nThank you for your support of listaDAO."
API = "https://api.lista.org/api/moolah/emission/"
MAGIC, LEGACY_MAGIC = "0x1626ba7e", "0x20c13b0b"


def cast(*args):
    out = subprocess.run(["cast", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("cast %s failed: %s" % (args[0], out.stderr.strip()[:300]))
    return out.stdout.strip()


def call(to, sig, *args):
    out = subprocess.run(["cast", "call", to, sig, *args, "--rpc-url", RPC], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else "revert"


def keccak(hexdata):
    return cast("keccak", hexdata)


def sign_text(message):  # personal_sign
    return cast("wallet", "sign", "--private-key", KEY, message)


def sign_digest(digest):  # raw signature over a 32-byte digest
    return cast("wallet", "sign", "--no-hash", "--private-key", KEY, digest)


def api(path, address, message, signature, kind):
    params = {"address": address, "message": message, "signature": signature}
    if kind:
        params["type"] = kind
    url = API + path + "?" + urllib.parse.urlencode(params)
    try:
        req = urllib.request.Request(url, headers={"accept": "application/json", "user-agent": "curl/8"})
        raw = urllib.request.urlopen(req, timeout=30).read()
    except Exception as e:  # HTTP errors still carry the JSON body
        raw = getattr(e, "read", lambda: str(e).encode())()
    try:
        body = json.loads(raw)
        return "%s %s" % (body.get("code"), body.get("msg"))
    except Exception:
        return raw[:80].decode("utf8", "replace")


owner = cast("wallet", "address", "--private-key", KEY)
account = call(HOST, "account()(address)")
box = call(HOST, "box()(address)")
probes = [call(HOST, "probes(uint256)(address)", str(i)) for i in range(7)]
message = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z") + SUFFIX
message_hex = "0x" + message.encode().hex()
h191 = cast("hash-message", message)
hkec = keccak(message_hex)

# Kernel v3: the root validator signs the EIP-712 wrap `Kernel(bytes32 hash)` under the account's own domain;
# the account-level signature is 0x00 (root validation) followed by that ECDSA signature.
domain = call(account, "eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])").split("\n")
name, version = json.loads(domain[1]), json.loads(domain[2])
domain_separator = keccak(cast(
    "abi-encode", "f(bytes32,bytes32,bytes32,uint256,address)",
    keccak("0x" + b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".hex()),
    keccak("0x" + name.encode().hex()), keccak("0x" + version.encode().hex()), "56", account))
wrapper_type = keccak("0x" + b"Kernel(bytes32 hash)".hex())


def kernel_signature(digest):
    struct = keccak(cast("abi-encode", "f(bytes32,bytes32)", wrapper_type, digest))
    wrapped = keccak("0x1901" + domain_separator[2:] + struct[2:])
    return "0x00" + sign_digest(wrapped)[2:]


def box_signature(inner):
    return cast("abi-encode", "f(bytes,bytes)", message_hex, inner)


rows = []  # (label, address, signature, expected on-chain answer, on-chain answer)


def check(label, address, digest, signature, legacy_data=None):
    if legacy_data is None:
        onchain = call(address, "isValidSignature(bytes32,bytes)(bytes4)", digest, signature)
    else:
        onchain = call(address, "isValidSignature(bytes,bytes)(bytes4)", legacy_data, signature)
    rows.append((label, address, signature, onchain))


print("owner (throwaway EOA) ", owner)
print("Kernel account        ", account, "(Kernel %s %s)" % (name, version))
print("StrategyBox           ", box)
print("message               ", json.dumps(message))
print()

k191, kkec = kernel_signature(h191), kernel_signature(hkec)
check("Kernel account, EIP-191 hash", account, h191, k191)
check("Kernel account, keccak hash", account, hkec, kkec)
check("StrategyBox, EIP-191 hash", box, h191, box_signature(k191))
check("StrategyBox, keccak hash", box, hkec, box_signature(kkec))
check("StrategyBox, legacy bytes form (message)", box, None, box_signature(k191), legacy_data=message_hex)
plain = box_signature("0x")
check("probe 0: (bytes32,bytes) anything", probes[0], h191, plain)
check("probe 1: (bytes32,bytes) EIP-191 hash", probes[1], h191, plain)
check("probe 2: (bytes32,bytes) keccak hash", probes[2], hkec, plain)
check("probe 3: (bytes,bytes) anything", probes[3], None, plain, legacy_data=message_hex)
check("probe 4: (bytes,bytes) data = message", probes[4], None, plain, legacy_data=message_hex)
check("probe 5: (bytes,bytes) data = EIP-191 hash", probes[5], None, plain, legacy_data=h191)
check("probe 6: (bytes,bytes) data = keccak hash", probes[6], None, plain, legacy_data=hkec)

# Negative controls on chain: the box refuses the account's valid signature over anything but the login text.
other = keccak("0x" + b"\x19\x01permit-like digest".hex())
neg_box = call(box, "isValidSignature(bytes32,bytes)(bytes4)", other, box_signature(kernel_signature(other)))
neg_acct = call(account, "isValidSignature(bytes32,bytes)(bytes4)", other, kernel_signature(other))
wrong_key_sig = "0x00" + "11" * 64 + "1b"
neg_wrong = call(box, "isValidSignature(bytes32,bytes)(bytes4)", h191, box_signature(wrong_key_sig))

ok = True
print("on chain (eth_call):")
for label, address, signature, onchain in rows:
    good = onchain in (MAGIC, LEGACY_MAGIC)
    ok &= good
    print("  %-46s %s  %s" % (label, address, "valid" if good else "NOT VALID (" + onchain + ")"))
print("  %-46s %s" % ("account signs another digest (control)", "valid" if neg_acct == MAGIC else neg_acct))
print("  %-46s %s" % ("box refuses that digest (must be invalid)", "invalid" if neg_box != MAGIC else "VALID: BUG"))
print("  %-46s %s" % ("box refuses a wrong signer (must be invalid)", "invalid" if neg_wrong != MAGIC else "VALID: BUG"))
ok &= neg_acct == MAGIC and neg_box != MAGIC and neg_wrong != MAGIC
if not ok:
    raise SystemExit("on-chain checks failed: do not read anything into the API answers")
if LOCAL:
    print("\n--local: API not queried.")
    sys.exit(0)

print("\nLista API (userProof / userMultiProof):")
eoa = sign_text(message)
controls = [
    ("EOA, good signature (control: accepted)", owner, eoa, None),
    ("EOA, wrong signature (control: 1005)", owner, eoa[:10] + "00000000" + eoa[18:], None),
    ("EOA signature sent as type=safe (control)", owner, eoa, "safe"),
]
for label, address, signature, kind in controls:
    print("  %-46s %s | %s" % (label, api("userProof", address, message, signature, kind),
                              api("userMultiProof", address, message, signature, kind)))
for kind in ("safe", None):
    print("  -- type=%s" % kind)
    for label, address, signature, _ in rows:
        print("  %-46s %s | %s" % (label, api("userProof", address, message, signature, kind),
                                  api("userMultiProof", address, message, signature, kind)))
    # Does the API insist on a 65-byte signature? Probes 0 and 3 accept anything.
    dummy = "0x" + "11" * 64 + "1b"
    print("  %-46s %s" % ("probe 0 with a 65-byte dummy signature", api("userProof", probes[0], message, dummy, kind)))
    print("  %-46s %s" % ("probe 3 with a 65-byte dummy signature", api("userProof", probes[3], message, dummy, kind)))
print("\nRead it like this: the probe rows that answer 000000000 are the call forms Lista uses;")
print("'Kernel account' accepted = borrow-side rewards claimable; 'StrategyBox' accepted = vault-side.")
