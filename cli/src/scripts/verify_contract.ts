import {
    createPXEClient,
    waitForPXE,
    AccountManager,
    Schnorr,
    AztecAddress,
    EthAddress,
    Fr,
    GrumpkinScalar,
    Contract,
    ContractDeployer,
    Note
} from '@aztec/aztec.js';
import { readFileSync } from 'fs';
import { resolve } from 'path';

async function main() {
    const pxeUrl = 'http://localhost:8080';
    const pxe = createPXEClient(pxeUrl);

    console.log('Connecting to sandbox...');
    await waitForPXE(pxe);

    console.log('Creating admin account...');
    const secretKey = Fr.random();
    const signingKey = GrumpkinScalar.random();
    const accountContract = new Schnorr(signingKey);
    const account = new AccountManager(pxe, secretKey, accountContract);

    // Deploy account
    const admin = await account.waitDeploy();
    console.log(`Connected.Admin: ${admin.getAddress().toString()} `);

    // Load contract artifact
    const artifactPath = resolve(__dirname, '../../../contracts/l2/target/zec_bridge.json');
    const artifact = JSON.parse(readFileSync(artifactPath, 'utf-8'));

    console.log('Deploying ZecBridge contract...');
    const portalAddress = EthAddress.random();

    // Deploy
    const deployer = new ContractDeployer(artifact, admin);
    const deployTx = deployer.deploy(admin.getAddress(), portalAddress);
    const contract = await deployTx.send().deployed();

    console.log(`Contract deployed at: ${contract.address.toString()} `);

    // 1. Process Deposit (Public)
    console.log('\n--- Testing process_deposit ---');
    const amount = 100n;
    const contentHash = Fr.random();

    await contract.methods.process_deposit(amount, contentHash).send().wait();
    console.log('Deposit processed successfully');

    const isProcessed = await contract.methods.is_deposit_processed(contentHash).simulate();
    console.log(`Is deposit processed ? ${isProcessed} `);

    // 2. Claim Deposit (Private)
    // Skipped for now due to complexity of generating proofs in this script without full setup.

    // 3. Get Total Supply
    console.log('\n--- Testing get_total_supply ---');
    const totalSupply = await contract.methods.get_total_supply().simulate();
    console.log(`Total supply: ${totalSupply} `);

    console.log('\nVerification script completed.');
}

main().catch(console.error);
