// cre8-contracts#30 acceptance: on a LOCAL chain 97 fork with the testnet deployment, a Kernel v3.3 account
// goes through enroll -> session key -> rebalance, every UserOp sponsored by our own VerifyingPaymaster and
// bundled by a local alto. Mirrors backend's construction (src/permissions.ts, src/chain.ts, src/scheduler.ts):
// the operator EOA deploys the account through the MetaFactory with the session permission in initConfig and
// enrolls it; the owner (sudo validator) approves the executor; the session key may only call
// `executeRebalance`, and its GasPolicy only accepts our paymaster.
//
// Negative checks: a session UserOp outside the CallPolicy, a paymaster signature from the wrong key, and a
// session UserOp without the paymaster (GasPolicy enforcePaymaster) must all be rejected.
//
// Run through ./run-fork.sh (starts alto on the fork). Reads deployments/testnet-97.json and, from
// ~/.cre8-testnet, the operator and paymaster-signer keys; prints no key. Fork only: refuses a non-anvil RPC.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { signerToEcdsaValidator } from '@zerodev/ecdsa-validator';
import { toInitConfig, toPermissionValidator } from '@zerodev/permissions';
import { CallPolicyVersion, toCallPolicy, toGasPolicy, toTimestampPolicy } from '@zerodev/permissions/policies';
import { toECDSASigner } from '@zerodev/permissions/signers';
import { PolicyFlags } from '@zerodev/permissions';
import { addressToEmptyAccount, createKernelAccount, createKernelAccountClient } from '@zerodev/sdk';
import { getEntryPoint, KERNEL_V3_3 } from '@zerodev/sdk/constants';
import {
  concat,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  erc20Abi,
  http,
  parseAbi,
  type Address,
  type Hex,
  type LocalAccount,
} from 'viem';
import { toPackedUserOperation } from 'viem/account-abstraction';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';

const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8547';
const BUNDLER = process.env.BUNDLER_URL ?? 'http://127.0.0.1:3047';
const KEYS = process.env.CRE8_TESTNET_KEYS ?? join(homedir(), '.cre8-testnet');
const MANIFEST = new URL('../../../deployments/testnet-97.json', import.meta.url);

const chain = defineChain({
  id: 97,
  name: 'BSC testnet (local fork)',
  nativeCurrency: { name: 'tBNB', symbol: 'tBNB', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const entryPoint = getEntryPoint('0.7');
const kernelVersion = KERNEL_V3_3;
const publicClient = createPublicClient({ chain, transport: http(RPC) });

const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'));
const C = manifest.contracts as Record<string, Address>;
const A = manifest.assets as Record<string, Record<string, Address>>;
const TRADE = ['WBNB', 'BTCB', 'AAPLB'] as const;
const FEES: Record<string, number> = { WBNB: 500, BTCB: 500, AAPLB: 2500 };

const registryAbi = parseAbi([
  'function registerStrategy(string name, string description, bool isPublic) returns (uint256)',
  'function publishVersion(uint256 id, address[] assets, uint16[] weightsBps, bytes32 scheduleHash, uint64 activeAt) returns (uint16)',
  'function enroll(address account, uint256 id)',
  'function nextStrategyId() view returns (uint256)',
  'function isEnrolled(address) view returns (bool)',
  'function effectiveFeeBps(uint256) view returns (uint16)',
]);
const usdtAbi = parseAbi(['function claimFor(address to, uint256 amount)']);
const routerAbi = parseAbi(['function previewSwap(address,address,uint256) view returns (uint256 quoted, uint256 minimum)']);
const executorAbi = parseAbi([
  'struct SwapStep { address tokenIn; address tokenOut; uint256 amountIn; uint256 amountOutMin; address venue; bytes data; }',
  'function executeRebalance(address account, SwapStep[] steps, uint256 deadline)',
]);
const paymasterAbi = parseAbi([
  'struct PackedUserOperation { address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature; }',
  'function getHash(PackedUserOperation userOp, uint48 validUntil, uint48 validAfter) view returns (bytes32)',
  'function getDeposit() view returns (uint256)',
]);

function key(name: string): Hex {
  return JSON.parse(readFileSync(join(KEYS, `${name}.json`), 'utf8')).data[0].private_key as Hex;
}

let failures = 0;
function check(ok: boolean, label: string, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures++;
}

// ---- our VerifyingPaymaster: sign getHash(userOp, validUntil, validAfter) with the paymaster signer ----
const PM_VERIFICATION_GAS = 80_000n;
const PM_POST_OP_GAS = 0n; // empty context: the EntryPoint never calls postOp
const stubSigner = privateKeyToAccount(generatePrivateKey());

function paymasterFor(signer: LocalAccount) {
  const window = () => {
    const now = Math.floor(Date.now() / 1000);
    return { validUntil: now + 3600, validAfter: 0 };
  };
  const timestamps = (validUntil: number, validAfter: number) =>
    encodeAbiParameters([{ type: 'uint48' }, { type: 'uint48' }], [validUntil, validAfter]);
  return {
    // Well-formed but wrong signature: recovers to a random address, so validation reports a signature
    // failure instead of reverting, which is what estimation needs.
    async getPaymasterStubData() {
      const sig = await stubSigner.signMessage({ message: { raw: `0x${'00'.repeat(32)}` } });
      return {
        paymaster: C.paymaster,
        paymasterData: concat([timestamps(0, 0), sig]),
        paymasterVerificationGasLimit: PM_VERIFICATION_GAS,
        paymasterPostOpGasLimit: PM_POST_OP_GAS,
      };
    },
    async getPaymasterData(userOp: any) {
      const { validUntil, validAfter } = window();
      const packed = toPackedUserOperation({
        ...userOp,
        paymaster: C.paymaster,
        paymasterVerificationGasLimit: PM_VERIFICATION_GAS,
        paymasterPostOpGasLimit: PM_POST_OP_GAS,
        paymasterData: '0x',
        signature: '0x',
      });
      const hash = await publicClient.readContract({
        address: C.paymaster,
        abi: paymasterAbi,
        functionName: 'getHash',
        args: [packed, validUntil, validAfter],
      });
      const sig = await signer.signMessage({ message: { raw: hash } });
      return {
        paymaster: C.paymaster,
        paymasterData: concat([timestamps(validUntil, validAfter), sig]),
        paymasterVerificationGasLimit: PM_VERIFICATION_GAS,
        paymasterPostOpGasLimit: PM_POST_OP_GAS,
      };
    },
  };
}

function clientFor(account: any, paymaster?: ReturnType<typeof paymasterFor>) {
  return createKernelAccountClient({
    account,
    chain,
    client: publicClient,
    bundlerTransport: http(BUNDLER, { timeout: 120_000 }),
    ...(paymaster ? { paymaster } : {}),
    // alto has no zd_getUserOperationGasPrice; same as backend's scheduler.
    userOperation: {
      estimateFeesPerGas: async () => {
        const gasPrice = await publicClient.getGasPrice();
        return { maxFeePerGas: gasPrice, maxPriorityFeePerGas: gasPrice };
      },
    },
  });
}

async function send(client: any, calls: { to: Address; data: Hex; value?: bigint }[]) {
  const hash = await client.sendUserOperation({ calls: calls.map((c) => ({ value: 0n, ...c })) });
  const receipt = await client.waitForUserOperationReceipt({ hash, timeout: 120_000 });
  return { hash, receipt };
}

async function expectRejected(label: string, run: () => Promise<unknown>) {
  try {
    await run();
    check(false, label, 'was accepted');
  } catch (err) {
    const text = String((err as Error)?.message ?? err);
    const aa = text.match(/AA\d\d[^\n"]*/)?.[0];
    const line = text.split('\n').find((l) => /reverted|reason|Details/i.test(l));
    check(true, label, (aa ?? line ?? 'rejected').trim().slice(0, 160));
  }
}

async function main() {
  const node = await publicClient.request({ method: 'anvil_nodeInfo' as any }).catch(() => null);
  if (!node) throw new Error(`${RPC} is not an anvil fork: this smoke spends tBNB, run it on the local fork`);
  if ((await publicClient.getChainId()) !== 97) throw new Error('not chain 97');

  const operator = privateKeyToAccount(key('operator'));
  const paymasterSigner = privateKeyToAccount(key('paymaster-signer'));
  const operatorWallet = createWalletClient({ account: operator, chain, transport: http(RPC) });
  const owner = privateKeyToAccount(generatePrivateKey());
  const sessionKey = privateKeyToAccount(generatePrivateKey());
  const executor = C.executor;
  const pm = paymasterFor(paymasterSigner);
  const depositBefore = await publicClient.readContract({ address: C.paymaster, abi: paymasterAbi, functionName: 'getDeposit' });

  // ---- session permission: same three policies as backend, GasPolicy pinned to our paymaster ----
  const validUntil = Math.floor(Date.now() / 1000) + 365 * 86400;
  const selector = encodeFunctionData({ abi: executorAbi, functionName: 'executeRebalance', args: [operator.address, [], 0n] }).slice(0, 10) as Hex;
  const policies = [
    toCallPolicy({ policyVersion: CallPolicyVersion.V0_0_4, permissions: [{ target: executor, selector }] }),
    toGasPolicy({ allowed: 10n ** 18n, enforcePaymaster: true, allowedPaymaster: C.paymaster }),
    toTimestampPolicy({ validAfter: 0, validUntil }),
  ];
  const permission = await toPermissionValidator(publicClient, {
    signer: await toECDSASigner({ signer: sessionKey }),
    policies,
    entryPoint,
    kernelVersion,
    flag: PolicyFlags.FOR_ALL_VALIDATION,
  });
  const initConfig = await toInitConfig(permission);
  const sudo = await signerToEcdsaValidator(publicClient, { signer: owner, entryPoint, kernelVersion });

  // ---- 1. operator deploys the account (MetaFactory, permission installed through initConfig) ----
  const deployAccount = await createKernelAccount(publicClient, {
    plugins: { sudo, regular: permission },
    entryPoint,
    kernelVersion,
    initConfig,
    useMetaFactory: true,
  } as any);
  const { factory, factoryData } = await deployAccount.getFactoryArgs();
  const deployTx = await operatorWallet.sendTransaction({ to: factory!, data: factoryData! });
  await publicClient.waitForTransactionReceipt({ hash: deployTx });
  const account = deployAccount.address;
  check(((await publicClient.getCode({ address: account })) ?? '0x') !== '0x', 'Kernel v3.3 account deployed by operator', account);

  // ---- 2. strategy + operator enroll + faucet ----
  const assets = [C.usdt, ...TRADE.map((s) => A[s].token)];
  const id = (await publicClient.readContract({ address: C.registry, abi: registryAbi, functionName: 'nextStrategyId' })) + 1n;
  for (const [fn, args] of [
    ['registerStrategy', ['testnet kernel smoke', 'cre8-contracts#30', false]],
    ['publishVersion', [id, assets, [2500, 2500, 2500, 2500], encodePacked(['string'], ['smoke']).padEnd(66, '0') as Hex, 0n]],
    ['enroll', [account, id]],
  ] as const) {
    const h = await operatorWallet.writeContract({ address: C.registry, abi: registryAbi, functionName: fn as any, args: args as any });
    await publicClient.waitForTransactionReceipt({ hash: h });
  }
  check(await publicClient.readContract({ address: C.registry, abi: registryAbi, functionName: 'isEnrolled', args: [account] }), 'operator enrolled the account', `strategy ${id}`);
  const claim = await operatorWallet.writeContract({ address: C.usdt, abi: usdtAbi, functionName: 'claimFor', args: [account, 1_000n * 10n ** 18n] });
  await publicClient.waitForTransactionReceipt({ hash: claim });

  // ---- 3. owner (sudo) approves the executor, sponsored ----
  const ownerAccount = await createKernelAccount(publicClient, { address: account, plugins: { sudo }, entryPoint, kernelVersion } as any);
  const approve = await send(
    clientFor(ownerAccount, pm),
    assets.map((t) => ({ to: t, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [executor, 2n ** 256n - 1n] }) })),
  );
  check(approve.receipt.success && (approve.receipt.paymaster ?? '').toLowerCase() === C.paymaster.toLowerCase(), 'owner UserOp (approve x4) sponsored by our paymaster', approve.hash);
  check((await publicClient.getBalance({ address: account })) === 0n, 'account holds no tBNB (gasless)');

  // ---- 4. session key rebalance, sponsored ----
  const sessionAccount = await createKernelAccount(publicClient, {
    address: account,
    plugins: { sudo: await signerToEcdsaValidator(publicClient, { signer: addressToEmptyAccount(owner.address), entryPoint, kernelVersion }), regular: permission },
    entryPoint,
    kernelVersion,
  } as any);
  const feeBps = await publicClient.readContract({ address: C.registry, abi: registryAbi, functionName: 'effectiveFeeBps', args: [id] });
  const steps = [];
  for (const s of TRADE) {
    const amountIn = 100n * 10n ** 18n;
    const [, minimum] = await publicClient.readContract({ address: C.router, abi: routerAbi, functionName: 'previewSwap', args: [C.usdt, A[s].token, amountIn] });
    const minGross = (minimum * 10_000n + BigInt(10_000 - feeBps) - 1n) / BigInt(10_000 - feeBps);
    const path = encodePacked(['address', 'uint24', 'address'], [C.usdt, FEES[s], A[s].token]);
    const input = encodeAbiParameters(
      [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'bytes' }, { type: 'bool' }],
      [executor, amountIn, minGross, path, true],
    );
    steps.push({
      tokenIn: C.usdt,
      tokenOut: A[s].token,
      amountIn,
      amountOutMin: minGross,
      venue: C.universalRouter,
      data: encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], ['0x00', [input]]),
    });
  }
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const rebalanceData = encodeFunctionData({ abi: executorAbi, functionName: 'executeRebalance', args: [account, steps, deadline] });
  const rebalance = await send(clientFor(sessionAccount, pm), [{ to: executor, data: rebalanceData }]);
  check(rebalance.receipt.success, 'session-key UserOp executeRebalance (3 buys) sponsored', rebalance.hash);
  for (const s of TRADE) {
    const bal = await publicClient.readContract({ address: A[s].token, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
    check(bal > 0n, `account bought ${s}`, bal.toString());
  }
  check((await publicClient.getBalance({ address: account })) === 0n, 'account still holds no tBNB');

  // ---- 5. what must be rejected ----
  await expectRejected('session key outside CallPolicy (USDT.transfer)', () =>
    send(clientFor(sessionAccount, pm), [
      { to: C.usdt, data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [operator.address, 1n] }) },
    ]),
  );
  await expectRejected('paymaster signature from the wrong key', () =>
    send(clientFor(sessionAccount, paymasterFor(privateKeyToAccount(generatePrivateKey()))), [{ to: executor, data: rebalanceData }]),
  );
  // Give the account its own tBNB so a missing prefund is not what stops it: only GasPolicy is left.
  const fund = await operatorWallet.sendTransaction({ to: account, value: 10n ** 16n });
  await publicClient.waitForTransactionReceipt({ hash: fund });
  await expectRejected('session key without our paymaster (GasPolicy enforcePaymaster)', () =>
    send(clientFor(sessionAccount), [{ to: executor, data: rebalanceData }]),
  );

  const depositAfter = await publicClient.readContract({ address: C.paymaster, abi: paymasterAbi, functionName: 'getDeposit' });
  console.log(`paymaster deposit: ${depositBefore} -> ${depositAfter} wei (spent ${depositBefore - depositAfter})`);
  console.log(`approve UserOp actualGasUsed ${approve.receipt.actualGasUsed}, rebalance UserOp actualGasUsed ${rebalance.receipt.actualGasUsed}`);
  if (failures) {
    console.log(`${failures} check(s) failed`);
    process.exit(1);
  }
  console.log('kernel smoke: all checks passed');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
