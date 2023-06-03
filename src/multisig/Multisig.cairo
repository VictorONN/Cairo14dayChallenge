#[contract]

mod Multisig {

    use array::ArrayTrait;
    use starknet::get_caller_address();

    struct Storage {
        num_confirmations_required: usize,
        is_owner: LegacyMap<ContractAddress, bool>,
        // is_confirmed: LegacyMap<ContractAddress, bool>,
        //keep transaction count
        prev_tx: felt252,
        // track transactions
        tx_info: LegacyMap<felt252, Transaction>,
        // track number of confirmations for each txId
        is_transaction_confirmed: LegacyMap<txId, usize>,
        //mapping from tx index => owner => bool
        approved: LegacyMap<uint, LegacyMap<address, bool>>,
    }


    ////////////////////EVENTS

    #[event]
    fn Deposit(sender: ContractAddress, amount: usize, balance: usize) {}

    #[event]
    fn SubmitTransaction (
        owner: ContractAddress, 
        txIndex: usize, 
        to: ContractAddress, 
        value: usize,
        data: Array<felt252>) {}

    #[event]
    fn ConfirmTransaction(owner: ContractAddress, txId: usize) {}

    #[event]
    fn RevokeTransaction(owner: ContractAddress, txId: usize) {}

    #[event]
    fn ExecuteTransaction(owner: ContractAddress, txId: usize) {}


    struct Transaction {
        to: ContractAddress,
        selector: felt252,
        // value: usize,
        calldata: Array<felt252>,
        executed: bool,
    }




    #[constructor]
    fn constructor(_numConfirmationsRequired: _usize, _owners: Array<ContractAddress> ){
        // ensure we have more than 1 owner
        assert(_owners.len() > 0, 'Owners required');
        
        assert(_numConfirmationsRequired > 0, 'invalid number of required confirmations');

        assert (_numConfirmationsRequired <= _owners.len(), 'invalid number of required confirmations');
        
        // TODO: Loop through owners to ensure no duplicates, zero addresses(are they in Cairo?) etc

        let mut multisig_owners: Array<252> = _owners;
        loop {

            match multisig_owners.pop_front() {
                Option::Some(owner) => {
                    //check it is not zero address
                    assert(owner.is_not_zero(), 'zero address!')
                    assert(is_owner::read(contractAddress, false, 'already added!'))
                    is_owner::write(contractAddress, true);
                },
                Option::None(()) => {
                    break();
                }
            };       
        }
    }

    // called by any owner to submit a transaction
    #[external]
    fn submit_transaction(contract_address: ContractAddress, entry_point_selector: felt252, value: usize, data: Array<felt252>) {

        let caller = get_caller_address();
        assert(is_owner(caller), 'not an owner!');

        let transaction = Transaction {
            to: contract_address, 
            selector: entry_point_selector, 
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
    fn confirm_transaction(tx_index: usize)  {
        let caller = get_caller_address();
        assert(is_owner(caller), 'not an owner!');

        //read the transaction from storage
        let call = tx_info::read(tx_index);

        //assert transaction is valid/exists
        assert(tx_info::read(tx_index) != 0, 'tx does not exist');


        // require confirmations below minimum required
        assert(is_transaction_confirmed::read(tx_index) < num_confirmations_required, 'max confirmations required');
        let num_confirmed = is_transaction_confirmed::read(tx_index);       
        
        //confirm the transaction 
        // is_confirmed::write(tx_index, true);
        approved::write(tx_index, caller, true);

        let new_confirmations = num_confirmed + 1;

        is_transaction_confirmed::write(tx_index, new_confirmations);

        ConfirmTransaction(caller, tx_index)
        return();
    }

    #[external]
    fn execute_transaction(txId: usize) {
        let caller = get_caller_address();
        assert(is_owner(caller), 'not an owner!');

        //read no of confirmations for transaction
        assert()

        // turn transaction executed to true 

        // make the function call 


        ExecuteTransaction(caller, txId);
        return();        
    }

    //reduce the confirmations by 1 and also turn confirmation to false
    #[external]
    fn revoke_confirmation(txId: usize) -> felt252 {
        let caller = get_caller_address();
        assert(is_owner(caller), 'not an owner!');

        //confirm transaction is confirmed

        //read the transaction from storage
        let call = tx_info::read(tx_index);

        //assert transaction is valid/exists
        assert(tx_info::read(tx_index) != 0, 'tx does not exist');

        // require confirmations below minimum required
        assert(is_transaction_confirmed::read(tx_index) > num_confirmations_required, 'max confirmations required');
        let num_confirmed = is_transaction_confirmed::read(tx_index);       
        
        //turn the transaction confirmation false 
        approved::write(tx_index, caller, false);

        let new_confirmations = num_confirmed - 1;

        is_transaction_confirmed::write(tx_index, new_confirmations);

        RevokeTransaction(caller, txId);
        return();         
    }


}