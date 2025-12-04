// ZecBridge - Zcash-Aztec Bridge L2 Contract

use dep::aztec::macros::aztec;

#[aztec]
contract ZecBridge {
    // Explicit imports
    use dep::aztec::state_vars::{Map, PublicMutable, PublicImmutable, PrivateSet};
    use dep::aztec::protocol_types::address::{AztecAddress, EthAddress};
    use dep::aztec::protocol_types::traits::ToField;
    use dep::aztec::note::note_getter_options::NoteGetterOptions;
    use dep::uint_note::uint_note::UintNote;
    use dep::aztec::hash::{compute_secret_hash, pedersen_hash};
    use dep::aztec::macros::functions::{initializer, internal, only_self, external};
    use dep::aztec::macros::storage::storage;
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
        self.storage.admin.initialize(admin);
        self.storage.portal_address.initialize(portal);
        self.storage.total_supply.write(0 as u128);
    }

    #[external("public")]
    fn process_deposit(amount: Field, content_hash: Field) {
        let processed = self.storage.processed_deposits.at(content_hash).read();
        assert(!processed, "Deposit already processed");
        
        self.storage.processed_deposits.at(content_hash).write(true);
        
        let amount_u128 = amount as u128;
        let current_supply = self.storage.total_supply.read();
        self.storage.total_supply.write(current_supply + amount_u128);
    }

    #[external("public")]
    fn get_total_supply() -> pub Field {
        self.storage.total_supply.read() as Field
    }

    #[external("public")]
    fn is_withdrawal_pending(withdrawal_hash: Field) -> pub bool {
        self.storage.pending_withdrawals.at(withdrawal_hash).read()
    }

    #[external("public")]
    fn is_deposit_processed(content_hash: Field) -> pub bool {
        self.storage.processed_deposits.at(content_hash).read()
    }

    #[external("private")]
    fn claim_deposit(to: AztecAddress, amount: Field, secret: Field) {
        let secret_hash = compute_secret_hash(secret);
        let content_hash = pedersen_hash([amount, secret_hash], 0);
        
        let amount_u128 = amount as u128;
        let mut note = UintNote::new(amount_u128, to);
        self.storage.balances.at(to).insert(note).emit(to, MessageDelivery.UNCONSTRAINED_ONCHAIN);

        ZecBridge::at(self.context.this_address())._verify_deposit_processed(content_hash).enqueue(self.context);
    }

    #[external("private")]
    fn transfer(from: AztecAddress, to: AztecAddress, amount: Field) {
        let amount_u128 = amount as u128;

        let options: NoteGetterOptions<UintNote, 2, Field, Field> = NoteGetterOptions::new().set_limit(MAX_NOTES_PER_PAGE);
        let notes = self.storage.balances.at(from).pop_notes(options);

        let mut total = 0 as u128;
        for i in 0..MAX_NOTES_PER_PAGE {
            if i < notes.len() {
                total += notes.get(i).get_value();
            }
        }

        assert(total >= amount_u128, "Insufficient balance");

        let mut to_note = UintNote::new(amount_u128, to);
        self.storage.balances.at(to).insert(to_note).emit(to, MessageDelivery.UNCONSTRAINED_ONCHAIN);

        let change = total - amount_u128;
        if change > 0 as u128 {
            let mut change_note = UintNote::new(change, from);
            self.storage.balances.at(from).insert(change_note).emit(from, MessageDelivery.UNCONSTRAINED_ONCHAIN);
        }
    }

    #[external("private")]
    fn exit_to_zcash(amount: Field, zcash_address: Field) {
        let caller = self.context.msg_sender().unwrap();
        let amount_u128 = amount as u128;

        let options: NoteGetterOptions<UintNote, 2, Field, Field> = NoteGetterOptions::new().set_limit(MAX_NOTES_PER_PAGE);
        let notes = self.storage.balances.at(caller).pop_notes(options);

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
            self.storage.balances.at(caller).insert(change_note).emit(caller, MessageDelivery.UNCONSTRAINED_ONCHAIN);
        }

        let caller_field = caller.to_field();
        let withdrawal_hash = pedersen_hash([amount, zcash_address, caller_field], 0);
        let _content = pedersen_hash([amount, zcash_address, withdrawal_hash], 0);

        ZecBridge::at(self.context.this_address())._finalize_exit(amount, withdrawal_hash).enqueue(self.context);
    }

    #[external("public")]
    #[only_self]
    fn _verify_deposit_processed(content_hash: Field) {
        let processed = self.storage.processed_deposits.at(content_hash).read();
        assert(processed, "Deposit not processed");
    }

    #[external("public")]
    #[only_self]
    fn _finalize_exit(amount: Field, withdrawal_hash: Field) {
        let amount_u128 = amount as u128;
        let current_supply = self.storage.total_supply.read();
        assert(current_supply >= amount_u128, "Insufficient total supply");
        self.storage.total_supply.write(current_supply - amount_u128);
        
        self.storage.pending_withdrawals.at(withdrawal_hash).write(true);
    }

    /*
    mod test {
        use crate::ZecBridge;
        use dep::aztec::test::helpers::test_environment::TestEnvironment;
        use dep::aztec::protocol_types::address::{AztecAddress, EthAddress};

        #[test]
        unconstrained fn test_deployment() {
            let mut env = TestEnvironment::new();
            let admin = env.create_light_account();
            let portal = EthAddress::from_field(0x12345678);
            
            let initializer = ZecBridge::interface().constructor(admin, portal);
            let _contract_address = env.deploy("ZecBridge").with_public_initializer(admin, initializer);
        }
    }
    */
}
