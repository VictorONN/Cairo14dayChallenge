#[account_contract]

mod Multisig {

    use starknet::ContractAddress;
    use starknet::get_tx_info;
    use starknet::get_caller_address;
    use starknet::call_contract_syscall;
    use starknet::VALIDATED;
    use serde::Serde;
    use serde::ArraySerde;
    use ecdsa::check_ecdsa_signature;
    use array::ArrayTrait;
    use option::OptionTrait;
    use traits::TryInto;
    use traits::Into;
    use box::BoxTrait;

    use starknet::StorageAccess;
    use starknet::StorageBaseAddress;
    use starknet::SyscallResult;
    use starknet::storage_address_from_base_and_offset;
    use starknet::storage_base_address_from_felt252;
    use starknet::storage_write_syscall;
    use starknet::storage_read_syscall;


    /////Call Struct/////
    #[derive(Serde, Drop)]
    struct Transaction {
        to: ContractAddress,
        selector: felt252,
        confirmations: usize,
        calldata: Array<felt252>,
        executed: bool,
    }

    ///STORAGE VALUES///
    struct Storage {
        num_confirmations_required: usize,
        num_owners: usize,
        //keep transaction count
        prev_tx: felt252,
        is_owner: LegacyMap<ContractAddress, bool>,
        // track transactions
        tx_info: LegacyMap<felt252, Transaction>,
        // approved: LegacyMap<uint, LegacyMap<address, bool>>,
        has_confirmed: LegacyMap<(ContractAddress, felt252), bool>,
        owners_pub_keys: LegacyMap<ContractAddress, felt252>,
    }


    ////////////////////EVENTS///////////

    #[event]
    fn Deposit(sender: ContractAddress, amount: usize, balance: usize) {}

    #[event]
    fn SubmitTransaction (
        owner: ContractAddress, 
        txIndex: felt252 
        // to: ContractAddress, 
        // value: usize,
        // data: Array<felt252>
        ) {}

    #[event]
    fn ConfirmTransaction(owner: ContractAddress, txId: felt252) {}

    #[event]
    fn RevokeTransaction(owner: ContractAddress, txId: felt252) {}

    #[event]
    fn ExecuteTransaction(owner: ContractAddress, txId: felt252) {}


    #[constructor]
    fn constructor(_confirmations: usize, _owners: Array<ContractAddress> ){
        // ensure we have more than 1 owner
        assert(_owners.len() > 0, 'Owners required');
        num_owners::write(_owners.len());
        
        assert(_confirmations > 2, 'invalid number of required confirmations');

        assert (_confirmations <= _owners.len(), 'invalid number of required confirmations');
        
        num_confirmations_required::write(_confirmations);
        // TODO: Loop through owners to ensure no duplicates, zero addresses(are they in Cairo?) etc

        let mut multisig_owners = _owners;
        loop {

            match multisig_owners.pop_front() {
                Option::Some(owner) => {
                    //is it possible to check it is not zero address?
                    assert(!owner.is_zero(), 'zero address!');
                    assert(!is_owner::read(owner), 'already added!');

                    is_owner::write(owner, true);
                },
                Option::None(_) => {
                    break();
                }
            };       
        };
    }

    // called by any owner to submit a transaction
    #[external]
    fn submit_transaction(contract_address: ContractAddress, entry_point_selector: felt252, value: usize, data: Array<felt252>) {

        let caller = get_caller_address();
        assert(is_owner::read(caller), 'not an owner!');

        let transaction = Transaction {
            to: contract_address, 
            selector: entry_point_selector,
            confirmations: 0_usize, 
            calldata: data, 
            executed: false
            };
        
        let tx_id = prev_tx::read() + 1;

        // store call in tx_info
        tx_info::write(tx_id, transaction);

        // update new transaction count   
        prev_tx::write(tx_id);          

        SubmitTransaction(caller, tx_id);
        return();
    }
    

    // owner should confirm the transaction
    #[external]
    fn confirm_transaction(tx_index: felt252)  {
        let caller = get_caller_address();
        assert(is_owner(caller), 'not an owner!');

        //confirm transaction exist
        //GO OVER CONVERSION BETWEEN FELT252 AND U8
        let prev: u32 = prev_tx::read().try_into().unwrap();
        assert(tx_index <= prev, 'tx does not exist');

        //check the caller has not confirmed the transaction
        assert(has_confirmed::read((caller, tx_index)) != true, 'caller has confirmed transaction!');

        //read the transaction from storage
        let Transaction{to, selector, confirmations, calldata, executed} = tx_info::read(tx_index);

        //assert transaction is valid/exists
        assert(tx_info::read(tx_index) != 0, 'tx does not exist');       

        // require confirmations below minimum required
        assert(Transaction.confirmations < num_confirmations_required::read(), 'max confirmations required');     

        let new_confirmations = Transaction.confirmations + 1;

        let updated_call = Transaction{
            to: to, 
            selector: selector, 
            confirmations: new_confirmations, 
            calldata: calldata, 
            executed: executed
            };

        //update storage   
        tx_info::write(tx_index, updated_call);
        //confirm the transaction 
        // approved::write(tx_index, caller, true);
        has_confirmed::write((caller, tx_index), true);

        ConfirmTransaction(caller, tx_index);
        return();
    }


    // executes if confirmation threshold is achieved
    #[external]
    fn execute_transaction(txId: felt252) -> Span<felt252> {
        let caller = get_caller_address();
        assert(is_owner(caller), 'not an owner!');

        //assert transaction is valid/exists
        let prev: u8 = prev_tx::read().try_into().unwrap();
        assert(txId.try_into().unwrap() <= prev, 'tx does not exist'); 

        //read the transaction from storage
        let Transaction{to, selector, confirmations, calldata, executed} = tx_info::read(txId);

        // require confirmations above minimum required
        assert(Transaction.confirmations > num_confirmations_required::read(), 'max confirmations required');  

        // confirm tx not executed
        assert(Transaction.executed == false, 'tx executed already!');

        // make the function call using the low-level call_contract_syscall
        let retdata: Span<felt252> = call_contract_syscall(
            address: to, 
            entry_point_selector: selector, 
            calldata: calldata.span()
            ).unwrap_syscall();      

        // turn transaction executed to true 
        let updated_call = Transaction{
            to: to, 
            selector: selector, 
            confirmations: confirmations, 
            calldata: calldata, 
            executed: true
        };

        tx_info::write(txId, updated_call);

        ExecuteTransaction(caller, txId);

        retdata      
    }

    //reduce the confirmations by 1 and also turn confirmation to false
    #[external]
    fn revoke_confirmation(tx_index: felt252) -> usize {
        let caller = get_caller_address();
        assert(is_owner::read(caller), 'not an owner!');

        //read the transaction from storage
        let call = tx_info::read(tx_index);

        //assert transaction is valid/exists
        // assert(tx_info::read(tx_index) != 0_usize, 'tx does not exist');

        // require confirmations below minimum required
        assert(call.confirmations > num_confirmations_required::read(), 'max confirmations required');
        let num_confirmed = call.confirmations;       
        
        //turn the transaction confirmation false 
        has_confirmed::write((caller, tx_index), false);

        let new_confirmations = num_confirmed - 1;

        RevokeTransaction(caller, tx_index);

        return new_confirmations;         
    }

    ////validate_declare__ validates account declare tx - enforces fee payment
    #[external]
    fn __validate_declare__(classhash: felt252) -> felt252 {
        let caller = get_caller_address();
        let _public_key = owners_pub_keys::read(caller);

        validate_transaction(_public_key)
    }

    // __validate_deploy__ validates account deploy tx
    #[external]
    fn __validate_deploy__(class_hash: felt252,
                           contract_address_salt: felt252, 
                           _public_key: felt252) -> felt252 {
        validate_transaction(_public_key)
    }

    // validate_transaction internal function that checks transaction signature is valid
    fn validate_transaction(_public_key: felt252) -> felt252 {
        let tx_info = get_tx_info().unbox();
        let signature: u32 = tx_info.signature;
        assert(signature.len() == 2_u32, 'invalid signature length!');

        assert(
            check_ecdsa_signature(
                message_hash: tx_info.transaction_hash,
                public_key: _public_key,
                signature_r: *signature[0_u32],
                signature_s: *signature[1_u32],
            ),
            'invalid signature!',
        );
        VALIDATED
    }

    ////Storage Access Implementation for Transaction struct/////

    impl TransactionStorageAccess of StorageAccess::<Call> {


    }


}