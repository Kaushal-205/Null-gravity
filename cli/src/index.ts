#!/usr/bin/env node
/**
 * Null-Gravity Bridge CLI
 * 
 * Commands for interacting with the Zcash-Aztec Bridge:
 * - deposit: Send ZEC to the bridge vault
 * - claim: Claim zZEC on Aztec
 * - withdraw: Exit zZEC back to Zcash
 * - status: Check bridge status
 */

import { Command } from 'commander';
import { depositCommand } from './deposit.js';
import { claimCommand } from './claim.js';
import { withdrawCommand } from './withdraw.js';
import { statusCommand } from './status.js';
import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

const program = new Command();

program
  .name('bridge')
  .description('CLI for the Zcash-Aztec Bridge (Null-Gravity)')
  .version('0.1.0');

// Register commands
program.addCommand(depositCommand);
program.addCommand(claimCommand);
program.addCommand(withdrawCommand);
program.addCommand(statusCommand);

// Parse arguments
program.parse(process.argv);

// Show help if no command provided
if (!process.argv.slice(2).length) {
  program.outputHelp();
}
