#[account_contract]

mod Multisig {

    use starknet::ContractAddress;
    use starknet::get_tx_info;
    use starknet::get_caller_address;
    use starknet::call_contract_syscall;
    use starknet::VALIDATED;
    use starknet::contract_address_try_from_felt252;
    use starknet::contract_address_to_felt252;
    use zeroable::Zeroable;
    use ecdsa::check_ecdsa_signature;
    use array::ArrayTrait;
    use array::SpanTrait;
    use option::OptionTrait;
    use traits::TryInto;
    use traits::Into;
    use box::BoxTrait;
    use serde::Serde;
    // use serde::ArraySerde;

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
        
        assert(_confirmations > 2, 'invalid confirmations');

        assert (_confirmations <= _owners.len(), 'invalid confirmations');
        
        num_confirmations_required::write(_confirmations);
        // TODO: Loop through owners to ensure no duplicates, zero addresses(are they in Cairo?) etc

        let mut multisig_owners = _owners;
        loop {

            match multisig_owners.pop_front() {
                Option::Some(owner) => {
                    //TODO: is it possible to check it is not zero address?
                    // assert(!owner.is_zero(), 'zero address!');
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
        assert(is_owner::read(caller), 'not an owner!');

        //confirm transaction exist
        //GO OVER CONVERSION BETWEEN FELT252 AND U8
        let prev: u32 = prev_tx::read().try_into().unwrap();
        assert(tx_index.try_into().unwrap() <= prev, 'tx does not exist');

        //check the caller has not confirmed the transaction
        // assert(has_confirmed::read((caller, tx_index)) != true, 'not confirmed!');
        let status: bool = has_confirmed::read((caller, tx_index));
        assert(status != true, 'already confirmed tx');

        //read the transaction from storage
        let Transaction{to, selector, confirmations, calldata, executed} = tx_info::read(tx_index);          

        let new_confirmations = confirmations + 1;

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
        assert(is_owner::read(caller), 'not an owner!');

        //assert transaction is valid/exists
        let prev: u8 = prev_tx::read().try_into().unwrap();
        assert(txId.try_into().unwrap() <= prev, 'tx does not exist'); 

        //read the transaction from storage
        let Transaction {to, selector, confirmations, calldata, executed} = tx_info::read(txId);

        // require confirmations above minimum required
        assert(confirmations >= num_confirmations_required::read(), 'max confirmations required');  

        // confirm tx not executed
        assert(executed == false, 'tx executed already!');

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
        let Transaction {to, selector, confirmations, calldata, executed } = tx_info::read(tx_index);    
        
        let status: bool = has_confirmed::read((caller, tx_index));
        assert(status == true, 'not confirmed');

        //turn the transaction confirmation false 
        has_confirmed::write((caller, tx_index), false);

        let new_confirmations = confirmations - 1;

        RevokeTransaction(caller, tx_index);

        return new_confirmations;         
    }

    ////validate_declare__ validates account declare tx - enforces fee payment
    #[external]
    fn __validate_declare__(class_hash: felt252) -> felt252 {
        let caller = get_caller_address();
        let _public_key = owners_pub_keys::read(caller);

        validate_transaction(_public_key)
    }

    // __validate_deploy__ validates account deploy tx
    #[external]
    fn __validate_deploy__(class_hash: felt252, contract_address_salt: felt252, _public_key: felt252) -> felt252 {
        validate_transaction(_public_key)
    }

     // __validate__ validates a tx before execution
    #[external]
    fn __validate__(contract_address: ContractAddress, entry_point_selector: felt252, calldata: Array<felt252>) -> felt252 {
        let caller = get_caller_address();
        let _public_key = owners_pub_keys::read(caller);
        validate_transaction(_public_key)
    }

    // validate_transaction internal function that checks transaction signature is valid
    fn validate_transaction(_public_key: felt252) -> felt252 {
        let tx_info = get_tx_info().unbox();
        let signature = tx_info.signature;
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

    // impl TransactionStorageAccess of StorageAccess::<Transaction> {
    //     fn write(address_domain: u32, base: StorageBaseAddress, value: Transaction) -> SyscallResult::<()> {
    //         storage_write_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 0_u8),
    //             contract_address_to_felt252(value.to)            
    //         );
    //         storage_write_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 1_u8),
    //             value.selector
    //         );
    //         let mut calldata_span = value.calldata.span();
    //         storage_write_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 2_u8),
    //             Serde::deserialize(ref calldata_span).unwrap()
    //         );
    //         storage_write_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 3_u8),
    //             value.confirmations.into()
    //         );
    //         let executed_base = storage_base_address_from_felt252(storage_address_from_base_and_offset(base, 4_u8).into());
    //         StorageAccess::write(address_domain, executed_base, value.executed);            
    //     }

    //     fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Transaction> {
    //         let to_result = storage_read_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 1_u8)
    //         )?;

    //         let selector_result = storage_read_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 2_u8)
    //         )?;

    //         let calldata_result = storage_read_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 3_u8)
    //         )?;

    //         let confirmations_result = storage_read_syscall(
    //             address_domain,
    //             storage_address_from_base_and_offset(base, 4_u8)
    //         )?;

    //         let executed_base = storage_base_address_from_felt252(storage_address_from_base_and_offset(base, 5_u8).into());
    //         let executed_result: bool = StorageAccess::read(address_domain, executed_base)?;

    //         let mut calldata_arr = ArrayTrait::new();
    //         calldata_result.serialize(ref calldata_arr);

    //         Result::Ok(
    //             Transaction {
    //                 to: contract_address_try_from_felt252(to_result).unwrap(),
    //                 selector: selector_result,
    //                 confirmations: confirmations_result.try_into().unwrap(),
    //                 calldata: calldata_arr,
    //                 executed: executed_result
    //             }
    //         )
    //     }       

    // }

    impl SerdeImpl of Serde::<Span<felt252>> {
        fn serialize(self: @Span<felt252>){
            
        }
        fn deserialize(){}

    }

    impl TransactionStorageAccess of StorageAccess::<Transaction> {
        fn write(address_domain: u32, base: StorageBaseAddress, value: Transaction) -> SyscallResult::<()> {
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 0_u8),
                contract_address_to_felt252(value.to)
            );
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 1_u8),
                value.selector
            );
            let mut calldata_span = value.calldata.span();
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 2_u8),
                Serde::deserialize(ref calldata_span).unwrap()
            );
            storage_write_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 3_u8),
                value.confirmations.into()
            );
            let executed_base = storage_base_address_from_felt252(storage_address_from_base_and_offset(base, 4_u8).into());
            StorageAccess::write(address_domain, executed_base, value.executed)
        }

        fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Transaction> {
            let to_result = storage_read_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 1_u8)
            )?;

            let selector_result = storage_read_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 2_u8)
            )?;

            let calldata_result = storage_read_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 3_u8)
            )?;

            let confirmations_result = storage_read_syscall(
                address_domain,
                storage_address_from_base_and_offset(base, 4_u8)
            )?;

            let executed_base = storage_base_address_from_felt252(storage_address_from_base_and_offset(base, 5_u8).into());
            let executed_result: bool = StorageAccess::read(address_domain, executed_base)?;

            let mut calldata_arr = ArrayTrait::new();
            calldata_result.serialize(ref calldata_arr);

            Result::Ok(
                // Call {
                //     to: contract_address_try_from_felt252(to_result).unwrap(),
                //     selector: selector_result,
                //     calldata: calldata_arr,
                //     confirmations: confirmations_result.try_into().unwrap(),
                //     executed: executed_result
                // }
            

                Transaction {
                        to: contract_address_try_from_felt252(to_result).unwrap(),
                        selector: selector_result,
                        confirmations: confirmations_result.try_into().unwrap(),
                        calldata: calldata_arr,
                        executed: executed_result
                }
            )
        }
    }

}