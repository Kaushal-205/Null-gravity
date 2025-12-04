// ZecBridge - Zcash-Aztec Bridge L2 Contract
// Private bridge for moving ZEC between Zcash and Aztec

use dep::aztec::macros::aztec;

#[aztec]
contract ZecBridge {
    use dep::aztec::macros::{
        functions::{initializer, internal, external, view},
        storage::storage,
    };
    use dep::aztec::state_vars::{Map, PublicMutable, PublicImmutable, PrivateSet};
    use dep::aztec::protocol_types::address::{AztecAddress, EthAddress};
    use dep::aztec::protocol_types::traits::{ToField, Packable};
    use dep::aztec::note::note_getter_options::NoteGetterOptions;
    use dep::uint_note::uint_note::UintNote;
    use dep::aztec::hash::{compute_secret_hash, pedersen_hash};
    use dep::aztec::messages::message_delivery::MessageDelivery;

    global MAX_NOTES_PER_PAGE: u32 = 16;

    #[storage]
    struct Storage<Context> {
        balances: Map<AztecAddress, PrivateSet<UintNote, Context>, Context>,
        total_supply: PublicMutable<u128, Context>,
        admin: PublicImmutable<AztecAddress, Context>,
        portal_address: PublicImmutable<EthAddress, Context>,
        pending_withdrawals: Map<Field, PublicMutable<bool, Context>, Context>,
        processed_deposits: Map<Field, PublicMutable<bool, Context>, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress, portal: EthAddress) {
        assert(!admin.is_zero(), "invalid admin");
        storage.admin.initialize(admin);
        storage.portal_address.initialize(portal);
        storage.total_supply.write(0 as u128);
    }

    /// Process a deposit from L1 - called by the admin after verifying the L1 message
    #[external("public")]
    fn process_deposit(amount: Field, content_hash: Field) {
        // Access control: only admin can process deposits
        let caller = context.msg_sender();
        let admin = storage.admin.read();
        
        // msg_sender() returns AztecAddress in public functions (not Option) in some versions, 
        // but let's check if it needs unwrap. In public, it's usually just AztecAddress or we can check equality directly.
        // Actually, context.msg_sender() in public context returns AztecAddress.
        assert(caller.unwrap() == admin, "Only admin can process deposits");

        let processed = storage.processed_deposits.at(content_hash).read();
        assert(!processed, "Deposit already processed");
        
        storage.processed_deposits.at(content_hash).write(true);
        
        let amount_u128 = amount as u128;
        let current_supply = storage.total_supply.read();
        storage.total_supply.write(current_supply + amount_u128);
    }

    #[external("public")]
    #[view]
    fn get_total_supply() -> pub Field {
        storage.total_supply.read() as Field
    }

    #[external("public")]
    #[view]
    fn is_withdrawal_pending(withdrawal_hash: Field) -> pub bool {
        storage.pending_withdrawals.at(withdrawal_hash).read()
    }

    #[external("public")]
    #[view]
    fn is_deposit_processed(content_hash: Field) -> pub bool {
        storage.processed_deposits.at(content_hash).read()
    }

    #[external("public")]
    #[view]
    fn get_admin() -> pub AztecAddress {
        storage.admin.read()
    }

    #[external("public")]
    #[view]
    fn get_portal() -> pub EthAddress {
        storage.portal_address.read()
    }

    /// Claim zZEC after deposit is processed - private function
    #[external("private")]
    fn claim_deposit(to: AztecAddress, amount: Field, secret: Field) {
        let secret_hash = compute_secret_hash(secret);
        let content_hash = pedersen_hash([amount, secret_hash], 0);
        
        let amount_u128 = amount as u128;
        let mut note = UintNote::new(amount_u128, to);
        storage.balances.at(to).insert(note).emit(to, MessageDelivery.UNCONSTRAINED_ONCHAIN);

        ZecBridge::at(context.this_address())._verify_deposit_processed(content_hash).enqueue(&mut context);
    }

    /// Transfer zZEC privately between accounts
    #[external("private")]
    fn transfer(from: AztecAddress, to: AztecAddress, amount: Field) {
        let amount_u128 = amount as u128;

        let options = NoteGetterOptions::new().set_limit(MAX_NOTES_PER_PAGE);
        let notes = storage.balances.at(from).pop_notes(options);

        let mut total = 0 as u128;
        for i in 0..MAX_NOTES_PER_PAGE {
            if i < notes.len() {
                total += notes.get(i).get_value();
            }
        }

        assert(total >= amount_u128, "Insufficient balance");

        let mut to_note = UintNote::new(amount_u128, to);
        storage.balances.at(to).insert(to_note).emit(to, MessageDelivery.UNCONSTRAINED_ONCHAIN);

        let change = total - amount_u128;
        if change > 0 as u128 {
            let mut change_note = UintNote::new(change, from);
            storage.balances.at(from).insert(change_note).emit(from, MessageDelivery.UNCONSTRAINED_ONCHAIN);
        }
    }

    /// Exit zZEC back to Zcash - burns the tokens and marks withdrawal as pending
    #[external("private")]
    fn exit_to_zcash(amount: Field, zcash_address: Field) {
        let caller = context.msg_sender().unwrap();
        let amount_u128 = amount as u128;

        let options = NoteGetterOptions::new().set_limit(MAX_NOTES_PER_PAGE);
        let notes = storage.balances.at(caller).pop_notes(options);

        let mut total = 0 as u128;
        for i in 0..MAX_NOTES_PER_PAGE {
            if i < notes.len() {
                total += notes.get(i).get_value();
            }
        }

        assert(total >= amount_u128, "Insufficient balance");

        let change = total - amount_u128;
        if change > 0 as u128 {
            let mut change_note = UintNote::new(change, caller);
            storage.balances.at(caller).insert(change_note).emit(caller, MessageDelivery.UNCONSTRAINED_ONCHAIN);
        }

        let caller_field = caller.to_field();
        let withdrawal_hash = pedersen_hash([amount, zcash_address, caller_field], 0);

        ZecBridge::at(context.this_address())._finalize_exit(amount, withdrawal_hash).enqueue(&mut context);
    }

    #[external("public")]
    #[internal]
    fn _verify_deposit_processed(content_hash: Field) {
        let processed = storage.processed_deposits.at(content_hash).read();
        assert(processed, "Deposit not processed");
    }

    #[external("public")]
    #[internal]
    fn _finalize_exit(amount: Field, withdrawal_hash: Field) {
        let amount_u128 = amount as u128;
        let current_supply = storage.total_supply.read();
        assert(current_supply >= amount_u128, "Insufficient total supply");
        storage.total_supply.write(current_supply - amount_u128);
        
        storage.pending_withdrawals.at(withdrawal_hash).write(true);
    }
}
