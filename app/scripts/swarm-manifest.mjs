#!/usr/bin/env node
// The site's manifest from the swarm's deployment record. The swarm deploys launch.json and hands the front-end
// job `.imd/reads/deployment.json` (contracts with name, address and blockNumber); this writes the same
// deploy.robinhood.json the site reads after a scripted deployment. The machine creates its inventory ledger in
// its constructor, so the ledger's address follows from the machine's (its first CREATE, nonce 1).
//   node app/scripts/swarm-manifest.mjs .imd/reads/deployment.json [out] [--check [--dev <address>]]
// --check also reads the chain before anything is funded: every contract's runtime code must equal this build's
// (immutables masked), and every immutable must hold launch.json's value (dev: --dev, else printed), the
// countdown included. Run `forge build src` on the pinned commit first: a full build also compiles the tests, and
// with via_ir that can change the bytecode (2026-10-17: 17,885 bytes full vs 16,866 contracts only, the deployed size).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, getAddress, getContractAddress, hexToBytes, http, parseAbi } from "viem";

const IMD = "0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127"; // IMD on Robinhood Chain, as in launch.json
const RPC = "https://rpc.mainnet.chain.robinhood.com";
const NAMES = { beacon: "DrandBeacon", machine: "IdentityMachine", views: "MachineViews", ethMinter: "EthMinter" };

const args = process.argv.slice(2);
const check = args.includes("--check");
const devAt = args.indexOf("--dev");
const dev = devAt >= 0 ? getAddress(args[devAt + 1]) : null;
const [input, out = new URL("../public/deploy.robinhood.json", import.meta.url).pathname] =
  args.filter((a, i) => a !== "--check" && (devAt < 0 || (i !== devAt && i !== devAt + 1)));
if (!input) throw new Error("usage: swarm-manifest.mjs <deployment.json> [out] [--check]");

const record = JSON.parse(readFileSync(input, "utf8"));
const d = record.handoff ?? record; // a workflow response carries the record as `handoff`
if (Number(d.chainId) !== 4663) throw new Error(`deployment is on chain ${d.chainId}, not Robinhood Chain (4663)`);
const byName = new Map((d.contracts ?? []).map((c) => [c.name, c]));
const manifest = { chainId: 4663, imd: IMD };
let startBlock = Infinity;
for (const [key, name] of Object.entries(NAMES)) {
  const c = byName.get(name);
  if (!c) throw new Error(`deployment has no ${name}`);
  manifest[key] = getAddress(c.address);
  if (!Number.isSafeInteger(c.blockNumber) || c.blockNumber <= 0) throw new Error(`${name} has no deployment block`);
  startBlock = Math.min(startBlock, c.blockNumber);
}
manifest.parts = getContractAddress({ from: manifest.machine, nonce: 1n });
manifest.startBlock = startBlock;

if (check) {
  // this repository keeps the Foundry project in contracts/; the public code-only export has it at the root
  const project = [new URL("../../contracts/", import.meta.url), new URL("../../", import.meta.url)]
    .find((u) => existsSync(new URL("launch.json", u)));
  const launch = JSON.parse(readFileSync(new URL("launch.json", project), "utf8"));
  const argsOf = (name) => launch.contracts.find((c) => c.contract === name).constructorArgs;
  const client = createPublicClient({ transport: http(process.env.RPC ?? RPC) }); // RPC= for a local copy
  const contractOf = { beacon: "DrandBeacon", machine: "IdentityMachine", parts: "Parts", views: "MachineViews", ethMinter: "EthMinter" };
  for (const [key, name] of Object.entries(contractOf)) {
    const { deployedBytecode } = JSON.parse(readFileSync(new URL(`out/${name}.sol/${name}.json`, project), "utf8"));
    const live = hexToBytes(await client.getCode({ address: manifest[key] }) ?? "0x");
    const built = hexToBytes(deployedBytecode.object);
    if (live.length !== built.length) throw new Error(`${name}: ${live.length} bytes on chain, ${built.length} built`);
    for (const refs of Object.values(deployedBytecode.immutableReferences ?? {}))
      for (const { start, length } of refs) { live.fill(0, start, start + length); built.fill(0, start, start + length); }
    if (!live.every((b, i) => b === built[i])) throw new Error(`${name}: the code on chain is not this build`);
  }
  const abi = parseAbi(["function inventory() view returns (address)", "function imd() view returns (address)",
    "function beacon() view returns (address)", "function machine() view returns (address)", "function dev() view returns (address)",
    "function seatRoot() view returns (bytes32)", "function basePrice() view returns (uint256)", "function start() view returns (uint256)",
    "function ledger() view returns (address)", "function poolManager() view returns (address)", "function quoter() view returns (address)",
    "function fee() view returns (uint24)", "function tickSpacing() view returns (int24)"]);
  const read = (key, functionName) => client.readContract({ address: manifest[key], abi, functionName });
  const expect = async (key, fn, want) => {
    const got = await read(key, fn);
    if (String(got).toLowerCase() !== String(want).toLowerCase()) throw new Error(`${key}.${fn}() is ${got}, expected ${want}`);
  };
  const m = argsOf("IdentityMachine"), e = argsOf("EthMinter");
  await expect("machine", "imd", m[0]);
  await expect("machine", "beacon", manifest.beacon);
  await expect("machine", "inventory", manifest.parts);
  await expect("machine", "seatRoot", m[3]);
  await expect("machine", "basePrice", m[4]);
  const deployedAt = (await client.getBlock({ blockNumber: BigInt(byName.get("IdentityMachine").blockNumber) })).timestamp;
  const delay = BigInt(process.env.DELAY ?? m[5]); // DELAY= only for a rehearsal deployed without the countdown
  await expect("machine", "start", deployedAt + delay);
  if (dev) await expect("machine", "dev", dev);
  for (const key of ["parts", "views", "ethMinter"]) await expect(key, "machine", manifest.machine);
  await expect("views", "ledger", manifest.parts);
  await expect("views", "imd", m[0]);
  await expect("ethMinter", "imd", m[0]);
  await expect("ethMinter", "poolManager", e[1]);
  await expect("ethMinter", "quoter", e[2]);
  await expect("ethMinter", "fee", e[3]);
  await expect("ethMinter", "tickSpacing", e[4]);
  console.log(`code matches this build; dev ${await read("machine", "dev")}${dev ? " (as expected)" : " (pass --dev to require it)"}; minting opens ${new Date(Number(deployedAt + delay) * 1000).toISOString()}`);
}

writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n");
console.log(`manifest: ${out}${check ? " (checked on chain)" : ""}`);
