// cre8-contracts#30 acceptance: on a LOCAL chain 97 fork with the testnet deployment, a Kernel v3.3 account
// goes through enroll -> session key -> rebalance, every UserOp sponsored by our own VerifyingPaymaster and
// bundled by a local alto. Mirrors backend's construction (src/permissions.ts, src/chain.ts, src/scheduler.ts):
// the operator EOA deploys the account through the MetaFactory with the session permission in initConfig and
// prepares its strategy; the owner (sudo validator) consents to enrollment and approves the executor; the session key may only call
// `executeRebalance` / `executeSupply` / `executeWithdraw`, and its GasPolicy only accepts our paymaster.
//
// Negative checks: a session UserOp outside the CallPolicy, a paymaster signature from the wrong key, and a
// session UserOp without the paymaster (GasPolicy enforcePaymaster) must all be rejected.
//
// Run through ./run-fork.sh (starts alto on the fork). Reads deployments/testnet-97.json and, from
// public anvil identities only; impersonates the operator and replaces the local paymaster's immutable
// signer on the verified anvil fork. Never reads real keys. The public chain and manifest are untouched.
import { readFileSync } from 'node:fs';

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
import { mnemonicToAccount } from 'viem/accounts';

const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8547';
const BUNDLER = process.env.BUNDLER_URL ?? 'http://127.0.0.1:3047';
const ANVIL_TEST_MNEMONIC = 'test test test test test test test test test test test junk';
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
  'function enroll(address account, uint256 id, uint16 expectedVersion)',
  'function nextStrategyId() view returns (uint256)',
  'function isEnrolled(address) view returns (bool)',
  'function effectiveFeeBps(uint256) view returns (uint16)',
]);
const usdtAbi = parseAbi(['function claimFor(address to, uint256 amount)']);
const routerAbi = parseAbi(['function previewSwap(address,address,uint256) view returns (uint256 quoted, uint256 minimum)']);
const executorAbi = parseAbi([
  'struct SwapStep { address tokenIn; address tokenOut; uint256 amountIn; uint256 amountOutMin; address venue; bytes data; }',
  'function executeRebalance(address account, SwapStep[] steps, uint256 deadline)',
  'function executeSupply(address account, bytes32 marketId, uint256 assets, uint256 minShares, uint256 deadline)',
  'function executeWithdraw(address account, bytes32 marketId, uint256 shares, uint256 minAssets, uint256 deadline)',
]);
const yieldAbi = parseAbi([
  'function setYieldPolicy(bytes32 id,uint256 dailyAssets,bool enabled)',
  'function quoteSupply(bytes32 id,address account,uint256 amount) returns (uint256)',
  'function quoteWithdraw(bytes32 id,uint256 shares) returns (uint256)',
  'function accountUnits(address account,bytes32 id) view returns (uint256)',
]);
const mockRateAbi = parseAbi(['function aprBps() view returns (uint16)']);
const paymasterAbi = parseAbi([
  'struct PackedUserOperation { address sender; uint256 nonce; bytes initCode; bytes callData; bytes32 accountGasLimits; uint256 preVerificationGas; bytes32 gasFees; bytes paymasterAndData; bytes signature; }',
  'function getHash(PackedUserOperation userOp, uint48 validUntil, uint48 validAfter) view returns (bytes32)',
  'function getDeposit() view returns (uint256)',
]);

async function forkRpc(method: string, params: unknown[]): Promise<void> {
  const response: unknown = await (await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) })).json();
  if (!response || typeof response !== 'object' || 'error' in response || !('result' in response)) {
    throw new Error(`local fork setup failed: ${method}`);
  }
}

let failures = 0;
function check(ok: boolean, label: string, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures++;
}

// ---- our VerifyingPaymaster: sign getHash(userOp, validUntil, validAfter) with the paymaster signer ----
const PM_VERIFICATION_GAS = 80_000n;
const PM_POST_OP_GAS = 0n; // empty context: the EntryPoint never calls postOp
const stubSigner = mnemonicToAccount(ANVIL_TEST_MNEMONIC, { addressIndex: 9 });

// Every validity window below (paymaster validUntil, session TimestampPolicy, executor deadline) is checked
// against block.timestamp, and the fork's clock runs ahead of the wall clock: fork-e2e.sh skips the 30-minute
// TWAP warm-up and, since cre8-contracts#39, an hour for the keeper's second poke round. Take "now" from the chain.
async function chainNow(): Promise<number> {
  return Number((await publicClient.getBlock()).timestamp);
}

function paymasterFor(signer: LocalAccount) {
  const window = async () => {
    const now = await chainNow();
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
      const { validUntil, validAfter } = await window();
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

async function send(client: any, calls: { to: Address; data: Hex; value?: bigint }[], callGasMultiplier = 1n) {
  const request = { calls: calls.map((c) => ({ value: 0n, ...c })) };
  let callGasLimit: bigint | undefined;
  if (callGasMultiplier > 1n) {
    const estimated = await client.prepareUserOperation(request);
    if (typeof estimated.callGasLimit !== 'bigint' || estimated.callGasLimit <= 0n) throw new Error('missing positive call gas estimate');
    callGasLimit = estimated.callGasLimit * callGasMultiplier;
    console.log(`call gas budget ${estimated.callGasLimit} -> ${callGasLimit}`);
  }
  // Send from the original calls so the paymaster signs the FINAL gas limits, never a stale prepared op.
  const hash = await client.sendUserOperation({ ...request, ...(callGasLimit === undefined ? {} : { callGasLimit }) });
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

  const operator = { address: manifest.roles.operator as Address };
  await forkRpc('anvil_impersonateAccount', [operator.address]);
  const paymasterSigner = mnemonicToAccount(ANVIL_TEST_MNEMONIC, { addressIndex: 6 });
  // The immutable signer is replaced ONLY on this verified local anvil instance. Same paymaster code,
  // account and EntryPoint deposit; no real signer key is read. The public deployment/manifest are untouched.
  const code = await publicClient.getCode({ address: C.paymaster });
  const original = (manifest.roles.paymasterSigner as Address).slice(2).toLowerCase().padStart(64, '0');
  const replacement = paymasterSigner.address.slice(2).toLowerCase().padStart(64, '0');
  if (!code || !code.toLowerCase().includes(original)) throw new Error('paymaster immutable signer missing');
  await forkRpc('anvil_setCode', [C.paymaster, code.toLowerCase().replaceAll(original, replacement)]);
  try {
    const operatorWallet = createWalletClient({ account: operator.address, chain, transport: http(RPC) });
    const owner = mnemonicToAccount(ANVIL_TEST_MNEMONIC, { addressIndex: 2 });
    const sessionKey = mnemonicToAccount(ANVIL_TEST_MNEMONIC, { addressIndex: 3 });
    const executor = C.executor;
    const pm = paymasterFor(paymasterSigner);
    const depositBefore = await publicClient.readContract({ address: C.paymaster, abi: paymasterAbi, functionName: 'getDeposit' });

    // ---- session permission: same three policies as backend, GasPolicy pinned to our paymaster ----
    const validUntil = (await chainNow()) + 365 * 86400;
    const selector = encodeFunctionData({ abi: executorAbi, functionName: 'executeRebalance', args: [operator.address, [], 0n] }).slice(0, 10) as Hex;
    const policies = [
      toCallPolicy({ policyVersion: CallPolicyVersion.V0_0_4, permissions: [
        { target: executor, selector },
        { target: executor, selector: encodeFunctionData({ abi: executorAbi, functionName: 'executeSupply', args: [operator.address, `0x${'00'.repeat(32)}`, 0n, 0n, 0n] }).slice(0, 10) as Hex },
        { target: executor, selector: encodeFunctionData({ abi: executorAbi, functionName: 'executeWithdraw', args: [operator.address, `0x${'00'.repeat(32)}`, 0n, 0n, 0n] }).slice(0, 10) as Hex },
      ] }),
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

    // ---- 2. strategy + owner consent + faucet ----
    const assets = [C.usdt, ...TRADE.map((s) => A[s].token)];
    const id = (await publicClient.readContract({ address: C.registry, abi: registryAbi, functionName: 'nextStrategyId' })) + 1n;
    const versionSnapshotTime = await chainNow();
    // Local fixture: publish yesterday, then wait until the original price snapshot.
    await forkRpc('anvil_setBlockTimestampInterval', [0]);
    await forkRpc('anvil_setTime', [(versionSnapshotTime - 86400) * 1000]);
    await forkRpc('anvil_mine', [1]);
    try {
      for (const [fn, args] of [
        ['registerStrategy', ['testnet kernel smoke', 'cre8-contracts#30', false]],
        ['publishVersion', [id, assets, [2500, 2500, 2500, 2500], encodePacked(['string'], ['smoke']).padEnd(66, '0') as Hex, 0n]],
      ] as const) {
        const h = await operatorWallet.writeContract({ address: C.registry, abi: registryAbi, functionName: fn as any, args: args as any });
        await publicClient.waitForTransactionReceipt({ hash: h });
      }
    } finally {
      await forkRpc('anvil_setTime', [versionSnapshotTime * 1000]);
      await forkRpc('anvil_mine', [1]);
      await forkRpc('anvil_removeBlockTimestampInterval', []);
    }
    const ownerAccount = await createKernelAccount(publicClient, { address: account, plugins: { sudo }, entryPoint, kernelVersion });
    const enrollment = await send(clientFor(ownerAccount, pm), [{
      to: C.registry,
      data: encodeFunctionData({ abi: registryAbi, functionName: 'enroll', args: [account, id, 1] }),
    }]);
    check(enrollment.receipt.success, 'owner signed consent to future versions (sudo UserOp)', enrollment.hash);
    check(await publicClient.readContract({ address: C.registry, abi: registryAbi, functionName: 'isEnrolled', args: [account] }), 'account enrolled at expected version', `strategy ${id}`);
    const claim = await operatorWallet.writeContract({ address: C.usdt, abi: usdtAbi, functionName: 'claimFor', args: [account, 1_000n * 10n ** 18n] });
    await publicClient.waitForTransactionReceipt({ hash: claim });

    // ---- 3. owner (sudo) approves the executor, sponsored ----
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
    const deadline = BigInt((await chainNow()) + 3600);
    const rebalanceData = encodeFunctionData({ abi: executorAbi, functionName: 'executeRebalance', args: [account, steps, deadline] });
    const rebalance = await send(clientFor(sessionAccount, pm), [{ to: executor, data: rebalanceData }]);
    check(rebalance.receipt.success, 'session-key UserOp executeRebalance (3 buys) sponsored', rebalance.hash);
    for (const s of TRADE) {
      const bal = await publicClient.readContract({ address: A[s].token, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
      check(bal > 0n, `account bought ${s}`, bal.toString());
    }
    check((await publicClient.getBalance({ address: account })) === 0n, 'account still holds no tBNB');

    // ---- yield: owner consent and approvals, then both typed actions via session + paymaster ----
    const yieldMarket = manifest.yieldMarkets.find((m: { protocol: string; symbol: string }) => m.protocol === 'Venus' && m.symbol === 'USDT') as
      { marketId: Hex; target: Address; receipt: Address } | undefined;
    if (!yieldMarket) throw new Error('Venus.USDT manifest entry missing');
    const apr = await publicClient.readContract({ address: yieldMarket.target, abi: mockRateAbi, functionName: 'aprBps' });
    if (apr !== 500) throw new Error('Venus.USDT must retain its simulated 5% APR');
    const amount = 100n * 10n ** 18n;
    const consent = await send(clientFor(ownerAccount, pm), [
      { to: C.yieldRegistry, data: encodeFunctionData({ abi: yieldAbi, functionName: 'setYieldPolicy', args: [yieldMarket.marketId, amount, true] }) },
      { to: yieldMarket.receipt, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [executor, 2n ** 256n - 1n] }) },
    ]);
    check(consent.receipt.success, 'owner yield consent and receipt approval sponsored');
    const quoteBlock = await publicClient.getBlockNumber({ cacheTime: 0 });
    const quote = await publicClient.simulateContract({ address: C.yieldRegistry, abi: yieldAbi, functionName: 'quoteSupply', args: [yieldMarket.marketId, account, amount], blockNumber: quoteBlock });
    // Choose a 5 bps signed margin within the fixed 10 bps execution floor. The remaining 5 bps
    // covers drift toward that floor; using the old quote's exact lower floor leaves no such room.
    const minShares = quote.result * 9_995n / 10_000n;
    if (minShares <= 0n) throw new Error('zero supply minimum');
    await forkRpc('evm_increaseTime', [1]);
    await forkRpc('anvil_mine', [1]);
    const supplyData = encodeFunctionData({ abi: executorAbi, functionName: 'executeSupply', args: [account, yieldMarket.marketId, amount, minShares, BigInt((await chainNow()) + 3600)] });
    const supply = await send(clientFor(sessionAccount, pm), [{ to: executor, data: supplyData }], 2n);
    check(supply.receipt.success && supply.receipt.paymaster?.toLowerCase() === C.paymaster.toLowerCase(), 'session-key executeSupply sponsored at nonzero APR', supply.hash);
    check(supply.receipt.receipt.blockNumber > quoteBlock, 'supply quote precedes execution block', `${quoteBlock} -> ${supply.receipt.receipt.blockNumber}`);
    const shares = await publicClient.readContract({ address: yieldMarket.receipt, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
    check(shares >= minShares && shares > 0n, 'Kernel holds actual yield receipts above signed min');
    const withdrawQuoteBlock = await publicClient.getBlockNumber({ cacheTime: 0 });
    const withdrawQuote = await publicClient.simulateContract({ address: C.yieldRegistry, abi: yieldAbi, functionName: 'quoteWithdraw', args: [yieldMarket.marketId, shares], blockNumber: withdrawQuoteBlock });
    const minAssets = withdrawQuote.result * 9_995n / 10_000n;
    if (minAssets <= 0n) throw new Error('zero withdraw minimum');
    const cashBefore = await publicClient.readContract({ address: C.usdt, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
    await forkRpc('evm_increaseTime', [1]);
    await forkRpc('anvil_mine', [1]);
    const withdrawData = encodeFunctionData({ abi: executorAbi, functionName: 'executeWithdraw', args: [account, yieldMarket.marketId, shares, minAssets, BigInt((await chainNow()) + 3600)] });
    // Alto's estimate can under-budget Kernel's nested execution around receipt/ledger cleanup.
    const withdraw = await send(clientFor(sessionAccount, pm), [{ to: executor, data: withdrawData }], 2n);
    check(withdraw.receipt.success && withdraw.receipt.paymaster?.toLowerCase() === C.paymaster.toLowerCase(), 'session-key executeWithdraw sponsored at nonzero APR', withdraw.hash);
    check(withdraw.receipt.receipt.blockNumber > withdrawQuoteBlock, 'withdraw quote precedes execution block', `${withdrawQuoteBlock} -> ${withdraw.receipt.receipt.blockNumber}`);
    const cashAfter = await publicClient.readContract({ address: C.usdt, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
    check(cashAfter - cashBefore >= minAssets, 'actual withdrawal clears signed minAssets');
    const remaining = await publicClient.readContract({ address: yieldMarket.receipt, abi: erc20Abi, functionName: 'balanceOf', args: [account] });
    const tracked = await publicClient.readContract({ address: C.yieldRegistry, abi: yieldAbi, functionName: 'accountUnits', args: [account, yieldMarket.marketId] });
    check(remaining === 0n && tracked === 0n, 'Kernel yield receipts and tracked units fully redeemed');
    check(await publicClient.readContract({ address: yieldMarket.target, abi: mockRateAbi, functionName: 'aprBps' }) === apr, 'mock APR remains nonzero and unchanged');
    await expectRejected('session key cannot change yield consent', () => send(clientFor(sessionAccount, pm), [
      { to: C.yieldRegistry, data: encodeFunctionData({ abi: yieldAbi, functionName: 'setYieldPolicy', args: [yieldMarket.marketId, amount, true] }) },
    ]));
    console.log(`yield UserOp actualGasUsed supply ${supply.receipt.actualGasUsed}, withdraw ${withdraw.receipt.actualGasUsed}`);

    // ---- 5. what must be rejected ----
    await expectRejected('session key outside CallPolicy (USDT.transfer)', () =>
      send(clientFor(sessionAccount, pm), [
        { to: C.usdt, data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [operator.address, 1n] }) },
      ]),
    );
    await expectRejected('paymaster signature from the wrong key', () =>
      send(clientFor(sessionAccount, paymasterFor(mnemonicToAccount(ANVIL_TEST_MNEMONIC, { addressIndex: 7 }))), [{ to: executor, data: rebalanceData }]),
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
      throw new Error(`${failures} check(s) failed`);
    }
  } finally {
    await forkRpc('anvil_setCode', [C.paymaster, code]);
    if (await publicClient.getCode({ address: C.paymaster }) !== code) throw new Error('local paymaster runtime restore failed');
    console.log('PASS local paymaster original runtime restored');
  }
  console.log('kernel smoke: all checks passed');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
