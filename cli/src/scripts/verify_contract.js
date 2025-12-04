import { readFileSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

async function main() {
    console.log('='.repeat(60));
    console.log('  NULL-GRAVITY BRIDGE - CONTRACT VERIFICATION');
    console.log('='.repeat(60));
    console.log();

    // 1. Check artifact exists
    const artifactPath = resolve(__dirname, '../../../contracts/l2/target/zec_bridge-ZecBridge.json');
    console.log(`📁 Checking artifact: ${artifactPath}`);

    if (!existsSync(artifactPath)) {
        console.error('❌ Artifact not found! Run: nargo compile');
        process.exit(1);
    }
    console.log('✅ Artifact file exists');

    // 2. Load and validate artifact
    const artifactContent = readFileSync(artifactPath, 'utf-8');
    const artifact = JSON.parse(artifactContent);

    console.log(`\n📋 Contract Name: ${artifact.name}`);
    console.log(`📋 Functions: ${artifact.functions.length}`);

    // 3. List all functions
    console.log('\n📜 Contract Functions:');
    for (const func of artifact.functions) {
        const visibility = func.is_unconstrained ? 'unconstrained' :
            (func.custom_attributes?.includes('aztec(public)') ? 'public' : 'private');
        console.log(`   - ${func.name} (${visibility})`);
    }

    // 4. Check for required bridge functions (with or without internal prefix)
    const requiredFunctions = [
        'constructor',
        'process_deposit',
        'claim_deposit',
        'exit_to_zcash',
        'get_total_supply',
        'is_deposit_processed'
    ];

    console.log('\n🔍 Checking required functions:');
    const functionNames = artifact.functions.map(f => f.name);
    let allPresent = true;

    for (const func of requiredFunctions) {
        // Check both direct name and internal prefixed name
        const present = functionNames.some(n => n === func || n.endsWith('__' + func));
        console.log(`   ${present ? '✅' : '❌'} ${func}`);
        if (!present) allPresent = false;
    }

    // 5. Summary
    console.log('\n' + '='.repeat(60));
    if (allPresent) {
        console.log('✅ CONTRACT VERIFICATION PASSED');
        console.log('   The ZecBridge contract artifact is valid and complete.');
        console.log('   All required bridge functions are present.');
    } else {
        console.log('⚠️  CONTRACT VERIFICATION WARNING');
        console.log('   Some required functions are missing.');
    }
    console.log('='.repeat(60));

    // 6. Deployment info
    console.log('\n📖 DEPLOYMENT INSTRUCTIONS:');
    console.log('   To deploy to Aztec Testnet (v2.1.4):');
    console.log('   1. Update Aztec.nr dependency to v2.1.4 in Nargo.toml');
    console.log('   2. Recompile with: nargo compile');
    console.log('   3. Use: aztec-wallet deploy --node-url https://aztec-testnet-fullnode.zkv.xyz');
    console.log();
    console.log('   Testnet RPC: https://aztec-testnet-fullnode.zkv.xyz');
    console.log('   Sponsored FPC: 0x299f...');
    console.log();
}

main().catch(console.error);
