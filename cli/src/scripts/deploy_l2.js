/**
 * Deploy ZecBridge contract to Aztec Sandbox (SDK 3.0.0-devnet.5)
 * Based on github.com/PraneshASP/zcash-aztec-bridge-poc
 * 
 * Usage:
 *   node src/scripts/deploy_l2.js
 */

import { createAztecNodeClient, waitForNode } from '@aztec/aztec.js/node';
import { Contract } from '@aztec/aztec.js/contracts';
import { TestWallet } from '@aztec/test-wallet/server';
import { Fr } from '@aztec/aztec.js/fields';
import { deriveSigningKey } from '@aztec/stdlib/keys';
import { EthAddress } from '@aztec/foundation/eth-address';
import { TokenContract } from '@aztec/noir-contracts.js/Token';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Note: TestWallet requires a connection to the Aztec Node, not just PXE.
// In the sandbox, the Node is usually available at the same URL or port 8080.
const PXE_URL = process.env.PXE_URL || 'http://127.0.0.1:8080';
const PORTAL_ADDRESS = process.env.PORTAL_ADDRESS || process.env.SERVICE_MANAGER_ADDRESS;

async function main() {
    if (!PORTAL_ADDRESS) {
        throw new Error('PORTAL_ADDRESS or SERVICE_MANAGER_ADDRESS env variable must be set');
    }

    console.log(`Connecting to Aztec Node at ${PXE_URL}...`);
    const node = createAztecNodeClient(PXE_URL);
    await waitForNode(node);
    console.log('Connected to Aztec Node.');

    // Create a TestWallet which spins up a local PXE connected to the Node
    const wallet = await TestWallet.create(node);

    // Use hardcoded secret to match sandbox's pre-funded account
    const secret = Fr.fromString('0x2153536ff6628eee01cf4024889d977a7c45e1561e4c5d43658f8a6c872a3b2e');
    const salt = Fr.ZERO;
    const signingKey = deriveSigningKey(secret);

    console.log('Creating Schnorr account...');
    const accountManager = await wallet.createSchnorrAccount(secret, salt, signingKey);
    let deployerWallet;
    try {
        deployerWallet = await accountManager.waitDeploy();
    } catch (e) {
        console.log('Account might be already deployed, getting wallet...');
        // If waitDeploy fails, we might need to construct the wallet manually or use the TestWallet
        // But TestWallet already has the account.
        // Let's try to use the TestWallet but with the specific account address.
        deployerWallet = wallet;
    }
    const deployerAddress = accountManager.address;
    console.log(`Deploying using account: ${deployerAddress.toString()}`);

    console.log('Waiting for account to sync...');
    // Access PXE from wallet (TestWallet exposes .pxe)
    const pxe = wallet.pxe;
    if (pxe) {
        const targetBlock = await node.getBlockNumber();
        console.log(`Target block: ${targetBlock}`);

        // Wait for a few seconds to allow PXE to sync
        console.log('Waiting 30s for PXE to sync...');
        await new Promise(resolve => setTimeout(resolve, 30000));
    } else {
        console.log('Cannot access PXE from wallet. Waiting 10s...');
        await new Promise(resolve => setTimeout(resolve, 10000));
    }

    // Deploy Token Contract first
    console.log('Deploying Token Contract...');
    // TokenContract.deploy(wallet, admin, name, symbol, decimals)
    const token = await TokenContract.deploy(deployerWallet, deployerAddress, "ZecBridge Token", "ZEC", 18)
        .send({ from: deployerAddress })
        .deployed();
    console.log(`Token deployed at: ${token.address.toString()}`);

    // Load ZecBridge artifact
    const artifactPath = path.resolve(__dirname, '../../../../contracts/l2/target/zec_bridge-ZecBridge.json');
    if (!fs.existsSync(artifactPath)) {
        throw new Error(`Artifact not found at ${artifactPath}. Run 'aztec-nargo compile' first.`);
    }
    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));

    // Deploy ZecBridge
    console.log('Deploying ZecBridge Contract...');
    const portalAddress = EthAddress.fromString(PORTAL_ADDRESS);

    // Constructor args: token: AztecAddress, portal_address: EthAddress
    // Contract.deploy(wallet, artifact, args...)
    const deployTx = Contract.deploy(deployerWallet, artifact, [token.address, portalAddress]);
    const bridge = await deployTx.send({ from: deployerAddress }).deployed();

    console.log(`ZecBridge deployed at: ${bridge.address.toString()}`);

    // Set bridge as minter on Token
    console.log('Setting bridge as minter on Token...');
    try {
        await token.methods.set_minter(bridge.address, true).send({ from: deployerAddress }).wait();
        console.log('Bridge set as minter.');
    } catch (err) {
        console.warn('Failed to set bridge as minter:', err.message);
        console.warn('You may need to set it manually.');
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
